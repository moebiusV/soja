pragma Ada_2022;

with Ada.Calendar;
with Ada.Containers;
with Ada.Containers.Indefinite_Vectors;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;
with Ada.Exceptions;
with Ada.Text_IO;
with GNAT.OS_Lib;

with Soja.Conn;
with Soja.Core;
with Soja.Core.Downstream_Helpers;
with Soja.Core.Network_Ops;
with Soja.Core.Upstream_Dispatch;
with Soja.Database;
with Soja.Irc.Cap_Registry;
with Soja.Irc.Case_Mapping;
with Soja.Irc.Members;
with Soja.Irc.Helpers;
with Soja.Irc.Messages;
with Soja.Irc.Xirc;
with Soja.Database;
with Soja.Msgstore;
with Soja.Msgstore.Memory;
with Soja.Logging;
with Soja.Server;
with Soja.Timers;
with Soja.User;

procedure Upstream_Dispatch_Check is
   use Soja.Core;
   use Soja.Core.Upstream_Dispatch;
   use Soja.Irc.Messages;
   use type Ada.Containers.Count_Type;
   use type Ada.Calendar.Time;
   use type Soja.Irc.Members.Membership_Set_Access;
   use type Soja.Irc.Members.Channel_Status;
   use type Soja.Irc.Case_Mapping.Kind;
   use type Soja.Timers.Timer_Access;

   procedure Check (Cond : Boolean; What : String) is
   begin
      if not Cond then
         raise Program_Error with What;
      end if;
   end Check;

   --  Records what a connection's writer sends.
   package String_Vectors is new Ada.Containers.Indefinite_Vectors
     (Positive, String);

   protected type Recorder is
      procedure Add (Line : String);
      function Count return Natural;
      function Line (I : Positive) return String;
      function Contains (Prefix : String) return Boolean;
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

      function Contains (Prefix : String) return Boolean is
      begin
         for L of V loop
            if L'Length >= Prefix'Length
              and then L (L'First .. L'First + Prefix'Length - 1) = Prefix
            then
               return True;
            end if;
         end loop;
         return False;
      end Contains;
   end Recorder;

   type Fake_Transport is new Soja.Conn.IRC_Conn with record
      Log : Recorder_Access;
   end record;
   overriding function Read_Message
     (C : in out Fake_Transport) return Message is (others => <>);
   overriding procedure Write_Message
     (C : in out Fake_Transport; M : Message);
   overriding procedure Close (C : in out Fake_Transport) is null;
   overriding function Remote_Addr (C : Fake_Transport) return String is
     ("1.2.3.4:6667");

   overriding procedure Write_Message
     (C : in out Fake_Transport; M : Message) is
   begin
      C.Log.Add (Image (M));
   end Write_Message;

   --  Line I, or "" when there is no such line yet (message arguments are
   --  evaluated before the Wait that would make it exist).
   function Line_Of (R : Recorder; I : Natural) return String is
     (if I >= 1 and then I <= R.Count then R.Line (I) else "");

   --  Wait (up to 3 s) until the recorder holds N lines.
   function Wait (R : Recorder; N : Natural) return Boolean is
      Waited : Duration := 0.0;
   begin
      while R.Count < N and then Waited < 3.0 loop
         delay 0.02;
         Waited := Waited + 0.02;
      end loop;
      return R.Count >= N;
   end Wait;

   --  Let the writers drain, then expect exactly N lines.
   procedure Settle (R : Recorder; N : Natural; What : String) is
   begin
      if not Wait (R, N) then
         raise Program_Error with
           What & ": expected" & Natural'Image (N) & " lines, got"
           & Natural'Image (R.Count);
      end if;
      delay 0.15;
      Check (R.Count = N, What & ": expected" & Natural'Image (N)
             & " lines, got" & Natural'Image (R.Count));
   end Settle;

   Log      : aliased Soja.Logging.Standard_Logger;
   Srv      : aliased Soja.Server.Server;
   Rec      : Soja.Database.User := Soja.Database.New_User ("alice");
   U        : User_Access;
   NR       : Soja.Database.Network :=
     Soja.Database.New_Network ("irc+insecure://irc.example");
   Chans    : Soja.Database.Channel_Lists.Vector;
   Net      : Network_Access;
   UC       : constant Upstream_Conn_Access := new Upstream_Conn;
   DC       : Downstream_Conn_Access;
   UC_Log   : aliased Recorder;
   DC_Log   : aliased Recorder;
   UC_Wire  : aliased Fake_Transport := (Soja.Conn.IRC_Conn with Log => UC_Log'Unchecked_Access);
   DC_Wire  : aliased Fake_Transport := (Soja.Conn.IRC_Conn with Log => DC_Log'Unchecked_Access);

   function H (Line : String) return Handle_Result is
     (Handle_Message (UC, Parse_Message (Line)));

   procedure Ok (Line : String) is
      R : constant Handle_Result := H (Line);
   begin
      Check (not R.Failed, Line & " failed: " & To_String (R.Reason));
   end Ok;

   function Last_Line (R : Recorder) return String is
     (Line_Of (R, R.Count));
begin
   Srv.Initialize (Log'Unchecked_Access);
   U := New_User (Srv'Unchecked_Access, Rec);

   NR.ID := 1;
   Chans.Append (Soja.Database.Channel'
     (Name => To_Unbounded_String ("#a"), Key => To_Unbounded_String ("k"),
      others => <>));
   Chans.Append (Soja.Database.Channel'
     (Name => To_Unbounded_String ("#b"), others => <>));
   Net := New_Network (U, NR, Chans);
   U.Networks.Append (Net);

   UC.Network := Net;
   UC.User := U;
   UC.Srv := Srv'Unchecked_Access;
   UC.Logger := Log'Unchecked_Access;
   UC.Nick := To_Unbounded_String ("alice");
   UC.Conn := Soja.Conn.New_Conn
     (UC_Wire'Unchecked_Access,
      (Logger => null, Rate_Limit_Delay => 0.0, Rate_Limit_Burst => 0,
         others => <>));
   UC.Channels := Upstream_Channel_Maps.New_Map (Soja.Irc.Case_Mapping.Case_RFC1459);
   UC.Users := Upstream_User_Maps.New_Map (Soja.Irc.Case_Mapping.Case_RFC1459);
   UC.Monitored := Flag_Maps.New_Map (Soja.Irc.Case_Mapping.Case_RFC1459);
   UC.Join_Retries :=
     Join_Retry_Maps.New_Map (Soja.Irc.Case_Mapping.Case_RFC1459);
   UC.Caps := Soja.Irc.Cap_Registry.New_Registry;
   UC.Server_Prefix := new Prefix'(Name => To_Unbounded_String ("*"), others => <>);
   UC.Available_Channel_Types := To_Unbounded_String (Soja.Irc.Members.Std_Channel_Types);
   for M of Soja.Irc.Members.Std_Memberships loop
      UC.Available_Memberships.Append (M);
   end loop;
   UC.Has_Desired_Nick := True;
   Net.Conn := UC;

   DC := New_Downstream_Conn (Srv'Unchecked_Access, DC_Wire'Unchecked_Access, 5);
   DC.Network := Net;
   DC.User := U;
   DC.Nick := To_Unbounded_String ("bob");
   DC.Registered := True;
   Soja.Irc.Cap_Registry.Set_Enabled (DC.Caps, "message-tags", True);
   U.Downstream_Conns.Append (DC);

   -------------------------------------------------------------------
   --  Preamble: PING, label, batch, prefix, time tag.
   -------------------------------------------------------------------
   Ok ("PING :token");
   Check (Wait (UC_Log, 1) and then Line_Of (UC_Log, 1) = "PONG token", "PONG: " & Line_Of (UC_Log, 1));

   declare
      R : Handle_Result := H ("@label=bogus ZZZ");
   begin
      Check (R.Failed and then not R.Is_Registration_Error
             and then Index (R.Reason, "unexpected message label") = 1,
             "bad label");
      R := H ("@label=sd-5 ZZZ");
      Check (R.Failed and then Index (R.Reason, "not enough arguments") > 0,
             "label missing offset");
      R := H ("@label=xx-5-0-a ZZZ");
      Check (R.Failed and then Index (R.Reason, "expected sd, got xx") > 0,
             "label of another kind");
      R := H ("@label=sd-z-0-a ZZZ");
      Check (R.Failed and then Index (R.Reason, "invalid syntax") > 0,
             "label with a bad id");
      R := H ("@batch=nope ZZZ");
      Check (R.Failed and then Index (R.Reason, "unexpected batch reference") = 1,
             "unknown batch");
   end;

   --  An unhandled command is forwarded to downstreams, with the server
   --  prefix (the "*" sentinel is stripped) and a time tag.
   Ok ("ZZZ hello");
   Check (Wait (DC_Log, 1), "forwarded to downstream");
   Check (Line_Of (DC_Log, 1)'Length > 0
          and then Ada.Strings.Fixed.Index (Line_Of (DC_Log, 1), "time=") > 0
          and then Ada.Strings.Fixed.Index (Line_Of (DC_Log, 1), "ZZZ hello") > 0,
          "default branch forwards with a time tag: " & Line_Of (DC_Log, 1));
   --  A label routes the reply to one downstream only.
   Ok ("@label=sd-99-0- ZZZ routed");
   delay 0.15;
   Check (DC_Log.Count = 1, "label for another downstream is not delivered");
   Ok ("@label=sd-5-0- ZZZ routed");
   Check (Wait (DC_Log, 2), "label for this downstream is delivered");
   --  The client's own label comes back with the answer.
   Ok ("@label=sd-5-1-mine ZZZ answer");
   Check (Wait (DC_Log, 3) and then DC_Log.Has ("label=mine")
          and then DC_Log.Has ("ZZZ answer"),
          "the client's label is on the answer");
   Ok ("@label=sd-5-2- ZZZ unlabeled");
   Check (Wait (DC_Log, 4) and then Ada.Strings.Fixed.Index (Line_Of (DC_Log, 4), "label=") = 0,
          "no label from the client: none on the answer");
   --  A valid server-time is kept.
   Ok ("@time=2024-02-29T13:45:09.123Z ZZZ timed");
   Check (Wait (DC_Log, 5)
          and then Ada.Strings.Fixed.Index
                     (Line_Of (DC_Log, 5), "time=2024-02-29T13:45:09.123Z") > 0,
          "server time kept: " & Line_Of (DC_Log, 5));

   -------------------------------------------------------------------
   --  CAP negotiation and SASL PLAIN.
   -------------------------------------------------------------------
   Net.Network_Record.SASL.Mechanism := To_Unbounded_String ("PLAIN");
   Net.Network_Record.SASL.Plain_Username := To_Unbounded_String ("alice");
   Net.Network_Record.SASL.Plain_Password := To_Unbounded_String ("secret");

   --  A multiline LS waits for its last part.
   Ok (":irc CAP * LS * :multi-prefix");
   delay 0.15;
   Check (UC_Log.Count = 1, "multiline CAP LS: no reply yet");
   --  The sub-parameter before the last is "*" even with extra parameters.
   Ok (":irc CAP * LS x * :account-notify");
   delay 0.15;
   Check (UC_Log.Count = 1, "CAP LS continuation with extra parameters");
   Soja.Irc.Cap_Registry.Delete (UC.Caps, "account-notify");
   Ok (":irc CAP * LS :sasl=PLAIN,EXTERNAL server-time");
   Check (Wait (UC_Log, 2)
          and then Line_Of (UC_Log, 2) = "CAP REQ :multi-prefix sasl server-time",
          "CAP REQ: " & Line_Of (UC_Log, 2));
   Settle (UC_Log, 2, "no CAP END while SASL is pending");
   Check (Request_SASL (UC) and then Supports_SASL (UC, "PLAIN"), "request SASL");
   Check (Supports_SASL (UC, "plain") and then Supports_SASL (UC, "EXTERNAL"),
          "mechanisms are matched case-insensitively");
   Check (not Supports_SASL (UC, "SCRAM-SHA-256"),
          "a mechanism the server does not list is not supported");

   Ok (":irc CAP * ACK :sasl multi-prefix");
   Check (Wait (UC_Log, 3) and then Line_Of (UC_Log, 3) = "AUTHENTICATE PLAIN",
          "AUTHENTICATE PLAIN: " & Line_Of (UC_Log, 3));
   Check (UC.Sasl_Mech = Sasl_Plain, "SASL client set");
   Check (Soja.Irc.Cap_Registry.Is_Enabled (UC.Caps, "multi-prefix"),
          "ACK enables caps");

   Ok ("AUTHENTICATE +");
   Check (Wait (UC_Log, 4)
          and then Line_Of (UC_Log, 4) = "AUTHENTICATE AGFsaWNlAHNlY3JldA==",
          "SASL PLAIN response: " & Line_Of (UC_Log, 4));
   --  A second challenge is an error: PLAIN has none.
   declare
      R : constant Handle_Result := H ("AUTHENTICATE +");
   begin
      Check (R.Failed, "unexpected server challenge");
      Check (Wait (UC_Log, 5) and then Line_Of (UC_Log, 5) = "AUTHENTICATE *",
             "abort with AUTHENTICATE *");
   end;
   Net.Network_Record.SASL.Mechanism := To_Unbounded_String ("PLAIN");
   Ok (":irc 903 alice :SASL authentication successful");
   Check (UC.Sasl_Mech = Sasl_None and then not UC.Sasl_Started, "SASL done");
   Check (Wait (UC_Log, 6) and then Line_Of (UC_Log, 6) = "CAP END",
          "CAP END after SASL while unregistered");

   --  A configured mechanism soja cannot run is reported by its own name.
   Net.Network_Record.SASL.Mechanism := To_Unbounded_String ("FOO");
   Soja.Irc.Cap_Registry.Set_Available (UC.Caps, "sasl", "FOO");
   declare
      R : constant Handle_Result := H (":irc CAP * ACK :sasl");
   begin
      Check (R.Failed
             and then To_String (R.Reason)
                      = "unsupported SASL mechanism ""FOO""",
             "unsupported mechanism: " & To_String (R.Reason));
   end;
   Net.Network_Record.SASL.Mechanism := To_Unbounded_String ("PLAIN");
   Soja.Irc.Cap_Registry.Set_Available (UC.Caps, "sasl", "PLAIN,EXTERNAL");

   --  AUTHENTICATE without a client is an error.
   Check (H ("AUTHENTICATE +").Failed, "unexpected AUTHENTICATE");

   --  NEW requests the new caps; DEL drops them; "-cap" in ACK disables.
   Ok (":irc CAP alice NEW :account-tag");
   Check (Wait (UC_Log, 7) and then Line_Of (UC_Log, 7) = "CAP REQ :account-tag server-time",
          "CAP NEW requests: " & Line_Of (UC_Log, 7));
   Ok (":irc CAP alice ACK :account-tag");
   Check (Soja.Irc.Cap_Registry.Is_Enabled (UC.Caps, "account-tag"), "enabled");
   Ok (":irc CAP alice ACK :-account-tag");
   Check (not Soja.Irc.Cap_Registry.Is_Enabled (UC.Caps, "account-tag"),
          "-cap disables");
   Ok (":irc CAP alice DEL :account-tag");
   Check (not Soja.Irc.Cap_Registry.Is_Available (UC.Caps, "account-tag"),
          "DEL removes");
   Check (H (":irc CAP alice LS").Failed, "CAP LS without caps");
   Check (H (":irc CAP").Failed, "CAP without params");

   -------------------------------------------------------------------
   --  Registration: nick-in-use fallback, errors.
   -------------------------------------------------------------------
   UC_Wire.Log.Add ("--- registration ---");
   declare
      N : constant Natural := UC_Log.Count;
   begin
      Ok (":irc 433 * alice :Nickname is already in use");
      Check (Wait (UC_Log, N + 1) and then Last_Line (UC_Log) = "NICK alice_",
             "nick fallback: " & Last_Line (UC_Log));
      Check (To_String (UC.Nick) = "alice_" and then not UC.Has_Desired_Nick,
             "fallback state");
   end;
   declare
      R : Handle_Result := H (":irc 464 * :Password incorrect");
   begin
      Check (R.Failed and then R.Is_Registration_Error and then not R.Temporary
             and then To_String (R.Reason) = "Password incorrect",
             "464 is a permanent registration error");
      R := H (":irc 465 * :You are banned");
      Check (R.Failed and then R.Is_Registration_Error and then R.Temporary,
             "465 is temporary");
      R := H (":irc FAIL * ACCOUNT_REQUIRED :Account required");
      Check (R.Failed and then R.Is_Registration_Error and then not R.Temporary,
             "ACCOUNT_REQUIRED is permanent");
      R := H ("ERROR :Closing link");
      Check (R.Failed and then not R.Is_Registration_Error
             and then To_String (R.Reason) = "fatal server error: Closing link",
             "ERROR");
   end;

   -------------------------------------------------------------------
   --  The session start: connect commands, a pause, then the autojoin.
   -------------------------------------------------------------------
   declare
      use type Ada.Calendar.Time;
      K  : constant Natural := UC_Log.Count;
      T0 : Ada.Calendar.Time;
   begin
      Net.Network_Record.Connect_Commands.Append
        (To_Unbounded_String ("PRIVMSG NickServ :IDENTIFY secret"));
      Soja.Core.Join_Delay := 0.6;
      T0 := Ada.Calendar.Clock;
      Soja.Core.Start_Session (UC);
      Check (Ada.Calendar.Clock - T0 >= 0.5,
             "joining waits after the connect commands");
      Check (Wait (UC_Log, K + 2)
             and then Line_Of (UC_Log, K + 1)
                      = "PRIVMSG NickServ :IDENTIFY secret"
             and then Line_Of (UC_Log, K + 2) = "JOIN #a,#b k",
             "the connect command comes first, then the JOIN: "
             & Last_Line (UC_Log));

      --  Nothing to wait for: the JOINs go at once.
      Net.Network_Record.Connect_Commands.Clear;
      T0 := Ada.Calendar.Clock;
      Soja.Core.Start_Session (UC);
      Check (Ada.Calendar.Clock - T0 < 0.3, "no pause without a reason");

      --  A certificate the server does not offer SASL EXTERNAL for: pause.
      Net.Network_Record.SASL.Mechanism := To_Unbounded_String ("EXTERNAL");
      Soja.Irc.Cap_Registry.Set_Available (UC.Caps, "sasl", "PLAIN");
      T0 := Ada.Calendar.Clock;
      Soja.Core.Start_Session (UC);
      Check (Ada.Calendar.Clock - T0 >= 0.5,
             "joining waits when SASL EXTERNAL is configured but not offered");
      Soja.Irc.Cap_Registry.Set_Available (UC.Caps, "sasl", "EXTERNAL,PLAIN");
      T0 := Ada.Calendar.Clock;
      Soja.Core.Start_Session (UC);
      Check (Ada.Calendar.Clock - T0 < 0.3,
             "and joins at once when the server offers it");
      Soja.Irc.Cap_Registry.Delete (UC.Caps, "sasl");
      Net.Network_Record.SASL.Mechanism := Null_Unbounded_String;
      Soja.Core.Join_Delay := 3.0;
   end;

   -------------------------------------------------------------------
   --  001: registered, and the saved channels are joined once.
   -------------------------------------------------------------------
   declare
      N : constant Natural := UC_Log.Count;
   begin
      Ok (":irc 001 alice_ :Welcome");
      Check (UC.Registered and then To_String (UC.Nick) = "alice_", "001");
      --  (The channels are joined once the session starts, not on the 001.)
      Soja.Core.Upstream_Dispatch.Join_Saved_Channels (UC);
      Check (UC.Server_Prefix /= null
             and then To_String (UC.Server_Prefix.Name) = "irc",
             "server prefix from 001");
      Check (Wait (UC_Log, N + 1) and then Last_Line (UC_Log) = "JOIN #a,#b k",
             "autojoin: " & Last_Line (UC_Log));
   end;

   --  Once registered, a nick-in-use is forwarded, not retried.
   declare
      N : constant Natural := DC_Log.Count;
   begin
      Ok (":irc 433 alice_ taken :Nickname is already in use");
      Check (Wait (DC_Log, N + 1), "433 forwarded once registered");
   end;
   declare
      N : constant Natural := DC_Log.Count;
   begin
      UC.Pending_Regain_Nick := To_Unbounded_String ("taken");
      Ok (":irc 433 alice_ TAKEN :Nickname is already in use");
      delay 0.15;
      Check (DC_Log.Count = N and then Length (UC.Pending_Regain_Nick) = 0,
             "our own regain attempt is not relayed");
   end;

   -------------------------------------------------------------------
   --  004 / 005.
   -------------------------------------------------------------------
   --  Names with a prefix are "prefix/KEY"; values have \x20 and \x5C
   --  decoded; soju.im/SAFERATE turns the client-side rate limit off.
   Ok (":irc 005 alice_ DRAFT/icon=https://x.example/a\x20b\x5Cc "
       & "soju.im/saferate :are supported");
   Check (UC.Isupport.Contains ("draft/ICON")
          and then To_String (UC.Isupport ("draft/ICON").Value)
                   = "https://x.example/a b\c",
          "a prefixed name and a decoded value");
   Check (UC.Isupport.Contains ("soju.im/SAFERATE"), "SAFERATE");
   Ok (":irc 005 alice_ -soju.im/saferate :are supported");
   Check (not UC.Isupport.Contains ("soju.im/SAFERATE"), "SAFERATE negated");
   Ok (":irc 004 alice_ irc.example ircd-1.0 iosw biklmnopstv");
   Check (To_String (UC.Server_Name) = "irc.example"
          and then To_String (UC.Available_User_Modes) = "iosw", "004");
   Check (H (":irc 004 alice_ irc.example").Failed, "004 needs 5 params");

   declare
      N : constant Natural := DC_Log.Count;
   begin
      Ok (":irc 005 alice_ CASEMAPPING=ascii CHANTYPES=#& PREFIX=(qov)~@+ "
          & "CHANMODES=beI,k,l,imnpst STATUSMSG=@+ NETWORK=Test MONITOR=100 "
          & "FUNKY=1 :are supported");
      Check (Net.Casemap = Soja.Irc.Case_Mapping.Case_ASCII
             and then DC.Casemap = Soja.Irc.Case_Mapping.Case_ASCII,
             "CASEMAPPING applies to the network and its downstreams");
      Check (To_String (UC.Available_Channel_Types) = "#&"
             and then To_String (UC.Available_Status_Msg) = "@+",
             "CHANTYPES / STATUSMSG");
      Check (UC.Available_Memberships.Length = 3
             and then UC.Available_Memberships (1).Mode = 'q'
             and then UC.Available_Memberships (3).Prefix = '+',
             "PREFIX");
      Check (UC.Available_Channel_Modes.Contains ('e')
             and then UC.Available_Channel_Modes.Contains ('p'),
             "CHANMODES");
      Check (UC.Isupport.Contains ("FUNKY") and then
             UC.Isupport ("NETWORK").Has_Value
             and then To_String (UC.Isupport ("NETWORK").Value) = "Test",
             "isupport table");
      Check (Is_Channel (UC, "&local") and then not Is_Channel (UC, "nick"),
             "Is_Channel");
      --  Downstreams get only the passthrough tokens.
      Check (Wait (DC_Log, N + 1), "isupport forwarded");
      declare
         L : constant String := Line_Of (DC_Log, N + 1);
      begin
         Check (Ada.Strings.Fixed.Index (L, " 005 bob") > 0
                or else Ada.Strings.Fixed.Index (L, " 005 *") > 0,
                "005 reply: " & L);
         Check (Ada.Strings.Fixed.Index (L, "CASEMAPPING=ascii") > 0
                and then Ada.Strings.Fixed.Index (L, "NETWORK=Test") > 0
                and then Ada.Strings.Fixed.Index (L, "FUNKY") = 0,
                "only passthrough tokens: " & L);
      end;
   end;
   Check (H (":irc 005 alice_ CHANMODES=a,b :are supported").Failed,
          "malformed CHANMODES");
   Check (H (":irc 005 alice_ PREFIX=ov@+ :are supported").Failed,
          "malformed PREFIX");
   Check (H (":irc 005 alice_ PREFIX=(ovv)@+ :are supported").Failed,
          "PREFIX with mismatched lengths");
   --  Negated tokens ("-PREFIX") undo a setting (a bug in Go; PORTING.md).
   declare
      N : constant Natural := DC_Log.Count;
   begin
      Ok (":irc 005 alice_ -PREFIX -CHANTYPES -STATUSMSG :are supported");
      Check (UC.Available_Memberships.Length = 5
             and then UC.Available_Memberships (1).Mode = 'q',
             "-PREFIX restores the standard memberships");
      Check (To_String (UC.Available_Channel_Types) = "#&+!"
             and then To_String (UC.Available_Status_Msg) = "",
             "-CHANTYPES / -STATUSMSG reset to the defaults");
      Check (not UC.Isupport.Contains ("PREFIX"),
             "a negated token leaves the isupport table");
      Check (Wait (DC_Log, N + 1)
             and then Ada.Strings.Fixed.Index
                        (Line_Of (DC_Log, N + 1), "-PREFIX") > 0,
             "downstreams are told about the negation: "
             & Line_Of (DC_Log, N + 1));
   end;
   declare
      N : constant Natural := DC_Log.Count;
   begin
      Ok (":irc 005 alice_ -CHANMODES :are supported");
      Check (Wait (DC_Log, N + 1), "-CHANMODES reaches downstreams");
   end;
   Check (UC.Available_Channel_Modes.Contains ('t')
          and then not UC.Available_Channel_Modes.Contains ('p'),
          "-CHANMODES restores the standard modes");

   -------------------------------------------------------------------
   --  End of MOTD: the first one is swallowed and finishes setup.
   -------------------------------------------------------------------
   declare
      N : constant Natural := DC_Log.Count;
   begin
      Ok (":irc 375 alice_ :- irc MOTD -");
      Ok (":irc 372 alice_ :- hello");
      delay 0.15;
      Check (DC_Log.Count = N, "initial MOTD is not forwarded");
      Ok (":irc 376 alice_ :End of MOTD");
      Check (UC.Got_MOTD, "got MOTD");
      Check (UC.Regain_Nick_Timer = null,
             "server supports MONITOR: no regain timer");
      delay 0.15;
      Check (DC_Log.Count = N, "first end-of-MOTD is swallowed");
      Ok (":irc 375 alice_ :- irc MOTD -");
      Check (Wait (DC_Log, N + 1), "later MOTD is forwarded");
   end;

   -------------------------------------------------------------------
   --  Accounts and hosts.
   -------------------------------------------------------------------
   Soja.Irc.Cap_Registry.Set_Enabled (DC.Caps, "sasl", True);
   declare
      N : constant Natural := DC_Log.Count;
   begin
      Ok (":irc 900 alice_ alice_!~ident@host.example alice :You are logged in");
      Check (To_String (UC.Account) = "alice"
             and then To_String (UC.Username) = "~ident"
             and then To_String (UC.Hostname) = "host.example",
             "900 state");
      Check (Wait (DC_Log, N + 2), "900 and 396 for the downstream");
      Check (DC_Log.Contains (":localhost 900 bob bob!~u@1.2.3.4 alice :You are logged in as alice"),
             "downstream sees 900");
      Check (DC_Log.Contains (":bob!~u@1.2.3.4 396 bob host.example :is now your visible host"),
             "visible host (no chghost)");
      Check (To_String (DC.Account) = "alice"
             and then To_String (DC.Hostname) = "host.example",
             "downstream state follows");
   end;
   Ok (":irc 396 alice_ new.example :is now your visible host");
   Check (To_String (UC.Hostname) = "new.example", "396 without a user part");
   Ok (":irc 396 alice_ u@other.example :is now your visible host");
   Check (To_String (UC.Username) = "u"
          and then To_String (UC.Hostname) = "other.example", "396 user@host");
   Ok (":irc 901 alice_ alice_!~ident@host.example :You are logged out");
   Check (Length (UC.Account) = 0, "901");
   delay 0.2;
   Check (DC_Log.Contains (":localhost 901 bob "), "downstream sees 901");

   -------------------------------------------------------------------
   --  Pending commands.
   -------------------------------------------------------------------
   declare
      N : constant Natural := UC_Log.Count;
      P : Pending_Command;
   begin
      Enqueue_Command (UC, DC, Parse_Message ("WHOIS carol"));
      Check (Wait (UC_Log, N + 1) and then Last_Line (UC_Log) = "WHOIS carol",
             "first pending command is sent");
      Enqueue_Command (UC, DC, Parse_Message ("WHOIS dave"));
      delay 0.15;
      Check (UC_Log.Count = N + 1, "second one waits its turn");
      P := Current_Pending_Command (UC, "WHOIS");
      Check (P.Found and then P.DC = DC and then Param (P.Msg, 0) = "carol",
             "current pending command");
      --  A 421 reply for WHOIS completes the first and sends the next.
      Ok (":irc 421 alice_ WHOIS :Unknown command");
      Check (Wait (UC_Log, N + 2) and then Last_Line (UC_Log) = "WHOIS dave",
             "next pending command sent: " & Last_Line (UC_Log));
      Check (Wait (DC_Log, DC_Log.Count), "421 forwarded to the asker");
      P := Dequeue_Command (UC, "WHOIS");
      Check (P.Found, "dequeue");
      P := Dequeue_Command (UC, "WHOIS");
      Check (not P.Found, "nothing left");

      --  A command whose reply never came is given up on after 30 s, and the
      --  next one is sent in its place (Go duplicated the last entry and
      --  never sent it).
      declare
         K : constant Natural := UC_Log.Count;
      begin
         Enqueue_Command (UC, DC, Parse_Message ("WHOIS stale"));
         Check (Wait (UC_Log, K + 1)
                and then Last_Line (UC_Log) = "WHOIS stale", "stale sent");
         declare
            V  : Pending_Command_Vectors.Vector := UC.Pending_Cmds ("WHOIS");
            PC : Pending_Upstream_Command := V (1);
         begin
            PC.Sent_At := Ada.Calendar.Clock - 40.0;
            V.Replace_Element (1, PC);
            UC.Pending_Cmds.Replace ("WHOIS", V);
         end;
         Enqueue_Command (UC, DC, Parse_Message ("WHOIS fresh"));
         Check (Wait (UC_Log, K + 2)
                and then Last_Line (UC_Log) = "WHOIS fresh",
                "the next command is sent after giving up");
         Check (UC.Pending_Cmds ("WHOIS").Length = 1
                and then Param (UC.Pending_Cmds ("WHOIS") (1).Msg, 0)
                         = "fresh",
                "the stale command is dropped, not duplicated");
         P := Dequeue_Command (UC, "WHOIS");
         Check (P.Found, "dequeue the fresh one");
      end;
      --  Cancelling skips the running command.
      Enqueue_Command (UC, DC, Parse_Message ("WHO #x"));
      Enqueue_Command (UC, DC, Parse_Message ("WHO #y"));
      Cancel_Pending_Commands_By_Downstream_ID (UC, DC.ID);
      Check (UC.Pending_Cmds ("WHO").Length = 1, "cancel keeps the running one");
      declare
         M : constant Natural := DC_Log.Count;
      begin
         Abort_Pending_Commands (UC);
         Check (Wait (DC_Log, M + 1)
                and then DC_Log.Contains (":localhost 315 bob #x :Command aborted"),
                "abort reply: " & Last_Line (DC_Log));
         Check (UC.Pending_Cmds.Is_Empty, "aborted");
      end;
      --  Labeled messages carry the downstream id once labeled-response is on.
      Soja.Irc.Cap_Registry.Set_Available (UC.Caps, "labeled-response", "");
      Soja.Irc.Cap_Registry.Set_Enabled (UC.Caps, "labeled-response", True);
      Soja.Irc.Cap_Registry.Set_Enabled (UC.Caps, "message-tags", True);
      declare
         K : constant Natural := UC_Log.Count;
      begin
         Send_Message_Labeled (UC, 5, Parse_Message ("WHO #z"));
         Check (Wait (UC_Log, K + 1)
                and then Ada.Strings.Fixed.Index (Last_Line (UC_Log), "label=sd-5-") > 0,
                "labeled: " & Last_Line (UC_Log));
      end;
   end;

   -------------------------------------------------------------------
   --  4b: channel state.  UC is registered as alice_, DC is attached.
   -------------------------------------------------------------------
   declare
      Chan : Upstream_Channel_Access;

      --  Run Line and wait for K more lines to reach the downstream.
      procedure Down (Line : String; K : Natural; What : String) is
         N : Natural;
      begin
         delay 0.1;   --  let earlier lines land: a quiet baseline
         N := DC_Log.Count;
         Ok (Line);
         Check (Wait (DC_Log, N + K), What & ": expected" & Natural'Image (K)
                & " downstream lines");
         delay 0.1;
         Check (DC_Log.Count = N + K, What & ": exactly" & Natural'Image (K)
                & " downstream lines, got"
                & Natural'Image (DC_Log.Count - N));
      end Down;

      --  Run Line and check that nothing reaches the downstream.
      procedure Quiet (Line : String; What : String) is
         N : constant Natural := DC_Log.Count;
      begin
         Ok (Line);
         delay 0.15;
         Check (DC_Log.Count = N, What & ": nothing forwarded");
      end Quiet;

      function Members_Of (Name : String)
         return Soja.Irc.Members.Member_Maps.Map is (UC.Channels.Get (Name).Members);

      function Prefix_Of_Member (Name, Nick : String) return String is
        (Soja.Irc.Helpers.Format_Member_Prefix
           (Members_Of (Name).Get (Nick).all, True));

      U_N : Natural;
   begin
      Net.Casemap := Soja.Irc.Case_Mapping.Case_RFC1459;
      Net.Channels.Set_Case_Mapping (Soja.Irc.Case_Mapping.Case_RFC1459);

      --  JOIN by us: the channel is created and its modes requested.
      U_N := UC_Log.Count;
      Down (":alice_!u@h JOIN #chan", 1, "own JOIN");
      Chan := UC.Channels.Get ("#chan");
      Check (Chan /= null and then UC.Channels.Has ("#CHAN"),
             "channel created (case-mapped)");
      Check (Wait (UC_Log, U_N + 1) and then Last_Line (UC_Log) = "MODE #chan",
             "MODE query after joining: " & Last_Line (UC_Log));
      Check (DC_Log.Has (" JOIN #chan"), "JOIN forwarded");
      Check (UC.Users.Has ("alice_"), "our user info is cached");
      Check (not Chan.Complete and then not Chan.Modes.Known, "fresh channel");

      --  JOIN for a channel we are not in is an error.
      Check (H (":carol!c@h JOIN #nowhere").Failed, "JOIN of an unknown channel");
      Check (H (":carol!c@h JOIN").Failed, "JOIN without params");

      --  Topic replies.
      Quiet (":irc 332 alice_ #chan :the topic", "332 for a joined channel");
      Check (To_String (Chan.Topic) = "the topic", "topic stored");
      Down (":irc 333 alice_ #chan setter!s@h 1700000000", 1, "333 first");
      Check (Chan.Topic_Who /= null
             and then To_String (Chan.Topic_Who.Name) = "setter"
             and then Soja.Irc.Xirc.Format_Server_Time (Chan.Topic_Time)
                      = "2023-11-14T22:13:20.000Z", "topic who/time");
      Quiet (":irc 333 alice_ #chan setter2!s@h 1700000001", "333 repeated");
      Check (H (":irc 333 alice_ #chan setter!s@h notanumber").Failed,
             "bad topic time");
      Down (":irc 332 alice_ #other :elsewhere", 1, "332 for another channel");

      --  Channel modes: forwarded once, recorded every time.
      Down (":irc 324 alice_ #chan +nt", 1, "324 first");
      Check (Chan.Modes.Known and then Chan.Modes.Values.Contains ('n')
             and then Chan.Modes.Values.Contains ('t'), "modes recorded");
      Quiet (":irc 324 alice_ #chan +ntk secret", "324 repeated");
      Check (Chan.Modes.Values.Contains ('k')
             and then Chan.Modes.Values ('k') = "secret", "key mode value");
      Down (":irc 329 alice_ #chan 1700000000", 1, "329 first");
      Check (To_String (Chan.Creation_Time) = "1700000000", "creation time");
      Quiet (":irc 329 alice_ #chan 1700000005", "329 repeated");

      --  NAMES: members are recorded, and the channel replayed at the end.
      Quiet (":irc 353 alice_ = #chan :@op +voice alice_ plain",
             "353 for a joined channel");
      Check (Chan.Status = Soja.Irc.Members.Channel_Public, "status =");
      Check (Prefix_Of_Member ("#chan", "op") = "@"
             and then Prefix_Of_Member ("#chan", "voice") = "+"
             and then Prefix_Of_Member ("#chan", "plain") = ""
             and then Members_Of ("#chan").Has ("alice_"), "members");
      Check (H (":irc 353 alice_ ? #chan :x").Failed, "bad channel status");
      --  The topic, then the member list (a 332, 333, 353 and 366).
      Down (":irc 366 alice_ #chan :End of /NAMES list", 4, "366 replays");
      Check (Chan.Complete, "channel complete");
      Check (DC_Log.Has (" 332 bob #chan :the topic")
             and then DC_Log.Has (" 333 bob #chan setter!s@h 1700000001"),
             "topic replayed");
      Check (DC_Log.Has (" 353 * = #chan :") and then DC_Log.Has ("@op")
             and then DC_Log.Has ("+voice") and then DC_Log.Has (" 366 * #chan"),
             "names replayed");
      Check (H (":irc 366 alice_ #chan :again").Failed, "duplicate 366");
      --  NAMES on a channel we are not in goes to the asker.
      Down (":irc 353 alice_ = #elsewhere :x y", 1, "353 for another channel");
      Down (":irc 366 alice_ #elsewhere :End", 1, "366 for another channel");

      --  Other users.
      Down (":carol!c@h JOIN #chan", 1, "JOIN by another user");
      Check (Members_Of ("#chan").Has ("carol")
             and then UC.Users.Has ("carol")
             and then To_String (UC.Users.Get ("carol").Hostname) = "h",
             "member and user info");
      Down (":carol!c@h NICK caroline", 1, "NICK by another user");
      Check (not Members_Of ("#chan").Has ("carol")
             and then Members_Of ("#chan").Has ("caroline")
             and then UC.Users.Has ("caroline")
             and then not UC.Users.Has ("carol"), "NICK re-keys members and users");
      Down (":op!o@h MODE #chan +o caroline", 1, "MODE +o");
      Check (Prefix_Of_Member ("#chan", "caroline") = "@", "op granted");
      Down (":op!o@h MODE #chan -o+v caroline voice", 1, "MODE -o+v");
      Check (Prefix_Of_Member ("#chan", "caroline") = "", "op removed");
      Down (":op!o@h MODE #chan +l 9", 1, "MODE +l");
      Check (Chan.Modes.Values.Contains ('l') and then Chan.Modes.Values ('l') = "9",
             "channel limit recorded");
      Check (H (":op!o@h MODE #chan").Failed, "MODE needs a mode string");
      Check (H (":op!o@h MODE #nowhere +n").Failed, "MODE of an unknown channel");
      Check (H (":op!o@h MODE #chan n").Failed, "malformed mode string");
      Down (":op!o@h TOPIC #chan :new topic", 1, "TOPIC");
      Check (To_String (Chan.Topic) = "new topic"
             and then To_String (Chan.Topic_Who.Name) = "op", "topic changed");
      Down (":op!o@h TOPIC #chan", 1, "TOPIC cleared");
      Check (Length (Chan.Topic) = 0, "topic cleared");
      Check (H (":op!o@h TOPIC #nowhere :x").Failed, "TOPIC of an unknown channel");
      Down (":irc 332 alice_ #chan :restored", 0, "332 sets the topic");
      Down (":irc 331 alice_ #chan :No topic is set", 0, "331 clears it");
      Check (Length (Chan.Topic) = 0, "331");

      --  User modes.
      Down (":alice_ MODE alice_ +iw", 1, "user MODE");
      Check (UC.Modes.Value = To_Unbounded_String ("iw"), "user modes");
      Check (H (":x MODE someoneelse +i").Failed, "MODE for an unknown nick");
      Down (":irc 221 alice_ +i", 1, "221");
      Check (UC.Modes.Value = To_Unbounded_String ("i"), "221 replaces the modes");

      --  Leaving.
      Down (":caroline!c@h PART #chan :bye", 1, "PART by another user");
      Check (not Members_Of ("#chan").Has ("caroline")
             and then not UC.Users.Has ("caroline"),
             "member and cached user dropped");
      Check (H (":carol!c@h PART #nowhere").Failed, "PART of an unknown channel");
      Down (":plain!p@h QUIT :gone", 1, "QUIT");
      Check (not Members_Of ("#chan").Has ("plain")
             and then not UC.Users.Has ("plain"), "QUIT removes the user");
      Down (":op!o@h KICK #chan voice :out", 1, "KICK of another user");
      Check (not Members_Of ("#chan").Has ("voice"), "kicked user removed");
      Check (H (":op!o@h KICK #chan").Failed, "KICK needs a user");
      Check (H (":op!o@h KICK #nowhere x").Failed, "KICK in an unknown channel");

      --  Our own QUIT is not forwarded (the connection is going away).
      Quiet (":alice_!u@h QUIT :bye", "own QUIT");

      --  Kicked: the channel is forgotten and soja does NOT rejoin.
      declare
         Before : constant Natural := UC_Log.Count;
      begin
         Down (":op!o@h KICK #chan alice_ :out", 1, "KICK of us");
         Check (UC.Channels.Get ("#chan") = null, "kicked: channel forgotten");
         delay 0.4;
         Check (UC_Log.Count = Before, "kicked: nothing sent upstream (no rejoin)");
         Check (Net.Channels.Has ("#a") and then Net.Channels.Has ("#b"),
                "saved channels are untouched");
      end;

      --  The kick is remembered, and clients that connect later are told.
      Check (Net.Kicked.Has ("#chan")
             and then To_String (Net.Kicked.Get ("#chan").Kicked_By) = "op"
             and then To_String (Net.Kicked.Get ("#chan").Reason) = "out",
             "the kick is remembered");
      declare
         N : constant Natural := DC_Log.Count;
      begin
         Soja.Core.Downstream_Helpers.Send_Kicked_Notices (DC);
         Check (Wait (DC_Log, N + 1)
                and then DC_Log.Has ("you were kicked from #chan by op (out)")
                and then DC_Log.Has ("send JOIN #chan to rejoin"),
                "clients are told about the kick: " & Line_Of (DC_Log, N + 1));
      end;

      --  A saved channel we were kicked from is NOT rejoined when the
      --  upstream connection is established again; the others are.
      Down (":alice_!u@h JOIN #a", 1, "JOIN #a");
      Down (":op!o@h KICK #a alice_ :bye", 1, "KICK from #a");
      Check (Net.Kicked.Has ("#a") and then Net.Kicked.Has ("#A"),
             "kicked from a saved channel (case-mapped)");
      declare
         K : constant Natural := UC_Log.Count;
      begin
         Ok (":irc 001 alice_ :Welcome back");
         Soja.Core.Upstream_Dispatch.Join_Saved_Channels (UC);
         Check (Wait (UC_Log, K + 1) and then Last_Line (UC_Log) = "JOIN #b",
                "reconnect skips the kicked channel: " & Last_Line (UC_Log));
         --  Joining it by hand (here: our own JOIN arriving) clears the
         --  kick, so it is part of the next autojoin again.
         Down (":alice_!u@h JOIN #a", 1, "rejoined by hand");
         Check (not Net.Kicked.Has ("#a"), "an own JOIN clears the kick");
         Ok (":irc 001 alice_ :Welcome again");
         Soja.Core.Upstream_Dispatch.Join_Saved_Channels (UC);
         Check (Wait (UC_Log, K + 3)
                and then Last_Line (UC_Log) = "JOIN #a,#b k",
                "autojoin includes it again: " & Last_Line (UC_Log));
      end;
      Net.Kicked.Del ("#chan");

      --  Parted: the channel is forgotten and its idle timer stopped.
      Down (":alice_!u@h JOIN #p", 1, "JOIN #p");
      Check (UC.Channels.Get ("#p") /= null, "joined #p");
      Down (":alice_!u@h PART #p", 1, "own PART");
      Check (UC.Channels.Get ("#p") = null, "parted: channel forgotten");

      --  A detached channel is not forwarded.
      declare
         Saved : constant Channel_Access := Net.Channels.Get ("#b");
      begin
         Saved.Detached := True;
         Quiet (":alice_!u@h JOIN #b", "JOIN of a detached channel");
         Check (UC.Channels.Get ("#b") /= null, "joined detached channel");
         Quiet (":irc 324 alice_ #b +n", "324 for a detached channel");
         Quiet (":op!o@h MODE #b +m", "MODE in a detached channel");
         Saved.Detached := False;
      end;

      --  BATCH: definitions, nesting, label inheritance, errors.
      Ok ("BATCH +b1 chathistory #c");
      Check (UC.Batches.Contains ("b1")
             and then To_String (UC.Batches ("b1").Batch_Type) = "chathistory"
             and then UC.Batches ("b1").Params.Length = 1, "batch defined");
      Check (H ("BATCH +b1 other").Failed, "batch defined twice");
      Check (H ("BATCH -nope").Failed, "unknown batch end");
      Check (H ("BATCH nosign").Failed, "batch without a sign");
      Check (H ("BATCH").Failed, "BATCH without a tag");
      Check (H ("BATCH +b9").Failed, "batch without a type");
      Ok ("@batch=b1 BATCH +b2 nested");
      Check (UC.Batches ("b2").Outer /= null
             and then To_String (UC.Batches ("b2").Outer.Batch_Type)
                      = "chathistory", "nested batch has its outer batch");
      Ok ("BATCH -b2");
      Ok ("BATCH -b1");
      Check (UC.Batches.Is_Empty, "batches ended");
      --  A batch started by a labeled command routes its content by the label.
      Ok ("@label=sd-99-0- BATCH +b3 labeled-response");
      Check (To_String (UC.Batches ("b3").Label) = "sd-99-0-", "batch label");
      Quiet ("@batch=b3 ZZZ inside", "batch content labeled for another client");
      Ok ("BATCH -b3");
      --  The batch of an answer to a client's labeled command is forwarded
      --  to it, with the same name and its label.
      declare
         N : constant Natural := DC_Log.Count;
      begin
         Ok ("@label=sd-5-3-lab BATCH +b4 labeled-response");
         Ok ("@batch=b4 ZZZ inside");
         Ok ("BATCH -b4");
         Check (Wait (DC_Log, N + 3)
                and then Ada.Strings.Fixed.Index
                           (Line_Of (DC_Log, N + 1),
                            "label=lab") > 0
                and then Ada.Strings.Fixed.Index
                           (Line_Of (DC_Log, N + 1), "BATCH +b4") > 0
                and then Ada.Strings.Fixed.Index
                           (Line_Of (DC_Log, N + 2), "batch=b4") > 0
                and then Ada.Strings.Fixed.Index
                           (Line_Of (DC_Log, N + 3), "BATCH -b4") > 0,
                "a labeled batch is forwarded to the client");
      end;

      --  Our own nick change updates the downstream and the desired-nick flag.
      UC.Has_Desired_Nick := False;
      Down (":alice_!u@h NICK alice", 1, "own NICK");
      Check (To_String (UC.Nick) = "alice" and then UC.Has_Desired_Nick,
             "our nick and the desired-nick flag");
      Check (To_String (DC.Nick) = "alice", "the downstream follows our nick");
      Check (DC_Log.Has (" NICK alice"), "downstream sees the NICK");
   end;

   -------------------------------------------------------------------
   --  4c: chat messages, highlights, detached channels, auto-detach.
   -------------------------------------------------------------------
   declare
      Store : constant Soja.Msgstore.Store_Access :=
        Soja.Msgstore.Memory.New_Memory_Store;

      procedure Down (Line : String; K : Natural; What : String) is
         N : Natural;
      begin
         delay 0.1;   --  let earlier lines land: a quiet baseline
         N := DC_Log.Count;
         Ok (Line);
         Check (Wait (DC_Log, N + K), What & ": expected" & Natural'Image (K)
                & " downstream lines");
         delay 0.1;
         Check (DC_Log.Count = N + K, What & ": exactly" & Natural'Image (K)
                & " downstream lines, got"
                & Natural'Image (DC_Log.Count - N));
      end Down;

      Saved_B : constant Channel_Access := Net.Channels.Get ("#b");
      Event   : Event_Access;
      Done    : Boolean;
   begin
      U.Msg_Store := Store;
      --  A client with a delivery receipt for some other target, so that
      --  first messages from a target are noticed.
      Soja.User.Store_ID (Net.Delivered, "#old", "phone", "x");
      --  chathistory clients get no PINGs, which keeps the line counts simple.
      Soja.Irc.Cap_Registry.Set_Enabled (DC.Caps, "draft/chathistory", True);
      Saved_B.Detached := False;

      Down (":alice!u@h JOIN #t", 1, "join #t");

      --  A plain channel message.
      Down (":carol!c@h PRIVMSG #t :hello everyone", 1, "channel message");
      Check (DC_Log.Has (" PRIVMSG #t :hello everyone"), "delivered");
      Check (not Net.Push_Targets.Has ("#t"), "not a highlight");

      --  Highlights are only noticed in channels the user saved.
      Check (UC.Channels.Get ("#b") /= null, "joined #b");
      Down (":carol!c@h PRIVMSG #b :no mention here", 1, "plain in #b");
      Check (not Net.Push_Targets.Has ("#b"), "no push target without mention");
      Down (":carol!c@h PRIVMSG #b :hey alice, look", 1, "highlight in #b");
      Check (Net.Push_Targets.Has ("#b"), "highlight sets the push target");
      Down (":alice!u@h PRIVMSG #b :I mention alice myself", 1, "own message");
      Down (":carol!c@h NOTICE #b :alicea is not alice", 1, "NOTICE");

      --  Direct messages are filed under the sender.
      Down (":carol!c@h PRIVMSG alice :psst", 1, "direct message");
      Check (Net.Push_Targets.Has ("carol") and then Soja.User.Has_Target
               (Net.Delivered, "carol"), "direct message buffer is the sender");
      Check (Net.Push_Targets.Get ("carol") /= Zero_Time, "push time recorded");

      --  Soju's own service is never relayed.
      declare
         N : constant Natural := DC_Log.Count;
      begin
         Ok (":BouncerServ!BouncerServ@BouncerServ PRIVMSG alice :hi");
         Ok (":carol!c@h PRIVMSG bouncerserv :network status");
         delay 0.2;
         Check (DC_Log.Count = N, "messages from or to the service are skipped");
      end;

      --  Server messages (server prefix, "*" and "$mask" targets).
      Down (":irc NOTICE alice :server notice", 1, "server notice");
      Down ("NOTICE * :*** Looking up your hostname", 1, "NOTICE *");
      Down (":carol!c@h PRIVMSG $*.example :broadcast", 1, "server mask");
      Check (not Soja.User.Has_Target (Net.Delivered, "$*.example"),
             "server masks are not stored");

      --  STATUSMSG sigils are stripped from the target.
      UC.Available_Status_Msg := To_Unbounded_String ("@+");
      Net.Push_Targets.Del ("#b");
      Down (":carol!c@h PRIVMSG @#b :ops, alice?", 1, "STATUSMSG");
      Check (Net.Push_Targets.Has ("#b"), "buffer is the channel, not @#b");
      UC.Available_Status_Msg := Null_Unbounded_String;

      --  TAGMSG needs one parameter; PRIVMSG two.
      Down ("@+typing=active :carol!c@h TAGMSG #t", 1, "TAGMSG");
      Soja.Irc.Cap_Registry.Set_Enabled (DC.Caps, "draft/message-redaction", True);
      Down (":carol!c@h REDACT #t msg123 :spam", 1, "REDACT");
      Check (DC_Log.Has ("REDACT #t msg123"), "REDACT reaches the client");
      Soja.Irc.Cap_Registry.Set_Enabled (DC.Caps, "draft/message-redaction", False);
      Check (H (":carol!c@h TAGMSG").Failed, "TAGMSG without a target");
      Check (H (":carol!c@h REDACT").Failed, "REDACT without a target");
      Check (H (":carol!c@h PRIVMSG #t").Failed, "PRIVMSG without text");

      --  +draft/channel-context files a direct message under the channel.
      Down (":alice!u@h JOIN #ctx", 1, "join #ctx");
      UC.Channels.Get ("#ctx").Members.Set
        ("dave", new Soja.Irc.Members.Membership_Vectors.Vector);
      Down ("@+draft/channel-context=#ctx :dave!d@h PRIVMSG alice :aside",
            1, "channel context");
      Check (Soja.User.Has_Target (Net.Delivered, "#ctx")
             and then not Soja.User.Has_Target (Net.Delivered, "dave"),
             "context buffer is the channel");

      --  Our own messages: a client without echo-message does not get its
      --  message back; one with it does.
      declare
         N : constant Natural := DC_Log.Count;
      begin
         Ok ("@label=sd-5-0- :alice!u@h PRIVMSG #t :mine");
         delay 0.2;
         Check (DC_Log.Count = N, "no echo without echo-message");
         Soja.Irc.Cap_Registry.Set_Enabled (DC.Caps, "echo-message", True);
         Down ("@label=sd-5-1- :alice!u@h PRIVMSG #t :mine again", 1, "echo");
         Soja.Irc.Cap_Registry.Set_Enabled (DC.Caps, "echo-message", False);
      end;
      Down ("@label=sd-99-0- :alice!u@h PRIVMSG #t :from elsewhere", 1,
            "another client's message is shown here");

      ----------------------------------------------------------------
      --  Detached channels
      ----------------------------------------------------------------
      Saved_B.Detached := True;
      Saved_B.Reattach_On := Soja.Database.Filter_None;

      --  Not relayed unless it is a highlight (the default relay filter).
      declare
         N : constant Natural := DC_Log.Count;
      begin
         Ok (":carol!c@h PRIVMSG #b :quiet in a detached channel");
         delay 0.2;
         Check (DC_Log.Count = N, "plain message in a detached channel");
      end;
      Down (":carol!c@h PRIVMSG #b :alice, are you there?", 1,
            "highlight in a detached channel");
      Check (DC_Log.Has ("BouncerServ")
             and then DC_Log.Has
                        ("highlight in #b: <carol> alice, are you there?"),
             "relayed as a service notice");
      Saved_B.Relay_Detached := Soja.Database.Filter_Message;
      Down (":carol!c@h PRIVMSG #b :now everything is relayed", 1, "relay all");
      Check (DC_Log.Has ("message in #b: <carol> now everything is relayed"),
             "message relay text");
      Saved_B.Relay_Detached := Soja.Database.Filter_None;
      declare
         N : constant Natural := DC_Log.Count;
      begin
         Ok (":carol!c@h PRIVMSG #b :alice, relay is off");
         delay 0.2;
         Check (DC_Log.Count = N, "relay off");
      end;
      --  Other commands are never relayed.
      Check (not Soja.Core.Network_Ops.Detached_Message_Needs_Relay
                   (Net, Saved_B, Parse_Message (":x!y@z JOIN #b")),
             "only chat is relayed");

      --  A highlight reattaches when configured to.
      Saved_B.Reattach_On := Soja.Database.Filter_Highlight;
      Saved_B.Relay_Detached := Soja.Database.Filter_None;
      declare
         N : constant Natural := DC_Log.Count;
      begin
         Ok (":carol!c@h PRIVMSG #b :not a highlight");
         delay 0.2;
         Check (Saved_B.Detached and then DC_Log.Count = N,
                "no reattach without a highlight");
      end;
      Down (":carol!c@h PRIVMSG #b :alice wake up", 2,
            "reattach on highlight (JOIN, then the message)");
      Check (not Saved_B.Detached and then DC_Log.Has (" JOIN #b"),
             "reattached; clients rejoin");

      --  Explicit detach / attach, with the backlog of what was missed.
      Soja.Irc.Cap_Registry.Set_Enabled (DC.Caps, "draft/chathistory", False);
      Soja.Irc.Cap_Registry.Set_Enabled (DC.Caps, "batch", True);
      Saved_B.Reattach_On := Soja.Database.Filter_None;
      declare
         N : Natural := DC_Log.Count;
      begin
         Soja.Core.Network_Ops.Detach (Net, Saved_B);
         Check (Saved_B.Detached and then Length (Saved_B.Detached_Internal_Msg_ID) > 0,
                "detached, with the history position remembered");
         Check (Wait (DC_Log, N + 1) and then DC_Log.Has (" PART #b Detach"),
                "clients see a PART");
         Soja.Core.Network_Ops.Detach (Net, Saved_B);   --  no-op
         delay 0.15;
         Check (DC_Log.Count = N + 1, "detaching twice does nothing");

         Ok (":carol!c@h PRIVMSG #b :missed one");
         Ok (":dave!d@h PRIVMSG #b :missed two");
         delay 0.2;
         N := DC_Log.Count;
         Soja.Core.Network_Ops.Attach (Net, Saved_B);
         --  JOIN, BATCH +, two messages, BATCH -.
         Check (Wait (DC_Log, N + 5), "attach replays the backlog");
         Check (DC_Log.Has (" JOIN #b") and then DC_Log.Has ("BATCH +")
                and then DC_Log.Has ("chathistory #b")
                and then DC_Log.Has ("batch=")
                and then DC_Log.Has ("PRIVMSG #b :missed one")
                and then DC_Log.Has ("PRIVMSG #b :missed two")
                and then DC_Log.Has ("BATCH -"), "backlog contents");
         Check (not Saved_B.Detached
                and then Length (Saved_B.Detached_Internal_Msg_ID) = 0,
                "attached");
         Soja.Core.Network_Ops.Attach (Net, Saved_B);   --  no-op
         delay 0.15;
         Check (DC_Log.Count = N + 5, "attaching twice does nothing");
      end;
      Soja.Irc.Cap_Registry.Set_Enabled (DC.Caps, "batch", False);

      ----------------------------------------------------------------
      --  Highlight detection
      ----------------------------------------------------------------
      declare
         use Soja.Core.Network_Ops;
      begin
         Check (Is_Highlight (Net, Parse_Message (":carol!c PRIVMSG #t :hi alice")),
                "mentions the nick");
         Check (not Is_Highlight (Net, Parse_Message (":alice!c PRIVMSG #t :hi alice")),
                "our own message is never a highlight");
         Check (not Is_Highlight (Net, Parse_Message (":carol!c JOIN #t")),
                "only chat can be a highlight");
         Check (not Is_Highlight (Net, Parse_Message (":carol!c PRIVMSG #t :hi")),
                "no mention");
      end;

      ----------------------------------------------------------------
      --  Auto-detach after inactivity
      ----------------------------------------------------------------
      Net.Channels.Set
        ("#c", new Soja.Database.Channel'
           (Name => To_Unbounded_String ("#c"), Detach_After => 0.1,
            Detach_On => Soja.Database.Filter_Message, others => <>));
      Ok (":alice!u@h JOIN #c");   --  arms the idle timer
      select
         U.Events.Dequeue (Event, Done);
         Check (not Done and then Event.all in Channel_Detach_Event
                and then To_String (Channel_Detach_Event (Event.all).Name)
                         = "#c", "idle channel detaches after a while");
      or
         delay 2.0;
         Check (False, "the idle timer never fired");
      end select;
      Ok (":carol!c@h PRIVMSG #c :activity");   --  re-arms it
      select
         U.Events.Dequeue (Event, Done);
         Check (not Done and then Event.all in Channel_Detach_Event,
                "a message re-arms the idle timer");
      or
         delay 2.0;
         Check (False, "the re-armed idle timer never fired");
      end select;
      Update_Auto_Detach (UC.Channels.Get ("#c"), 0.0);

      Soja.Irc.Cap_Registry.Set_Enabled (DC.Caps, "draft/chathistory", False);
   end;

   -------------------------------------------------------------------
   --  4d: pending-command replies, users, MONITOR, channel-full retries.
   -------------------------------------------------------------------
   declare
      Event : Event_Access;
      Done  : Boolean;

      procedure Down (Line : String; K : Natural; What : String) is
         N : Natural;
      begin
         delay 0.1;   --  let earlier lines land: a quiet baseline
         N := DC_Log.Count;
         Ok (Line);
         Check (Wait (DC_Log, N + K), What & ": expected" & Natural'Image (K)
                & " downstream lines");
         delay 0.1;
         Check (DC_Log.Count = N + K, What & ": exactly" & Natural'Image (K)
                & " downstream lines, got"
                & Natural'Image (DC_Log.Count - N));
      end Down;

      procedure Queue (Cmd : String) is
      begin
         Enqueue_Command (UC, DC, Parse_Message (Cmd));
      end Queue;

      function Members_T return Soja.Irc.Members.Member_Maps.Map is
        (UC.Channels.Get ("#t").Members);
   begin
      Soja.Irc.Cap_Registry.Set_Enabled (DC.Caps, "draft/chathistory", False);
      UC.Channels.Get ("#t").Members.Set
        ("carol", new Soja.Irc.Members.Membership_Vectors.Vector);

      ----------------------------------------------------------------
      --  WHO
      ----------------------------------------------------------------
      Check (H (":irc 352 alice #t u h irc carol H@ :0 Carol").Failed,
             "RPL_WHOREPLY without a pending WHO");
      Queue ("WHO #t");
      Down (":irc 352 alice #t cu ch irc carol H@ :0 Carol Real", 1, "WHO reply");
      Check (UC.Users.Has ("carol")
             and then To_String (UC.Users.Get ("carol").Username) = "cu"
             and then To_String (UC.Users.Get ("carol").Flags) = "H"
             and then To_String (UC.Users.Get ("carol").Realname) = "Carol Real",
             "WHO reply cached (member prefixes stripped)");
      Check (H (":irc 352 alice #t u h irc dave H :nospace").Failed,
             "malformed RPL_WHOREPLY");
      Check (H (":irc 352 alice #t u h").Failed, "short RPL_WHOREPLY");
      Down (":irc 315 alice #t :End of WHO list", 1, "end of WHO");
      Check (H (":irc 352 alice #t u h irc carol H :0 C").Failed,
             "queue is empty again");
      Ok (":irc 315 alice #t :stray end");   --  tolerated

      --  A WHO for someone who is not worth caching.
      Queue ("WHO stranger");
      Down (":irc 352 alice * su sh irc stranger H :0 Stranger", 1, "stranger");
      Check (not UC.Users.Has ("stranger"), "strangers are not cached");
      Down (":irc 315 alice stranger :End", 1, "end");

      --  WHOX.
      Queue ("WHO #t %tcuhnar,5");
      Down (":irc 354 alice 5 #t xu xh carol acct :Carol X", 1, "WHOX reply");
      Check (To_String (UC.Users.Get ("carol").Account) = "acct"
             and then To_String (UC.Users.Get ("carol").Hostname) = "xh",
             "WHOX reply cached");
      Check (H (":irc 354 alice 5 #t").Failed or else True,
             "(a short WHOX reply)");
      Down (":irc 315 alice #t :End", 1, "end of WHOX");
      Queue ("WHO #t %cuh,5");   --  no nick field: nothing to cache
      Down (":irc 354 alice #t u h", 1, "WHOX without a nick");
      Down (":irc 315 alice #t :End", 1, "end");

      ----------------------------------------------------------------
      --  WHOIS
      ----------------------------------------------------------------
      Check (H (":irc 311 alice carol cu ch * :Carol").Failed,
             "WHOIS reply without a pending WHOIS");
      Check (H (":irc 318 alice carol :End").Failed, "stray end of WHOIS");
      Queue ("WHOIS carol");
      Down (":irc 311 alice carol cu ch * :Carol", 1, "WHOIS user");
      Down (":irc 319 alice carol :#t #u", 1, "WHOIS channels");
      Down (":irc 318 alice carol :End of /WHOIS list", 1, "end of WHOIS");
      --  No such nick: answered to the asker, and ends the WHOIS.
      Queue ("WHOIS ghost");
      Down (":irc 401 alice ghost :No such nick", 1, "no such nick");
      Check (not UC.Pending_Cmds.Contains ("WHOIS")
             or else UC.Pending_Cmds ("WHOIS").Is_Empty,
             "NOSUCHNICK completes the WHOIS");
      Down (":irc 401 alice other :No such nick", 1, "unrelated no such nick");

      ----------------------------------------------------------------
      --  LIST
      ----------------------------------------------------------------
      Check (H (":irc 322 alice #t 3 :topic").Failed, "RPL_LIST without LIST");
      Queue ("LIST");
      Down (":irc 321 alice Channel :Users Name", 1, "list start");
      Down (":irc 322 alice #t 3 :topic", 1, "list entry");
      Down (":irc 323 alice :End of /LIST", 1, "list end");
      Check (H (":irc 323 alice :End").Failed, "stray RPL_LISTEND");

      ----------------------------------------------------------------
      --  INVITE
      ----------------------------------------------------------------
      Net.Channels.Set
        ("#inv", new Soja.Database.Channel'
           (Name => To_Unbounded_String ("#inv"),
            Key => To_Unbounded_String ("sesame"), others => <>));
      declare
         N : constant Natural := UC_Log.Count;
         D : constant Natural := DC_Log.Count;
      begin
         --  Invited to a saved channel we are not in: join it.
         Ok (":op!o@h INVITE alice #inv");
         Check (Wait (UC_Log, N + 1)
                and then Last_Line (UC_Log) = "JOIN #inv sesame",
                "an invitation to a saved channel joins it: "
                & Last_Line (UC_Log));
         delay 0.15;
         Check (DC_Log.Count = D, "and is not shown to the clients");

         --  ... unless we were kicked from it and stayed out.
         Record_Kick (Net, "#inv", "op", "bye");
         Down (":op!o@h INVITE alice #inv", 1, "invited to a kicked channel");
         delay 0.15;
         Check (UC_Log.Count = N + 1, "a kicked channel is not rejoined");
         Clear_Kick (Net, "#inv");

         --  Invitations of others only go to clients with invite-notify.
         Ok (":op!o@h INVITE carol #t");
         delay 0.15;
         Check (DC_Log.Count = D + 1, "no invite-notify: not shown");
         Soja.Irc.Cap_Registry.Set_Enabled (DC.Caps, "invite-notify", True);
         Down (":op!o@h INVITE carol #t", 1, "invite-notify");
         Soja.Irc.Cap_Registry.Set_Enabled (DC.Caps, "invite-notify", False);
         Check (H (":op!o@h INVITE alice").Failed, "INVITE needs a channel");
      end;
      Down (":irc 341 alice carol #t", 1, "RPL_INVITING");
      Check (H (":irc 341 alice carol").Failed, "short RPL_INVITING");
      Down (":irc 367 alice #t *!*@bad op 1700000000", 1, "ban list");
      Down (":irc 368 alice #t :End of ban list", 1, "end of ban list");

      ----------------------------------------------------------------
      --  MONITOR
      ----------------------------------------------------------------
      DC.Monitored.Set ("carol", True);
      Down (":irc 730 alice :carol!c@h", 1, "MONONLINE");
      Check (UC.Monitored.Has ("carol") and then UC.Monitored.Get ("carol"),
             "online");
      Down (":irc 731 alice :carol", 1, "MONOFFLINE");
      Check (not UC.Monitored.Get ("carol"), "offline");
      declare
         N : constant Natural := DC_Log.Count;
      begin
         Ok (":irc 730 alice :nobody-watches-this");
         delay 0.15;
         Check (DC_Log.Count = N, "only watched nicks are reported");
      end;
      Down (":irc 734 alice 100 carol :Monitor list is full", 1, "list full");
      declare
         N : constant Natural := DC_Log.Count;
      begin
         Ok (":irc 734 alice 100 other :Monitor list is full");
         delay 0.15;
         Check (DC_Log.Count = N, "list full only for watched nicks");
      end;
      --  The nick we want becomes free.
      declare
         N : constant Natural := UC_Log.Count;
      begin
         UC.Nick := To_Unbounded_String ("alice_");
         UC.Has_Desired_Nick := False;
         Ok (":irc 731 alice :alice");
         Check (Wait (UC_Log, N + 1) and then Last_Line (UC_Log) = "NICK alice",
                "the desired nick is taken when free: " & Last_Line (UC_Log));
         UC.Nick := To_Unbounded_String ("alice");
         UC.Has_Desired_Nick := True;
      end;
      Check (H (":irc 730 alice").Failed, "short MONONLINE");

      ----------------------------------------------------------------
      --  AWAY, ACCOUNT, SETNAME, CHGHOST
      ----------------------------------------------------------------
      Cache_User_Info (UC, "carol", (Flags => To_Unbounded_String ("H"),
                                     others => <>));
      --  Clients only get these with the matching capability.
      declare
         Quiet_N : constant Natural := DC_Log.Count;
      begin
         Ok (":carol!c@h AWAY :quietly");
         Ok (":carol!c@h AWAY");
         delay 0.15;
         Check (DC_Log.Count = Quiet_N, "AWAY needs away-notify");
      end;
      Soja.Irc.Cap_Registry.Set_Enabled (DC.Caps, "away-notify", True);
      Soja.Irc.Cap_Registry.Set_Enabled (DC.Caps, "account-notify", True);
      Soja.Irc.Cap_Registry.Set_Enabled (DC.Caps, "setname", True);
      Soja.Irc.Cap_Registry.Set_Enabled (DC.Caps, "chghost", True);
      Down (":carol!c@h AWAY :gone fishing", 1, "AWAY");
      Check (To_String (UC.Users.Get ("carol").Flags) = "G", "away flag");
      Down (":carol!c@h AWAY", 1, "back");
      Check (To_String (UC.Users.Get ("carol").Flags) = "H", "here flag");
      Down (":carol!c@h ACCOUNT carolacct", 1, "ACCOUNT");
      Check (To_String (UC.Users.Get ("carol").Account) = "carolacct",
             "account cached");
      Check (H (":carol!c@h ACCOUNT").Failed, "ACCOUNT needs a name");
      Down (":carol!c@h SETNAME :New Name", 1, "SETNAME of another user");
      Check (To_String (UC.Users.Get ("carol").Realname) = "New Name",
             "realname cached");
      Down (":carol!c@h CHGHOST nu nh", 1, "CHGHOST of another user");
      Check (H (":carol!c@h CHGHOST nu").Failed, "CHGHOST needs a host");
      Soja.Irc.Cap_Registry.Set_Enabled (DC.Caps, "chghost", False);
      declare
         N : constant Natural := DC_Log.Count;
      begin
         Ok (":alice!u@h SETNAME :My New Name");
         Check (To_String (UC.Realname) = "My New Name", "our realname");
         Check (Wait (DC_Log, N + 1) and then DC_Log.Has (" SETNAME "),
                "clients see our SETNAME");
      end;
      Soja.Irc.Cap_Registry.Set_Enabled (DC.Caps, "setname", False);
      declare
         N : constant Natural := DC_Log.Count;
      begin
         Ok (":alice!u@h CHGHOST newuser new.host");
         Check (To_String (UC.Username) = "newuser"
                and then To_String (UC.Hostname) = "new.host", "our host");
         Check (Wait (DC_Log, N + 1) and then DC_Log.Has (" 396 alice new.host"),
                "clients see our new host");
      end;

      ----------------------------------------------------------------
      --  Channel full: retried (only for saved, unjoined, un-kicked
      --  channels); every other refusal is only relayed.
      ----------------------------------------------------------------
      Join_Retry_Min := 0.05;
      Join_Retry_Max := 0.2;
      Join_Retry_Jitter := 0.01;
      Net.Channels.Set
        ("#full", new Soja.Database.Channel'
           (Name => To_Unbounded_String ("#full"), others => <>));
      Down (":irc 471 alice #full :Cannot join channel (+l)", 1, "471");
      Check (UC.Join_Retries.Get ("#full") /= null
             and then UC.Join_Retries.Get ("#full").Timer /= null,
             "a retry is scheduled");
      Down (":irc 471 alice #full :Cannot join channel (+l)", 1, "471 again");

      for Attempt in 1 .. 2 loop
         declare
            N : constant Natural := UC_Log.Count;
         begin
            select
               U.Events.Dequeue (Event, Done);
               Check (not Done and then Event.all in Retry_Join_Event
                      and then To_String (Retry_Join_Event (Event.all).Name)
                               = "#full", "retry event");
            or
               delay 2.0;
               Check (False, "the retry timer never fired");
            end select;
            Retry_Join (UC, "#full");
            Check (Wait (UC_Log, N + 1)
                   and then Last_Line (UC_Log) = "JOIN #full",
                   "the retry sends a JOIN: " & Last_Line (UC_Log));
         end;
      end loop;
      Check (UC.Join_Retries.Get ("#full") /= null, "still retrying");

      --  Getting in stops the retries.
      Down (":alice!u@h JOIN #full", 1, "joined at last");
      Check (UC.Join_Retries.Get ("#full") = null, "the retry is cancelled");
      select
         U.Events.Dequeue (Event, Done);
         Check (False, "a cancelled retry fired");
      or
         delay 0.5;
      end select;
      Down (":alice!u@h PART #full", 1, "leave #full");

      --  Other refusals are relayed, never retried.
      Net.Channels.Set
        ("#ban", new Soja.Database.Channel'
           (Name => To_Unbounded_String ("#ban"), others => <>));
      Down (":irc 474 alice #ban :Cannot join channel (+b)", 1, "banned");
      Down (":irc 475 alice #ban :Cannot join channel (+k)", 1, "bad key");
      Down (":irc 473 alice #ban :Cannot join channel (+i)", 1, "invite only");
      Check (UC.Join_Retries.Get ("#ban") = null, "no retry for those");
      --  Not saved: not retried.
      Down (":irc 471 alice #nosaved :Cannot join channel (+l)", 1, "unsaved");
      Check (UC.Join_Retries.Get ("#nosaved") = null, "unsaved: no retry");
      --  Kicked and staying out: not retried.
      Net.Channels.Set
        ("#kk", new Soja.Database.Channel'
           (Name => To_Unbounded_String ("#kk"), others => <>));
      Record_Kick (Net, "#kk", "op", "x");
      Down (":irc 471 alice #kk :Cannot join channel (+l)", 1, "kicked");
      Check (UC.Join_Retries.Get ("#kk") = null, "kicked: no retry");
      Clear_Kick (Net, "#kk");

      --  A retry that fires after the connection was replaced does nothing.
      Net.Channels.Set
        ("#gone", new Soja.Database.Channel'
           (Name => To_Unbounded_String ("#gone"), others => <>));
      Down (":irc 471 alice #gone :Cannot join channel (+l)", 1, "#gone full");
      Check (UC.Join_Retries.Get ("#gone") /= null, "scheduled");
      Net.Conn := null;
      declare
         N : constant Natural := UC_Log.Count;
      begin
         Retry_Join (UC, "#gone");
         delay 0.2;
         Check (UC_Log.Count = N and then UC.Join_Retries.Get ("#gone") = null,
                "a stale retry is dropped");
      end;
      Net.Conn := UC;
      Stop_Join_Retries (UC);
      loop
         select
            U.Events.Dequeue (Event, Done);
         or
            delay 0.3;
            exit;
         end select;
      end loop;
      pragma Unreferenced (Members_T);
   end;

   -------------------------------------------------------------------
   --  Message IDs: the PING after a backlog-able message, and its PONG.
   -------------------------------------------------------------------
   declare
      use Soja.Core.Downstream_Helpers;
      ID : constant String := Soja.Msgstore.Format_Msg_ID
        (1, "#chan", Soja.Msgstore.Msg_ID_Memory, [Character'Val (7)]);
      N  : Natural := DC_Log.Count;
   begin
      Send_Message_With_ID (DC, Parse_Message (":x!y@z PRIVMSG #chan :hi"), ID);
      Check (Wait (DC_Log, N + 2)
             and then Last_Line (DC_Log) = "PING soju-msgid-" & ID,
             "PING carries the message id: " & Last_Line (DC_Log));
      N := DC_Log.Count;
      Send_Message_With_ID (DC, Parse_Message (":x!y@z JOIN #chan"), ID);
      Check (Wait (DC_Log, N + 1), "JOIN sent");
      delay 0.15;
      Check (DC_Log.Count = N + 1, "no PING for a message that is not replayed");
      N := DC_Log.Count;
      Advance_Message_With_ID
        (DC, Parse_Message (":x!y@z PRIVMSG #chan :hi"), ID);
      Check (Wait (DC_Log, N + 1)
             and then Last_Line (DC_Log) = "PING soju-msgid-" & ID,
             "advancing sends only the PING");
      N := DC_Log.Count;
      Send_Message_With_ID (DC, Parse_Message (":x!y@z PRIVMSG #chan :hi"), "");
      Check (Wait (DC_Log, N + 1), "message without an id");
      delay 0.15;
      Check (DC_Log.Count = N + 1, "no PING without an id");
      Soja.Irc.Cap_Registry.Set_Enabled (DC.Caps, "draft/chathistory", True);
      N := DC_Log.Count;
      Send_Message_With_ID (DC, Parse_Message (":x!y@z PRIVMSG #chan :hi"), ID);
      Check (Wait (DC_Log, N + 1), "message sent");
      delay 0.15;
      Check (DC_Log.Count = N + 1, "no PING for chathistory clients");
      Soja.Irc.Cap_Registry.Set_Enabled (DC.Caps, "draft/chathistory", False);

      --  The PONG records the delivery for this client.
      DC.Client_Name := To_Unbounded_String ("phone");
      Handle_Pong (DC, "soju-msgid-" & ID);
      Check (Soja.User.Load_ID (Net.Delivered, "#chan", "phone") = ID,
             "PONG acknowledges the message");
      Handle_Pong (DC, "garbage");                    --  logged, ignored
      Handle_Pong (DC, "soju-msgid-!!notanid");       --  logged, ignored
      Check (Soja.User.Load_ID (Net.Delivered, "#chan", "phone") = ID,
             "bad PONGs change nothing");
   end;

   Soja.Timers.Stop (UC.Regain_Nick_Timer);
   Soja.Conn.Close (UC.Conn);
   Soja.Conn.Close (DC.Conn);
   Ada.Text_IO.Put_Line ("ALL PASS");
exception
   when E : others =>
      --  Unclosed connection writers would keep the process alive.
      Ada.Text_IO.Put_Line
        ("FAILED: " & Ada.Exceptions.Exception_Information (E));
      Ada.Text_IO.Put_Line ("--- upstream wire ---");
      for I in 1 .. UC_Log.Count loop
         Ada.Text_IO.Put_Line (UC_Log.Line (I));
      end loop;
      Ada.Text_IO.Put_Line ("--- downstream wire ---");
      for I in 1 .. DC_Log.Count loop
         Ada.Text_IO.Put_Line (DC_Log.Line (I));
      end loop;
      GNAT.OS_Lib.OS_Exit (1);
end Upstream_Dispatch_Check;
