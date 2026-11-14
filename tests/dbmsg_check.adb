pragma Ada_2022;

with Ada.Calendar;
with Ada.Containers;
with Ada.Exceptions;
with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;
with Ada.Text_IO;
with GNAT.OS_Lib;

with GNATCOLL.SQL.Exec;    use GNATCOLL.SQL.Exec;
with GNATCOLL.SQL.Sqlite;

with Soja.Database;        use Soja.Database;
with Soja.Database.Sqlite;
with Soja.Irc.Messages;    use Soja.Irc.Messages;
with Soja.Irc.Xirc;

--  The message store's database methods: store, list, last per target, FTS.
procedure Dbmsg_Check is
   use type Ada.Containers.Count_Type;
   use type Ada.Calendar.Time;

   procedure Check (Cond : Boolean; What : String) is
   begin
      if not Cond then
         raise Program_Error with What;
      end if;
   end Check;

   DB  : Database_Access := Soja.Database.Sqlite.Open_Temp_Sqlite_DB;
   Usr : User := New_User ("alice");
   Net : Network := New_Network ("irc+insecure://x");
   Net2 : Network := New_Network ("irc+insecure://y");

   Base : constant Ada.Calendar.Time := Ada.Calendar.Time_Of (2026, 6, 1, 12.0 * 3600.0);

   function At_Time (Seconds : Duration) return Ada.Calendar.Time is
     (Ada.Calendar."+" (Base, Seconds));

   --  A PRIVMSG/NOTICE/JOIN line with a time tag.
   function Line
     (Cmd, Who, Target, Text : String; Seconds : Duration) return Message
   is
      Raw : constant String :=
        "@time=" & Soja.Irc.Xirc.Format_Server_Time (At_Time (Seconds))
        & " :" & Who & "!u@h " & Cmd & " " & Target
        & (if Text = "" then "" else " :" & Text);
   begin
      return Parse_Message (Raw);
   end Line;

   function One (M : Message) return Soja.Irc.Messages.Message_Vectors.Vector is
      V : Soja.Irc.Messages.Message_Vectors.Vector;
   begin
      V.Append (M);
      return V;
   end One;

   function Texts (V : Soja.Irc.Messages.Message_Vectors.Vector) return String is
      R : Unbounded_String;
   begin
      for M of V loop
         if Length (R) > 0 then
            Append (R, "|");
         end if;
         Append (R, (if M.Params.Is_Empty then To_String (M.Command)
                     else To_String (M.Params (Natural (M.Params.Length)))));
      end loop;
      return To_String (R);
   end Texts;

   function List
     (Opts : Message_Options; Target : String := "#chan")
      return String is
     (Texts (List_Messages (DB.all, Net.ID, Target, Opts)));

   Ids : Id_Lists.Vector;
   Opts : Message_Options;
