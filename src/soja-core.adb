pragma Ada_2022;

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
with Soja.Irc.Numerics;

package body Soja.Core is

   use Soja.Logging;
   use Soja.Irc.Messages;
   use type AWS.Net.Socket_Access;

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
      DC.Hostname := To_Unbounded_String (Remote);
      DC.Caps := Soja.Irc.Cap_Registry.New_Registry;
      DC.Casemap := Case_ASCII;
      DC.Registration := new Downstream_Registration;
      for Cap of Permanent_Downstream_Caps loop
         Soja.Irc.Cap_Registry.Set_Available (DC.Caps, Cap.all, "");
      end loop;
      --  Deferred: the "sasl" cap value (serverSASLMechanisms) and the
      --  message-store caps, both of which need srv.Config().
      return DC;
   end New_Downstream_Conn;

   -----------------
   --  Event loop --
   -----------------

   --  user.go's handleEvent: dispatch on the event variant.  Every handler is
   --  a stub until the connection methods they call are ported.
   procedure Handle (U : not null User_Access; E : Event_Access) is
      pragma Unreferenced (U);
   begin
      if E.all in Upstream_Message_Event then
         null;   --  deferred: handleUpstreamMessage
      elsif E.all in Upstream_Connection_Error_Event then
         null;   --  deferred: handleUpstreamConnectionError
      elsif E.all in Upstream_Connected_Event then
         null;   --  deferred: handleUpstreamConnected
      elsif E.all in Upstream_Disconnected_Event then
         null;   --  deferred: handleUpstreamDisconnected
      elsif E.all in Upstream_Error_Event then
         null;   --  deferred: handleUpstreamError
      elsif E.all in Downstream_Message_Event then
         null;   --  deferred: handleDownstreamMessage
      elsif E.all in Downstream_Connected_Event then
         null;   --  deferred: handleDownstreamConnected
      elsif E.all in Downstream_Disconnected_Event then
         null;   --  deferred: handleDownstreamDisconnected
      elsif E.all in Channel_Detach_Event then
         null;   --  deferred: handleChannelDetach
      elsif E.all in Broadcast_Event then
         null;   --  deferred: handleBroadcast
      elsif E.all in Stop_Event then
         null;   --  deferred: stop the user
      elsif E.all in Try_Regain_Nick_Event then
         null;   --  deferred: handleTryRegainNick
      end if;
   end Handle;

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
   begin
      if not Is_Stopped (Net) then
         Net.Stopped.Set;
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
   type Handle_Result is record
      Failed    : Boolean := False;
      Reason    : Unbounded_String;
      Temporary : Boolean := True;
   end record;

   --  Minimal handleMessage for the registration phase: PING/PONG, CAP LS ->
   --  CAP END (requesting no caps), 001 -> registered, nick-in-use fallback,
   --  and the registration-error numerics.  The full post-registration message
   --  dispatch (JOIN/PRIVMSG/NICK/...) is deferred.
   function Handle_Message (UC : not null Upstream_Conn_Access;
      M : Soja.Irc.Messages.Message) return Handle_Result
   is
      use Soja.Irc.Numerics;
      Cmd : constant String := To_String (M.Command);
      R   : Handle_Result := (Failed => False, others => <>);
      P   : Param_Vectors.Vector;
   begin
      if Cmd = "PING" then
         Send_Message (UC, Make_Message ("PONG", M.Params));
      elsif Cmd = "CAP" then
         if Natural (M.Params.Length) >= 2
           and then To_String (M.Params (2)) = "LS"
         then
            P.Append (To_Unbounded_String ("END"));
            Send_Message (UC, Make_Message ("CAP", P));
         end if;
      elsif Cmd = "ERROR" then
         R := (Failed => True,
               Reason => To_Unbounded_String ("fatal server error"),
               Temporary => False);
      elsif Cmd = RPL_WELCOME then
         UC.Nick := M.Params (1);
         UC.Registered := True;
         UC.Server_Prefix := M.Prefix;
         UC.Logger.Print
           ("connection registered with nick " & To_String (UC.Nick));
      elsif Cmd = ERR_NICKNAMEINUSE then
         if not UC.Registered and then Length (UC.Nick) + 1 < 30 then
            Append (UC.Nick, "_");
            UC.Has_Desired_Nick := False;
            P.Append (UC.Nick);
            Send_Message (UC, Make_Message ("NICK", P));
         else
            R := (Failed => True,
                  Reason => To_Unbounded_String ("nickname in use"),
                  Temporary => True);
         end if;
      elsif Cmd = ERR_ERRONEUSNICKNAME or else Cmd = ERR_PASSWDMISMATCH then
         R := (Failed => True,
               Reason => M.Params (Natural (M.Params.Length)),
               Temporary => False);
      elsif Cmd = ERR_NICKCOLLISION or else Cmd = ERR_UNAVAILRESOURCE
        or else Cmd = ERR_NOPERMFORHOST or else Cmd = ERR_YOUREBANNEDCREEP
      then
         R := (Failed => True,
               Reason => M.Params (Natural (M.Params.Length)),
               Temporary => True);
      elsif Cmd = "FAIL" then
         if Natural (M.Params.Length) >= 2
           and then To_String (M.Params (1)) = "*"
           and then To_String (M.Params (2)) = "ACCOUNT_REQUIRED"
         then
            R := (Failed => True,
                  Reason => To_Unbounded_String ("account required"),
                  Temporary => False);
         end if;
      else
         null;   --  deferred: the full message dispatch
      end if;
      return R;
   end Handle_Message;

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
         R := Handle_Message (UC, M);
         if R.Failed then
            return (Success => False, Reason => R.Reason,
                    Temporary => R.Temporary);
         end if;
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

      Register (UC);

      RR := Run_Until_Registered (UC);
      if not RR.Success then
         Soja.Conn.Close (UC.Conn);
         return (Text => To_Unbounded_String
                   ("failed to register: " & To_String (RR.Reason)),
                 Temporary => RR.Temporary);
      end if;

      Net.Conn := UC;
      Net.User.Events.Enqueue (new Upstream_Connected_Event'(UC => UC));

      Read_Messages (UC, Net.User.Events);

      Net.User.Events.Enqueue (new Upstream_Disconnected_Event'(UC => UC));
      Soja.Conn.Close (UC.Conn);
      return (Text => Null_Unbounded_String, Temporary => True);
   end Run_Conn;

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
            delay Delay_Needed;
         end if;
         Last_Try := Ada.Calendar.Clock;

         Err := Run_Conn (Net);
         if Err.Text /= Null_Unbounded_String then
            Net.Logger.Print
              ("connection error to " & To_String (Net.Network_Record.Addr)
               & ": " & To_String (Err.Text));
            Net.User.Events.Enqueue
              (new Upstream_Connection_Error_Event'
                 (Net => Net, Error => Err.Text));
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
            U.Networks.Append (Net);
            Spawn_Network (Net);
         end;
      end loop;
   end Load_Networks;

   procedure Run (U : not null User_Access) is
   begin
      Load_Networks (U);
      loop
         declare
            E    : Event_Access;
            Done : Boolean;
         begin
            U.Events.Dequeue (E, Done);
            exit when Done;
            Handle (U, E);
         end;
      end loop;
   end Run;

end Soja.Core;
