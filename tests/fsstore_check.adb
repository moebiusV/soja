pragma Ada_2022;

with Ada.Calendar;
with Ada.Calendar.Arithmetic;
with Ada.Calendar.Formatting;
with Ada.Containers;
with Ada.Directories;
with Ada.Exceptions;
with Ada.Streams.Stream_IO;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;
with Ada.Text_IO;
with GNAT.OS_Lib;

with Soja.Database;        use Soja.Database;
with Soja.Irc.Messages;    use Soja.Irc.Messages;
with Soja.Irc.Xirc;
with Soja.Msgstore;        use Soja.Msgstore;
with Soja.Msgstore.Fs;
with Soja.Msgstore.Znclog;

--  The file message store and the ZNC log format (msgstore/fs.go, znclog).
procedure Fsstore_Check is
   use type Ada.Calendar.Time;
   use type Ada.Containers.Count_Type;

   procedure Check (Cond : Boolean; What : String) is
   begin
      if not Cond then
         raise Program_Error with What;
      end if;
   end Check;

   Root : constant String := "/tmp/soja-fsstore-check";

   --  Local times, as the logs use.
   function Local (Y, M, D, H, Mi, S : Natural) return Ada.Calendar.Time is
     (Ada.Calendar.Formatting.Time_Of
        (Ada.Calendar.Year_Number (Y), Ada.Calendar.Month_Number (M),
         Ada.Calendar.Day_Number (D), H, Mi, S));

   --  09:00 local, N days ago; and a day's file name.
   function Days_Ago (N : Natural) return Ada.Calendar.Time is
      Y : Ada.Calendar.Year_Number;
      M : Ada.Calendar.Month_Number;
      D : Ada.Calendar.Day_Number;
      S : Ada.Calendar.Day_Duration;
   begin
      Ada.Calendar.Split (Ada.Calendar.Clock, Y, M, D, S);
      return Ada.Calendar.Arithmetic."-"
        (Local (Y, M, D, 9, 0, 0), Ada.Calendar.Arithmetic.Day_Count (N));
   end Days_Ago;

   function Date_Name (T : Ada.Calendar.Time) return String is
      Y : Ada.Calendar.Year_Number;
      M : Ada.Calendar.Month_Number;
      D : Ada.Calendar.Day_Number;
      S : Ada.Calendar.Day_Duration;
      function Two (N : Natural) return String is
        (if N < 10 then "0" & Ada.Strings.Fixed.Trim (Natural'Image (N), Ada.Strings.Left)
         else Ada.Strings.Fixed.Trim (Natural'Image (N), Ada.Strings.Left));
   begin
      Ada.Calendar.Split (T, Y, M, D, S);
      return Ada.Strings.Fixed.Trim (Integer'Image (Y), Ada.Strings.Left)
        & "-" & Two (M) & "-" & Two (D);
   end Date_Name;

   function Tagged_Line (Raw : String; T : Ada.Calendar.Time) return Message is
     (Parse_Message
        ("@time=" & Soja.Irc.Xirc.Format_Server_Time (T) & " " & Raw));

   function Contents (Path : String) return String is
      use Ada.Streams;
      F : Stream_IO.File_Type;
      R : Unbounded_String;
      Chunk : Stream_Element_Array (1 .. 4096);
      Last  : Stream_Element_Offset;
   begin
      Stream_IO.Open (F, Stream_IO.In_File, Path);
      loop
         Stream_IO.Read (F, Chunk, Last);
         exit when Last < Chunk'First;
         for I in Chunk'First .. Last loop
            Append (R, Character'Val (Chunk (I)));
         end loop;
      end loop;
      Stream_IO.Close (F);
      return To_String (R);
   end Contents;

   procedure Write_File (Path, Text : String) is
      F : Ada.Text_IO.File_Type;
   begin
      Ada.Directories.Create_Path (Ada.Directories.Containing_Directory (Path));
      Ada.Text_IO.Create (F, Ada.Text_IO.Out_File, Path);
      Ada.Text_IO.Put (F, Text);
      Ada.Text_IO.Close (F);
   end Write_File;

   function Texts (V : Message_Vector) return String is
      R : Unbounded_String;
   begin
      for M of V loop
         declare
            Last : constant String :=
              (if M.Params.Is_Empty then ""
               else To_String (M.Params (Natural (M.Params.Length))));
            Item : constant String := To_String (M.Command) & ":" & Last;
         begin
            if Length (R) > 0 then
               Append (R, "|");
            end if;
            Append (R, Item);
         end;
      end loop;
      return To_String (R);
   end Texts;

   User : constant Soja.Database.User := New_User ("alice");
   Net  : Network := New_Network ("irc+insecure://x");
   Dummy : Boolean;
   Zero_Time : Ada.Calendar.Time renames Soja.Database.Null_Time;
begin
   Net.ID := 7;
   Net.Name := To_Unbounded_String ("libera");
   GNAT.OS_Lib.Delete_File (Root, Dummy);
   if Ada.Directories.Exists (Root) then
      Ada.Directories.Delete_Tree (Root);
   end if;

   ------------------------------------------------------------------
   --  File names
   ------------------------------------------------------------------
   Check (Soja.Msgstore.Fs.Escape_Filename (".") = "-"
          and then Soja.Msgstore.Fs.Escape_Filename ("..") = "--"
          and then Soja.Msgstore.Fs.Escape_Filename ("a/b\c") = "a-b-c"
          and then Soja.Msgstore.Fs.Escape_Filename ("#chan") = "#chan",
          "EscapeFilename");

   ------------------------------------------------------------------
   --  The line format
   ------------------------------------------------------------------
   declare
      use Soja.Msgstore.Znclog;
      T : constant Ada.Calendar.Time := Local (2026, 5, 10, 12, 34, 56);
      function L (Raw : String) return String is
        (Marshal_Line (Parse_Message (Raw), T));
   begin
      Check (L (":bob!u@h PRIVMSG #c :hello there") = "[12:34:56] <bob> hello there",
             "PRIVMSG: " & L (":bob!u@h PRIVMSG #c :hello there"));
      Check (L (":bob!u@h PRIVMSG #c :" & ASCII.SOH & "ACTION waves" & ASCII.SOH)
             = "[12:34:56] * bob waves", "ACTION");
      Check (L (":bob!u@h NOTICE #c :a notice") = "[12:34:56] -bob- a notice",
             "NOTICE");
      Check (L (":bob!u@h JOIN #c") = "[12:34:56] *** Joins: bob (u@h)", "JOIN");
      Check (L (":bob!u@h PART #c :bye now") = "[12:34:56] *** Parts: bob (u@h) (bye now)",
             "PART");
      Check (L (":bob!u@h PART #c") = "[12:34:56] *** Parts: bob (u@h) ()",
             "PART without a reason");
      Check (L (":bob!u@h QUIT :gone") = "[12:34:56] *** Quits: bob (u@h) (gone)",
             "QUIT");
      Check (L (":op!u@h KICK #c bob :out") = "[12:34:56] *** bob was kicked by op (out)",
             "KICK");
      Check (L (":bob!u@h NICK bobby") = "[12:34:56] *** bob is now known as bobby",
             "NICK");
      Check (L (":bob!u@h TOPIC #c :new topic") = "[12:34:56] *** bob changes topic to 'new topic'",
             "TOPIC");
      Check (L (":bob!u@h MODE #c +o carol") = "[12:34:56] *** bob sets mode: +o carol",
             "MODE");
      Check (L (":bob!u@h PING x") = "" and then L (":bob!u@h 001 x") = "",
             "other commands are not logged");

      declare
         Msg : Message;
         When_T : Ada.Calendar.Time;
         Ok  : Boolean;
         Ref : constant Ada.Calendar.Time := Local (2026, 5, 10, 0, 0, 0);
         Nw  : constant Soja.Database.Network := Net;
         procedure Read (Line, Entity : String; Events : Boolean) is
         begin
            Unmarshal_Line (Line, User, Nw, Entity, Ref, Events, Msg, When_T, Ok);
         end Read;
      begin
         Read ("[12:34:56] <bob> hello <there> world", "#c", False);
         Check (Ok and then To_String (Msg.Command) = "PRIVMSG"
                and then To_String (Msg.Prefix.Name) = "bob"
                and then Param (Msg, 0) = "#c"
                and then Param (Msg, 1) = "hello <there> world"
                and then When_T = Local (2026, 5, 10, 12, 34, 56)
                and then Get_Tag (Msg.Tags, "time")
                         = Soja.Irc.Xirc.Format_Server_Time (When_T),
                "a message, split at the first '> ' only");
         Read ("[12:34:56] -svc- notice text", "#c", False);
         Check (Ok and then To_String (Msg.Command) = "NOTICE"
                and then Param (Msg, 1) = "notice text", "a notice");
         Read ("[12:34:56] * bob waves hello", "#c", False);
         Check (Ok and then Param (Msg, 1) = ASCII.SOH & "ACTION waves hello" & ASCII.SOH,
                "an action");
         Read ("[12:34:56] <bob> psst", "bob", False);
         Check (Ok and then Param (Msg, 0) = "alice",
                "a message to us from the entity: the entity becomes our nick");
         Read ("[12:34:56] *** Joins: bob (u@h)", "#c", False);
         Check (not Ok, "events are skipped unless asked for");
         Read ("[12:34:56] *** Joins: bob (u@h)", "#c", True);
         Check (Ok and then To_String (Msg.Command) = "JOIN"
                and then To_String (Msg.Prefix.User) = "u"
                and then To_String (Msg.Prefix.Host) = "h", "JOIN event");
         Read ("[12:34:56] *** Parts: bob (u@h) (see you)", "#c", True);
         Check (Ok and then To_String (Msg.Command) = "PART"
                and then Param (Msg, 1) = "see you", "PART event");
         Read ("[12:34:56] *** Quits: bob (u@h) ()", "#c", True);
         Check (Ok and then To_String (Msg.Command) = "QUIT"
                and then Msg.Params.Is_Empty, "QUIT event, no reason");
         Read ("[12:34:56] *** bob was kicked by op (spam)", "#c", True);
         Check (Ok and then To_String (Msg.Command) = "KICK"
                and then To_String (Msg.Prefix.Name) = "op"
                and then Param (Msg, 1) = "bob" and then Param (Msg, 2) = "spam",
                "KICK event");
         Read ("[12:34:56] *** bob is now known as robert", "#c", True);
         Check (Ok and then To_String (Msg.Command) = "NICK"
                and then Param (Msg, 0) = "robert", "NICK event");
         Read ("[12:34:56] *** bob changes topic to 'the topic'", "#c", True);
         Check (Ok and then To_String (Msg.Command) = "TOPIC"
                and then Param (Msg, 1) = "the topic", "TOPIC event");
         Read ("[12:34:56] *** bob sets mode: +o carol", "#c", True);
         Check (Ok and then To_String (Msg.Command) = "MODE"
                and then Natural (Msg.Params.Length) = 3
                and then Param (Msg, 1) = "+o" and then Param (Msg, 2) = "carol",
                "MODE event");
         Read ("[12:34:56] garbage", "#c", False);
         Check (not Ok, "a line that is not a message");
         Read ("[12:34:56] *** Joins: bob", "#c", True);
         Check (not Ok, "a malformed event");
         begin
            Read ("12:34:56 <bob> no brackets", "#c", False);
            Check (False, "a line without the time was accepted");
         exception
            when Store_Error => null;
         end;
         begin
            Read ("[ab:34:56] <bob> x", "#c", False);
            Check (False, "a non-numeric time was accepted");
         exception
            when Store_Error => null;
         end;
         begin
            Read ("[99:34:56] <bob> x", "#c", False);
            Check (False, "an impossible time was accepted");
         exception
            when Store_Error => null;
         end;
      end;
   end;

   ------------------------------------------------------------------
   --  The store: what is on disk, and message IDs
   ------------------------------------------------------------------
   declare
      Store : constant Store_Access :=
        Soja.Msgstore.Fs.New_Fs_Store (Root, User);
      --  (Recent days: loading the latest messages walks back from today and
      --  gives up after 100 days without a log, as soju does.)
      Day1  : constant Ada.Calendar.Time := Days_Ago (3);
      Day2  : constant Ada.Calendar.Time := Days_Ago (2);
      Opts  : Load_Message_Options :=
        (Network => Net, Entity => To_Unbounded_String ("#c"),
         Limit => 100, Events => False);
      Path1 : constant String :=
        Root & "/alice/libera/#c/" & Date_Name (Day1) & ".log";
      Path2 : constant String :=
        Root & "/alice/libera/#c/" & Date_Name (Day2) & ".log";
      Id1, Id2, Id3 : Unbounded_String;
   begin
      Check (Store.Supports_Chat_History and then Store.Supports_Search
             and then Store.Supports_Rename_Network, "capabilities");
      Check (Soja.Msgstore.Fs.Is_Fs_Store (Store.all), "IsFSStore");

      --  Nothing yet: an ID that works in history queries.
      declare
         Before : constant String := Store.Last_Msg_ID (Net, "#c", Day1);
      begin
         Check (Before /= "" and then Store.Load_Latest_ID (Before, Opts).Is_Empty,
                "an ID for a day without a log");
      end;

      Id1 := To_Unbounded_String (Store.Append (Net, "#c", Tagged_Line
        (":bob!u@h PRIVMSG #c :first of the day", Day1)));
      Id2 := To_Unbounded_String (Store.Append (Net, "#c", Tagged_Line
        (":carol!u@h PRIVMSG #c :second", Day1 + 60.0)));
      Check (Store.Append (Net, "#c", Tagged_Line
               (":srv PING :x", Day1 + 70.0)) = "",
             "a message that is not logged has no ID");
      Id3 := To_Unbounded_String (Store.Append (Net, "#c", Tagged_Line
        (":dave!u@h JOIN #c", Day1 + 120.0)));
      Check (Contents (Path1)
             = "[09:00:00] <bob> first of the day" & ASCII.LF
               & "[09:01:00] <carol> second" & ASCII.LF
               & "[09:02:00] *** Joins: dave (u@h)" & ASCII.LF,
             "the log file, in ZNC's format: " & Contents (Path1));
      Check (Id1 /= Id2 and then Id2 /= Id3, "distinct IDs");
      Check (Store.Last_Msg_ID (Net, "#c", Day1)
             /= To_String (Id3), "LastMsgID points at the end of the file");

      Id3 := To_Unbounded_String (Store.Append (Net, "#c", Tagged_Line
        (":bob!u@h PRIVMSG #c :next day", Day2)));
      Check (Contents (Path2) = "[09:00:00] <bob> next day" & ASCII.LF,
             "another day, another file");

      --  LoadLatestID: after an ID, the newest first-limited.
      Check (Texts (Store.Load_Latest_ID (To_String (Id1), Opts))
             = "PRIVMSG:second|PRIVMSG:next day", "after the first message");
      Check (Texts (Store.Load_Latest_ID (To_String (Id2), Opts))
             = "PRIVMSG:next day", "after the second");
      Check (Texts (Store.Load_Latest_ID
                      (Store.Last_Msg_ID (Net, "#c", Day1), Opts))
             = "PRIVMSG:next day", "after the end of a day's file");
      Opts.Limit := 1;
      Check (Texts (Store.Load_Latest_ID (To_String (Id1), Opts))
             = "PRIVMSG:next day", "the newest one when the limit cuts");
      Opts.Limit := 100;
      Opts.Events := True;
      Check (Texts (Store.Load_Latest_ID (To_String (Id1), Opts))
             = "PRIVMSG:second|JOIN:#c|PRIVMSG:next day",
             "with events: " & Texts (Store.Load_Latest_ID (To_String (Id1), Opts)));
      Opts.Events := False;
      Check (Texts (Store.Load_Latest_ID ("", Opts))
             = "PRIVMSG:first of the day|PRIVMSG:second|PRIVMSG:next day",
             "no ID: everything");

      --  IDs of another network or entity, or garbage, are refused.
      declare
         Other : Network := Net;
      begin
         Other.ID := 8;
         begin
            Check (Store.Load_Latest_ID
                     (Store.Last_Msg_ID (Other, "#c", Day1), Opts).Is_Empty, "x");
            Check (False, "an ID of another network was accepted");
         exception
            when Store_Error => null;
         end;
      end;
      begin
         Check (Store.Load_Latest_ID
                  (Store.Last_Msg_ID (Net, "#other", Day1), Opts).Is_Empty, "x");
         Check (False, "an ID of another entity was accepted");
      exception
         when Store_Error => null;
      end;
      begin
         Check (Store.Load_Latest_ID ("%%%", Opts).Is_Empty, "x");
         Check (False, "garbage was accepted as an ID");
      exception
         when Store_Error => null;
      end;

      ---------------------------------------------------------------
      --  History by time, across days
      ---------------------------------------------------------------
      Check (Texts (Store.Load_Before_Time (Day2 + 3600.0, Zero_Time, Opts))
             = "PRIVMSG:first of the day|PRIVMSG:second|PRIVMSG:next day",
             "before: walks back across days");
      Opts.Limit := 2;
      Check (Texts (Store.Load_Before_Time (Day2 + 3600.0, Zero_Time, Opts))
             = "PRIVMSG:second|PRIVMSG:next day", "before, the newest two");
      Opts.Limit := 100;
      Check (Texts (Store.Load_Before_Time (Day2 + 3600.0, Day1 + 30.0, Opts))
             = "PRIVMSG:second|PRIVMSG:next day", "before, down to a time");
      Check (Texts (Store.Load_After_Time (Day1 - 3600.0, Day2 + 3600.0, Opts))
             = "PRIVMSG:first of the day|PRIVMSG:second|PRIVMSG:next day",
             "after: walks forward across days");
      Opts.Limit := 2;
      Check (Texts (Store.Load_After_Time (Day1 - 3600.0, Day2 + 3600.0, Opts))
             = "PRIVMSG:first of the day|PRIVMSG:second", "after, the oldest two");
      Opts.Limit := 100;
      Check (Texts (Store.Load_After_Time (Day1, Day2, Opts))
             = "PRIVMSG:second", "bounds are excluded");
      Check (Store.Load_Before_Time (Day1 - 7200.0, Zero_Time, Opts).Is_Empty,
             "before the first message");

      ---------------------------------------------------------------
      --  Search
      ---------------------------------------------------------------
      declare
         Found : Message_Vector;
      begin
         Found := Store.Search
           (Net, (Limit => 10, In_Target => To_Unbounded_String ("#c"),
                  Text => To_Unbounded_String ("DAY"), others => <>));
         Check (Texts (Found) = "PRIVMSG:first of the day|PRIVMSG:next day",
                "search is case-insensitive: " & Texts (Found));
         Found := Store.Search
           (Net, (Limit => 1, In_Target => To_Unbounded_String ("#c"),
                  Text => To_Unbounded_String ("day"), others => <>));
         Check (Texts (Found) = "PRIVMSG:next day",
                "the newest match when the limit cuts");
         Found := Store.Search
           (Net, (Limit => 10, In_Target => To_Unbounded_String ("#c"),
                  From => To_Unbounded_String ("carol"), others => <>));
         Check (Texts (Found) = "PRIVMSG:second", "by sender");
         Found := Store.Search
           (Net, (Limit => 10, In_Target => To_Unbounded_String ("#c"),
                  Start => Day1 + 30.0, End_Time => Day2 + 30.0,
                  others => <>));
         Check (Texts (Found) = "PRIVMSG:second|PRIVMSG:next day",
                "between times");
         Found := Store.Search
           (Net, (Limit => 10, In_Target => To_Unbounded_String ("#c"),
                  Text => To_Unbounded_String ("Zzz"), others => <>));
         Check (Found.Is_Empty, "no match");
      end;

      ---------------------------------------------------------------
      --  Targets (by the time the files were last written)
      ---------------------------------------------------------------
      declare
         Ignored : constant String := Store.Append
           (Net, "bob", Tagged_Line (":bob!u@h PRIVMSG alice :psst", Day1));
         Ignored2 : constant String := Store.Append
           (Net, "#empty", Tagged_Line (":bob!u@h PRIVMSG #empty :x", Day1));
         pragma Unreferenced (Ignored, Ignored2);
         Now : constant Ada.Calendar.Time := Ada.Calendar.Clock;
         T   : Target_Vectors.Vector;
      begin
         T := Store.List_Targets (Net, Now - 3600.0, Now + 3600.0, 10, False);
         Check (T.Length = 3, "three targets:" & T.Length'Image);
         Check (Texts (Store.Load_Before_Time (Day2 + 3600.0, Zero_Time, Opts)) /= "",
                "(still readable)");
         T := Store.List_Targets (Net, Now - 3600.0, Now + 3600.0, 2, False);
         Check (T.Length = 2, "the limit");
         T := Store.List_Targets (Net, Now + 3600.0, Now - 3600.0, 10, False);
         Check (T.Length = 3, "the other direction");
         T := Store.List_Targets (Net, Now + 100.0, Now + 7200.0, 10, False);
         Check (T.Is_Empty, "nothing in a later window");
         declare
            Other : Network := New_Network ("irc+insecure://y");
         begin
            Other.Name := To_Unbounded_String ("nonet");
            Check (Store.List_Targets
                     (Other, Now - 3600.0, Now + 3600.0, 10, False).Is_Empty,
                   "a network without logs");
         end;
      end;

      ---------------------------------------------------------------
      --  Many entities: open files are recycled, nothing is lost
      ---------------------------------------------------------------
      for I in 1 .. 30 loop
         declare
            Name : constant String :=
              "#room" & Ada.Strings.Fixed.Trim (Integer'Image (I), Ada.Strings.Left);
            Ignored : constant String := Store.Append
              (Net, Name, Tagged_Line
                 (":bob!u@h PRIVMSG " & Name & " :hello", Day1 + Duration (I)));
            pragma Unreferenced (Ignored);
         begin
            null;
         end;
      end loop;
      Check (Store.Append (Net, "#room1", Tagged_Line
               (":bob!u@h PRIVMSG #room1 :again", Day1 + 500.0)) /= "",
             "writing to an entity whose file was closed");
      declare
         O : constant Load_Message_Options :=
           (Network => Net, Entity => To_Unbounded_String ("#room1"),
            Limit => 10, Events => False);
      begin
         Check (Texts (Store.Load_Latest_ID ("", O)) = "PRIVMSG:hello|PRIVMSG:again",
                "both messages of a recycled file: "
                & Texts (Store.Load_Latest_ID ("", O)));
      end;

      ---------------------------------------------------------------
      --  Renaming a network moves its history
      ---------------------------------------------------------------
      declare
         Renamed : Network := Net;
         Taken   : Network := Net;
      begin
         Renamed.Name := To_Unbounded_String ("freenode");
         Taken.Name := To_Unbounded_String ("oftc");
         Ada.Directories.Create_Path (Root & "/alice/oftc");
         begin
            Store.Rename_Network (Net, Taken);
            Check (False, "renaming onto an existing network");
         exception
            when Store_Error => null;
         end;
         Check (Ada.Directories.Exists (Root & "/alice/libera/#c"),
                "nothing moved on that error");
         Store.Rename_Network (Net, Renamed);
         Check (not Ada.Directories.Exists (Root & "/alice/libera")
                and then Ada.Directories.Exists
                           (Root & "/alice/freenode/#c/" & Date_Name (Day1)
                            & ".log"),
                "the directory moved");
      end;
   end;
   Ada.Text_IO.Put_Line ("ALL PASS");
exception
   when E : others =>
      Ada.Text_IO.Put_Line
        ("FAILED: " & Ada.Exceptions.Exception_Information (E));
      GNAT.OS_Lib.OS_Exit (1);
end Fsstore_Check;
