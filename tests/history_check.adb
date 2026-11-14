pragma Ada_2022;

with Ada.Calendar;
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
with Soja.Irc.Xirc;
with Soja.Msgstore;
with Soja.Msgstore.Db;
with Soja.Msgstore.Memory;
with Soja.Server;
with Soja.User;

--  The registered client's commands (downstream.go handleMessageRegistered).
procedure History_Check is
   package SD renames Soja.Database;
   use type Ada.Containers.Count_Type;
   use type SD.Read_Receipt_Access;

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
   --  CHATHISTORY and SEARCH
   -------------------------------------------------------------------
   declare
      use type Ada.Calendar.Time;
      Start : constant Ada.Calendar.Time := Ada.Calendar.Clock - 3600.0;

      function Stamp (Seconds : Duration) return String is
        (Soja.Irc.Xirc.Format_Server_Time (Start + Seconds));

      procedure Put (Target, Who, Text : String; Seconds : Duration) is
         ID : constant String := U.Msg_Store.Append
           (Net.Network_Record, Target,
            Parse_Message ("@time=" & Stamp (Seconds) & " :" & Who
                           & "!u@h PRIVMSG " & Target & " :" & Text));
         pragma Unreferenced (ID);
      begin
         null;
      end Put;

      --  What the client got since Mark, as the text of the lines.
      Mark : Natural;
      procedure Begin_Query is
      begin
         delay 0.15;
         Mark := DC_Log.Count;
      end Begin_Query;

      function Got return String is
         R : Unbounded_String;
      begin
         delay 0.25;
         for I in Mark + 1 .. DC_Log.Count loop
            if Length (R) > 0 then
               Append (R, "\");
            end if;
            Append (R, DC_Log.Line (I));
         end loop;
         return To_String (R);
      end Got;

      --  The messages of a batch, without the tags: "text1|text2".
      function Texts_Of (Lines : String) return String is
         R : Unbounded_String;
         From : Positive := Lines'First;
      begin
         for I in Lines'Range loop
            if Lines (I) = '\' or else I = Lines'Last then
               declare
                  Last : constant Natural :=
                    (if Lines (I) = '\' then I - 1 else I);
                  L    : constant String := Lines (From .. Last);
                  P    : constant Natural := Ada.Strings.Fixed.Index (L, " PRIVMSG ");
                  --  After the target word; a one-word text has no colon.
                  Sp   : constant Natural :=
                    (if P = 0 then 0
                     else Ada.Strings.Fixed.Index (L (P + 9 .. L'Last), " "));
               begin
                  if Sp > 0 then
                     if Length (R) > 0 then
                        Append (R, "|");
                     end if;
                     Append (R, (if L (Sp + 1) = ':' then L (Sp + 2 .. L'Last)
                                 else L (Sp + 1 .. L'Last)));
                  end if;
               end;
               From := I + 1;
            end if;
         end loop;
         return To_String (R);
      end Texts_Of;
   begin
      --  Without a history store: not available.
      Check (Error_Of (DC, "CHATHISTORY LATEST #chat * 10")
             = "421 alice_ CHATHISTORY :Chat history disabled",
             "memory store: " & Error_Of (DC, "CHATHISTORY LATEST #chat * 10"));
      Check (Error_Of (DC, "SEARCH text=x;in=#chat")
             = "421 alice_ SEARCH :Unknown command", "no search either");

      U.Msg_Store := Soja.Msgstore.Db.New_Db_Store (DB);
      Soja.Irc.Cap_Registry.Set_Enabled (DC.Caps, "batch", True);
      Soja.Irc.Cap_Registry.Set_Enabled (DC.Caps, "message-tags", True);
      Soja.Irc.Cap_Registry.Set_Enabled (DC.Caps, "server-time", True);

      Put ("#chat", "bob", "first", 10.0);
      Put ("#chat", "carol", "second thing", 20.0);
      Put ("#chat", "bob", "third", 30.0);
      Put ("#chat", "carol", "fourth, the last", 40.0);
      Put ("carol", "carol", "a private note", 25.0);

      --  LATEST
      Begin_Query;
      Ok (DC, "CHATHISTORY LATEST #chat * 100");
      declare
         Lines : constant String := Got;
      begin
         Check (Has (Lines, "BATCH +") and then Has (Lines, " chathistory #chat")
                and then Has (Lines, "BATCH -"),
                "wrapped in a chathistory batch: " & Lines);
         Check (Texts_Of (Lines) = "first|second thing|third|fourth, the last",
                "LATEST *: " & Texts_Of (Lines));
         Check (Has (Lines, "@batch=") and then Has (Lines, "time="),
                "batch and time tags: " & Lines);
      end;
      Begin_Query;
      Ok (DC, "CHATHISTORY LATEST #chat * 2");
      Check (Texts_Of (Got) = "third|fourth, the last", "LATEST with a limit");
      Begin_Query;
      Ok (DC, "CHATHISTORY LATEST #CHAT timestamp=" & Stamp (35.0) & " 10");
      Check (Texts_Of (Got) = "fourth, the last",
             "LATEST <time> is the newest messages after it (and the target "
             & "is case-mapped)");

      --  BEFORE, AFTER, BETWEEN
      Begin_Query;
      Ok (DC, "CHATHISTORY BEFORE #chat timestamp=" & Stamp (30.0) & " 10");
      Check (Texts_Of (Got) = "first|second thing", "BEFORE");
      Begin_Query;
      Ok (DC, "CHATHISTORY BEFORE #chat timestamp=" & Stamp (30.0) & " 1");
      Check (Texts_Of (Got) = "second thing", "BEFORE, the newest of them");
      Begin_Query;
      Ok (DC, "CHATHISTORY AFTER #chat timestamp=" & Stamp (10.0) & " 10");
      Check (Texts_Of (Got) = "second thing|third|fourth, the last", "AFTER");
      Begin_Query;
      Ok (DC, "CHATHISTORY AFTER #chat timestamp=" & Stamp (10.0) & " 1");
      Check (Texts_Of (Got) = "second thing", "AFTER, the oldest of them");
      Begin_Query;
      Ok (DC, "CHATHISTORY BETWEEN #chat timestamp=" & Stamp (10.0)
              & " timestamp=" & Stamp (40.0) & " 10");
      Check (Texts_Of (Got) = "second thing|third", "BETWEEN, oldest to newest");
      Begin_Query;
      Ok (DC, "CHATHISTORY BETWEEN #chat timestamp=" & Stamp (40.0)
              & " timestamp=" & Stamp (10.0) & " 10");
      Check (Texts_Of (Got) = "second thing|third", "BETWEEN, newest to oldest");

      --  TARGETS
      Begin_Query;
      Ok (DC, "CHATHISTORY TARGETS timestamp=" & Stamp (0.0) & " timestamp="
              & Stamp (100.0) & " 10");
      declare
         Lines : constant String := Got;
      begin
         Check (Has (Lines, "BATCH +") and then Has (Lines, "draft/chathistory-targets")
                and then Has (Lines, "CHATHISTORY TARGETS carol " & Stamp (25.0))
                and then Has (Lines, "CHATHISTORY TARGETS #chat " & Stamp (40.0)),
                "targets with their latest time: " & Lines);
         Check (Ada.Strings.Fixed.Index (Lines, "TARGETS carol")
                < Ada.Strings.Fixed.Index (Lines, "TARGETS #chat"),
                "oldest first");
      end;
      --  A detached channel is not a target.
      Net.Channels.Set ("#chat", new SD.Channel'
        (Name => To_Unbounded_String ("#chat"), Detached => True, others => <>));
      Begin_Query;
      Ok (DC, "CHATHISTORY TARGETS timestamp=" & Stamp (0.0) & " timestamp="
              & Stamp (100.0) & " 10");
      declare
         Lines : constant String := Got;
      begin
         Check (Has (Lines, "TARGETS carol") and then not Has (Lines, "TARGETS #chat"),
                "detached channels are skipped: " & Lines);
      end;
      Net.Channels.Del ("#chat");

      --  On the bouncer connection there are no targets (an empty batch).
      Begin_Query;
      Soja.Irc.Cap_Registry.Set_Enabled (Bnc.Caps, "batch", True);
      declare
         B : constant Natural := Bnc_Log.Count;
      begin
         Ok (Bnc, "CHATHISTORY TARGETS * * 10");
         delay 0.25;
         Check (Bnc_Log.Count = B + 2 and then Has (Bnc_Log.Line (B + 1), "BATCH +")
                and then Has (Bnc_Log.Line (B + 1), "draft/chathistory-targets"),
                "bouncer connection: an empty targets batch");
      end;

      --  The service has no history: an empty batch.
      Begin_Query;
      Ok (DC, "CHATHISTORY LATEST BouncerServ * 10");
      declare
         Lines : constant String := Got;
      begin
         Check (Has (Lines, " chathistory BouncerServ") and then Texts_Of (Lines) = "",
                "BouncerServ: nothing: " & Lines);
      end;

      --  Errors.
      Check (Has (Error_Of (DC, "CHATHISTORY FROB #chat 1"),
                  "FAIL CHATHISTORY INVALID_PARAMS FROB") and then
             Has (Error_Of (DC, "CHATHISTORY FROB #chat 1"), "Unknown command"),
             "unknown subcommand");
      Check (Error_Of (DC, "CHATHISTORY")(1 .. 3) = "461", "needs a subcommand");
      Check (Error_Of (DC, "CHATHISTORY LATEST #chat *")(1 .. 3) = "461",
             "needs a limit");
      Check (Has (Error_Of (DC, "CHATHISTORY LATEST #chat * 5000"),
                  "INVALID_PARAMS LATEST 5000 :Invalid limit"), "limit too big");
      Check (Has (Error_Of (DC, "CHATHISTORY LATEST #chat * -1"),
                  "Invalid limit"), "negative limit");
      Check (Has (Error_Of (DC, "CHATHISTORY LATEST #chat * ten"),
                  "Invalid limit"), "limit not a number");
      Check (Has (Error_Of (DC, "CHATHISTORY BEFORE #chat garbage 10"),
                  "INVALID_PARAMS BEFORE garbage :Invalid first bound"),
             "bad first bound");
      Check (Has (Error_Of (DC, "CHATHISTORY BEFORE #chat * 10"),
                  "Invalid first bound"), "* is only for LATEST");
      Check (Has (Error_Of (DC, "CHATHISTORY BETWEEN #chat timestamp="
                            & Stamp (1.0) & " nope 10"),
                  "INVALID_PARAMS BETWEEN nope :Invalid second bound"),
             "bad second bound");
      Check (Has (Error_Of (Bnc, "CHATHISTORY LATEST #chat * 10"),
                  "INVALID_TARGET LATEST #chat")
             and then Has (Error_Of (Bnc, "CHATHISTORY LATEST #chat * 10"),
                           "Cannot fetch chat history on bouncer connection"),
             "history needs a network");

      --  SEARCH
      Begin_Query;
      Ok (DC, "SEARCH text=second;in=#chat");
      declare
         Lines : constant String := Got;
      begin
         Check (Has (Lines, " soju.im/search") and then Texts_Of (Lines) = "second thing",
                "search by text: " & Lines);
      end;
      Begin_Query;
      Ok (DC, "SEARCH from=bob;in=#chat");
      Check (Texts_Of (Got) = "first|third", "search by sender");
      Begin_Query;
      Ok (DC, "SEARCH in=#chat;limit=1");
      Check (Texts_Of (Got) = "fourth, the last", "the newest one within the limit");
      Begin_Query;
      Ok (DC, "SEARCH in=#chat;after=" & Stamp (10.0) & ";before=" & Stamp (40.0));
      Check (Texts_Of (Got) = "second thing|third", "search between times");
      Begin_Query;
      Ok (DC, "SEARCH in=#chat;text=!!!");
      Check (Texts_Of (Got) = "", "text without words matches nothing");
      Check (Has (Error_Of (DC, "SEARCH text=x"),
                  "SEARCH INVALID_PARAMS in :The in parameter is mandatory"),
             "in is mandatory");
      Check (Has (Error_Of (Bnc, "SEARCH in=#chat"),
                  "INVALID_PARAMS in :Cannot search on bouncer connection"),
             "search needs a network");
      Check (Has (Error_Of (DC, "SEARCH in=#chat;limit=0"),
                  "INVALID_PARAMS limit :Invalid limit"), "bad limit");
      Check (Has (Error_Of (DC, "SEARCH in=#chat;after=yesterday"),
                  "INVALID_PARAMS after :Invalid criteria"), "bad time");
      Check (Error_Of (DC, "SEARCH")(1 .. 3) = "461", "SEARCH needs attributes");
   end;

   -------------------------------------------------------------------
   --  READ and MARKREAD
   -------------------------------------------------------------------
   declare
      use type Ada.Calendar.Time;
      Past  : constant Ada.Calendar.Time := Ada.Calendar.Clock - 7200.0;
      function Stamp (Seconds : Duration) return String is
        (Soja.Irc.Xirc.Format_Server_Time (Past + Seconds));

      D2_Log : Recorder_Access;
      D2     : constant Downstream_Conn_Access := New_DC (U, Net, 7, D2_Log);
      Mark1, Mark2, MarkB : Natural;

      procedure Begin_Query is
      begin
         delay 0.2;
         Mark1 := DC_Log.Count;
         Mark2 := D2_Log.Count;
         MarkB := Bnc_Log.Count;
      end Begin_Query;

      function Last_Of (R : Recorder_Access; Mark : Natural) return String is
      begin
         delay 0.25;
         return (if R.Count > Mark then R.Line (R.Count) else "");
      end Last_Of;

      function Stored return String is
         R : constant SD.Read_Receipt_Access :=
           SD.Get_Read_Receipt (DB.all, Net.Network_Record.ID, "#chat");
      begin
         return (if R = null then "" else Soja.Irc.Xirc.Format_Server_Time
                                           (R.Timestamp));
      end Stored;
   begin
      U.Downstream_Conns.Append (D2);
      Soja.Irc.Cap_Registry.Set_Enabled (DC.Caps, "draft/read-marker", True);
      Soja.Irc.Cap_Registry.Set_Enabled (D2.Caps, "soju.im/read", True);

      --  Nothing stored yet: "*".
      Begin_Query;
      Ok (DC, "MARKREAD #chat");
      Check (Last_Of (DC_Log, Mark1) = ":alice_!~u@1.2.3.4 MARKREAD #chat *",
             "no marker yet: " & Last_Of (DC_Log, Mark1));
      Check (D2_Log.Count = Mark2, "a query is answered to the asker alone");

      --  Setting one: stored, sent to every client of the network, each in
      --  the dialect it speaks (MARKREAD, or READ for soju.im/read).
      Begin_Query;
      Ok (DC, "MARKREAD #chat timestamp=" & Stamp (10.0));
      Check (Last_Of (DC_Log, Mark1)
             = ":alice_!~u@1.2.3.4 MARKREAD #chat timestamp=" & Stamp (10.0),
             "the asker gets the new marker: " & Last_Of (DC_Log, Mark1));
      Check (Last_Of (D2_Log, Mark2)
             = ":alice_!~u@1.2.3.4 READ #chat timestamp=" & Stamp (10.0),
             "another client gets it as READ: " & Last_Of (D2_Log, Mark2));
      Check (Bnc_Log.Count = MarkB, "not the bouncer connection");
      Check (Stored = Stamp (10.0), "stored: " & Stored);

      --  An older marker changes nothing and is not broadcast.
      Begin_Query;
      Ok (DC, "READ #chat timestamp=" & Stamp (5.0));
      Check (Last_Of (DC_Log, Mark1)
             = ":alice_!~u@1.2.3.4 MARKREAD #chat timestamp=" & Stamp (10.0),
             "the asker is told the marker it has");
      Check (D2_Log.Count = Mark2, "and nobody else");
      Check (Stored = Stamp (10.0), "still the newer one");

      --  A newer one, with the target in another case.
      Begin_Query;
      Ok (DC, "MARKREAD #CHAT timestamp=" & Stamp (20.0));
      Check (Stored = Stamp (20.0), "stored under the case-mapped name");
      Check (Has (Last_Of (D2_Log, Mark2), "READ #CHAT timestamp="),
             "the target is reported as the client wrote it");

      --  A time in the future is clamped to now.
      Begin_Query;
      Ok (DC, "MARKREAD #chat timestamp="
              & Soja.Irc.Xirc.Format_Server_Time (Ada.Calendar.Clock + 86_400.0));
      declare
         Reply    : constant String := Last_Of (DC_Log, Mark1);
         Tomorrow : constant String := Soja.Irc.Xirc.Format_Server_Time
           (Ada.Calendar.Clock + 90_000.0);
         Day      : constant String :=
           Tomorrow (Tomorrow'First .. Tomorrow'First + 9);
      begin
         Check (Has (Reply, "MARKREAD #chat timestamp=")
                and then not Has (Reply, "timestamp=" & Day),
                "a future marker is clamped to now: " & Reply);
      end;

      --  A marker at or after a pending push target clears the target.
      declare
         Pending : constant Ada.Calendar.Time := Ada.Calendar.Clock - 60.0;
      begin
         Net.Push_Targets.Set ("#chat", Pending);
         Ok (DC, "MARKREAD #chat timestamp="
                 & Soja.Irc.Xirc.Format_Server_Time (Ada.Calendar.Clock));
         Check (not Net.Push_Targets.Has ("#chat"), "the push target is cleared");
      end;

      --  The service keeps no markers.
      Begin_Query;
      Ok (DC, "MARKREAD BouncerServ timestamp=" & Stamp (1.0));
      Check (Last_Of (DC_Log, Mark1) = ":alice_!~u@1.2.3.4 MARKREAD BouncerServ *",
             "BouncerServ: always *");

      --  Errors.
      Check (Has (Error_Of (DC, "MARKREAD"),
                  "FAIL MARKREAD NEED_MORE_PARAMS") , "needs a target");
      Check (Has (Error_Of (DC, "READ"), "FAIL READ NEED_MORE_PARAMS"),
             "READ too");
      Check (Has (Error_Of (DC, "MARKREAD #chat msgid=abc"),
                  "MARKREAD INVALID_PARAMS msgid=abc :Unknown criteria"),
             "only timestamp criteria");
      Check (Has (Error_Of (DC, "MARKREAD #chat *"), "Unknown criteria"),
             "* is not a criteria");
      Check (Has (Error_Of (DC, "MARKREAD #chat timestamp=garbage"),
                  "INVALID_PARAMS timestamp=garbage :Invalid criteria"),
             "bad time");
      Soja.Irc.Cap_Registry.Set_Enabled (Bnc.Caps, "draft/read-marker", True);
      Check (Has (Error_Of (Bnc, "MARKREAD #chat"),
                  "MARKREAD INTERNAL_ERROR #chat :Cannot set read markers on "
                  & "bouncer connection"), "needs a network");
      --  Without either capability a client may still send the command (the
      --  capability only decides what it is sent back): it just hears nothing.
      Soja.Irc.Cap_Registry.Set_Enabled (DC.Caps, "draft/read-marker", False);
      Begin_Query;
      Check (Error_Of (DC, "MARKREAD #chat") = "",
             "a client without the capability can still ask");
      Check (Last_Of (DC_Log, Mark1) = "" or else DC_Log.Count = Mark1,
             "and is sent nothing");
   end;

   for I in 1 .. N_Conns loop
      Soja.Conn.Close (Conns (I));
   end loop;
   Ada.Text_IO.Put_Line ("ALL PASS");
exception
   when E : others =>
      Ada.Text_IO.Put_Line
        ("FAILED: " & Ada.Exceptions.Exception_Information (E));
      Ada.Text_IO.Put_Line ("--- client on the network ---");
      if DC_Log /= null then
         for I in 1 .. DC_Log.Count loop
            Ada.Text_IO.Put_Line (DC_Log.Line (I));
         end loop;
      end if;
      GNAT.OS_Lib.OS_Exit (1);
end History_Check;
