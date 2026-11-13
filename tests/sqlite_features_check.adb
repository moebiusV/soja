pragma Ada_2022;

with Ada.Exceptions;
with Ada.Text_IO;
with GNAT.OS_Lib;

with GNATCOLL.SQL.Exec;    use GNATCOLL.SQL.Exec;
with GNATCOLL.SQL.Sqlite;

--  The SQLite under gnatcoll-sqlite has what soju's SQL needs and what
--  Alpine's own SQLite has: a guard against gnatcoll-db going back to its
--  bundled 2017 amalgamation (3.21.0: no FTS5, no upsert, no RETURNING...).
procedure Sqlite_Features_Check is
   Desc : constant Database_Description :=
     GNATCOLL.SQL.Sqlite.Setup (":memory:");
   DB   : constant Database_Connection := Build_Connection (Desc);

   procedure Check (Cond : Boolean; What : String) is
   begin
      if not Cond then
         raise Program_Error with What;
      end if;
   end Check;

   --  Run one statement; it must work.
   procedure Run (SQL : String) is
   begin
      Execute (DB, SQL);
      if not Success (DB) then
         raise Program_Error with "failed: " & SQL & " (" & Error (DB) & ")";
      end if;
   end Run;

   --  The first column of the first row of a query ("" when none).
   function One (SQL : String) return String is
      C : Forward_Cursor;
   begin
      Fetch (C, DB, SQL);
      if not Success (DB) then
         raise Program_Error with "failed: " & SQL & " (" & Error (DB) & ")";
      end if;
      return (if Has_Row (C) then Value (C, 0) else "");
   end One;

   procedure Expect (SQL, Want : String) is
      Got : constant String := One (SQL);
   begin
      Check (Got = Want, SQL & " gave [" & Got & "], wanted [" & Want & "]");
   end Expect;

   --  The feature options of Alpine's libsqlite3 (PRAGMA compile_options),
   --  not its limits and defaults.
   type Name_Access is access constant String;
   Options : constant array (Positive range <>) of Name_Access :=
     [new String'("ENABLE_FTS3"), new String'("ENABLE_FTS3_PARENTHESIS"),
      new String'("ENABLE_FTS4"), new String'("ENABLE_FTS5"),
      new String'("ENABLE_GEOPOLY"), new String'("ENABLE_RTREE"),
      new String'("ENABLE_MATH_FUNCTIONS"), new String'("ENABLE_PERCENTILE"),
      new String'("ENABLE_SESSION"), new String'("ENABLE_PREUPDATE_HOOK"),
      new String'("ENABLE_COLUMN_METADATA"),
      new String'("ENABLE_UNLOCK_NOTIFY"), new String'("ENABLE_DBSTAT_VTAB"),
      new String'("SOUNDEX"), new String'("SECURE_DELETE"),
      new String'("USE_URI"), new String'("THREADSAFE=1")];
begin
   Check (DB /= null, "a connection");

   --  A modern SQLite: Alpine's is 3.5x; the bundled one was 3.21.0.
   Expect ("SELECT sqlite_version() >= '3.40.0'", "1");

   for O of Options loop
      Expect ("SELECT sqlite_compileoption_used('" & O.all & "')", "1");
   end loop;

   --  soju's message store: FTS5 over the Message table, kept in step by
   --  triggers, searched with MATCH (MessageFTS in database/sqlite.go).
   Run ("CREATE TABLE Message (id INTEGER PRIMARY KEY, text TEXT)");
   Run ("CREATE VIRTUAL TABLE MessageFTS USING fts5 "
        & "(text, content='Message', content_rowid='id')");
   Run ("CREATE TRIGGER MessageFTS_ai AFTER INSERT ON Message BEGIN "
        & "INSERT INTO MessageFTS(rowid, text) VALUES (new.id, new.text); END");
   Run ("INSERT INTO Message(text) VALUES ('hello brave new world')");
   Run ("INSERT INTO Message(text) VALUES ('goodbye cruel world')");
   Expect ("SELECT id FROM Message WHERE id IN "
           & "(SELECT ROWID FROM MessageFTS WHERE MessageFTS MATCH 'brave')",
           "1");
   Expect ("SELECT count(*) FROM MessageFTS WHERE MessageFTS MATCH 'world'",
           "2");

   --  StoreMessages: INSERT ... ON CONFLICT DO NOTHING (SQLite 3.24).
   Run ("CREATE TABLE MessageTarget (id INTEGER PRIMARY KEY, network INTEGER, "
        & "target TEXT, UNIQUE (network, target))");
   Run ("INSERT INTO MessageTarget(network, target) VALUES (1, '#a') "
        & "ON CONFLICT DO NOTHING");
   Run ("INSERT INTO MessageTarget(network, target) VALUES (1, '#a') "
        & "ON CONFLICT DO NOTHING");
   Expect ("SELECT count(*) FROM MessageTarget", "1");
   Run ("INSERT INTO MessageTarget(network, target) VALUES (1, '#a') "
        & "ON CONFLICT (network, target) DO UPDATE SET target = '#A'");
   Expect ("SELECT target FROM MessageTarget", "#A");

   --  What later migrations and queries are likely to want.
   Expect ("SELECT row_number() OVER (ORDER BY id DESC) FROM Message LIMIT 1",
           "1");                                                --  3.25
   Run ("ALTER TABLE Message RENAME COLUMN text TO body");        --  3.25
   Run ("ALTER TABLE MessageTarget ADD COLUMN extra TEXT");
   Run ("ALTER TABLE MessageTarget DROP COLUMN extra");           --  3.35
   Expect ("INSERT INTO MessageTarget(network, target) VALUES (2, '#b') "
           & "RETURNING target", "#b");                           --  3.35
   Expect ("SELECT json_extract('{""a"": [1, 2, 3]}', '$.a[1]')", "2");
   Expect ("SELECT sqrt(16)", "4.0");
   Expect ("SELECT unixepoch('1970-01-02')", "86400");            --  3.38
   Expect ("SELECT iif(1 < 2, 'yes', 'no')", "yes");              --  3.32

   --  Foreign keys can be enforced.
   Run ("PRAGMA foreign_keys = ON");
   Expect ("PRAGMA foreign_keys", "1");

   Ada.Text_IO.Put_Line ("ALL PASS");
exception
   when E : others =>
      Ada.Text_IO.Put_Line
        ("FAILED: " & Ada.Exceptions.Exception_Information (E));
      GNAT.OS_Lib.OS_Exit (1);
end Sqlite_Features_Check;
