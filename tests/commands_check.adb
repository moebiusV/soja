pragma Ada_2022;

with Ada.Containers;
with Ada.Containers.Indefinite_Vectors;
with Ada.Exceptions;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;
with Ada.Text_IO;
with GNAT.OS_Lib;

with Soja.Conn;
with Soja.Core;                use Soja.Core;
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
with Soja.Irc.Modes;
with Soja.Logging;
with Soja.Msgstore.Memory;
with Soja.Server;
with Soja.User;

--  The registered client's commands (downstream.go handleMessageRegistered).
procedure Commands_Check is
   package SD renames Soja.Database;
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
   type Fake_Transport_Access is access all Fake_Transport;

   function Wait (R : Recorder_Access; N : Natural) return Boolean is
      Waited : Duration := 0.0;
   begin
      while R.Count < N and then Waited < 3.0 loop
         delay 0.02;
         Waited := Waited + 0.02;
      end loop;
      return R.Count >= N;
   end Wait;

   function Line_Of (R : Recorder_Access; I : Natural) return String is
     (if I >= 1 and then I <= R.Count then R.Line (I) else "");
   function Last (R : Recorder_Access) return String is
     (Line_Of (R, R.Count));

   Log : aliased Soja.Logging.Standard_Logger;
   Srv : aliased Soja.Server.Server;
   DB  : SD.Database_Access := Soja.Database.Sqlite.Open_Temp_Sqlite_DB;
   Rec : SD.User := SD.New_User ("alice");

   Conns   : array (1 .. 64) of Soja.Conn.Conn_Access;
   N_Conns : Natural := 0;

   function New_DC
     (U : User_Access; Net : Network_Access; ID : Long_Long_Integer;
      Log_Out : out Recorder_Access) return Downstream_Conn_Access
   is
      R  : constant Recorder_Access := new Recorder;
      T  : constant Fake_Transport_Access := new Fake_Transport'
        (Soja.Conn.IRC_Conn with Log => R);
      DC : constant Downstream_Conn_Access :=
        New_Downstream_Conn (Srv'Unchecked_Access, T.all'Unchecked_Access, ID);
   begin
      DC.User := U;
      DC.Network := Net;
      DC.Nick := To_Unbounded_String ("alice_");
      DC.Nick_CM := To_Unbounded_String ("alice_");
      DC.Registered := True;
      N_Conns := N_Conns + 1;
      Conns (N_Conns) := DC.Conn;
      Log_Out := R;
      return DC;
   end New_DC;

   function New_UC
     (U : User_Access; Net : Network_Access; Log_Out : out Recorder_Access)
      return Upstream_Conn_Access
   is
      R  : constant Recorder_Access := new Recorder;
      T  : constant Fake_Transport_Access := new Fake_Transport'
        (Soja.Conn.IRC_Conn with Log => R);
      UC : constant Upstream_Conn_Access := new Upstream_Conn;
      CM : constant Soja.Irc.Case_Mapping.Kind :=
        Soja.Irc.Case_Mapping.Case_RFC1459;
   begin
      UC.Network := Net;
      UC.User := U;
      UC.Srv := Srv'Unchecked_Access;
      UC.Logger := Log'Unchecked_Access;
      UC.Nick := To_Unbounded_String ("alice_");
      UC.Conn := Soja.Conn.New_Conn
        (T.all'Unchecked_Access,
         (Logger => null, Rate_Limit_Delay => 0.0, Rate_Limit_Burst => 0,
         others => <>));
      N_Conns := N_Conns + 1;
      Conns (N_Conns) := UC.Conn;
      UC.Channels := Upstream_Channel_Maps.New_Map (CM);
      UC.Users := Upstream_User_Maps.New_Map (CM);
      UC.Monitored := Flag_Maps.New_Map (CM);
      UC.Join_Retries := Join_Retry_Maps.New_Map (CM);
      UC.Caps := Soja.Irc.Cap_Registry.New_Registry;
      UC.Server_Prefix :=
        new Prefix'(Name => To_Unbounded_String ("irc"), others => <>);
      UC.Available_Channel_Types := To_Unbounded_String ("#&+!");
      UC.Available_Channel_Modes := Soja.Irc.Modes.Std_Channel_Modes;
      for M of Soja.Irc.Members.Std_Memberships loop
         UC.Available_Memberships.Append (M);
      end loop;
      UC.Has_Desired_Nick := True;
      Log_Out := R;
      return UC;
   end New_UC;

   function Cmd (DC : Downstream_Conn_Access; Line : String)
      return Irc_Error_Result is
     (Handle_Downstream_Message (DC, Parse_Message (Line)));

   procedure Ok (DC : Downstream_Conn_Access; Line : String) is
      R : constant Irc_Error_Result := Cmd (DC, Line);
   begin
      if R.Failed then
         Check (False, Line & " failed: "
                & (if R.Is_IRC then Soja.Downstream.Image (R.Err)
                   else To_String (R.Text)));
      end if;
   end Ok;

   --  The IRC error a command fails with, as a string ("" when it works).
   function Error_Of (DC : Downstream_Conn_Access; Line : String)
      return String
   is
      R : constant Irc_Error_Result := Cmd (DC, Line);
   begin
      if not R.Failed then
         return "";
      end if;
      return (if R.Is_IRC then Soja.Downstream.Image (R.Err)
              else "plain: " & To_String (R.Text));
   end Error_Of;

   function Seen (R : Recorder_Access; Needle : String) return Boolean is
      Waited : Duration := 0.0;
   begin
      while not R.Has (Needle) and then Waited < 3.0 loop
         delay 0.02;
         Waited := Waited + 0.02;
      end loop;
      return R.Has (Needle);
   end Seen;

   function Has (Text, Needle : String) return Boolean is
     (Ada.Strings.Fixed.Index (Text, Needle) > 0);

   U     : User_Access;
   Net   : Network_Access;
   UC    : Upstream_Conn_Access;
   UC_Log, DC_Log, Bnc_Log : Recorder_Access;
   DC, Bnc : Downstream_Conn_Access;

   function Saved (Name : String) return Channel_Access is
     (Net.Channels.Get (Name));
   function Stored_Channels return SD.Channel_Lists.Vector is
     (SD.List_Channels (DB.all, Net.Network_Record.ID));
