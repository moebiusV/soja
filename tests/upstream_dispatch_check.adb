pragma Ada_2022;

with Ada.Containers;
with Ada.Containers.Indefinite_Vectors;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;
with Ada.Exceptions;
with Ada.Text_IO;
with GNAT.OS_Lib;

with Soja.Conn;
with Soja.Core;
with Soja.Core.Upstream_Dispatch;
with Soja.Database;
with Soja.Irc.Cap_Registry;
with Soja.Irc.Case_Mapping;
with Soja.Irc.Members;
with Soja.Irc.Messages;
with Soja.Logging;
with Soja.Server;
with Soja.Timers;

procedure Upstream_Dispatch_Check is
   use Soja.Core;
   use Soja.Core.Upstream_Dispatch;
   use Soja.Irc.Messages;
   use type Ada.Containers.Count_Type;
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

   UC.Network := Net;
   UC.User := U;
   UC.Logger := Log'Unchecked_Access;
   UC.Nick := To_Unbounded_String ("alice");
   UC.Conn := Soja.Conn.New_Conn
     (UC_Wire'Unchecked_Access,
      (Logger => null, Rate_Limit_Delay => 0.0, Rate_Limit_Burst => 0));
   UC.Channels := Upstream_Channel_Maps.New_Map (Soja.Irc.Case_Mapping.Case_RFC1459);
   UC.Users := Upstream_User_Maps.New_Map (Soja.Irc.Case_Mapping.Case_RFC1459);
   UC.Monitored := Flag_Maps.New_Map (Soja.Irc.Case_Mapping.Case_RFC1459);
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
      Check (R.Failed, "label missing offset");
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
   Ok ("@label=sd-99-0 ZZZ routed");
   delay 0.15;
   Check (DC_Log.Count = 1, "label for another downstream is not delivered");
   Ok ("@label=sd-5-0 ZZZ routed");
   Check (Wait (DC_Log, 2), "label for this downstream is delivered");
   --  A valid server-time is kept.
   Ok ("@time=2024-02-29T13:45:09.123Z ZZZ timed");
   Check (Wait (DC_Log, 3)
          and then Ada.Strings.Fixed.Index
                     (Line_Of (DC_Log, 3), "time=2024-02-29T13:45:09.123Z") > 0,
          "server time kept: " & Line_Of (DC_Log, 3));

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
   Ok (":irc CAP * LS :sasl=PLAIN,EXTERNAL server-time");
   Check (Wait (UC_Log, 2)
          and then Line_Of (UC_Log, 2) = "CAP REQ :multi-prefix sasl server-time",
          "CAP REQ: " & Line_Of (UC_Log, 2));
   Settle (UC_Log, 2, "no CAP END while SASL is pending");
   Check (Request_SASL (UC) and then Supports_SASL (UC, "PLAIN"), "request SASL");

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
   --  001: registered, and the saved channels are joined once.
   -------------------------------------------------------------------
   declare
      N : constant Natural := UC_Log.Count;
   begin
      Ok (":irc 001 alice_ :Welcome");
      Check (UC.Registered and then To_String (UC.Nick) = "alice_", "001");
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
   --  Go quirk (see PORTING.md): "-TOKEN" never matches its switch case,
   --  so negating PREFIX leaves the memberships as they were.
   Ok (":irc 005 alice_ -PREFIX :are supported");
   Check (UC.Available_Memberships.Length = 3, "negation quirk kept");

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

   Soja.Timers.Stop (UC.Regain_Nick_Timer);
   Soja.Conn.Close (UC.Conn);
   Soja.Conn.Close (DC.Conn);
   Ada.Text_IO.Put_Line ("ALL PASS");
exception
   when E : others =>
      --  Unclosed connection writers would keep the process alive.
      Ada.Text_IO.Put_Line
        ("FAILED: " & Ada.Exceptions.Exception_Information (E));
      GNAT.OS_Lib.OS_Exit (1);
end Upstream_Dispatch_Check;
