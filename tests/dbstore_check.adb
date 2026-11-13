pragma Ada_2022;

with Ada.Calendar;
with Ada.Containers;
with Ada.Exceptions;
with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;
with Ada.Text_IO;
with GNAT.OS_Lib;

with Soja.Database;        use Soja.Database;
with Soja.Database.Sqlite;
with Soja.Irc.Messages;    use Soja.Irc.Messages;
with Soja.Irc.Xirc;
with Soja.Msgstore;        use Soja.Msgstore;
with Soja.Msgstore.Db;
with Soja.Msgstore.Memory;

--  The database message store (msgstore/db.go): message IDs, history, search.
procedure Dbstore_Check is
   use type Ada.Containers.Count_Type;
   use type Ada.Calendar.Time;

   procedure Check (Cond : Boolean; What : String) is
   begin
      if not Cond then
         raise Program_Error with What;
      end if;
   end Check;

   DB    : Database_Access := Soja.Database.Sqlite.Open_Temp_Sqlite_DB;
   Usr   : User := New_User ("alice");
   Net   : Network := New_Network ("irc+insecure://x");
   Store : constant Store_Access := Soja.Msgstore.Db.New_Db_Store (DB);

   Base : constant Ada.Calendar.Time :=
     Ada.Calendar.Time_Of (2026, 6, 1, 12.0 * 3600.0);
   function At_Time (S : Duration) return Ada.Calendar.Time is
     (Ada.Calendar."+" (Base, S));

   function Msg (Cmd, Who, Target, Text : String; S : Duration) return Message
   is (Parse_Message
         ("@time=" & Soja.Irc.Xirc.Format_Server_Time (At_Time (S))
          & " :" & Who & "!u@h " & Cmd & " " & Target
          & (if Text = "" then "" else " :" & Text)));

   function Texts (V : Message_Vector) return String is
      R : Unbounded_String;
   begin
      for M of V loop
         if Length (R) > 0 then
            Append (R, "|");
         end if;
         Append (R, M.Params (Natural (M.Params.Length)));
      end loop;
      return To_String (R);
   end Texts;

   function Names (V : Target_Vectors.Vector) return String is
      R : Unbounded_String;
   begin
      for T of V loop
         if Length (R) > 0 then
            Append (R, ",");
         end if;
         Append (R, T.Name);
      end loop;
      return To_String (R);
   end Names;

   Opts : Load_Message_Options;
   First, Mid, Last : Unbounded_String;