begin
   Srv.Initialize (Log'Unchecked_Access);
   Srv.Set_DB (DB);
   SD.Store_User (DB.all, Rec);
   Rec.Enabled := True;
   SD.Store_User (DB.all, Rec);
   U := New_User (Srv'Unchecked_Access, Rec);
   U.Msg_Store := Soja.Msgstore.Memory.New_Memory_Store;

   declare
      NRec : SD.Network := SD.New_Network ("irc+insecure://irc.example");
   begin
      NRec.Enabled := False;
      NRec.Name := To_Unbounded_String ("net");
      Net := Soja.Core.User_Ops.Create_Network (U, NRec);
   end;
   UC := New_UC (U, Net, UC_Log);
   Net.Conn := UC;
   DC := New_DC (U, Net, 1, DC_Log);
   Bnc := New_DC (U, null, 2, Bnc_Log);
   U.Downstream_Conns.Append (DC);
   U.Downstream_Conns.Append (Bnc);

   -------------------------------------------------------------------
   --  PING / PONG / USER
   -------------------------------------------------------------------
   Ok (DC, "PING token");
   Check (Wait (DC_Log, 1) and then Last (DC_Log) = ":localhost PONG localhost token",
          "PONG: " & Last (DC_Log));
   Ok (DC, "PING token localhost");
   Check (Error_Of (DC, "PING token elsewhere")
            = "402 alice_ elsewhere :No such server", "PING to another server");
   Check (Error_Of (DC, "PING")(1 .. 3) = "461", "PING needs a token");
   Check (Error_Of (DC, "PONG")(1 .. 3) = "461", "PONG needs a token");
   Ok (DC, "PONG soju-msgid-garbage");   --  logged, ignored
   Check (Error_Of (DC, "USER a 0 * :b") = "462 alice_ :You may not reregister",
          "USER after registering");

   -------------------------------------------------------------------
   --  NICK
   -------------------------------------------------------------------
   Check (Error_Of (DC, "NICK bad:nick")
            = "432 alice_ bad:nick :Nickname contains illegal characters",
          "illegal nickname");
   Check (Error_Of (DC, "NICK BouncerServ")
            = "433 alice_ BouncerServ :Nickname reserved for bouncer service",
          "the service's nick");

   --  On a network: stored, and sent upstream.
   declare
      N : constant Natural := UC_Log.Count;
   begin
      Ok (DC, "NICK newnick");
      Check (Wait (UC_Log, N + 1) and then Last (UC_Log) = "NICK newnick",
             "NICK relayed upstream");
      Check (To_String (Net.Network_Record.Nick) = "newnick"
             and then SD.List_Networks (DB.all, U.User_Record.ID) (1).Nick
                      = To_Unbounded_String ("newnick"),
             "stored for the network");
   end;
   --  Without an upstream, the client is just told.
   Net.Conn := null;
   declare
      N : constant Natural := DC_Log.Count;
   begin
      Ok (DC, "NICK offline");
      Check (Wait (DC_Log, N + 1) and then Last (DC_Log)(1 .. 6) /= "",
             "offline: the client learns the nick");
      Check (To_String (DC.Nick) = "offline", "the client's nick follows");
   end;
   Net.Conn := UC;
   DC.Nick := To_Unbounded_String ("alice_");
   DC.Nick_CM := To_Unbounded_String ("alice_");
   --  On the bouncer connection: the user's default, for every such client.
   declare
      N : constant Natural := Bnc_Log.Count;
   begin
      Ok (Bnc, "NICK ally");
      Check (To_String (U.User_Record.Nick) = "ally"
             and then SD.Get_User (DB.all, "alice").Nick
                      = To_Unbounded_String ("ally"), "the user's nick");
      Check (Wait (Bnc_Log, N + 1) and then To_String (Bnc.Nick) = "ally",
             "bouncer clients follow");
   end;
   Bnc.Nick := To_Unbounded_String ("alice_");
   Bnc.Nick_CM := To_Unbounded_String ("alice_");

   -------------------------------------------------------------------
   --  SETNAME
   -------------------------------------------------------------------
   DC.Realname := To_Unbounded_String ("Same");
   Soja.Irc.Cap_Registry.Set_Enabled (DC.Caps, "setname", True);
   declare
      N : constant Natural := DC_Log.Count;
   begin
      Ok (DC, "SETNAME Same");
      Check (Wait (DC_Log, N + 1) and then Last (DC_Log)(1 .. 1) = ":",
             "an unchanged realname is echoed");
   end;
   Soja.Irc.Cap_Registry.Set_Enabled (UC.Caps, "setname", True);
   declare
      N : constant Natural := UC_Log.Count;
   begin
      Ok (DC, "SETNAME :Brand New");
      Check (Wait (UC_Log, N + 1) and then Last (UC_Log) = "SETNAME :Brand New",
             "relayed when the upstream has setname");
      Check (SD.List_Networks (DB.all, U.User_Record.ID) (1).Realname
             = To_Unbounded_String ("Brand New"), "and stored");
   end;
   Soja.Irc.Cap_Registry.Set_Enabled (UC.Caps, "setname", False);
   declare
      Old : constant Network_Access := Net;
   begin
      Ok (DC, "SETNAME :Reconnect Me");
      Net := U.Networks (1);
      Check (Net /= Old and then DC.Network = Net
             and then To_String (Net.Network_Record.Realname) = "Reconnect Me",
             "without setname the network reconnects with the new realname");
      --  Back to a connected fixture.
      Net.Conn := UC;
      UC.Network := Net;
   end;
   Ok (Bnc, "SETNAME :User Wide");
   Check (To_String (U.User_Record.Realname) = "User Wide", "the user's realname");
   Check (Error_Of (DC, "SETNAME")(1 .. 3) = "461", "SETNAME needs a name");

   -------------------------------------------------------------------
   --  JOIN
   -------------------------------------------------------------------
   Check (Error_Of (Bnc, "JOIN #x")
            = "400 * JOIN :Cannot interact with channels and users on the "
              & "bouncer connection. Did you mean to use a specific network?",
          "JOIN on the bouncer connection");
   Net.Conn := null;
   Check (Error_Of (DC, "JOIN #x") = "400 * JOIN :Disconnected from upstream network",
          "JOIN while disconnected");
   Net.Conn := UC;
   Check (Error_Of (DC, "JOIN")(1 .. 3) = "461", "JOIN needs a channel");

   declare
      N : constant Natural := UC_Log.Count;
   begin
      Ok (DC, "JOIN #one,#two,notachannel,#bad" & ASCII.BEL & "name,#keyed key1");
      Ok (DC, "JOIN #keyed2,#plain key2");
      Check (Wait (UC_Log, N + 4), "upstream JOINs");
      --  (The keys are matched to the channels by position.)
      Check (Line_Of (UC_Log, N + 1) = "JOIN #one key1"
             and then Line_Of (UC_Log, N + 2) = "JOIN #two",
             "each channel is joined");
      Check (Wait (DC_Log, 1), "replies");
      Check (UC_Log.Has ("JOIN #keyed2 key2") and then UC_Log.Has ("JOIN #plain"),
             "keys are matched to channels");
      Check (DC_Log.Has (" 403 " & To_String (DC.Nick)
                         & " notachannel :Not a channel name")
             and then DC_Log.Has (" 476 " & To_String (DC.Nick) & " "),
             "bad names are answered, with the client's nick");
      Check (Saved ("#one") /= null and then Saved ("#two") /= null
             and then To_String (Saved ("#keyed2").Key) = "key2",
             "channels are saved with their keys");
      Check (Stored_Channels.Length >= 4, "and stored");
   end;

   --  A duplicate JOIN is not sent upstream again (clients JOIN in bulk).
   UC.Channels.Set ("#one", New_Upstream_Channel (UC, "#one"));
   declare
      N : constant Natural := UC_Log.Count;
   begin
      Ok (DC, "JOIN #one");
      delay 0.15;
      Check (UC_Log.Count = N, "already joined: nothing sent");
   end;
   --  A key is updated, never cleared; a detached channel is attached.
   Saved ("#one").Detached := True;
   declare
      N : constant Natural := DC_Log.Count;
   begin
      Ok (DC, "JOIN #one newkey");
      Check (not Saved ("#one").Detached
             and then To_String (Saved ("#one").Key) = "newkey",
             "attached, with the new key");
      Check (Wait (DC_Log, N + 1), "clients are told it is attached");
      Ok (DC, "JOIN #one");
      Check (To_String (Saved ("#one").Key) = "newkey", "the key is kept");
   end;

   -------------------------------------------------------------------
   --  PART
   -------------------------------------------------------------------
   declare
      N : constant Natural := UC_Log.Count;
   begin
      Net.Push_Targets.Set ("#two", Zero_Time);
      Record_Kick (Net, "#two", "op", "x");
      Ok (DC, "PART #two :bye all");
      Check (Wait (UC_Log, N + 1) and then Last (UC_Log) = "PART #two :bye all",
             "PART relayed with its reason");
      Check (Saved ("#two") = null, "the channel is forgotten");
      Check (not Net.Push_Targets.Has ("#two") and then not Net.Kicked.Has ("#two"),
             "with its push target and any kick");
      declare
         Names : Unbounded_String;
      begin
         for C of Stored_Channels loop
            Append (Names, To_String (C.Name) & " ");
         end loop;
         Check (Ada.Strings.Fixed.Index (To_String (Names), "#two") = 0,
                "and deleted from the database");
      end;

      Ok (DC, "PART #plain");
      Check (Wait (UC_Log, N + 2) and then Last (UC_Log) = "PART #plain",
             "PART without a reason");
   end;
   --  Detach: the channel stays, flagged; no PART upstream.
   declare
      N : constant Natural := UC_Log.Count;
   begin
      Ok (DC, "PART #one :Detach");
      delay 0.15;
      Check (Saved ("#one").Detached and then UC_Log.Count = N,
             "detach keeps the channel and sends nothing upstream");
      Ok (DC, "PART #ghost :detach");
      Check (Saved ("#ghost") /= null and then Saved ("#ghost").Detached,
             "detaching an unknown channel creates it detached");
      declare
         Found : Boolean := False;
      begin
         for C of Stored_Channels loop
            if To_String (C.Name) = "#ghost" and then C.Detached then
               Found := True;
            end if;
         end loop;
         Check (Found, "stored, detached");
      end;
   end;
   Check (Error_Of (Bnc, "PART #x")(1 .. 3) = "400", "PART on the bouncer");

   -------------------------------------------------------------------
   --  KICK, MODE, TOPIC
   -------------------------------------------------------------------
   declare
      N : constant Natural := UC_Log.Count;
   begin
      Ok (DC, "KICK #one troll :out");
      Check (Wait (UC_Log, N + 1) and then Last (UC_Log) = "KICK #one troll out",
             "KICK is relayed");
   end;

   --  MODE of ourselves.
   UC.Modes.Value := To_Unbounded_String ("iw");
   declare
      N : constant Natural := DC_Log.Count;
   begin
      Ok (DC, "MODE alice_");
      Check (Wait (DC_Log, N + 1) and then Line_Of (DC_Log, N + 1) = ":localhost 221 alice_ +iw",
             "user modes: " & Line_Of (DC_Log, N + 1));
      Ok (Bnc, "MODE alice_");
      Check (Wait (Bnc_Log, 1) and then Last (Bnc_Log)(1 .. 20) /= "",
             "user modes on the bouncer");
   end;
   declare
      N : constant Natural := UC_Log.Count;
   begin
      Ok (DC, "MODE alice_ +i");
      Check (Wait (UC_Log, N + 1) and then Last (UC_Log) = "MODE alice_ +i",
             "user mode change relayed");
   end;
   Check (Error_Of (DC, "MODE someoneelse +o") = "502 alice_ :Cannot change mode for other users",
          "MODE of another user");
   Check (Error_Of (DC, "MODE")(1 .. 3) = "461", "MODE needs a target");

   --  Channel modes.
   declare
      N : Natural := UC_Log.Count;
      Ch : constant Upstream_Channel_Access := UC.Channels.Get ("#one");
      D : Natural := DC_Log.Count;
   begin
      Ok (DC, "MODE #one +o troll");
      Check (Wait (UC_Log, N + 1) and then Last (UC_Log) = "MODE #one +o troll",
             "channel mode change relayed");
      N := UC_Log.Count;
      Ok (DC, "MODE #one");        --  modes not known yet: ignored
      delay 0.15;
      Check (UC_Log.Count = N and then DC_Log.Count = D, "unknown modes: ignored");
      Ch.Modes.Known := True;
      Ch.Modes.Values.Include ('n', "");
      Ch.Modes.Values.Include ('k', "sekrit");
      Ch.Creation_Time := To_Unbounded_String ("1700000000");
      Ok (DC, "MODE #one");
      Check (Wait (DC_Log, D + 2)
             and then Line_Of (DC_Log, D + 1) = ":localhost 324 alice_ #one +kn sekrit"
             and then Line_Of (DC_Log, D + 2) = ":localhost 329 alice_ #one 1700000000",
             "channel modes: " & Line_Of (DC_Log, D + 1));
      N := UC_Log.Count;
      Ok (DC, "MODE #elsewhere");  --  not joined: asked upstream
      Check (Wait (UC_Log, N + 1) and then Last (UC_Log) = "MODE #elsewhere",
             "modes of a channel we are not in");
   end;

   --  TOPIC.
   declare
      N : Natural := UC_Log.Count;
      D : Natural := DC_Log.Count;
   begin
      Ok (DC, "TOPIC #one :a new topic");
      Check (Wait (UC_Log, N + 1) and then Last (UC_Log) = "TOPIC #one :a new topic",
             "setting a topic");
      UC.Channels.Get ("#one").Topic := To_Unbounded_String ("the topic");
      Ok (DC, "TOPIC #one");
      Check (Wait (DC_Log, D + 1) and then Last (DC_Log) = ":localhost 332 alice_ #one :the topic",
             "reading a topic we know");
      N := UC_Log.Count;
      Ok (DC, "TOPIC #far");
      Check (Wait (UC_Log, N + 1) and then Last (UC_Log) = "TOPIC #far",
             "reading the topic of a channel we are not in");
      Check (Error_Of (DC, "TOPIC")(1 .. 3) = "461", "TOPIC needs a channel");
   end;

   -------------------------------------------------------------------
   --  LIST, NAMES
   -------------------------------------------------------------------
   declare
      N : Natural := UC_Log.Count;
   begin
      Ok (DC, "LIST >5");
      Check (Wait (UC_Log, N + 1) and then Last (UC_Log) = "LIST >5",
             "LIST goes upstream through the pending queue");
      Check (UC.Pending_Cmds.Contains ("LIST"), "and is awaiting its reply");
      Check (Error_Of (Bnc, "LIST")(1 .. 3) = "400", "LIST on the bouncer");
   end;
   declare
      D : Natural := DC_Log.Count;
      N : Natural := UC_Log.Count;
   begin
      Ok (DC, "NAMES");
      Check (Wait (DC_Log, D + 1) and then Last (DC_Log) = ":localhost 366 alice_ * :End of /NAMES list",
             "NAMES without arguments");
      D := DC_Log.Count;
      UC.Channels.Get ("#one").Complete := True;
      UC.Channels.Get ("#one").Status := Soja.Irc.Members.Channel_Public;
      UC.Channels.Get ("#one").Members.Set
        ("troll", new Soja.Irc.Members.Membership_Vectors.Vector);
      Ok (DC, "NAMES #one,#unjoined");
      Check (Wait (DC_Log, D + 2) and then DC_Log.Has (" 353 * = #one troll"),
             "NAMES of a joined channel is answered here");
      Check (Wait (UC_Log, N + 1) and then Last (UC_Log) = "NAMES #unjoined",
             "and asked upstream for the others");
   end;

   -------------------------------------------------------------------
   --  WHO
   -------------------------------------------------------------------
   delay 0.3;   --  let earlier replies land before counting lines
   declare
      D : Natural := DC_Log.Count;
      B : Natural := Bnc_Log.Count;
      N : Natural;
   begin
      Ok (DC, "WHO");
      Check (Wait (DC_Log, D + 1)
             and then Last (DC_Log) = ":localhost 315 * * :End of /WHO list",
             "WHO without a mask: " & Last (DC_Log));

      --  The bouncer connection answers for itself.
      Bnc.Realname := To_Unbounded_String ("Alice Real");
      U.User_Record.Admin := True;
      Ok (Bnc, "WHO alice_");
      Check (Wait (Bnc_Log, B + 2)
             and then Line_Of (Bnc_Log, B + 1)
                      = ":localhost 352 * * alice 1.2.3.4 localhost alice_ H* :0 Alice Real"
             and then Line_Of (Bnc_Log, B + 2)
                      = ":localhost 315 * alice_ :End of /WHO list",
             "self WHO: " & Line_Of (Bnc_Log, B + 1));
      --  An away client is marked G (the bouncer has no upstream to ask).
      B := Bnc_Log.Count;
      Bnc.Away := To_Unbounded_String ("lunch");
      Ok (Bnc, "WHO alice_");
      Check (Wait (Bnc_Log, B + 2)
             and then Line_Of (Bnc_Log, B + 1)
                      = ":localhost 352 * * alice 1.2.3.4 localhost alice_ G* :0 Alice Real",
             "self WHO while away: " & Line_Of (Bnc_Log, B + 1));
      Bnc.Away := Null_Unbounded_String;
      U.User_Record.Admin := False;
      B := Bnc_Log.Count;
      Ok (Bnc, "WHO alice_ %uhnar,7");
      Check (Wait (Bnc_Log, B + 2)
             and then Line_Of (Bnc_Log, B + 1)
                      = ":localhost 354 * alice 1.2.3.4 alice_ alice :Alice Real",
             "self WHOX: " & Line_Of (Bnc_Log, B + 1));
      B := Bnc_Log.Count;
      Ok (Bnc, "WHO BouncerServ");
      Check (Wait (Bnc_Log, B + 2)
             and then Line_Of (Bnc_Log, B + 1)
                      = ":localhost 352 * * BouncerServ BouncerServ localhost "
                        & "BouncerServ H*B :0 soju bouncer service",
             "WHO of the service: " & Line_Of (Bnc_Log, B + 1));
      B := Bnc_Log.Count;
      Ok (Bnc, "WHO somebody");
      Check (Wait (Bnc_Log, B + 1)
             and then Last (Bnc_Log) = ":localhost 315 * somebody :End of /WHO list",
             "the bouncer connection has nobody else");
      D := DC_Log.Count;
      UC.Isupport.Include ("BOT", (Has_Value => True,
                                   Value => To_Unbounded_String ("B")));
      Ok (DC, "WHO bouncerserv");
      Check (Wait (DC_Log, D + 2) and then DC_Log.Has ("H*B"),
             "on a network the service uses the upstream's bot flag");

      --  On a network: from the cache when it can, else asked upstream.
      Soja.Irc.Cap_Registry.Set_Enabled (UC.Caps, "away-notify", True);
      Soja.Core.Upstream_Dispatch.Cache_User_Info
        (UC, "carol",
         (Nickname => To_Unbounded_String ("carol"),
          Username => To_Unbounded_String ("cu"),
          Hostname => To_Unbounded_String ("ch.example"),
          Server   => To_Unbounded_String ("irc"),
          Flags    => To_Unbounded_String ("H*"),
          Realname => To_Unbounded_String ("Carol C"), others => <>));
      Soja.Core.Upstream_Dispatch.Cache_User_Info
        (UC, "troll",
         (Nickname => To_Unbounded_String ("troll"),
          Username => To_Unbounded_String ("tu"),
          Hostname => To_Unbounded_String ("th.example"),
          Server   => To_Unbounded_String ("irc"),
          Flags    => To_Unbounded_String ("G"),
          Realname => To_Unbounded_String ("Troll T"), others => <>));
      D := DC_Log.Count;
      N := UC_Log.Count;
      Ok (DC, "WHO carol");
      Check (Wait (DC_Log, D + 2)
             and then Line_Of (DC_Log, D + 1)
                      = ":localhost 352 * * cu ch.example irc carol H* :0 Carol C",
             "a cached user: " & Line_Of (DC_Log, D + 1));
      Check (UC_Log.Count = N, "nothing asked upstream");

      --  A channel: every member must be cached; prefixes come from NAMES.
      declare
         Op : constant Soja.Irc.Members.Membership_Set_Access :=
           new Soja.Irc.Members.Membership_Vectors.Vector;
      begin
         Op.Append (Soja.Irc.Members.Std_Memberships (3));   --  o, @
         UC.Channels.Get ("#one").Members.Set ("carol", Op);
      end;
      D := DC_Log.Count;
      Ok (DC, "WHO #one");
      Check (Wait (DC_Log, D + 3), "a channel's members and the end");
      Check (DC_Log.Has (" 352 * #one cu ch.example irc carol H*@ :0 Carol C"),
             "the member prefix goes after the H/G and * flags");
      Check (DC_Log.Has (" 352 * #one tu th.example irc troll G :0 Troll T"),
             "a member without rank");
      --  A channel with an uncached member goes upstream.
      UC.Channels.Get ("#one").Members.Set
        ("stranger", new Soja.Irc.Members.Membership_Vectors.Vector);
      N := UC_Log.Count;
      Ok (DC, "WHO #one");
      Check (Wait (UC_Log, N + 1) and then Last (UC_Log) = "WHO #one",
             "an incomplete cache is not used");
      UC.Channels.Get ("#one").Members.Del ("stranger");
      --  WHOX fields the cache lacks (account) with no account-notify.
      UC.Pending_Cmds.Clear;   --  (the WHO above is still waiting for its reply)
      N := UC_Log.Count;
      Ok (DC, "WHO carol %na,1");
      Check (Wait (UC_Log, N + 1) and then Last (UC_Log) = "WHO carol %na,1",
             "fields we cannot keep up to date are asked upstream");
      Check (Error_Of (Bnc, "WHO x")'Length = 0, "no error on the bouncer");
   end;

   -------------------------------------------------------------------
   --  WHOIS
   -------------------------------------------------------------------
   delay 0.3;   --  let earlier replies land before counting lines
   declare
      D : Natural := DC_Log.Count;
      B : Natural := Bnc_Log.Count;
      N : Natural := UC_Log.Count;
   begin
      Check (Error_Of (DC, "WHOIS") = "431 alice_ :No nickname given",
             "WHOIS without a nick");
      Ok (DC, "WHOIS carol,dave");
      --  (Only the local checks look at the first user; the message is
      --  forwarded as it came.)
      Check (Wait (UC_Log, N + 1) and then Last (UC_Log) = "WHOIS carol,dave",
             "WHOIS goes upstream");
      N := UC_Log.Count;
      Ok (DC, "WHOIS irc.example erin");
      delay 0.15;
      Check (UC.Pending_Cmds ("WHOIS").Length = 2 and then UC_Log.Count = N,
             "the second one queues behind the first (not sent yet)");
      Check (Param (UC.Pending_Cmds ("WHOIS") (2).Msg, 1) = "erin",
             "and keeps its parameters");

      U.User_Record.Admin := True;
      Ok (Bnc, "WHOIS alice_");
      Check (Wait (Bnc_Log, B + 5), "the bouncer's own WHOIS");
      Check (Bnc_Log.Has (" 311 alice_ alice_ alice 1.2.3.4 * :Alice Real")
             and then Bnc_Log.Has (" 312 alice_ alice_ localhost soju")
             and then Bnc_Log.Has (" 313 alice_ alice_ :is a bouncer administrator")
             and then Bnc_Log.Has (" 330 alice_ alice_ alice :is logged in as")
             and then Bnc_Log.Has (" 318 alice_ alice_ :End of /WHOIS list"),
             "self WHOIS");
      U.User_Record.Admin := False;

      Ok (Bnc, "WHOIS BouncerServ");
      Check (Wait (Bnc_Log, B + 11), "the service's WHOIS");
      Check (Bnc_Log.Has (" 311 alice_ BouncerServ BouncerServ BouncerServ * :soju bouncer service")
             and then Bnc_Log.Has ("is the bouncer service")
             and then Bnc_Log.Has (" 335 alice_ BouncerServ :is a bot"),
             "service WHOIS");
      Ok (DC, "WHOIS bouncerserv");
      Check (Wait (DC_Log, D + 6), "the service's WHOIS on a network too");
      Check (Error_Of (Bnc, "WHOIS carol")(1 .. 3) = "400",
             "WHOIS of others needs a network");
   end;

   -------------------------------------------------------------------
   --  PRIVMSG, NOTICE, TAGMSG, INVITE, AWAY, INFO, MONITOR, ...
   -------------------------------------------------------------------
   delay 0.3;
   declare
      N : Natural := UC_Log.Count;
      B : Natural := Bnc_Log.Count;
      D : Natural := DC_Log.Count;
   begin
      Ok (DC, "PRIVMSG #one,carol :hello there");
      Check (Wait (UC_Log, N + 2)
             and then Line_Of (UC_Log, N + 1) = "PRIVMSG #one :hello there"
             and then Line_Of (UC_Log, N + 2) = "PRIVMSG carol :hello there",
             "PRIVMSG is sent to each target");
      N := UC_Log.Count;
      Ok (DC, "NOTICE carol :psst");
      Ok (DC, "TAGMSG #one");
      Check (Wait (UC_Log, N + 2) and then Last (UC_Log) = "TAGMSG #one",
             "NOTICE and TAGMSG");
      Check (Error_Of (DC, "PRIVMSG carol")(1 .. 3) = "461",
             "PRIVMSG needs text");
      Check (Error_Of (DC, "PRIVMSG")(1 .. 3) = "461", "PRIVMSG needs a target");

      --  To oneself on the bouncer connection: echoed back.
      Ok (Bnc, "PRIVMSG alice_ :note to self");
      Check (Wait (Bnc_Log, B + 1)
             and then Last (Bnc_Log) = ":alice_!~u@1.2.3.4 PRIVMSG alice_ :note to self",
             "self message: " & Last (Bnc_Log));

      --  To the service: the handler answers; PRIVMSG only.
      Ok (DC, "PRIVMSG BouncerServ :help");
      Check (Wait (DC_Log, D + 1)
             and then DC_Log.Has ("BouncerServ!BouncerServ@BouncerServ NOTICE"),
             "the service answers");
      Check (Error_Of (Bnc, "PRIVMSG somebody :hi")(1 .. 3) = "400",
             "no messaging others on the bouncer connection");

      --  Bouncer-wide broadcast needs an administrator.
      Check (Error_Of (DC, "NOTICE $*")(1 .. 3) = "461", "(needs text)");
      Check (Error_Of (Bnc, "NOTICE $* :everyone")
               = "415 alice_ $* :Permission denied to broadcast message to "
                 & "all bouncer users", "broadcast needs admin");
      U.User_Record.Admin := True;
      Ok (Bnc, "NOTICE $* :everyone");
      U.User_Record.Admin := False;

      --  NickServ passwords are saved for SASL.
      N := UC_Log.Count;
      Ok (DC, "PRIVMSG NickServ :IDENTIFY hunter2");
      Check (Wait (UC_Log, N + 1)
             and then Last (UC_Log) = "PRIVMSG NickServ :IDENTIFY hunter2",
             "NickServ message is relayed");

      --  A STATUSMSG sigil on the target does not hide NickServ (the message
      --  itself goes upstream as it came).
      UC.Available_Status_Msg := To_Unbounded_String ("@+");
      N := UC_Log.Count;
      Ok (DC, "PRIVMSG +NickServ :IDENTIFY hunter3");
      Check (Wait (UC_Log, N + 1)
             and then Last (UC_Log) = "PRIVMSG +NickServ :IDENTIFY hunter3",
             "the message is relayed with its sigil");
      Check (To_String (Net.Network_Record.SASL.Plain_Password) = "hunter3",
             "NickServ is recognised behind a STATUSMSG sigil");
      UC.Available_Status_Msg := Null_Unbounded_String;
   end;

   declare
      N : Natural := UC_Log.Count;
      D : Natural;
   begin
      Ok (DC, "INVITE carol #one");
      Check (Wait (UC_Log, N + 1) and then Last (UC_Log) = "INVITE carol #one",
             "INVITE relayed");
      Check (Error_Of (Bnc, "INVITE carol #one")(1 .. 3) = "400",
             "INVITE needs a network");

      N := UC_Log.Count;
      Ok (DC, "AWAY :lunch");
      Check (To_String (DC.Away) = "lunch", "AWAY is remembered");
      delay 0.2;
      Ok (DC, "AWAY");
      Check (Length (DC.Away) = 0, "and cleared");
      delay 0.2;
      Check (DC_Log.Has (" 306 ") and then DC_Log.Has (" 305 "),
             "with the replies");

      Ok (Bnc, "INFO");
      delay 0.2;
      Check (Bnc_Log.Has (" 371 alice_ :soju <https://soju.im>")
             and then Bnc_Log.Has (" 374 alice_ :End of INFO"), "INFO");
      N := UC_Log.Count;
      Ok (DC, "INFO");
      Check (Wait (UC_Log, N + 1) and then Last (UC_Log) = "INFO",
             "INFO on a network goes upstream");

      --  Registration, authentication.
      Check (Error_Of (DC, "REGISTER acct")(1 .. 3) = "461", "REGISTER params");
      Check (Error_Of (DC, "VERIFY acct")(1 .. 3) = "461", "VERIFY params");
      Check (Error_Of (DC, "REGISTER acct mail pw")
               = "FAIL REGISTER TEMPORARILY_UNAVAILABLE * "
                 & ":Upstream network account registration not supported",
             "REGISTER needs the capability");
      Soja.Irc.Cap_Registry.Set_Enabled
        (UC.Caps, "draft/account-registration", True);
      N := UC_Log.Count;
      Ok (DC, "REGISTER acct mail pw");
      delay 0.15;
      Check (UC.Pending_Cmds.Contains ("REGISTER"), "REGISTER is queued");
      Check (Error_Of (DC, "AUTHENTICATE PLAIN")
               = "904 alice_ :Upstream network authentication not supported",
             "AUTHENTICATE needs upstream SASL");

      --  MONITOR.
      Check (Error_Of (DC, "MONITOR L")(1 .. 3) = "421",
             "MONITOR without upstream support");
      UC.Isupport.Include
        ("MONITOR", (Has_Value => True, Value => Null_Unbounded_String));
      D := DC_Log.Count;
      Ok (DC, "MONITOR + carol,BouncerServ");
      Check (Wait (DC_Log, D + 1) and then DC_Log.Has (" 730 alice_ BouncerServ"),
             "the service is always online");
      Ok (DC, "MONITOR L");
      Check (Wait (DC_Log, D + 4) and then DC_Log.Has (" 732 alice_ carol")
             and then DC_Log.Has (" 733 alice_ :End of MONITOR list"),
             "MONITOR L");
      D := DC_Log.Count;
      Ok (DC, "MONITOR S");
      Check (Wait (DC_Log, D + 2) and then DC_Log.Has (" 731 alice_ carol"),
             "MONITOR S: offline until known");
      Ok (DC, "MONITOR - carol");
      Ok (DC, "MONITOR C");
      D := DC_Log.Count;
      Ok (DC, "MONITOR L");
      Check (Wait (DC_Log, D + 1) and then Last (DC_Log)(1 .. 20) /= ""
             and then DC.Monitored.Length = 0, "cleared");
      Check (Error_Of (DC, "MONITOR")(1 .. 3) = "461", "MONITOR needs more");
   end;

   -------------------------------------------------------------------
   --  BOUNCER (soju.im/bouncer-networks)
   -------------------------------------------------------------------
   delay 0.3;
   declare
      B : Natural := Bnc_Log.Count;
      function Id_Of (Name : String) return String is
      begin
         for Net of U.Networks loop
            if SD.Get_Name (Net.Network_Record) = Name then
               return Ada.Strings.Fixed.Trim
                 (Long_Long_Integer'Image (Net.Network_Record.ID),
                  Ada.Strings.Left);
            end if;
         end loop;
         return "";
      end Id_Of;
   begin
      Ok (Bnc, "BOUNCER LISTNETWORKS");
      Check (Wait (Bnc_Log, B + 1)
             and then Bnc_Log.Has ("BOUNCER NETWORK " & Id_Of ("net") & " ")
             and then Bnc_Log.Has ("name=net")
             and then Bnc_Log.Has ("host=irc.example")
             and then Bnc_Log.Has ("tls=0"),
             "LISTNETWORKS");

      Check (Has (Error_Of (Bnc, "BOUNCER ADDNETWORK bogus=1"),
                  "UNKNOWN_ATTRIBUTE ADDNETWORK bogus"), "unknown attribute");
      Check (Has (Error_Of (Bnc, "BOUNCER ADDNETWORK port=6667"),
                  "NEED_ATTRIBUTE ADDNETWORK host"), "host is needed");
      Check (Has (Error_Of (Bnc, "BOUNCER ADDNETWORK name=x"),
                  "UNKNOWN_ERROR ADDNETWORK"), "an empty address is refused");
      Check (Error_Of (Bnc, "BOUNCER ADDNETWORK")(1 .. 3) = "461",
             "needs attributes");
      Check (Has (Error_Of (Bnc, "BOUNCER BIND 1"),
                  "REGISTRATION_IS_COMPLETED"), "no bind after registering");
      Check (Has (Error_Of (Bnc, "BOUNCER FROB"), "UNKNOWN_COMMAND FROB"),
             "unknown subcommand");
      Check (Has (Error_Of (Bnc, "BOUNCER DELNETWORK 0"), "INVALID_NETID"),
             "bad id");
      Check (Has (Error_Of (Bnc, "BOUNCER CHANGENETWORK 999 name=x"),
                  "INVALID_NETID CHANGENETWORK 999"), "unknown id");

      B := Bnc_Log.Count;
      Ok (Bnc, "BOUNCER ADDNETWORK host=127.0.0.1;port=1;tls=0;name=second;"
               & "nickname=zed");
      declare
         Id : constant String := Id_Of ("second");
      begin
         Check (Id /= "", "the network was created");
         Check (Seen (Bnc_Log, "BOUNCER ADDNETWORK " & Id),
                "ADDNETWORK is answered");
         Check (To_String (Get_Network (U, "second").Network_Record.Addr)
                = "irc+insecure://127.0.0.1:1"
                and then To_String (Get_Network (U, "second")
                                      .Network_Record.Nick) = "zed",
                "from the attributes");

         Ok (Bnc, "BOUNCER CHANGENETWORK " & Id & " host=::1;port=6667;tls=0");
         Check (To_String (Get_Network (U, "second").Network_Record.Addr)
                = "irc+insecure://[::1]:6667", "an IPv6 host is bracketed");
         B := Bnc_Log.Count;
         Ok (Bnc, "BOUNCER CHANGENETWORK " & Id & " name=third");
         Check (Get_Network (U, "third") /= null, "renamed");
         Check (Seen (Bnc_Log, "BOUNCER CHANGENETWORK " & Id),
                "CHANGENETWORK is answered");

         B := Bnc_Log.Count;
         Ok (Bnc, "BOUNCER DELNETWORK " & Id);
         Check (Get_Network (U, "third") = null, "deleted");
         Check (Seen (Bnc_Log, "BOUNCER DELNETWORK " & Id),
                "DELNETWORK is answered");
      end;
   end;

   -------------------------------------------------------------------
   --  Anything else
   -------------------------------------------------------------------
   declare
      N : Natural := UC_Log.Count;
   begin
      Ok (DC, "FROBNICATE a b");
      Check (Wait (UC_Log, N + 1) and then Last (UC_Log) = "FROBNICATE a b",
             "unknown commands go upstream on a network");
   end;
   Check (Error_Of (Bnc, "FROBNICATE a")(1 .. 3) = "421",
          "but not on the bouncer connection");
   Net.Conn := null;
   Check (Error_Of (DC, "FROBNICATE a")
            = "421 * FROBNICATE :Disconnected from upstream network",
          "or while disconnected");
   Net.Conn := UC;

   for I in 1 .. N_Conns loop
      Soja.Conn.Close (Conns (I));
   end loop;
   Ada.Text_IO.Put_Line ("ALL PASS");
exception
   when E : others =>
      Ada.Text_IO.Put_Line
        ("FAILED: " & Ada.Exceptions.Exception_Information (E));
      Ada.Text_IO.Put_Line ("--- upstream ---");
      if UC_Log /= null then
         for I in 1 .. UC_Log.Count loop
            Ada.Text_IO.Put_Line (UC_Log.Line (I));
         end loop;
      end if;
      Ada.Text_IO.Put_Line ("--- client on the network ---");
      if DC_Log /= null then
         for I in 1 .. DC_Log.Count loop
            Ada.Text_IO.Put_Line (DC_Log.Line (I));
         end loop;
      end if;
      Ada.Text_IO.Put_Line ("--- client on the bouncer connection ---");
      if Bnc_Log /= null then
         for I in 1 .. Bnc_Log.Count loop
            Ada.Text_IO.Put_Line (Bnc_Log.Line (I));
         end loop;
      end if;
      GNAT.OS_Lib.OS_Exit (1);
end Commands_Check;