begin
   Store_User (DB.all, Usr);
   Store_Network (DB.all, Usr.ID, Net);
   Store_Network (DB.all, Usr.ID, Net2);

   Check (Get_Message_Last_ID (DB.all, Net.ID, "#chan") = 0, "no messages yet");
   Check (Store_Messages (DB.all, Net.ID, "#chan",
                          Soja.Irc.Messages.Message_Vectors.Empty_Vector).Is_Empty,
          "storing nothing");

   ------------------------------------------------------------------
   --  Store and read back
   ------------------------------------------------------------------
   declare
      V : Soja.Irc.Messages.Message_Vectors.Vector;
   begin
      V.Append (Line ("PRIVMSG", "bob", "#chan", "hello brave new world", 10.0));
      V.Append (Line ("JOIN", "carol", "#chan", "", 20.0));
      V.Append (Line ("PRIVMSG", "carol", "#chan", "second line here", 30.0));
      V.Append (Line ("NOTICE", "bob", "#chan", "a notice, with punctuation!", 40.0));
      V.Append (Line ("PRIVMSG", "bob", "#chan", "the last one", 50.0));
      Ids := Store_Messages (DB.all, Net.ID, "#chan", V);
   end;
   Check (Ids.Length = 5 and then Ids (1) < Ids (2) and then Ids (4) < Ids (5),
          "five increasing IDs");
   Check (Get_Message_Last_ID (DB.all, Net.ID, "#chan") = Ids (5),
          "the last message is the newest by time");
   Check (Get_Message_Last_ID (DB.all, Net.ID, "#other") = 0,
          "another target has none");
   Check (Get_Message_Last_ID (DB.all, Net2.ID, "#chan") = 0,
          "another network has none");

   Opts := (Limit => 100, others => <>);
   Check (List (Opts) = "hello brave new world|second line here|"
                        & "a notice, with punctuation!|the last one",
          "messages only, oldest first: " & List (Opts));
   Opts.Events := True;
   Check (List (Opts) = "hello brave new world|#chan|second line here|"
                        & "a notice, with punctuation!|the last one",
          "with events: " & List (Opts));

   ------------------------------------------------------------------
   --  Limits, order, bounds
   ------------------------------------------------------------------
   Opts := (Limit => 2, others => <>);
   Check (List (Opts) = "hello brave new world|second line here",
          "the first two");
   Opts.Take_Last := True;
   Check (List (Opts) = "a notice, with punctuation!|the last one",
          "the last two, still oldest first: " & List (Opts));
   Opts := (Limit => 100, After_ID => Ids (3), others => <>);
   Check (List (Opts) = "a notice, with punctuation!|the last one",
          "after an ID");
   Opts := (Limit => 100, After_Time => At_Time (10.0),
            Before_Time => At_Time (50.0), others => <>);
   Check (List (Opts) = "second line here|a notice, with punctuation!",
          "bounds are exclusive: " & List (Opts));
   Opts := (Limit => 100, Sender => To_Unbounded_String ("bob"), others => <>);
   Check (List (Opts) = "hello brave new world|a notice, with punctuation!|"
                        & "the last one", "by sender");
   Opts := (Limit => 0, others => <>);
   Check (List (Opts) = "", "a limit of 0");

   ------------------------------------------------------------------
   --  Full-text search (FTS5)
   ------------------------------------------------------------------
   Opts := (Limit => 100, Text => To_Unbounded_String ("brave"), others => <>);
   Check (List (Opts) = "hello brave new world", "one word");
   Opts.Text := To_Unbounded_String ("world hello");
   Check (List (Opts) = "hello brave new world", "two words, any order");
   Opts.Text := To_Unbounded_String ("last");
   Check (List (Opts) = "the last one", "another word");
   Opts.Text := To_Unbounded_String ("NOTICE punctuation");
   Check (List (Opts) = "a notice, with punctuation!", "punctuation separates");
   Opts.Text := To_Unbounded_String ("nonexistent");
   Check (List (Opts) = "", "no match");
   --  FTS5 operators and quotes are plain text, not syntax.
   Opts.Text := To_Unbounded_String ("hello AND (world OR ""zzz"" NOT");
   Check (List (Opts) = "", "operators are not interpreted");
   Opts.Text := To_Unbounded_String ("hello OR last");
   Check (List (Opts) = "", "OR is a word: nothing has hello, or and last");
   Opts.Text := To_Unbounded_String ("!!! ???");
   Check (List (Opts) = "", "text without any word matches nothing");
   Opts.Text := To_Unbounded_String ("world");
   Opts.Sender := To_Unbounded_String ("bob");
   Check (List (Opts) = "hello brave new world", "text and sender together");
   Opts.Sender := To_Unbounded_String ("carol");
   Check (List (Opts) = "", "text and the wrong sender");
   Opts := (Limit => 100, Text => To_Unbounded_String ("höhe"), others => <>);
   declare
      V : Soja.Irc.Messages.Message_Vectors.Vector :=
        One (Line ("PRIVMSG", "dora", "#chan", "die Höhe ist 42", 60.0));
      Ignored : constant Id_Lists.Vector :=
        Store_Messages (DB.all, Net.ID, "#chan", V);
      pragma Unreferenced (Ignored);
   begin
      Check (List (Opts) = "die Höhe ist 42", "non-ASCII letters: " & List (Opts));
      Opts.Text := To_Unbounded_String ("42");
      Check (List (Opts) = "die Höhe ist 42", "digits");
   end;

   ------------------------------------------------------------------
   --  Last message per target
   ------------------------------------------------------------------
   declare
      Ignored : constant Id_Lists.Vector := Store_Messages
        (DB.all, Net.ID, "bob",
         One (Line ("PRIVMSG", "bob", "alice", "psst", 5.0)));
      Ignored2 : constant Id_Lists.Vector := Store_Messages
        (DB.all, Net.ID, "#quiet",
         One (Line ("JOIN", "alice", "#quiet", "", 70.0)));
      pragma Unreferenced (Ignored, Ignored2);
      T : Message_Target_Lists.Vector;
   begin
      Opts := (Limit => 10, others => <>);
      T := List_Message_Last_Per_Target (DB.all, Net.ID, Opts);
      Check (T.Length = 2, "targets, without events:" & T.Length'Image);
      Check (To_String (T (1).Name) = "bob" and then To_String (T (2).Name) = "#chan"
             and then T (2).Latest_Message = At_Time (60.0),
             "oldest first, by latest message; a target with only events "
             & "(#quiet) has nothing to report and is left out");
      Opts.Events := True;
      T := List_Message_Last_Per_Target (DB.all, Net.ID, Opts);
      Check (T.Length = 3 and then To_String (T (3).Name) = "#quiet"
             and then T (3).Latest_Message = At_Time (70.0), "with events");
      Opts := (Limit => 1, Take_Last => True, others => <>);
      T := List_Message_Last_Per_Target (DB.all, Net.ID, Opts);
      Check (T.Length = 1 and then To_String (T (1).Name) = "#chan",
             "the newest target only");
      Opts := (Limit => 10, After_Time => At_Time (5.0),
               Before_Time => At_Time (70.0), others => <>);
      T := List_Message_Last_Per_Target (DB.all, Net.ID, Opts);
      Check (T.Length = 1 and then To_String (T (1).Name) = "#chan",
             "target bounds exclude the ends");
      Check (List_Message_Last_Per_Target (DB.all, Net2.ID, Opts).Is_Empty,
             "another network");
   end;

   ------------------------------------------------------------------
   --  A time tag that is not a time is an error; nothing is stored.
   ------------------------------------------------------------------
   begin
      declare
         Bad : Soja.Irc.Messages.Message_Vectors.Vector;
      begin
         Bad.Append (Line ("PRIVMSG", "x", "#bad", "fine", 1.0));
         Bad.Append (Parse_Message ("@time=garbage :x!u@h PRIVMSG #bad :oops"));
         declare
            Ignored : constant Id_Lists.Vector :=
              Store_Messages (DB.all, Net.ID, "#bad", Bad);
            pragma Unreferenced (Ignored);
         begin
            Check (False, "a bad time tag was accepted");
         end;
      end;
   exception
      when Database_Error => null;
   end;
   Check (Get_Message_Last_ID (DB.all, Net.ID, "#bad") = 0,
          "a failed batch stores none of its messages");

   ------------------------------------------------------------------
   --  Expiry (message-expiry): older messages are deleted, newer stay.
   ------------------------------------------------------------------
   declare
      V : Soja.Irc.Messages.Message_Vectors.Vector;
      Ignored : Id_Lists.Vector;
      pragma Unreferenced (Ignored);
   begin
      V.Append (Line ("PRIVMSG", "bob", "#expiry", "very old", 0.1));
      V.Append (Line ("PRIVMSG", "bob", "#expiry", "old", 0.2));
      V.Append (Line ("PRIVMSG", "bob", "#expiry", "recent", 0.9));
      Ignored := Store_Messages (DB.all, Net.ID, "#expiry", V);
      Opts := (Limit => 100, others => <>);
      Check (List (Opts, "#expiry")'Length > 0, "stored");
      Delete_Messages_Before (DB.all, At_Time (0.5));
      Check (List (Opts, "#expiry") = "recent",
             "the messages before the cutoff are deleted: "
             & List (Opts, "#expiry"));
      Check (Get_Message_Last_ID (DB.all, Net.ID, "#chan") /= 0,
             "later messages of other targets are kept");
   end;

   ------------------------------------------------------------------
   --  Deleting messages keeps the index in step (the FTS triggers).
   ------------------------------------------------------------------
   Delete_Network (DB.all, Net.ID);
   Opts := (Limit => 100, Text => To_Unbounded_String ("brave"), others => <>);
   Check (List (Opts) = "", "deleted with its network");

   Close (DB.all);

   ------------------------------------------------------------------
   --  A database made before FTS5 was available gets the index on open,
   --  with the existing messages in it.
   ------------------------------------------------------------------
   declare
      Path : constant String := "/tmp/soja-dbmsg-check.db";
      Ok   : Boolean;

      procedure Raw (SQL : String) is
         D : constant Database_Description := GNATCOLL.SQL.Sqlite.Setup (Path);
         C : Database_Connection := Build_Connection (D);
      begin
         Execute (C, SQL);
         Commit_Or_Rollback (C);
         Check (Success (C), SQL & ": " & Error (C));
         GNATCOLL.SQL.Exec.Free (C);
      end Raw;

      DB2 : Database_Access;
      U2  : User := New_User ("zed");
      N2  : Network := New_Network ("irc+insecure://z");
   begin
      GNAT.OS_Lib.Delete_File (Path, Ok);
      DB2 := Soja.Database.Sqlite.Open_Sqlite_DB (Path);
      Store_User (DB2.all, U2);
      Store_Network (DB2.all, U2.ID, N2);
      declare
         Ignored : constant Id_Lists.Vector := Store_Messages
           (DB2.all, N2.ID, "#old",
            One (Line ("PRIVMSG", "bob", "#old", "kept from before", 1.0)));
         pragma Unreferenced (Ignored);
      begin
         null;
      end;
      Close (DB2.all);

      --  Make it look like a database from before: no index, no triggers.
      Raw ("DROP TRIGGER MessageFTSInsert");
      Raw ("DROP TRIGGER MessageFTSDelete");
      Raw ("DROP TRIGGER MessageFTSUpdate");
      Raw ("DROP TABLE MessageFTS");

      DB2 := Soja.Database.Sqlite.Open_Sqlite_DB (Path);
      Check (Texts (List_Messages
                      (DB2.all, N2.ID, "#old",
                       (Limit => 10, Text => To_Unbounded_String ("before"),
                        others => <>))) = "kept from before",
             "the index was rebuilt when the database was opened");
      declare
         Ignored : constant Id_Lists.Vector := Store_Messages
           (DB2.all, N2.ID, "#old",
            One (Line ("PRIVMSG", "bob", "#old", "added afterwards", 2.0)));
         pragma Unreferenced (Ignored);
      begin
         Check (Texts (List_Messages
                         (DB2.all, N2.ID, "#old",
                          (Limit => 10, Text => To_Unbounded_String ("afterwards"),
                           others => <>))) = "added afterwards",
                "and kept up to date by the triggers");
      end;
      Close (DB2.all);
      GNAT.OS_Lib.Delete_File (Path, Ok);
   end;
   Ada.Text_IO.Put_Line ("ALL PASS");
exception
   when E : others =>
      Ada.Text_IO.Put_Line
        ("FAILED: " & Ada.Exceptions.Exception_Information (E));
      GNAT.OS_Lib.OS_Exit (1);
end Dbmsg_Check;
