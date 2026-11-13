pragma Ada_2022;

with Ada.Containers;
with Ada.Exceptions;
with Ada.IO_Exceptions;
with Ada.Streams;
with Ada.Strings.Fixed;
with AWS.Default;
with AWS.Net;
with AWS.Net.SSL;
with AWS.Net.SSL.Certificate;
with AWS.Net.Std;
with CryptoLib.Hashes;
with Soja.Backoff;
with Soja.Conn.Net;
with Soja.Core.Downstream_Commands;
with Soja.Core.Downstream_Handshake;
with Soja.Core.Upstream_Dispatch;
with Soja.Core.User_Events;
with Soja.Irc.Cap_Registry;
with Soja.Irc.Genmsg;
with Soja.Irc.Helpers;
with Soja.Irc.Numerics;
with Soja.Msgstore.Memory;

package body Soja.Core is

   use Soja.Logging;
   use Soja.Irc.Messages;
   use type AWS.Net.Socket_Access;
   use type Soja.Timers.Timer_Access;
   use type Soja.Msgstore.Store_Access;
   use type Ada.Containers.Count_Type;
   use type Soja.Database.Database_Access;

   ------------
   -- Signal --
   ------------

   protected body Signal is

      procedure Set is
      begin
         Set_Flag := True;
      end Set;

      function Is_Set return Boolean is
        (Set_Flag);

      entry Wait when Set_Flag is
      begin
         null;
      end Wait;

   end Signal;

   ----------------
   -- Event queue --
   ----------------

   protected body Event_Queue is

      entry Enqueue (E : Event_Access) when Count < Event_Capacity is
      begin
         Buf ((Head + Count - 1) mod Event_Capacity + 1) := E;
         Count := Count + 1;
      end Enqueue;

      entry Dequeue (E : out Event_Access; Done : out Boolean)
        when Count > 0 or else Closed
      is
      begin
         if Count > 0 then
            E := Buf (Head);
            Head := Head mod Event_Capacity + 1;
            Count := Count - 1;
            Done := False;
         else
            E := null;
            Done := True;
         end if;
      end Dequeue;

      procedure Try_Enqueue (E : Event_Access; Ok : out Boolean) is
      begin
         if Count < Event_Capacity then
            Buf ((Head + Count - 1) mod Event_Capacity + 1) := E;
            Count := Count + 1;
            Ok := True;
         else
            Ok := False;
         end if;
      end Try_Enqueue;

      procedure Close is
      begin
         Closed := True;
      end Close;

      function Is_Closed return Boolean is
        (Closed);

   end Event_Queue;

   ------------------
   --  Constructors --
   ------------------

   --  server.go's prefixLogger: wrap a base logger with a textual prefix.
   function Prefixed (Base : Logger_Access; Text : String)
      return Logger_Access
   is
   begin
      return new Prefix_Logger'
        (Base   => Base,
         Prefix => To_Unbounded_String (Text));
   end Prefixed;

   --  net.SplitHostPort's host part; the whole string when it has no port
   --  ("host:port", "[v6]:port"), as newDownstreamConn falls back to.
   function Host_Of (Addr : String) return String is
      Colons : Natural := 0;
      Last   : Natural := 0;
   begin
      if Addr'Length > 0 and then Addr (Addr'First) = '[' then
         for I in Addr'Range loop
            if Addr (I) = ']' then
               if I < Addr'Last and then Addr (I + 1) = ':' then
                  return Addr (Addr'First + 1 .. I - 1);
               end if;
               return Addr;
            end if;
         end loop;
         return Addr;
      end if;
      for I in Addr'Range loop
         if Addr (I) = ':' then
            Colons := Colons + 1;
            Last := I;
         end if;
      end loop;
      if Colons = 1 then
         return Addr (Addr'First .. Last - 1);
      end if;
      return Addr;
   end Host_Of;

   --  downstream.go's permanentDownstreamCaps: capabilities always advertised
   --  (each with an empty value string).
   type String_Access is access constant String;

   Permanent_Downstream_Caps : constant array (Positive range <>) of
     String_Access :=
     [new String'("batch"), new String'("cap-notify"),
      new String'("echo-message"), new String'("invite-notify"),
      new String'("server-time"), new String'("setname"),
      new String'("draft/pre-away"), new String'("draft/read-marker"),
      new String'("draft/no-implicit-names"),
      new String'("soju.im/account-required"),
      new String'("soju.im/bouncer-networks"),
      new String'("soju.im/bouncer-networks-notify"),
      new String'("soju.im/no-implicit-names"),
      new String'("soju.im/read"), new String'("soju.im/webpush")];

   function New_User
     (Srv : Soja.Server.Server_Access; Rec : Soja.Database.User)
      return User_Access
   is
      U : constant User_Access := new User;
   begin
      U.User_Record := Rec;
      U.Srv := Srv;
      U.Logger := Prefixed
        (Soja.Server.Logger (Srv.all),
         "user " & To_String (Rec.Username) & ": ");
      U.Events := new Event_Queue;
      U.Done := new Signal;
      declare
         Driver : constant String :=
           To_String (Soja.Server.Config (Srv.all).Msg_Store_Driver);
      begin
         if Driver = "memory" then
            U.Msg_Store := Soja.Msgstore.Memory.New_Memory_Store;
         end if;
         --  "fs" and "db": not ported yet (no history for those users).
      end;
      return U;
   end New_User;

   function New_Network
     (U : User_Access; Rec : Soja.Database.Network;
      Channels : Soja.Database.Channel_Lists.Vector) return Network_Access
   is
      Net : constant Network_Access := new Network;
      CM  : constant Kind := Case_ASCII;   --  maps start on the strictest fold
   begin
      Net.Network_Record := Rec;
      Net.User := U;
      Net.Logger := Prefixed
        (U.Logger, "network " & Soja.Database.Get_Name (Rec) & ": ");
      Net.Stopped := new Signal;
      Net.Channels := Channel_Maps.New_Map (CM);
      for Ch of Channels loop
         Net.Channels.Set (To_String (Ch.Name), new Soja.Database.Channel'(Ch));
      end loop;
      Net.Delivered := Soja.User.New_Delivered_Store (CM);
      Net.Push_Targets := Time_Maps.New_Map (CM);
      Net.Kicked := Kick_Maps.New_Map (CM);
      Net.Casemap := Case_RFC1459;   --  stdCaseMapping
      return Net;
   end New_Network;

   function New_Downstream_Conn
     (Srv : Soja.Server.Server_Access;
      IC  : not null Soja.Conn.IRC_Conn_Access;
      ID  : Long_Long_Integer) return Downstream_Conn_Access
   is
      Remote : constant String := Soja.Conn.Remote_Addr (IC.all);
      Logger : constant Logger_Access :=
        Prefixed (Soja.Server.Logger (Srv.all),
                  "downstream " & Remote & ": ");
      DC : constant Downstream_Conn_Access := new Downstream_Conn;
   begin
      DC.Conn := Soja.Conn.New_Conn
        (IC, (Logger           => Logger,
              Rate_Limit_Delay => 0.0,
              Rate_Limit_Burst => 0));
      DC.Srv := Srv;
      DC.Logger := Logger;
      DC.ID := ID;
      DC.Nick := To_Unbounded_String ("*");
      DC.Nick_CM := To_Unbounded_String ("*");
      DC.Username := To_Unbounded_String ("~u");
      DC.Hostname := To_Unbounded_String (Host_Of (Remote));
      DC.Caps := Soja.Irc.Cap_Registry.New_Registry;
      DC.Casemap := Case_ASCII;
      DC.Monitored := Flag_Maps.New_Map (Case_ASCII);
      DC.Registration := new Downstream_Registration;
      for Cap of Permanent_Downstream_Caps loop
         Soja.Irc.Cap_Registry.Set_Available (DC.Caps, Cap.all, "");
      end loop;
      Soja.Irc.Cap_Registry.Set_Available
        (DC.Caps, "sasl", Server_SASL_Mechanisms (Srv));
      --  TODO (Go): this is racy, chathistory should only be enabled after
      --  authentication, once the user's store is known to support it.
      declare
         Driver : constant String :=
           To_String (Soja.Server.Config (Srv.all).Msg_Store_Driver);
      begin
         if Driver = "fs" or else Driver = "db" then
            Soja.Irc.Cap_Registry.Set_Available
              (DC.Caps, "draft/chathistory", "");
            Soja.Irc.Cap_Registry.Set_Available
              (DC.Caps, "soju.im/search", "");
         end if;
      end;
      return DC;
   end New_Downstream_Conn;

   -----------------
   --  Event loop --
   -----------------

   --  user.go's handleEvent: dispatch on the event variant.  Every handler is
   --  a stub until the connection methods they call are ported.

   -----------------------------
   --  network/user helpers  --
   -----------------------------

   procedure For_Each_Downstream
     (Net : not null Network_Access; Process : not null Downstream_Process) is
   begin
      for DC of Net.User.Downstream_Conns loop
         if DC.Network = Net then
            Process (DC);
         end if;
      end loop;
   end For_Each_Downstream;

   function Is_Stopped (Net : not null Network_Access) return Boolean is
   begin
      return Net.Stopped.Is_Set;
   end Is_Stopped;

   procedure Stop_Network (Net : not null Network_Access) is
      UC : constant Upstream_Conn_Access := Net.Active_Conn;
   begin
      if not Is_Stopped (Net) then
         Net.Stopped.Set;
      end if;
      --  The run loop is blocked reading from the server (or dialing,
      --  registering): closing the connection wakes it up.
      if UC /= null then
         Soja.Conn.Close (UC.Conn);
      end if;
   end Stop_Network;

   function Equal_Casemap (Net : not null Network_Access; A, B : String)
      return Boolean
   is
   begin
      return Soja.Irc.Case_Mapping.Fold (Net.Casemap, A) =
             Soja.Irc.Case_Mapping.Fold (Net.Casemap, B);
   end Equal_Casemap;

   function Get_Network (U : not null User_Access; Name : String)
      return Network_Access
   is
   begin
      for Net of U.Networks loop
         if To_String (Net.Network_Record.Addr) = Name then
            return Net;
         end if;
         if Net.Network_Record.Name /= Null_Unbounded_String
           and then To_String (Net.Network_Record.Name) = Name
         then
            return Net;
         end if;
      end loop;
      return null;
   end Get_Network;

   function Get_Network_By_ID (U : not null User_Access; ID : Long_Long_Integer)
      return Network_Access
   is
   begin
      for Net of U.Networks loop
         if Net.Network_Record.ID = ID then
            return Net;
         end if;
      end loop;
      return null;
   end Get_Network_By_ID;

   --  Split "host:port" (or "[ipv6]:port") into Host and Port, defaulting the
   --  port when absent (Go's net.SplitHostPort plus each scheme's default).
   procedure Split_Host_Port
     (Addr : String; Default_Port : Positive;
      Host : out Unbounded_String; Port : out Positive)
   is
      Close : Natural;
      Colon : Natural;
   begin
      if Addr'Length > 0 and then Addr (Addr'First) = '[' then
         Close := Ada.Strings.Fixed.Index (Addr, "]");
         if Close > 0 then
            Host := To_Unbounded_String
              (Addr (Addr'First + 1 .. Close - 1));
            if Close + 2 <= Addr'Last then
               Port := Positive'Value (Addr (Close + 2 .. Addr'Last));
            else
               Port := Default_Port;
            end if;
            return;
         end if;
      end if;

      Colon := Ada.Strings.Fixed.Index (Addr, ":");
      if Colon = 0 then
         Host := To_Unbounded_String (Addr);
         Port := Default_Port;
      else
         Host := To_Unbounded_String (Addr (Addr'First .. Colon - 1));
         Port := Positive'Value (Addr (Colon + 1 .. Addr'Last));
      end if;
   end Split_Host_Port;

   --  dialTCP: a plain TCP connection to the URL's host:port.
   function Dial_TCP (U : Soja.Database.Network_URL; Default_Port : Positive)
      return AWS.Net.Socket_Access
   is
      Host : Unbounded_String;
      Port : Positive;
      Sock : constant AWS.Net.Socket_Access := AWS.Net.Socket (False);
   begin
      Split_Host_Port (To_String (U.Host), Default_Port, Host, Port);
      AWS.Net.Std.Socket_Type (Sock.all).Connect (To_String (Host), Port);
      return Sock;
   end Dial_TCP;

   --  Hex-encode one byte (lowercase, two characters).
   Hex_Digits : constant String := "0123456789abcdef";

   function Hex (B : Ada.Streams.Stream_Element) return String is
      V : constant Natural := Natural (B);
   begin
      return Hex_Digits (V / 16 + 1) & Hex_Digits (V mod 16 + 1);
   end Hex;

   function Hex_SHA256 (D : CryptoLib.Hashes.SHA256_Digest) return String is
      R : String (1 .. 64);
      J : Positive := 1;
   begin
      for I in D'Range loop
         R (J .. J + 1) := Hex (D (I));
         J := J + 2;
      end loop;
      return R;
   end Hex_SHA256;

   function Hex_SHA512 (D : CryptoLib.Hashes.SHA512_Digest) return String is
      R : String (1 .. 128);
      J : Positive := 1;
   begin
      for I in D'Range loop
         R (J .. J + 1) := Hex (D (I));
         J := J + 2;
      end loop;
      return R;
   end Hex_SHA512;

   --  certfp: verify the peer's certificate fingerprint against the configured
   --  "sha-256:..." / "sha-512:..." value.  Only the leaf certificate is
   --  checked (Go iterates the whole presented chain).
   function Verify_CertFP
     (Sock : in out AWS.Net.SSL.Socket_Type; CertFP : String) return Boolean
   is
      Col : constant Natural := Ada.Strings.Fixed.Index (CertFP, ":");
   begin
      if Col = 0 then
         return False;
      end if;

      AWS.Net.SSL.Do_Handshake (Sock);

      declare
         Cert      : constant AWS.Net.SSL.Certificate.Object :=
           AWS.Net.SSL.Certificate.Get (Sock);
         DER_Bytes : constant Ada.Streams.Stream_Element_Array :=
           AWS.Net.SSL.Certificate.DER (Cert);
         Algo      : constant String := CertFP (CertFP'First .. Col - 1);
         Want      : constant String := CertFP (Col + 1 .. CertFP'Last);
      begin
         if Algo = "sha-256" then
            return Hex_SHA256 (CryptoLib.Hashes.SHA256 (DER_Bytes)) = Want;
         elsif Algo = "sha-512" then
            return Hex_SHA512 (CryptoLib.Hashes.SHA512 (DER_Bytes)) = Want;
         else
            return False;
         end if;
      end;
   end Verify_CertFP;

   --  A TLS connection to the URL's host:port (ircs scheme).  With a certfp
   --  configured, peer verification is done manually against the fingerprint;
   --  otherwise the peer is verified against the system CA bundle.  SASL
   --  EXTERNAL (client certificate) is deferred.
   function Dial_TLS
     (Net : not null Network_Access; U : Soja.Database.Network_URL)
      return AWS.Net.Socket_Access
   is
      Host     : Unbounded_String;
      Port     : Positive;
      Plain    : AWS.Net.Socket_Access := AWS.Net.Socket (False);
      Config   : AWS.Net.SSL.Config := AWS.Net.SSL.Null_Config;
      SSL_Sock : AWS.Net.SSL.Socket_Type;
      CertFP   : constant String := To_String (Net.Network_Record.Cert_FP);
   begin
      Split_Host_Port (To_String (U.Host), 6697, Host, Port);
      AWS.Net.Std.Socket_Type (Plain.all).Connect (To_String (Host), Port);

      if CertFP /= "" then
         AWS.Net.SSL.Initialize
           (Config,
            Security_Mode     => AWS.Net.SSL.TLS_Client,
            Check_Certificate => False);
         SSL_Sock := AWS.Net.SSL.Secure_Client
           (Plain.all, Config, To_String (Host));
         AWS.Net.Free (Plain);
         if not Verify_CertFP (SSL_Sock, CertFP) then
            Net.Logger.Print
              ("TLS certificate fingerprint doesn't match for "
               & To_String (Host));
            --  One-way close_notify, matching Go's tls.Client teardown on
            --  error (a bidirectional shutdown would wait for the peer).
            SSL_Sock.Shutdown (AWS.Net.Shut_Write);
            return null;
         end if;
      else
         AWS.Net.SSL.Initialize
           (Config,
            Security_Mode       => AWS.Net.SSL.TLS_Client,
            Check_Certificate   => True,
            Trusted_CA_Filename => AWS.Default.Trusted_CA);
         SSL_Sock := AWS.Net.SSL.Secure_Client
           (Plain.all, Config, To_String (Host));
         AWS.Net.Free (Plain);
      end if;

      return new AWS.Net.SSL.Socket_Type'(SSL_Sock);
   end Dial_TLS;

   --  connectToUpstream: dial the upstream, wrap it as an ircConn + conn, and
   --  build the upstreamConn.  SASL EXTERNAL certificate handling and the
   --  unix-socket schemes are deferred.
   function Connect_To_Upstream (Net : not null Network_Access)
      return Upstream_Conn_Access
   is
      U      : constant Soja.Database.Network_URL :=
        Soja.Database.URL (Net.Network_Record);
      Scheme : constant String := To_String (U.Scheme);
      Logger : constant Logger_Access := Prefixed
        (Net.User.Logger,
         "upstream " & Soja.Database.Get_Name (Net.Network_Record) & ": ");
      Sock   : AWS.Net.Socket_Access;
      IC     : Soja.Conn.IRC_Conn_Access;
   begin
      if Scheme = "ircs" then
         Sock := Dial_TLS (Net, U);
      elsif Scheme = "irc+insecure" then
         Sock := Dial_TCP (U, 6667);
      elsif Scheme = "irc+unix" or else Scheme = "unix" then
         Net.Logger.Print
           ("upstream unix-socket scheme not yet ported: " & Scheme);
         return null;
      else
         Net.Logger.Print
           ("failed to dial: unknown scheme " & Scheme);
         return null;
      end if;

      if Sock = null then
         return null;
      end if;

      IC := new Soja.Conn.Net.Net_IRC_Conn'(Soja.Conn.Net.Create (Sock));

      return Upc : constant Upstream_Conn_Access := new Upstream_Conn do
         Upc.Conn := Soja.Conn.New_Conn
           (IC, (Logger           => Logger,
                 Rate_Limit_Delay => Soja.Server.Upstream_Message_Delay,
                 Rate_Limit_Burst => Soja.Server.Upstream_Message_Burst));
         Upc.Srv := Net.User.Srv;
         Upc.Logger := Logger;
         Upc.Network := Net;
         Upc.User := Net.User;
         Upc.Channels := Upstream_Channel_Maps.New_Map (Case_RFC1459);
         Upc.Users := Upstream_User_Maps.New_Map (Case_RFC1459);
         Upc.Caps := Soja.Irc.Cap_Registry.New_Registry;
         Upc.Server_Prefix := new Soja.Irc.Messages.Prefix'
           (Name => To_Unbounded_String ("*"), others => <>);
         Upc.Available_Channel_Types :=
           To_Unbounded_String (Soja.Irc.Members.Std_Channel_Types);
         Upc.Available_Memberships :=
           Soja.Irc.Members.Membership_Vectors.Empty_Vector;
         for M of Soja.Irc.Members.Std_Memberships loop
            Upc.Available_Memberships.Append (M);
         end loop;
         Upc.Available_Channel_Modes := Soja.Irc.Modes.Std_Channel_Modes;
         Upc.Monitored := Flag_Maps.New_Map (Case_RFC1459);
         Upc.Join_Retries := Join_Retry_Maps.New_Map (Case_RFC1459);
         Upc.Has_Desired_Nick := True;
      end return;
   end Connect_To_Upstream;

   ---------------------------
   --  Upstream connection --
   ---------------------------

   --  A bare message with a command and params (no prefix/tags).
   function Make_Message (Command : String; P : Param_Vectors.Vector)
      return Soja.Irc.Messages.Message
   is
      M : Soja.Irc.Messages.Message := (others => <>);
   begin
      M.Command := To_Unbounded_String (Command);
      M.Params := P;
      return M;
   end Make_Message;

   function Read_Message (UC : not null Upstream_Conn_Access)
      return Soja.Irc.Messages.Message is
   begin
      return Soja.Conn.Read_Message (UC.Conn);
   end Read_Message;

   procedure Send_Message (UC : not null Upstream_Conn_Access;
      M : Soja.Irc.Messages.Message)
   is
      Msg : Soja.Irc.Messages.Message := M;
   begin
      if not Soja.Irc.Cap_Registry.Is_Enabled (UC.Caps, "message-tags") then
         Msg.Tags := (others => <>);
      end if;
      Soja.Conn.Send_Message (UC.Conn, Msg);
   end Send_Message;

   procedure Register (UC : not null Upstream_Conn_Access) is
      P : Param_Vectors.Vector;
   begin
      UC.Nick := To_Unbounded_String
        (Soja.Database.Get_Nick
           (UC.User.User_Record, UC.Network.Network_Record));
      UC.Username := To_Unbounded_String
        (Soja.Database.Get_Username
           (UC.User.User_Record, UC.Network.Network_Record));
      UC.Realname := To_Unbounded_String
        (Soja.Database.Get_Realname
           (UC.User.User_Record, UC.Network.Network_Record));

      P.Append (To_Unbounded_String ("LS"));
      P.Append (To_Unbounded_String ("302"));
      Send_Message (UC, Make_Message ("CAP", P));

      if UC.Network.Network_Record.Pass /= Null_Unbounded_String then
         P.Clear;
         P.Append (UC.Network.Network_Record.Pass);
         Send_Message (UC, Make_Message ("PASS", P));
      end if;

      P.Clear;
      P.Append (UC.Nick);
      Send_Message (UC, Make_Message ("NICK", P));

      P.Clear;
      P.Append (UC.Username);
      P.Append (To_Unbounded_String ("0"));
      P.Append (To_Unbounded_String ("*"));
      P.Append (UC.Realname);
      Send_Message (UC, Make_Message ("USER", P));
   end Register;

   --  The outcome of handling one message during registration.
   function Run_Until_Registered (UC : not null Upstream_Conn_Access)
      return Registration_Result
   is
      M : Message;
      R : Handle_Result;
   begin
      loop
         exit when UC.Registered;
         begin
            M := Read_Message (UC);
         exception
            when Ada.IO_Exceptions.End_Error | AWS.Net.Socket_Error =>
               return (Success   => False,
                       Reason    => To_Unbounded_String
                         ("failed to read message"),
                       Temporary => True);
         end;
         R := Soja.Core.Upstream_Dispatch.Handle_Message (UC, M);
         if R.Failed then
            if R.Is_Registration_Error then
               return (Success => False, Reason => R.Reason,
                       Temporary => R.Temporary);
            end if;
            --  Message tags are dropped so they don't clutter the log.
            M.Tags := (others => <>);
            return (Success   => False,
                    Reason    => To_Unbounded_String
                      ("failed to handle message "
                       & Soja.Irc.Helpers.Quote (Image (M)) & ": "
                       & To_String (R.Reason)),
                    Temporary => True);
         end if;
      end loop;

      for Command of UC.Network.Network_Record.Connect_Commands loop
         begin
            Send_Message (UC, Parse_Message (To_String (Command)));
         exception
            when E : Parse_Error =>
               UC.Logger.Print
                 ("failed to parse connect command "
                  & Soja.Irc.Helpers.Quote (To_String (Command)) & ": "
                  & Ada.Exceptions.Exception_Message (E));
         end;
      end loop;

      return (Success => True, Reason => Null_Unbounded_String,
              Temporary => True);
   end Run_Until_Registered;

   --  uc.readMessages: forward each upstream message to the user's event queue.
   procedure Read_Messages (UC : not null Upstream_Conn_Access;
      Events : not null Event_Queue_Access)
   is
      M : Message;
   begin
      loop
         begin
            M := Read_Message (UC);
         exception
            when Ada.IO_Exceptions.End_Error | AWS.Net.Socket_Error =>
               exit;
         end;
         Events.Enqueue (new Upstream_Message_Event'(Msg => M, UC => UC));
      end loop;
   end Read_Messages;

   function Run_Conn (Net : not null Network_Access) return Run_Conn_Error is
      UC : constant Upstream_Conn_Access := Connect_To_Upstream (Net);
      RR : Registration_Result;
   begin
      if UC = null then
         return (Text => To_Unbounded_String ("failed to connect"),
                 Temporary => True);
      end if;

      Net.Active_Conn := UC;
      if Is_Stopped (Net) then
         Soja.Conn.Close (UC.Conn);   --  stopped while dialing
      end if;

      Register (UC);

      RR := Run_Until_Registered (UC);
      if not RR.Success then
         Soja.Conn.Close (UC.Conn);
         Net.Active_Conn := null;
         return (Text => To_Unbounded_String
                   ("failed to register: " & To_String (RR.Reason)),
                 Temporary => RR.Temporary);
      end if;

      --  (The user's loop sets Net.Conn when it handles this event.)
      Net.User.Events.Enqueue (new Upstream_Connected_Event'(UC => UC));

      Read_Messages (UC, Net.User.Events);

      Net.User.Events.Enqueue (new Upstream_Disconnected_Event'(UC => UC));
      Soja.Conn.Close (UC.Conn);
      Net.Active_Conn := null;
      return (Text => Null_Unbounded_String, Temporary => True);
   end Run_Conn;

   ---------------------------
   --  Downstream connection --
   ---------------------------

   procedure Send_Message (DC : not null Downstream_Conn_Access;
      M : Message)
   is
      use Soja.Irc.Cap_Registry;

      Msg : Message := Copy (M);
      Cmd : constant String := To_String (M.Command);
   begin
      if not Is_Enabled (DC.Caps, "message-tags") then
         if Cmd = "TAGMSG" then
            return;
         end if;

         --  Without message-tags, only the tags backed by an enabled
         --  capability survive.
         declare
            Names : Soja.Irc.Genmsg.String_Vectors.Vector;
         begin
            for C in Msg.Tags.Data.Iterate loop
               Names.Append (Tag_Maps.Key (C));
            end loop;
            for Name of Names loop
               if not ((Name = "time"
                        and then Is_Enabled (DC.Caps, "server-time"))
                       or else (Name = "account"
                                and then Is_Enabled (DC.Caps, "account-tag"))
                       or else (Name = "batch"
                                and then Is_Enabled (DC.Caps, "batch")))
               then
                  Msg.Tags.Data.Exclude (Name);
               end if;
            end loop;
         end;
      end if;

      if not Is_Enabled (DC.Caps, "batch")
        and then Get_Tag (Msg.Tags, "batch") /= ""
      then
         Msg.Tags.Data.Exclude ("batch");
      end if;

      if Cmd = "JOIN" and then not Is_Enabled (DC.Caps, "extended-join")
        and then Msg.Params.Length > 1
      then
         Msg.Params.Set_Length (1);
      end if;

      if (Cmd = "SETNAME" and then not Is_Enabled (DC.Caps, "setname"))
        or else (Cmd = "CHGHOST" and then not Is_Enabled (DC.Caps, "chghost"))
        or else (Cmd = "AWAY" and then not Is_Enabled (DC.Caps, "away-notify"))
        or else (Cmd = "ACCOUNT"
                 and then not Is_Enabled (DC.Caps, "account-notify"))
        or else (Cmd = "MARKREAD"
                 and then not Is_Enabled (DC.Caps, "draft/read-marker"))
        or else (Cmd = "READ"
                 and then not Is_Enabled (DC.Caps, "soju.im/read"))
      then
         return;
      end if;

      if Msg.Prefix /= null and then To_String (Msg.Prefix.Name) = "*" then
         --  "*" is a sentinel value used to simplify upstream message
         --  handling.
         Msg.Prefix := null;
      end if;
      if Msg.Prefix = null and then Soja.Irc.Helpers.Is_Numeric (Cmd) then
         --  Numerics must always carry a source.
         Msg.Prefix := Server_Prefix (DC.Srv);
      end if;

      Soja.Conn.Send_Message (DC.Conn, Msg);
   end Send_Message;

   function Handle_Message_Unregistered
     (DC : not null Downstream_Conn_Access; M : Message)
      return Irc_Error_Result
   is
   begin
      return Soja.Core.Downstream_Handshake.Handle_Message_Unregistered (DC, M);
   end Handle_Message_Unregistered;

   function Register_Downstream (DC : not null Downstream_Conn_Access)
      return Irc_Error_Result
   is
   begin
      return Soja.Core.Downstream_Handshake.Register (DC);
   end Register_Downstream;

   function Run_Until_Registered_Downstream
     (DC : not null Downstream_Conn_Access) return Boolean
   is
   begin
      return Soja.Core.Downstream_Handshake.Run_Until_Registered (DC);
   end Run_Until_Registered_Downstream;

   --  One task per network (Go's `go network.run()`).
   task type Network_Task (Net : not null Network_Access);
   task body Network_Task is
   begin
      Run_Network (Net);
   end Network_Task;
   type Network_Task_Access is access Network_Task;

   procedure Spawn_Network (Net : not null Network_Access) is
      T : Network_Task_Access := new Network_Task (Net);
      pragma Unreferenced (T);
   begin
      null;
   end Spawn_Network;

   --  Sort a network slice by ID (Go's sort.Slice over u.srv.db.ListNetworks).
   procedure Sort_By_ID (V : in out Soja.Database.Network_Lists.Vector) is
   begin
      for I in 1 .. Natural (V.Length) loop
         for J in reverse 2 .. I loop
            if V.Element (J - 1).ID > V.Element (J).ID then
               declare
                  Tmp : constant Soja.Database.Network := V.Element (J - 1);
               begin
                  V.Replace_Element (J - 1, V.Element (J));
                  V.Replace_Element (J, Tmp);
               end;
            end if;
         end loop;
      end loop;
   end Sort_By_ID;

   ----------------------------
   -- Server_SASL_Mechanisms --
   ----------------------------

   function Server_SASL_Mechanisms (Srv : Soja.Server.Server_Access)
      return String
   is
      Driver : constant String :=
        To_String (Soja.Server.Config (Srv.all).Auth_Driver);
   begin
      if Driver = "oauth2" then
         return "PLAIN,OAUTHBEARER";
      elsif Driver = "internal" or else Driver = "pam" then
         return "PLAIN";
      end if;
      return "";
   end Server_SASL_Mechanisms;

   ----------------------------------------
   -- upstreamChannel and its timers --
   ----------------------------------------

   ----------------------------------------------------------------------
   -- Server prefix, downstream snapshots, casemapping, SASL auto-save --
   ----------------------------------------------------------------------

   function Server_Prefix (Srv : Soja.Server.Server_Access)
      return Soja.Irc.Messages.Prefix_Access
   is
   begin
      return new Soja.Irc.Messages.Prefix'
        (Name => Soja.Server.Config (Srv.all).Hostname, others => <>);
   end Server_Prefix;

   function Downstreams (Net : not null Network_Access)
      return Downstream_Conn_Vectors.Vector
   is
      Result : Downstream_Conn_Vectors.Vector;
   begin
      for DC of Net.User.Downstream_Conns loop
         if DC.Network = Net then
            Result.Append (DC);
         end if;
      end loop;
      return Result;
   end Downstreams;

   procedure Update_Casemapping (DC : not null Downstream_Conn_Access) is
      CM : Kind := Case_ASCII;
   begin
      if DC.Network /= null then
         CM := DC.Network.Casemap;
      end if;
      DC.Casemap := CM;
      DC.Nick_CM := To_Unbounded_String (Fold (CM, To_String (DC.Nick)));
      DC.Monitored.Set_Case_Mapping (CM);
   end Update_Casemapping;

   procedure Update_Casemapping
     (Net : not null Network_Access; CM : Soja.Irc.Case_Mapping.Kind)
   is
   begin
      Net.Casemap := CM;
      Net.Channels.Set_Case_Mapping (CM);
      Soja.User.Set_Case_Mapping (Net.Delivered, CM);
      Net.Push_Targets.Set_Case_Mapping (CM);
      Net.Kicked.Set_Case_Mapping (CM);

      if Net.Conn /= null then
         declare
            UC : constant Upstream_Conn_Access := Net.Conn;

            procedure Set_Members
              (Name : String; Ch : Upstream_Channel_Access)
            is
               pragma Unreferenced (Name);
            begin
               Ch.Members.Set_Case_Mapping (CM);
            end Set_Members;
         begin
            UC.Channels.Set_Case_Mapping (CM);
            UC.Channels.For_Each (Set_Members'Access);
            UC.Users.Set_Case_Mapping (CM);
            UC.Monitored.Set_Case_Mapping (CM);
            UC.Join_Retries.Set_Case_Mapping (CM);
         end;
      end if;

      for DC of Downstreams (Net) loop
         Update_Casemapping (DC);
      end loop;
   end Update_Casemapping;

   procedure Auto_Save_SASL_Plain
     (Net : not null Network_Access; Username, Password : String)
   is
      Mech : constant String :=
        To_String (Net.Network_Record.SASL.Mechanism);
      DB   : constant Soja.Database.Database_Access :=
        Soja.Server.DB (Net.User.Srv.all);
   begin
      --  The user may have e.g. the EXTERNAL mechanism configured: do not
      --  automatically erase the key pair or any other credentials.
      if Mech /= "" and then Mech /= "PLAIN" then
         return;
      end if;

      Net.Logger.Print
        ("auto-saving SASL PLAIN credentials with username "
         & Soja.Irc.Helpers.Quote (Username));
      Net.Network_Record.SASL.Mechanism := To_Unbounded_String ("PLAIN");
      Net.Network_Record.SASL.Plain_Username := To_Unbounded_String (Username);
      Net.Network_Record.SASL.Plain_Password := To_Unbounded_String (Password);
      if DB /= null then
         Soja.Database.Store_Network
           (DB.all, Net.User.User_Record.ID, Net.Network_Record);
      end if;
   exception
      when E : others =>
         Net.Logger.Print
           ("failed to save SASL PLAIN credentials: "
            & Ada.Exceptions.Exception_Message (E));
   end Auto_Save_SASL_Plain;

   ---------------------------------------------------------------
   -- Kick records (persisted; see Soja.Database.Kick_Record) --
   ---------------------------------------------------------------

   procedure Store_Kick_Quietly
     (Net : not null Network_Access; Kick : in out Soja.Database.Kick_Record)
   is
      DB : constant Soja.Database.Database_Access :=
        Soja.Server.DB (Net.User.Srv.all);
   begin
      if DB /= null then
         Soja.Database.Store_Kick (DB.all, Net.Network_Record.ID, Kick);
      end if;
   exception
      when E : others =>
         Net.Logger.Print
           ("failed to store the kick record: "
            & Ada.Exceptions.Exception_Message (E));
   end Store_Kick_Quietly;

   --  Mark a stored kick as rejoined (history keeps it).
   procedure End_Kick
     (Net : not null Network_Access; ID : Long_Long_Integer)
   is
      Rec : Soja.Database.Kick_Record;
   begin
      if ID = 0 then
         return;
      end if;
      Rec.ID := ID;
      Rec.Rejoined_At := Ada.Calendar.Clock;
      Store_Kick_Quietly (Net, Rec);
   end End_Kick;

   procedure Record_Kick
     (Net : not null Network_Access;
      Channel, Kicked_By, Reason : String)
   is
      Old  : constant Kick_Info_Access := Net.Kicked.Get (Channel);
      Info : constant Kick_Info_Access := new Kick_Info;
      Rec  : Soja.Database.Kick_Record;
   begin
      --  Being kicked means we were in the channel again, so an earlier kick
      --  that is still active was rejoined without us noticing.
      if Old /= null then
         End_Kick (Net, Old.ID);
      end if;

      Info.Kicked_By := To_Unbounded_String (Kicked_By);
      Info.Reason := To_Unbounded_String (Reason);
      Info.At_Time := Ada.Calendar.Clock;

      Rec.Channel := To_Unbounded_String (Channel);
      Rec.Kicked_By := Info.Kicked_By;
      Rec.Reason := Info.Reason;
      Rec.Kicked_At := Info.At_Time;
      Store_Kick_Quietly (Net, Rec);
      Info.ID := Rec.ID;

      Net.Kicked.Set (Channel, Info);
   end Record_Kick;

   procedure Clear_Kick
     (Net : not null Network_Access; Channel : String)
   is
      Old : constant Kick_Info_Access := Net.Kicked.Get (Channel);
   begin
      if Old = null then
         return;
      end if;
      Net.Kicked.Del (Channel);
      End_Kick (Net, Old.ID);
   end Clear_Kick;

   procedure Load_Kicks (Net : not null Network_Access) is
      DB : constant Soja.Database.Database_Access :=
        Soja.Server.DB (Net.User.Srv.all);
   begin
      if DB = null then
         return;
      end if;
      for K of Soja.Database.List_Kicks
                 (DB.all, Net.Network_Record.ID, Active_Only => True)
      loop
         declare
            Name : constant String := To_String (K.Channel);
            Old  : constant Kick_Info_Access := Net.Kicked.Get (Name);
         begin
            --  Two active records for a channel (shouldn't happen): the
            --  older one is superseded.
            if Old /= null then
               End_Kick (Net, Old.ID);
            end if;
            Net.Kicked.Set
              (Name,
               new Kick_Info'(Kicked_By => K.Kicked_By, Reason => K.Reason,
                              At_Time => K.Kicked_At, ID => K.ID));
         end;
      end loop;
   exception
      when E : others =>
         Net.Logger.Print
           ("failed to load the kick records: "
            & Ada.Exceptions.Exception_Message (E));
   end Load_Kicks;

   ---------------------------------------------------------------
   -- Update_Result, Stop_User, downstream message dispatch --
   ---------------------------------------------------------------

   protected body Update_Result is
      procedure Finish (Error : String) is
      begin
         Last := To_Unbounded_String (Error);
         Is_Done := True;
      end Finish;

      entry Wait (Error : out Unbounded_String) when Is_Done is
      begin
         Error := Last;
      end Wait;
   end Update_Result;

   protected body Run_Output is
      procedure Put (Text : String) is
      begin
         Lines.Append (Text);
      end Put;

      procedure Finish (Failed : Boolean; Error : String) is
      begin
         Is_Done := True;
         Has_Failed := Failed;
         Reason := To_Unbounded_String (Error);
      end Finish;

      entry Next
        (Is_Line : out Boolean; Text : out Unbounded_String;
         Failed : out Boolean)
        when Natural (Lines.Length) > Taken or else Is_Done is
      begin
         if Natural (Lines.Length) > Taken then
            Taken := Taken + 1;
            Is_Line := True;
            Text := To_Unbounded_String (Lines (Taken));
            Failed := False;
         else
            Is_Line := False;
            Text := Reason;
            Failed := Has_Failed;
         end if;
      end Next;
   end Run_Output;

   function Stop_User
     (U : not null User_Access; Timeout : Duration := 30.0) return Boolean
   is
      Queued : Boolean := False;
   begin
      if U.Done.Is_Set then
         return True;   --  already stopped
      end if;

      select
         U.Events.Enqueue (new Stop_Event);
         Queued := True;
      or
         delay Timeout;
      end select;
      if not Queued then
         return False;
      end if;

      select
         U.Done.Wait;
         return True;
      or
         delay Timeout;
         return False;
      end select;
   end Stop_User;

   function Has_Persistent_Msg_Store (U : not null User_Access)
      return Boolean
   is
   begin
      return U.Msg_Store /= null
        and then not Soja.Msgstore.Memory.Is_Memory_Store (U.Msg_Store.all);
   end Has_Persistent_Msg_Store;

   function Handle_Message_Registered
     (DC : not null Downstream_Conn_Access; M : Message)
      return Irc_Error_Result
   is
   begin
      return Soja.Core.Downstream_Commands.Handle_Message_Registered (DC, M);
   end Handle_Message_Registered;

   function Handle_Downstream_Message
     (DC : not null Downstream_Conn_Access; M : Message)
      return Irc_Error_Result
   is
   begin
      if To_String (M.Command) = "QUIT" then
         Soja.Conn.Shutdown (DC.Conn);
         return (Failed => False);   --  TODO (Go): stop handling commands
      elsif DC.Registered then
         return Handle_Message_Registered (DC, M);
      end if;
      return Handle_Message_Unregistered (DC, M);
   end Handle_Downstream_Message;

   ----------------
   -- Append_Log --
   ----------------

   --  storableMessageTags: tags that cause a TAGMSG to be stored.
   function Is_Storable_Tag (Tag : String) return Boolean is
     (Tag = "+draft/react" or else Tag = "+react");

   function Append_Log
     (UC     : not null Upstream_Conn_Access;
      Entity : String;
      Msg    : Soja.Irc.Messages.Message) return String
   is
      Store : constant Soja.Msgstore.Store_Access := UC.User.Msg_Store;
   begin
      if Store = null then
         return "";
      end if;

      if To_String (Msg.Command) = "TAGMSG" then
         declare
            Storable : Boolean := False;
         begin
            for C in Msg.Tags.Data.Iterate loop
               if Is_Storable_Tag (Tag_Maps.Key (C)) then
                  Storable := True;
                  exit;
               end if;
            end loop;
            if not Storable then
               return "";
            end if;
         end;
      end if;

      --  Don't store messages with a server mask target.
      if Entity'Length > 0 and then Entity (Entity'First) = '$' then
         return "";
      end if;

      declare
         Entity_CM : constant String :=
           Soja.Irc.Case_Mapping.Fold (UC.Network.Casemap, Entity);
      begin
         --  The messages sent/received from NickServ may contain
         --  security-related information (like passwords): don't store them.
         if Entity_CM = "nickserv" then
            return "";
         end if;

         if not Soja.User.Has_Target (UC.Network.Delivered, Entity) then
            --  This is the first message we receive from this target.  Save
            --  the last message ID in delivery receipts, so that we can send
            --  the new message in the backlog if an offline client
            --  reconnects.
            declare
               Last_ID : Unbounded_String;

               procedure Record_For (Client_Name : String) is
               begin
                  Soja.User.Store_ID
                    (UC.Network.Delivered, Entity, Client_Name,
                     To_String (Last_ID));
               end Record_For;
            begin
               --  (In the body, not the declarative part, so that the
               --  handler below catches a Store_Error from the store.)
               Last_ID := To_Unbounded_String
                 (Store.Last_Msg_ID
                    (UC.Network.Network_Record, Entity_CM,
                     Ada.Calendar.Clock));
               Soja.User.For_Each_Client
                 (UC.Network.Delivered, Record_For'Access);
            exception
               when E : Soja.Msgstore.Store_Error =>
                  UC.Logger.Print
                    ("failed to log message: failed to get last message ID: "
                     & Ada.Exceptions.Exception_Message (E));
                  return "";
            end;
         end if;

         return Store.Append (UC.Network.Network_Record, Entity_CM, Msg);
      exception
         when E : Soja.Msgstore.Store_Error =>
            UC.Logger.Print
              ("failed to append message to store: "
               & Ada.Exceptions.Exception_Message (E));
            return "";
      end;
   end Append_Log;

   function New_Upstream_Channel
     (UC : not null Upstream_Conn_Access; Name : String)
      return Upstream_Channel_Access
   is
   begin
      return new Upstream_Channel'
        (Name    => To_Unbounded_String (Name),
         Conn    => UC,
         Members => Soja.Irc.Members.Member_Maps.New_Map
                      (UC.Network.Casemap),
         others  => <>);
   end New_Upstream_Channel;

   type Detach_Action is new Soja.Timers.Action with record
      UC   : Upstream_Conn_Access;
      Name : Unbounded_String;
   end record;

   overriding procedure Run (A : in out Detach_Action) is
      Ok : Boolean := False;
   begin
      --  Go does a blocking `events <- eventChannelDetach{...}`.  Here
      --  whoever stops this timer waits for Run to return, and may be the
      --  very task that must make room in the queue, so wait for room only
      --  for a while.
      for Attempt in 1 .. 20 loop
         A.UC.Network.User.Events.Try_Enqueue
           (new Channel_Detach_Event'(UC => A.UC, Name => A.Name), Ok);
         exit when Ok;
         delay 0.5;
      end loop;
      if not Ok then
         A.UC.Logger.Print ("skipping a channel detach: the event queue is full");
      end if;
   end Run;

   procedure Update_Auto_Detach
     (Ch : not null Upstream_Channel_Access; Dur : Duration)
   is
   begin
      Soja.Timers.Stop (Ch.Detach_Timer);
      if Dur = 0.0 then
         return;
      end if;
      Ch.Detach_Timer := Soja.Timers.After_Func
        (Dur, new Detach_Action'(UC => Ch.Conn, Name => Ch.Name));
   end Update_Auto_Detach;

   function Is_Our_Nick (UC : not null Upstream_Conn_Access; Nick : String)
      return Boolean
   is
   begin
      return Equal_Casemap (UC.Network, To_String (UC.Nick), Nick);
   end Is_Our_Nick;

   type Regain_Nick_Action is new Soja.Timers.Action with record
      UC   : Upstream_Conn_Access;
      Nick : Unbounded_String;
   end record;

   overriding procedure Run (A : in out Regain_Nick_Action) is
      Ok : Boolean;
   begin
      A.UC.Network.User.Events.Try_Enqueue
        (new Try_Regain_Nick_Event'(UC => A.UC, Nick => A.Nick), Ok);
      if not Ok then
         A.UC.Logger.Print
           ("skipping nick regain attempt: event queue is full");
      end if;
   end Run;

   procedure Stop_Regain_Nick_Timer (UC : not null Upstream_Conn_Access) is
   begin
      --  Maybe we're racing with the timer task, so maybe a
      --  Try_Regain_Nick_Event still arrives; Try_Regain_Nick handles that.
      Soja.Timers.Stop (UC.Regain_Nick_Timer);
      UC.Regain_Nick_Backoff := null;
   end Stop_Regain_Nick_Timer;

   procedure Start_Regain_Nick_Timer (UC : not null Upstream_Conn_Access) is
      Want : constant String := Soja.Database.Get_Nick
        (UC.User.User_Record, UC.Network.Network_Record);
   begin
      if UC.Regain_Nick_Backoff /= null or else UC.Regain_Nick_Timer /= null
      then
         raise Program_Error with "startRegainNickTimer called twice";
      end if;
      if Is_Our_Nick (UC, Want) then
         return;
      end if;

      UC.Regain_Nick_Backoff := new Soja.Backoff.Backoffer'
        (Soja.Backoff.New_Backoffer
           (Min => 15.0, Max => 600.0, Jitter => 10.0));
      UC.Regain_Nick_Timer := Soja.Timers.After_Func
        (Soja.Backoff.Next (UC.Regain_Nick_Backoff.all),
         new Regain_Nick_Action'
           (UC => UC, Nick => To_Unbounded_String (Want)));
   end Start_Regain_Nick_Timer;

   procedure Try_Regain_Nick
     (UC : not null Upstream_Conn_Access; Nick : String)
   is
   begin
      if UC.Regain_Nick_Timer = null then
         return;
      end if;

      --  Maybe the user has updated their desired nick.
      declare
         Want : constant String := Soja.Database.Get_Nick
           (UC.User.User_Record, UC.Network.Network_Record);
         P    : Param_Vectors.Vector;
      begin
         if Want /= Nick or else Is_Our_Nick (UC, Want) then
            Stop_Regain_Nick_Timer (UC);
            return;
         end if;

         Soja.Timers.Reset
           (UC.Regain_Nick_Timer,
            Soja.Backoff.Next (UC.Regain_Nick_Backoff.all));

         if Length (UC.Pending_Regain_Nick) > 0 then
            return;
         end if;

         P.Append (To_Unbounded_String (Want));
         Send_Message (UC, Make_Message ("NICK", P));
         UC.Pending_Regain_Nick := To_Unbounded_String (Want);
      end;
   end Try_Regain_Nick;

   procedure Run_Network (Net : not null Network_Access) is
      use type Ada.Calendar.Time;
      Backoff : Soja.Backoff.Backoffer := Soja.Backoff.New_Backoffer
        (Soja.Server.Retry_Connect_Min_Delay,
         Soja.Server.Retry_Connect_Max_Delay,
         Soja.Server.Retry_Connect_Jitter);
      Last_Try : Ada.Calendar.Time := Ada.Calendar.Clock;
      Delay_Needed : Duration;
      Err : Run_Conn_Error;
   begin
      if not Net.User.User_Record.Enabled
        or else not Net.Network_Record.Enabled
      then
         return;
      end if;

      loop
         exit when Is_Stopped (Net);

         Delay_Needed := Soja.Backoff.Next (Backoff)
           - (Ada.Calendar.Clock - Last_Try);
         if Delay_Needed > 0.0 then
            Net.Logger.Print
              ("waiting " & Duration'Image (Delay_Needed)
               & " before trying to reconnect to "
               & To_String (Net.Network_Record.Addr));
            --  (Woken up early when the network is stopped.)
            select
               Net.Stopped.Wait;
            or
               delay Delay_Needed;
            end select;
            exit when Is_Stopped (Net);
         end if;
         Last_Try := Ada.Calendar.Clock;

         Net.User.Srv.Add_Upstreams (1);
         Err := Run_Conn (Net);
         Net.User.Srv.Add_Upstreams (-1);
         if Err.Text /= Null_Unbounded_String then
            Net.Logger.Print
              ("connection error to " & To_String (Net.Network_Record.Addr)
               & ": " & To_String (Err.Text));
            Net.User.Events.Enqueue
              (new Upstream_Connection_Error_Event'
                 (Net => Net,
                  Error => "connection error: " & Err.Text));
            exit when not Err.Temporary;
         else
            Soja.Backoff.Reset (Backoff);
         end if;
      end loop;
   end Run_Network;

   procedure Load_Networks (U : not null User_Access) is
      DB  : constant Soja.Database.Database_Access :=
        Soja.Server.DB (U.Srv.all);
      Nets : Soja.Database.Network_Lists.Vector;
   begin
      --  Deferred: the user's message store (newUser's msgStore) and the
      --  delivery-receipt loading (needs msgStore).
      Nets := Soja.Database.List_Networks (DB.all, U.User_Record.ID);
      Sort_By_ID (Nets);
      for Rec of Nets loop
         declare
            Chs : constant Soja.Database.Channel_Lists.Vector :=
              Soja.Database.List_Channels (DB.all, Rec.ID);
            Net : constant Network_Access := New_Network (U, Rec, Chs);
         begin
            Load_Kicks (Net);
            U.Networks.Append (Net);

            if Has_Persistent_Msg_Store (U) then
               for R of Soja.Database.List_Delivery_Receipts (DB.all, Rec.ID)
               loop
                  Soja.User.Store_ID
                    (Net.Delivered, To_String (R.Target),
                     To_String (R.Client), To_String (R.Internal_Msg_ID));
               end loop;
            end if;

            Spawn_Network (Net);
         end;
      end loop;
   end Load_Networks;

   procedure Run (U : not null User_Access) is
      Stop : Boolean := False;

      procedure Finish is
      begin
         if U.Msg_Store /= null then
            begin
               U.Msg_Store.Close;
            exception
               when E : others =>
                  U.Logger.Print
                    ("failed to close message store for user "
                     & Soja.Irc.Helpers.Quote
                         (To_String (U.User_Record.Username)) & ": "
                     & Ada.Exceptions.Exception_Message (E));
            end;
         end if;
         if U.Delete_On_Stop then
            begin
               Soja.Database.Delete_User
                 (Soja.Server.DB (U.Srv.all).all, U.User_Record.ID);
            exception
               when E : others =>
                  U.Logger.Print
                    ("failed to delete user "
                     & Soja.Irc.Helpers.Quote
                         (To_String (U.User_Record.Username)) & ": "
                     & Ada.Exceptions.Exception_Message (E));
            end;
         end if;
         U.Done.Set;
      end Finish;
   begin
      begin
         Load_Networks (U);
      exception
         when E : others =>
            U.Logger.Print
              ("failed to list networks for user "
               & Soja.Irc.Helpers.Quote (To_String (U.User_Record.Username))
               & ": " & Ada.Exceptions.Exception_Message (E));
            Finish;
            return;
      end;

      loop
         declare
            E    : Event_Access;
            Done : Boolean;
         begin
            U.Events.Dequeue (E, Done);
            exit when Done;
            begin
               Soja.Core.User_Events.Handle_Event (U, E, Stop);
            exception
               when Err : others =>
                  --  A failing handler must not take the whole user down.
                  U.Logger.Print
                    ("event handler failed: "
                     & Ada.Exceptions.Exception_Information (Err));
            end;
            exit when Stop;
         end;
      end loop;

      Finish;
   end Run;

end Soja.Core;
