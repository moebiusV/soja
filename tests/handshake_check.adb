pragma Ada_2022;

with Ada.Calendar;
with Ada.Containers;
with Ada.Containers.Indefinite_Vectors;
with Ada.Exceptions;
with Ada.IO_Exceptions;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;
with Ada.Text_IO;
with GNAT.OS_Lib;

with Soja.Base64;
with Soja.Conn;
with Soja.Core;                use Soja.Core;
with Soja.Core.Downstream_Handshake;
with Soja.Core.Downstream_Helpers;
with Soja.Core.Upstream_Dispatch;
with Soja.Core.User_Ops;
with Soja.Database;
with Soja.Database.Sqlite;
with Soja.Downstream;
with Soja.Irc.Case_Mapping;
with Soja.Irc.Cap_Registry;
with Soja.Irc.Members;
with Soja.Irc.Messages;        use Soja.Irc.Messages;
with Soja.Logging;
with Soja.Msgstore.Memory;
with Soja.Server;
with Soja.User;

--  Registration (CAP, PASS, SASL, BOUNCER BIND) and the welcome burst.
procedure Handshake_Check is
   package SD renames Soja.Database;
   package HS renames Soja.Core.Downstream_Handshake;
   use type Ada.Containers.Count_Type;

   procedure Check (Cond : Boolean; What : String) is
   begin
      if not Cond then
         raise Program_Error with What;
      end if;
   end Check;

   package String_Vectors is new Ada.Containers.Indefinite_Vectors
     (Positive, String);

   protected type Recorder is
      procedure Add (Line : String);
      function Count return Natural;
      function Line (I : Positive) return String;
      function Has (Needle : String) return Boolean;
   private
      V : String_Vectors.Vector;
   end Recorder;
   type Recorder_Access is access all Recorder;

   protected body Recorder is
      procedure Add (Line : String) is
      begin
         V.Append (Line);
      end Add;
      function Count return Natural is (Natural (V.Length));
      function Line (I : Positive) return String is (V (I));
      function Has (Needle : String) return Boolean is
      begin
         for L of V loop
            if Ada.Strings.Fixed.Index (L, Needle) > 0 then
               return True;
            end if;
         end loop;
         return False;
      end Has;
   end Recorder;

   --  A client that says a script of lines, then either hangs up (End_Error)
   --  or, with Hang, waits until the connection is closed.
   protected type Gate is
      procedure Open;
      entry Wait;
   private
      Is_Open : Boolean := False;
   end Gate;
   protected body Gate is
      procedure Open is
      begin
         Is_Open := True;
      end Open;
      entry Wait when Is_Open is
      begin
         null;
      end Wait;
   end Gate;
   type Gate_Access is access all Gate;

   type Script_Access is access all String_Vectors.Vector;

   type Fake_Client is new Soja.Conn.IRC_Conn with record
      Log    : Recorder_Access;
      Script : Script_Access;
      Next   : Natural := 0;
      Hang   : Boolean := False;
      Closed : Gate_Access;
   end record;
   overriding function Read_Message
     (C : in out Fake_Client) return Message;
   overriding procedure Write_Message
     (C : in out Fake_Client; M : Message);
   overriding procedure Close (C : in out Fake_Client);
   overriding function Remote_Addr (C : Fake_Client) return String is
     ("1.2.3.4:6667");

   overriding function Read_Message (C : in out Fake_Client) return Message is
   begin
      if C.Next < Natural (C.Script.Length) then
         C.Next := C.Next + 1;
         return Parse_Message (C.Script (C.Next));
      end if;
      if C.Hang then
         C.Closed.Wait;
      end if;
      raise Ada.IO_Exceptions.End_Error;
   end Read_Message;
   overriding procedure Write_Message
     (C : in out Fake_Client; M : Message) is
   begin
      C.Log.Add (Image (M));
   end Write_Message;
   overriding procedure Close (C : in out Fake_Client) is
   begin
      C.Closed.Open;
   end Close;

   type Fake_Client_Access is access all Fake_Client;

   Last_Log : Recorder_Access;   --  the newest client's output, for failures
   Conns   : array (1 .. 64) of Soja.Conn.Conn_Access;
   N_Conns : Natural := 0;

   Log : aliased Soja.Logging.Standard_Logger;
   Srv : aliased Soja.Server.Server;
   DB  : SD.Database_Access := Soja.Database.Sqlite.Open_Temp_Sqlite_DB;
   Rec : SD.User := SD.New_User ("alice");

   function B64 (S : String) return String is (Soja.Base64.Encode (S));
   function Plain (User, Pass : String) return String is
     (B64 (ASCII.NUL & User & ASCII.NUL & Pass));

   --  A fresh client connection reading Script.
   function New_Client
     (Script : String_Vectors.Vector; ID : Long_Long_Integer;
      Log_Out : out Recorder_Access; Hang : Boolean := False)
      return Downstream_Conn_Access
   is
      R : constant Recorder_Access := new Recorder;
      S : constant Script_Access := new String_Vectors.Vector'(Script);
      T : constant Fake_Client_Access := new Fake_Client'
        (Soja.Conn.IRC_Conn with Log => R, Script => S, Next => 0,
         Hang => Hang, Closed => new Gate);
      DC : constant Downstream_Conn_Access :=
        New_Downstream_Conn (Srv'Unchecked_Access, T.all'Unchecked_Access, ID);
   begin
      N_Conns := N_Conns + 1;
      Conns (N_Conns) := DC.Conn;
      Log_Out := R;
      Last_Log := R;
      return DC;
   end New_Client;

   function Script (A, B, C, D, E, F, G, H : String := "")
      return String_Vectors.Vector
   is
      V : String_Vectors.Vector;
   begin
      if A /= "" then V.Append (A); end if;
      if B /= "" then V.Append (B); end if;
      if C /= "" then V.Append (C); end if;
      if D /= "" then V.Append (D); end if;
      if E /= "" then V.Append (E); end if;
      if F /= "" then V.Append (F); end if;
      if G /= "" then V.Append (G); end if;
      if H /= "" then V.Append (H); end if;
      return V;
   end Script;

   procedure Settle is
   begin
      delay 0.25;   --  let the writer tasks drain
   end Settle;

   U : User_Access;
   Cfg : Soja.Server.Server_Config_Access;

   Channel_Names : constant array (1 .. 3) of access constant String :=
     [new String'("#chan"), new String'("#quiet"), new String'("#pending")];
begin
   Srv.Initialize (Log'Unchecked_Access);
   Srv.Set_DB (DB);
   SD.Set_Password (Rec, "secret");
   SD.Store_User (DB.all, Rec);
   Rec.Enabled := True;
   SD.Store_User (DB.all, Rec);
   U := New_User (Srv'Unchecked_Access, Rec);

   -------------------------------------------------------------------
   --  CAP negotiation
   -------------------------------------------------------------------
   declare
      Out_Log : Recorder_Access;
      DC : constant Downstream_Conn_Access := New_Client
        (Script ("CAP LS 302", "CAP REQ :server-time sasl",
                 "CAP REQ :server-time nope", "CAP REQ :-cap-notify",
                 "CAP REQ", "CAP LIST", "CAP BOGUS", "CAP END"),
         1, Out_Log);
      R : Irc_Error_Result;
      use Soja.Irc.Cap_Registry;
   begin
      for I in 1 .. 8 loop
         declare
            M : constant Message := Soja.Conn.Read_Message (DC.Conn);
         begin
            R := HS.Handle_Message_Unregistered (DC, M);
            if R.Failed then
               Check (R.Is_IRC, "CAP errors are IRC replies");
               Send_Message (DC, R.Err.Message);
            end if;
         end;
      end loop;
      Settle;
      Check (Out_Log.Has ("CAP * LS :") and then Out_Log.Has ("server-time")
             and then Out_Log.Has ("sasl=PLAIN")
             and then Out_Log.Has ("account-notify")
             and then Out_Log.Has ("multi-prefix"),
             "LS 302 shows the sasl value and the capabilities that depend on "
             & "the upstream");
      Check (DC.Cap_Version = 302 and then Is_Enabled (DC.Caps, "cap-notify"),
             "302 implies cap-notify");
      Check (Is_Enabled (DC.Caps, "server-time")
             and then Is_Enabled (DC.Caps, "sasl"), "REQ enabled the caps");
      Check (Out_Log.Has ("ACK :server-time sasl"), "ACK");
      Check (Out_Log.Has ("NAK :server-time nope"), "NAK for an unknown cap");
      Check (Out_Log.Has ("NAK -cap-notify"),
             "cap-notify cannot be disabled with CAP 302");
      Check (Out_Log.Has (" 410 ") and then Out_Log.Has ("Missing argument in CAP REQ command")
             and then Out_Log.Has ("Unknown CAP command"), "410 errors");
      Check (Out_Log.Has ("CAP * LIST :") and then Out_Log.Has ("sasl"),
             "LIST");
      Check (not DC.Registration.Negotiating_Caps, "CAP END ends negotiation");
      --  The nick of a still unregistered client is "*".
      Check (Out_Log.Has (":localhost CAP * LS"), "from the server");
   end;

   -------------------------------------------------------------------
   --  Registration with PASS
   -------------------------------------------------------------------
   declare
      Out_Log : Recorder_Access;
      DC : constant Downstream_Conn_Access := New_Client
        (Script ("PASS secret", "NICK ali", "USER alice/libera@phone 0 * :Alice"),
         2, Out_Log);
   begin
      Check (HS.Run_Until_Registered (DC), "registered with PASS");
      Check (DC.Registered and then To_String (DC.Username) = "alice"
             and then To_String (DC.Client_Name) = "phone"
             and then To_String (DC.Registration.Network_Name) = "libera",
             "username, client and network were taken from the username");
      Check (Length (DC.Registration.Pass) = 0, "the password is dropped");
   end;

   --  A wrong password is answered (soju just drops the connection), and the
   --  client may try again.
   declare
      Out_Log : Recorder_Access;
      DC : constant Downstream_Conn_Access := New_Client
        (Script ("PASS wrong", "NICK ali", "USER alice 0 * :Alice",
                 "PASS secret", "USER alice 0 * :Alice"),
         3, Out_Log);
   begin
      Check (HS.Run_Until_Registered (DC), "registered after a retry");
      Settle;
      Check (Out_Log.Has (" 464 ") and then Out_Log.Has ("Invalid credentials"),
             "a wrong password is reported");
   end;

   --  No password at all.
   declare
      Out_Log : Recorder_Access;
      DC : constant Downstream_Conn_Access := New_Client
        (Script ("NICK ali", "USER alice 0 * :Alice"), 4, Out_Log);
   begin
      Check (not HS.Run_Until_Registered (DC), "no password: not registered");
      Settle;
      Check (Out_Log.Has (" 464 ") and then Out_Log.Has ("Authentication required"),
             "authentication required");
   end;
   declare
      Out_Log : Recorder_Access;
      DC : constant Downstream_Conn_Access := New_Client
        (Script ("CAP REQ :sasl", "CAP END", "NICK ali",
                 "USER alice 0 * :Alice"), 5, Out_Log);
   begin
      Check (not HS.Run_Until_Registered (DC), "no password, sasl enabled");
      Settle;
      Check (Out_Log.Has ("FAIL * ACCOUNT_REQUIRED"), "ACCOUNT_REQUIRED");
   end;

   --  Mismatching client / network names in the username.
   declare
      Out_Log : Recorder_Access;
      DC : constant Downstream_Conn_Access := New_Client
        (Script ("CAP REQ :sasl", "AUTHENTICATE PLAIN",
                 "AUTHENTICATE " & Plain ("alice@phone", "secret"),
                 "CAP END", "NICK ali", "USER alice@laptop 0 * :Alice"),
         6, Out_Log);
   begin
      Check (not HS.Run_Until_Registered (DC), "client name mismatch");
      Settle;
      Check (Out_Log.Has (" 432 ") and then Out_Log.Has ("Client name mismatch"),
             "mismatch is reported");
   end;

   -------------------------------------------------------------------
   --  SASL
   -------------------------------------------------------------------
   declare
      Out_Log : Recorder_Access;
      DC : constant Downstream_Conn_Access := New_Client
        (Script ("CAP REQ :sasl", "AUTHENTICATE PLAIN",
                 "AUTHENTICATE " & Plain ("alice/libera@phone", "secret"),
                 "BOUNCER BIND 7", "CAP END", "NICK ali", "USER x 0 * :A"),
         7, Out_Log);
   begin
      Check (HS.Run_Until_Registered (DC), "registered with SASL PLAIN");
      Settle;
      Check (Out_Log.Has ("AUTHENTICATE +") and then Out_Log.Has (" 903 "),
             "the exchange: an empty challenge, then 903");
      Check (To_String (DC.Username) = "alice"
             and then To_String (DC.Client_Name) = "phone"
             and then DC.Registration.Network_ID = 7,
             "credentials and BOUNCER BIND");
      Check (DC.Sasl = null, "the exchange is over");
   end;

   declare
      Out_Log : Recorder_Access;
      DC : constant Downstream_Conn_Access := New_Client
        (Script ("AUTHENTICATE PLAIN",                        --  no sasl cap
                 "CAP REQ :sasl", "AUTHENTICATE",             --  no argument
                 "AUTHENTICATE SCRAM-SHA-256",                --  unsupported
                 "AUTHENTICATE PLAIN", "AUTHENTICATE *",      --  aborted
                 "AUTHENTICATE PLAIN", "AUTHENTICATE ???"),   --  bad base64
         8, Out_Log);
      R : Irc_Error_Result;
   begin
      for I in 1 .. 8 loop
         R := HS.Handle_Message_Unregistered
                (DC, Soja.Conn.Read_Message (DC.Conn));
         if R.Failed and then R.Is_IRC then
            Send_Message (DC, R.Err.Message);
         end if;
      end loop;
      Settle;
      Check (Out_Log.Has ("AUTHENTICATE requires the ""sasl"" capability"),
             "needs the cap");
      Check (Out_Log.Has ("Missing AUTHENTICATE argument"), "needs an argument");
      Check (Out_Log.Has ("Unsupported SASL mechanism"), "unsupported mechanism");
      Check (Out_Log.Has (" 906 ") and then Out_Log.Has ("SASL authentication aborted"),
             "aborted");
      Check (Out_Log.Has ("Invalid base64-encoded response"), "bad base64");
      Check (DC.Sasl = null, "failures reset the exchange");
   end;

   declare
      Out_Log : Recorder_Access;
      DC : constant Downstream_Conn_Access := New_Client
        (Script ("CAP REQ :sasl", "AUTHENTICATE PLAIN",
                 "AUTHENTICATE " & Plain ("alice", "not the password"),
                 "AUTHENTICATE ANONYMOUS", "AUTHENTICATE " & B64 ("trace")),
         9, Out_Log);
      R : Irc_Error_Result;
   begin
      for I in 1 .. 5 loop
         R := HS.Handle_Message_Unregistered
                (DC, Soja.Conn.Read_Message (DC.Conn));
         Check (not R.Failed, "no IRC error: the failure is reported with 904");
      end loop;
      Settle;
      Check (Out_Log.Has (" 904 ") and then Out_Log.Has ("Invalid credentials"),
             "wrong password over SASL");
      Check (Out_Log.Has (" 904 :Authentication failed")
             or else Out_Log.Has ("Authentication failed"),
             "ANONYMOUS is accepted by the exchange but never authenticates");
      Check (Length (DC.Registration.Auth_Username) = 0, "not authenticated");
   end;

   --  Protocol errors drop the connection (plain errors, not IRC replies).
   declare
      Out_Log : Recorder_Access;
      DC : constant Downstream_Conn_Access := New_Client
        (Script ("CAP REQ :sasl", "AUTHENTICATE PLAIN",
                 "AUTHENTICATE " & B64 ("only-one-part")),
         10, Out_Log);
   begin
      Check (not HS.Run_Until_Registered (DC), "an invalid response is fatal");
      DC.Registered := False;
   end;
   declare
      Out_Log : Recorder_Access;
      DC : constant Downstream_Conn_Access := New_Client
        (Script ("CAP REQ :sasl", "AUTHENTICATE PLAIN",
                 "AUTHENTICATE " & Plain ("someone-else" & ASCII.NUL & "alice", "x")),
         11, Out_Log);
   begin
      Check (not HS.Run_Until_Registered (DC),
             "a response with too many parts is fatal");
   end;

   --  SASL PLAIN impersonation: the identity is "user[/network][@client]";
   --  only an administrator may log in as somebody else.
   declare
      Bob : SD.User := SD.New_User ("bob");
      Out_Log : Recorder_Access;
      Mine : SD.User := SD.Get_User (DB.all, "alice");
   begin
      SD.Store_User (DB.all, Bob);

      declare
         DC : constant Downstream_Conn_Access := New_Client
           (Script ("CAP REQ :sasl", "AUTHENTICATE PLAIN",
                    "AUTHENTICATE "
                    & B64 ("bob@laptop" & ASCII.NUL & "alice" & ASCII.NUL
                           & "secret")),
            21, Out_Log);
         R  : Irc_Error_Result;
      begin
         for I in 1 .. 3 loop
            R := HS.Handle_Message_Unregistered
                   (DC, Soja.Conn.Read_Message (DC.Conn));
         end loop;
         Settle;
         Check (Out_Log.Has (" 904 ") and then not DC.Impersonating
                and then Length (DC.Registration.Auth_Username) = 0,
                "a user who is not an administrator cannot impersonate");
      end;

      Mine.Admin := True;
      SD.Store_User (DB.all, Mine);
      declare
         DC : constant Downstream_Conn_Access := New_Client
           (Script ("CAP REQ :sasl", "AUTHENTICATE PLAIN",
                    "AUTHENTICATE "
                    & B64 ("bob/net@laptop" & ASCII.NUL & "alice" & ASCII.NUL
                           & "secret"),
                    "CAP END", "NICK b", "USER x 0 * :B"),
            22, Out_Log);
      begin
         Check (HS.Run_Until_Registered (DC),
                "an administrator logs in as another user");
         Check (DC.Impersonating
                and then To_String (DC.Registration.Auth_Username) = "bob"
                and then To_String (DC.Client_Name) = "laptop",
                "as that user, from that client");
      end;
      declare
         DC : constant Downstream_Conn_Access := New_Client
           (Script ("CAP REQ :sasl", "AUTHENTICATE PLAIN",
                    "AUTHENTICATE "
                    & B64 ("nobody" & ASCII.NUL & "alice" & ASCII.NUL
                           & "secret")),
            23, Out_Log);
         R  : Irc_Error_Result;
      begin
         for I in 1 .. 3 loop
            R := HS.Handle_Message_Unregistered
                   (DC, Soja.Conn.Read_Message (DC.Conn));
         end loop;
         Settle;
         Check (Out_Log.Has (" 904 ") and then not DC.Impersonating,
                "and the user must exist");
      end;
      Mine.Admin := False;
      SD.Store_User (DB.all, Mine);
   end;

   --  BOUNCER BIND needs authentication; other subcommands are unknown.
   declare
      Out_Log : Recorder_Access;
      DC : constant Downstream_Conn_Access := New_Client
        (Script ("BOUNCER BIND 1", "BOUNCER NOPE", "BOUNCER", "AWAY :brb",
                 "AWAY", "WHATEVER x"), 12, Out_Log);
      R : Irc_Error_Result;
   begin
      for I in 1 .. 6 loop
         R := HS.Handle_Message_Unregistered
                (DC, Soja.Conn.Read_Message (DC.Conn));
         if R.Failed and then R.Is_IRC then
            Send_Message (DC, R.Err.Message);
         end if;
      end loop;
      Settle;
      Check (Out_Log.Has ("BOUNCER ACCOUNT_REQUIRED BIND"), "BIND needs auth");
      Check (Out_Log.Has ("BOUNCER UNKNOWN_COMMAND NOPE"), "unknown subcommand");
      Check (Out_Log.Has (" 461 "), "BOUNCER needs a subcommand");
      Check (Out_Log.Has (" 306 ") and then Out_Log.Has (" 305 "),
             "AWAY is acknowledged before registration");
      Check (Out_Log.Has (" 421 ") and then Out_Log.Has ("WHATEVER"),
             "unknown commands");
   end;

   -------------------------------------------------------------------
   --  Registration timeout
   -------------------------------------------------------------------
   declare
      Out_Log : Recorder_Access;
      DC : constant Downstream_Conn_Access := New_Client
        (Script ("NICK slow"), 13, Out_Log, Hang => True);
      Saved : constant Duration := Soja.Server.Downstream_Register_Timeout;
   begin
      Soja.Server.Downstream_Register_Timeout := 0.4;
      Check (not HS.Run_Until_Registered (DC), "a silent client times out");
      Soja.Server.Downstream_Register_Timeout := Saved;
      Settle;
      Check (Out_Log.Has ("Connection registration timed out"),
             "the client is told why");
   end;

   -------------------------------------------------------------------
   --  Welcome
   -------------------------------------------------------------------
   --  On the bouncer connection (no network).
   Cfg := new Soja.Server.Server_Config;
   Cfg.Hostname := To_Unbounded_String ("bnc.example");
   Cfg.Title := To_Unbounded_String ("My Bouncer");
   Cfg.MOTD := To_Unbounded_String ("line one" & ASCII.LF & "line two");
   Srv.Set_Config (Cfg);
   declare
      Out_Log : Recorder_Access;
      DC : constant Downstream_Conn_Access := New_Client
        (Script ("NICK ali", "USER alice 0 * :Alice"), 20, Out_Log);
      Res : Irc_Error_Result;
   begin
      DC.Registered := True;
      DC.Username := To_Unbounded_String ("alice");
      Res := HS.Welcome (DC, U);
      Check (not Res.Failed, "welcome");
      Settle;
      Check (To_String (DC.Nick) = "alice" and then DC.Registration = null
             and then DC.User = U, "state after welcome");
      Check (Out_Log.Has (" 001 alice :Welcome to soju, alice")
             and then Out_Log.Has (" 002 alice :Your host is bnc.example")
             and then Out_Log.Has (" 004 alice bnc.example soju aiwroO OovaimnqpsrtklbeI"),
             "001, 002, 004");
      Check (Out_Log.Has (" 005 * BOT=B CASEMAPPING=ascii CHANTYPES= "
                          & "LINELEN=4096 NETWORK=My")
             and then Out_Log.Has ("WHOX draft/ACCOUNTREQUIRED "
                                   & "soju.im/SAFERATE")
             and then not Out_Log.Has ("BOUNCER_NETID"),
             "ISUPPORT on the bouncer connection, sorted");
      Check (not Out_Log.Has (" 221 "), "no user modes without a network");
      Check (Out_Log.Has (" 375 ") and then Out_Log.Has ("line one")
             and then Out_Log.Has ("line two") and then Out_Log.Has (" 376 "),
             "MOTD");
   end;

   --  An admin gets +o; without a MOTD the hint says so.
   Cfg := new Soja.Server.Server_Config;
   Cfg.Has_File_Uploader := True;
   Cfg.HTTP_Ingress := To_Unbounded_String ("https://bnc.example");
   Cfg.Icon_Path := To_Unbounded_String ("/tmp/icon.png");
   Srv.Set_Config (Cfg);
   U.User_Record.Admin := True;
   declare
      Out_Log : Recorder_Access;
      DC : constant Downstream_Conn_Access := New_Client
        (Script ("NICK ali"), 21, Out_Log);
      Res : Irc_Error_Result;
   begin
      DC.Registered := True;
      DC.Registration.Auth_Username := To_Unbounded_String ("alice");
      Res := HS.Welcome (DC, U);
      Check (not Res.Failed, "welcome (admin)");
      Settle;
      Check (Out_Log.Has (" 221 alice +o"), "admins are operators");
      Check (Out_Log.Has (" 422 alice :No MOTD"), "no MOTD");
      Check (Out_Log.Has ("soju.im/FILEHOST=https://bnc.example/uploads"),
             "file host");
      Check (Out_Log.Has ("draft/ICON=https://bnc.example/icon"),
             "an icon file is served at /icon");
   end;
   Cfg.Icon_Path := Null_Unbounded_String;
   Cfg.Icon_URL := To_Unbounded_String ("https://cdn.example/i.png");
   declare
      Out_Log : Recorder_Access;
      DC : constant Downstream_Conn_Access := New_Client
        (Script ("NICK ali"), 24, Out_Log);
      Res : Irc_Error_Result;
   begin
      DC.Registered := True;
      DC.Registration.Auth_Username := To_Unbounded_String ("alice");
      Res := HS.Welcome (DC, U);
      Check (not Res.Failed, "welcome (icon URL)");
      Settle;
      Check (Out_Log.Has ("draft/ICON=https://cdn.example/i.png"),
             "an icon URL is told as it is");
   end;
   U.User_Record.Admin := False;
   Srv.Set_Config (new Soja.Server.Server_Config);

   --  On a network that is connected.
   declare
      NRec : SD.Network := SD.New_Network ("irc+insecure://irc.example:6667");
      Net  : Network_Access;
      UC_Log, DC_Log : Recorder_Access;
      UC : constant Upstream_Conn_Access := new Upstream_Conn;
      UC_T : constant Fake_Client_Access := new Fake_Client'
        (Soja.Conn.IRC_Conn with Log => new Recorder,
         Script => new String_Vectors.Vector, Next => 0, Hang => False,
         Closed => new Gate);
      CM : constant Soja.Irc.Case_Mapping.Kind :=
        Soja.Irc.Case_Mapping.Case_RFC1459;
      DC : Downstream_Conn_Access;
      Res : Irc_Error_Result;
   begin
      NRec.Enabled := False;
      NRec.Name := To_Unbounded_String ("libera");
      Net := Soja.Core.User_Ops.Create_Network (U, NRec);
      Net.Channels.Set
        ("#chan", new SD.Channel'(Name => To_Unbounded_String ("#chan"), others => <>));
      Net.Channels.Set
        ("#quiet", new SD.Channel'(Name => To_Unbounded_String ("#quiet"),
                                   Detached => True, others => <>));

      UC.Network := Net;
      UC.User := U;
      UC.Srv := Srv'Unchecked_Access;
      UC.Logger := Log'Unchecked_Access;
      UC.Nick := To_Unbounded_String ("alice_");
      UC.Conn := Soja.Conn.New_Conn
        (UC_T.all'Unchecked_Access,
         (Logger => null, Rate_Limit_Delay => 0.0, Rate_Limit_Burst => 0,
         others => <>));
      N_Conns := N_Conns + 1;
      Conns (N_Conns) := UC.Conn;
      UC_Log := UC_T.Log;
      UC.Channels := Upstream_Channel_Maps.New_Map (CM);
      UC.Users := Upstream_User_Maps.New_Map (CM);
      UC.Monitored := Flag_Maps.New_Map (CM);
      UC.Join_Retries := Join_Retry_Maps.New_Map (CM);
      UC.Caps := Soja.Irc.Cap_Registry.New_Registry;
      UC.Modes.Value := To_Unbounded_String ("iw");
      UC.Username := To_Unbounded_String ("uu");
      UC.Hostname := To_Unbounded_String ("uh.example");
      UC.Isupport.Include ("NETWORK", (Has_Value => True,
                                       Value => To_Unbounded_String ("Libera")));
      UC.Isupport.Include ("WHOX", (Has_Value => False, Value => <>));
      UC.Isupport.Include ("SECRET", (Has_Value => True,
                                      Value => To_Unbounded_String ("x")));
      UC.Server_Prefix := new Prefix'(Name => To_Unbounded_String ("irc"), others => <>);
      for M of Soja.Irc.Members.Std_Memberships loop
         UC.Available_Memberships.Append (M);
      end loop;
      Net.Conn := UC;

      --  The channels the upstream is in: one complete (with topic and
      --  members), one detached, one still being joined.
      for Name of Channel_Names loop
         declare
            Ch : constant Upstream_Channel_Access :=
              New_Upstream_Channel (UC, Name.all);
         begin
            Ch.Complete := Name.all /= "#pending";
            Ch.Status := Soja.Irc.Members.Channel_Public;
            Ch.Topic := To_Unbounded_String ("the topic");
            Ch.Members.Set
              ("alice_", new Soja.Irc.Members.Membership_Vectors.Vector);
            UC.Channels.Set (Name.all, Ch);
         end;
      end loop;

      --  A kick we are staying out of.
      Record_Kick (Net, "#kicked", "op", "bye");

      --  Bind by id.
      DC := New_Client (Script ("x"), 30, DC_Log);
      DC.Registered := True;
      DC.Registration.Auth_Username := To_Unbounded_String ("alice");
      DC.Registration.Network_ID := Net.Network_Record.ID;
      Soja.Irc.Cap_Registry.Set_Enabled
        (DC.Caps, "soju.im/bouncer-networks-notify", True);
      Soja.Irc.Cap_Registry.Set_Enabled (DC.Caps, "batch", True);
      Soja.Irc.Cap_Registry.Set_Enabled (DC.Caps, "extended-join", True);
      Soja.Irc.Cap_Registry.Set_Available (UC.Caps, "extended-join", "");
      Soja.Irc.Cap_Registry.Set_Enabled (UC.Caps, "extended-join", True);
      UC.Account := To_Unbounded_String ("acct");
      UC.Realname := To_Unbounded_String ("Real Name");
      Res := HS.Welcome (DC, U);
      Check (not Res.Failed, "welcome on a network");
      Settle;
      Check (DC.Network = Net and then To_String (DC.Nick) = "alice_",
             "bound to the network, with the upstream's nick");
      Check (DC_Log.Has (" 001 alice_ :Welcome to soju, alice_"), "001");
      Check (DC_Log.Has ("BOUNCER_NETID=" & Ada.Strings.Fixed.Trim
                           (Long_Long_Integer'Image (Net.Network_Record.ID),
                            Ada.Strings.Left))
             and then DC_Log.Has ("NETWORK=Libera") and then DC_Log.Has ("WHOX")
             and then not DC_Log.Has ("SECRET")
             and then DC_Log.Has ("CLIENTTAGDENY=*"),
             "ISUPPORT: the network's own tokens, passthrough only; tags denied");
      Check (DC_Log.Has (" 221 alice_ +iw"), "the upstream's user modes");
      Check (DC_Log.Has (" 422 alice_ :Use /motd"), "MOTD hint on a network");
      Check (DC_Log.Has ("BATCH +") and then DC_Log.Has ("soju.im/bouncer-networks")
             and then DC_Log.Has ("BOUNCER NETWORK")
             and then DC_Log.Has ("name=libera"), "the network list batch");
      Check (DC_Log.Has (" JOIN #chan acct :Real Name"),
             "the replayed JOIN carries the account and real name "
             & "(extended-join)");
      Check (DC_Log.Has (" JOIN #chan") and then DC_Log.Has (" 332 alice_ #chan :the topic")
             and then DC_Log.Has (" 353 * = #chan alice_")
             and then DC_Log.Has (" 366 * #chan"), "the joined channel is replayed");
      Check (not DC_Log.Has ("#quiet") and then not DC_Log.Has ("#pending"),
             "detached and incomplete channels are not");
      Check (DC_Log.Has ("you were kicked from #kicked by op (bye)")
             and then DC_Log.Has ("send JOIN #kicked to rejoin"),
             "kicked channels are announced");
      Check (DC_Log.Has ("MARKREAD") = False, "(no read markers asked for)");

      --  Bind by name, to an existing network.
      DC := New_Client (Script ("x"), 31, DC_Log);
      DC.Registered := True;
      DC.Registration.Network_Name := To_Unbounded_String ("libera");
      Res := HS.Welcome (DC, U);
      Check (not Res.Failed and then DC.Network = Net, "bound by name");

      --  Errors.
      DC := New_Client (Script ("x"), 32, DC_Log);
      DC.Registered := True;
      DC.Registration.Network_ID := 99999;
      Res := HS.Welcome (DC, U);
      Check (Res.Failed and then Res.Is_IRC
             and then Soja.Downstream.Image (Res.Err)
                        = "FAIL BOUNCER INVALID_NETID 99999 :Unknown network ID",
             "unknown network id: " & Soja.Downstream.Image (Res.Err));
      DC := New_Client (Script ("x"), 33, DC_Log);
      DC.Registered := True;
      DC.Registration.Network_Name := To_Unbounded_String ("*");
      Res := HS.Welcome (DC, U);
      Check (Res.Failed and then Soja.Downstream.Image (Res.Err)
               = "464 * :Multi-upstream mode is no longer supported",
             "multi-upstream mode: " & Soja.Downstream.Image (Res.Err));

      --  History: the backlog of a client that was away.
      declare
         Store : constant Soja.Msgstore.Store_Access :=
           Soja.Msgstore.Memory.New_Memory_Store;
         Before : Unbounded_String;
      begin
         U.Msg_Store := Store;
         Before := To_Unbounded_String
           (Store.Last_Msg_ID (Net.Network_Record, "#chan", Ada.Calendar.Clock));
         Soja.User.Store_ID (Net.Delivered, "#chan", "phone", To_String (Before));
         declare
            Ignored : constant String := Store.Append
              (Net.Network_Record, "#chan",
               Parse_Message (":carol!c@h PRIVMSG #chan :while you were away"));
            pragma Unreferenced (Ignored);
         begin
            null;
         end;

         DC := New_Client (Script ("x"), 34, DC_Log);
         DC.Registered := True;
         DC.Registration.Network_ID := Net.Network_Record.ID;
         DC.Client_Name := To_Unbounded_String ("phone");
         Soja.Irc.Cap_Registry.Set_Enabled (DC.Caps, "batch", True);
         Res := HS.Welcome (DC, U);
         Check (not Res.Failed, "welcome with a backlog");
         Settle;
         Check (DC_Log.Has ("chathistory #chan")
                and then DC_Log.Has ("PRIVMSG #chan :while you were away"),
                "the missed message is replayed in a batch");
         Check (Soja.User.Load_ID (Net.Delivered, "#chan", "phone")
                /= To_String (Before), "history is fast-forwarded");

         --  A second client with the same name does not get it again.
         U.Downstream_Conns.Append (DC);
         declare
            Second_Log : Recorder_Access;
            Second : constant Downstream_Conn_Access :=
              New_Client (Script ("x"), 35, Second_Log);
         begin
            Second.Registered := True;
            Second.Registration.Network_ID := Net.Network_Record.ID;
            Second.Client_Name := To_Unbounded_String ("phone");
            Soja.User.Store_ID
              (Net.Delivered, "#chan", "phone", To_String (Before));
            Res := HS.Welcome (Second, U);
            Settle;
            Check (not Second_Log.Has ("chathistory"),
                   "only the first client of that name gets the backlog");
         end;
         U.Downstream_Conns.Clear;
         U.Msg_Store := null;
      end;
   end;

   -------------------------------------------------------------------
   --  Asking for a new network by name creates it
   -------------------------------------------------------------------
   declare
      Asked : Unbounded_String;
      Fails : Boolean := False;

      function Fake_Check (Addr : String) return String is
      begin
         Asked := To_Unbounded_String (Addr);
         return (if Fails then "connection refused" else "");
      end Fake_Check;

      DC_Log : Recorder_Access;
      DC     : Downstream_Conn_Access;
      Res    : Irc_Error_Result;
      Before : constant Natural := Natural (U.Networks.Length);

      function Try (Nick, Network : String; ID : Long_Long_Integer)
         return Irc_Error_Result
      is
      begin
         DC := New_Client (Script ("x"), ID, DC_Log);
         DC.Registered := True;
         DC.Registration.Nick := To_Unbounded_String (Nick);
         DC.Registration.Network_Name := To_Unbounded_String (Network);
         return HS.Welcome (DC, U);
      end Try;
   begin
      HS.Sanity_Check := Fake_Check'Unrestricted_Access;

      Res := Try ("bobby/irc.new.example", "irc.new.example", 40);
      Check (not Res.Failed and then To_String (Asked) = "irc.new.example:6697",
             "a new network is checked on port 6697 first");
      Check (Natural (U.Networks.Length) = Before + 1
             and then DC.Network /= null
             and then To_String (DC.Network.Network_Record.Nick) = "bobby"
             and then To_String (DC.Network.Network_Record.Addr)
                      = "irc.new.example",
             "created, with the nick stripped of its network suffix");
      Check (Natural (SD.List_Networks (DB.all, U.User_Record.ID).Length)
             = Before + 1,
             "and stored");

      Res := Try ("bobby", "other.example:7000", 41);
      Check (To_String (Asked) = "other.example:7000", "an explicit port is kept");
      Check (not Res.Failed, "second network");

      Fails := True;
      Res := Try ("bobby", "down.example", 42);
      Check (Res.Failed and then Soja.Downstream.Image (Res.Err)
               = "464 * :Failed to connect to ""down.example""",
             "unreachable server: " & Soja.Downstream.Image (Res.Err));
      Fails := False;

      Res := Try ("bad nick!", "ok.example", 43);
      Check (Res.Failed and then Soja.Downstream.Image (Res.Err)(1 .. 3) = "432",
             "illegal nickname characters");
      Res := Try ("BouncerServ", "ok2.example", 44);
      Check (Res.Failed and then Soja.Downstream.Image (Res.Err)(1 .. 3) = "433",
             "the service's nick is reserved");
      Check (Natural (U.Networks.Length) = Before + 2,
             "failed attempts create nothing");
      HS.Sanity_Check := HS.Default_Sanity_Check'Access;
   end;

   for I in 1 .. N_Conns loop
      Soja.Conn.Close (Conns (I));
   end loop;
   Ada.Text_IO.Put_Line ("ALL PASS");
exception
   when E : others =>
      Ada.Text_IO.Put_Line
        ("FAILED: " & Ada.Exceptions.Exception_Information (E));
      if Last_Log /= null then
         delay 0.3;
         Ada.Text_IO.Put_Line ("--- the newest client received ---");
         for I in 1 .. Last_Log.Count loop
            Ada.Text_IO.Put_Line (Last_Log.Line (I));
         end loop;
      end if;
      GNAT.OS_Lib.OS_Exit (1);
end Handshake_Check;