begin
   Store_User (DB.all, Usr);
   Store_Network (DB.all, Usr.ID, Net);
   Opts := (Network => Net, Entity => To_Unbounded_String ("#c"),
            Limit => 100, Events => False);

   Check (Store.Supports_Chat_History and then Store.Supports_Search,
          "capabilities");

   --  An ID for the empty history is valid in history queries.
   declare
      Empty_ID : constant String := Store.Last_Msg_ID (Net, "#c", Base);
   begin
      Check (Empty_ID /= "", "an ID even when there are no messages");
      Check (Store.Load_Latest_ID (Empty_ID, Opts).Is_Empty, "nothing after it");
   end;

   First := To_Unbounded_String
     (Store.Append (Net, "#c", Msg ("PRIVMSG", "bob", "#c", "one", 10.0)));
   Mid := To_Unbounded_String
     (Store.Append (Net, "#c", Msg ("PRIVMSG", "bob", "#c", "two", 20.0)));
   Last := To_Unbounded_String
     (Store.Append (Net, "#c", Msg ("PRIVMSG", "bob", "#c", "three", 30.0)));
   Check (First /= Mid and then Mid /= Last, "distinct IDs");
   Check (Store.Last_Msg_ID (Net, "#c", Base) = To_String (Last),
          "LastMsgID is the newest message's ID");
   Check (Store.Last_Msg_ID (Net, "#d", Base) /= To_String (Last),
          "another target");

   --  LoadLatestID: what came after an ID, up to the limit (the newest ones).
   Check (Texts (Store.Load_Latest_ID (To_String (First), Opts)) = "two|three",
          "after the first");
   Check (Texts (Store.Load_Latest_ID (To_String (Mid), Opts)) = "three",
          "after the second");
   Check (Store.Load_Latest_ID (To_String (Last), Opts).Is_Empty, "after last");
   Opts.Limit := 1;
   Check (Texts (Store.Load_Latest_ID (To_String (First), Opts)) = "three",
          "the newest one when the limit cuts");
   Opts.Limit := 100;

   --  IDs of other stores are refused.
   declare
      Mem : constant Store_Access := Soja.Msgstore.Memory.New_Memory_Store;
      Foreign : constant String := Mem.Append
        (Net, "#c", Msg ("PRIVMSG", "bob", "#c", "m", 1.0));
   begin
      begin
         Check (Store.Load_Latest_ID (Foreign, Opts).Is_Empty, "x");
         Check (False, "a memory-store ID was accepted");
      exception
         when Store_Error => null;
      end;
      begin
         Check (Store.Load_Latest_ID ("!!not base64!!", Opts).Is_Empty, "x");
         Check (False, "garbage was accepted as an ID");
      exception
         when Store_Error => null;
      end;
   end;

   --  History by time.
   declare
      Ignored : constant String := Store.Append
        (Net, "#c", Msg ("JOIN", "carol", "#c", "", 25.0));
      pragma Unreferenced (Ignored);
   begin
      Check (Texts (Store.Load_Before_Time (At_Time (30.0), Null_Time, Opts))
             = "one|two", "before 30 s");
      Check (Texts (Store.Load_Before_Time (At_Time (100.0), At_Time (10.0), Opts))
             = "two|three", "before, with a lower bound (excluded)");
      Opts.Limit := 1;
      Check (Texts (Store.Load_Before_Time (At_Time (100.0), Null_Time, Opts))
             = "three", "the newest before a time, within the limit");
      Opts.Limit := 100;
      Check (Texts (Store.Load_After_Time (At_Time (10.0), At_Time (100.0), Opts))
             = "two|three", "after 10 s");
      Check (Texts (Store.Load_After_Time (At_Time (10.0), At_Time (30.0), Opts))
             = "two", "after, with an upper bound (excluded)");
      Opts.Limit := 1;
      Check (Texts (Store.Load_After_Time (At_Time (0.0), At_Time (100.0), Opts))
             = "one", "the oldest after a time, within the limit");
      Opts.Limit := 100;
      Opts.Events := True;
      Check (Texts (Store.Load_After_Time (At_Time (10.0), At_Time (100.0), Opts))
             = "two|#c|three", "with events");
      Opts.Events := False;
   end;

   --  Targets.
   declare
      Ignored1 : constant String := Store.Append
        (Net, "bob", Msg ("PRIVMSG", "bob", "alice", "psst", 5.0));
      Ignored2 : constant String := Store.Append
        (Net, "#d", Msg ("PRIVMSG", "bob", "#d", "late", 50.0));
      pragma Unreferenced (Ignored1, Ignored2);
   begin
      Check (Names (Store.List_Targets (Net, At_Time (0.0), At_Time (100.0), 10, False))
             = "bob,#c,#d", "targets, oldest first when end is after start");
      Check (Names (Store.List_Targets (Net, At_Time (100.0), At_Time (0.0), 10, False))
             = "bob,#c,#d", "and still oldest first when end is before start");
      Check (Names (Store.List_Targets (Net, At_Time (100.0), At_Time (0.0), 2, False))
             = "#c,#d", "the newest two, when the limit cuts the other way");
      Check (Names (Store.List_Targets (Net, At_Time (0.0), At_Time (100.0), 2, False))
             = "bob,#c", "the oldest two");
      Check (Names (Store.List_Targets (Net, At_Time (10.0), At_Time (45.0), 10, False))
             = "#c", "bounds are excluded: " &
             Names (Store.List_Targets (Net, At_Time (10.0), At_Time (45.0), 10, False)));
   end;

   --  Search.
   declare
      Ignored : constant String := Store.Append
        (Net, "#c", Msg ("PRIVMSG", "dora", "#c", "the three musketeers", 40.0));
      pragma Unreferenced (Ignored);
      Found : Message_Vector;
   begin
      Found := Store.Search
        (Net, (Limit => 10, In_Target => To_Unbounded_String ("#c"),
               Text => To_Unbounded_String ("three"), others => <>));
      Check (Texts (Found) = "three|the three musketeers", "search by text");
      Found := Store.Search
        (Net, (Limit => 1, In_Target => To_Unbounded_String ("#c"),
               Text => To_Unbounded_String ("three"), others => <>));
      Check (Texts (Found) = "the three musketeers",
             "the newest match when the limit cuts");
      Found := Store.Search
        (Net, (Limit => 10, In_Target => To_Unbounded_String ("#c"),
               From => To_Unbounded_String ("dora"), others => <>));
      Check (Texts (Found) = "the three musketeers", "search by sender");
      Found := Store.Search
        (Net, (Limit => 10, In_Target => To_Unbounded_String ("#c"),
               Start => At_Time (15.0), End_Time => At_Time (35.0),
               others => <>));
      Check (Texts (Found) = "two|three", "search between times");
   end;

   Store.Close;
   Ada.Text_IO.Put_Line ("ALL PASS");
exception
   when E : others =>
      Ada.Text_IO.Put_Line
        ("FAILED: " & Ada.Exceptions.Exception_Information (E));
      GNAT.OS_Lib.OS_Exit (1);
end Dbstore_Check;
