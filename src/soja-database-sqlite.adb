pragma Ada_2022;

with Ada.Calendar;
with Ada.Calendar.Formatting;
with Ada.Strings;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;
with Ada.Unchecked_Deallocation;

with Ada.Strings.UTF_Encoding.Wide_Wide_Strings;
with Ada.Wide_Wide_Characters.Handling;

with GNATCOLL.SQL.Sqlite;

with Soja.Irc.Helpers;
with Soja.Irc.Messages;

package body Soja.Database.Sqlite is

   use GNATCOLL.SQL.Exec;
   use type Ada.Calendar.Time;

   -----------
   -- Mutex --
   -----------

   protected body Mutex is

      entry Seize when not Locked is
      begin
         Locked := True;
      end Seize;

      procedure Release is
      begin
         Locked := False;
      end Release;

   end Mutex;

   -----------
   -- Guard --
   -----------

   procedure Finalize (G : in out Guard) is
   begin
      if G.M /= null then
         G.M.Release;
         G.M := null;
      end if;
   end Finalize;

   procedure Acquire (G : in out Guard; M : Mutex_Access) is
   begin
      M.Seize;
      G.M := M;
   end Acquire;

   --------------------------
   --  Schema + migrations --
   --------------------------

   --  The final schema (sqlite_schema.sql).  gnatcoll prepares a single
   --  statement per Execute (Go's driver runs the whole blob), so the schema
   --  and the multi-statement migrations are split into individual
   --  statements.  The on-disk result is identical.
   type Stmt_Array is array (Positive range <>) of Unbounded_String;

   Schema_Stmts : constant Stmt_Array :=
     [1  => To_Unbounded_String
       ("CREATE TABLE User (id INTEGER PRIMARY KEY, username TEXT NOT NULL " &
        "UNIQUE, password TEXT, admin INTEGER NOT NULL DEFAULT 0, realname " &
        "TEXT, nick TEXT, created_at TEXT NOT NULL, enabled INTEGER NOT " &
        "NULL " &
        "DEFAULT 1, downstream_interacted_at TEXT, max_networks INTEGER " &
        "NOT NULL DEFAULT -1)"),
      2  => To_Unbounded_String
       ("CREATE TABLE Network (id INTEGER PRIMARY KEY, name TEXT, user " &
        "INTEGER NOT NULL, addr TEXT NOT NULL, nick TEXT, username TEXT, " &
        "realname TEXT, certfp TEXT, pass TEXT, connect_commands TEXT, " &
        "sasl_mechanism TEXT, sasl_plain_username TEXT, sasl_plain_password " &
        "TEXT, sasl_external_cert BLOB, sasl_external_key BLOB, auto_away " &
        "INTEGER NOT NULL DEFAULT 1, enabled INTEGER NOT NULL DEFAULT 1, " &
        "FOREIGN KEY(user) REFERENCES User(id), UNIQUE(user, addr, nick), " &
        "UNIQUE(user, name))"),
      3  => To_Unbounded_String
       ("CREATE TABLE Channel (id INTEGER PRIMARY KEY, network INTEGER NOT " &
        "NULL, name TEXT NOT NULL, key TEXT, detached INTEGER NOT NULL " &
        "DEFAULT 0, detached_internal_msgid TEXT, relay_detached INTEGER " &
        "NOT " &
        "NULL DEFAULT 0, reattach_on INTEGER NOT NULL DEFAULT 0, " &
        "detach_after " &
        "INTEGER NOT NULL DEFAULT 0, detach_on INTEGER NOT NULL DEFAULT 0, " &
        "FOREIGN KEY(network) REFERENCES Network(id), UNIQUE(network, name))"),
      4  => To_Unbounded_String
       ("CREATE TABLE DeliveryReceipt (id INTEGER PRIMARY KEY, network " &
        "INTEGER NOT NULL, target TEXT NOT NULL, client TEXT, " &
        "internal_msgid " &
        "TEXT NOT NULL, FOREIGN KEY(network) REFERENCES Network(id), " &
        "UNIQUE(network, target, client))"),
      5  => To_Unbounded_String
       ("CREATE TABLE ReadReceipt (id INTEGER PRIMARY KEY, network INTEGER " &
        "NOT NULL, target TEXT NOT NULL, timestamp TEXT NOT NULL, FOREIGN " &
        "KEY(network) REFERENCES Network(id), UNIQUE(network, target))"),
      6  => To_Unbounded_String
       ("CREATE TABLE WebPushConfig (id INTEGER PRIMARY KEY, created_at " &
       "TEXT " &
        "NOT NULL, vapid_key_public TEXT NOT NULL, vapid_key_private TEXT " &
        "NOT NULL, UNIQUE(vapid_key_public))"),
      7  => To_Unbounded_String
       ("CREATE TABLE WebPushSubscription (id INTEGER PRIMARY KEY, " &
       "created_at " &
        "TEXT NOT NULL, updated_at TEXT NOT NULL, user INTEGER NOT NULL, " &
        "network INTEGER, endpoint TEXT NOT NULL, key_vapid TEXT, key_auth " &
        "TEXT, key_p256dh TEXT, FOREIGN KEY(user) REFERENCES User(id), " &
        "FOREIGN KEY(network) REFERENCES Network(id), UNIQUE(network, " &
        "endpoint))"),
      8  => To_Unbounded_String
       ("CREATE TABLE Message (id INTEGER PRIMARY KEY, target INTEGER NOT " &
        "NULL, raw TEXT NOT NULL, time TEXT NOT NULL, sender TEXT NOT NULL, " &
        "text TEXT, FOREIGN KEY(target) REFERENCES MessageTarget(id))"),
      9  => To_Unbounded_String
       ("CREATE INDEX MessageIndex ON Message(target, time)"),
      10 => To_Unbounded_String
       ("CREATE TABLE MessageTarget (id INTEGER PRIMARY KEY, network " &
       "INTEGER " &
        "NOT NULL, target TEXT NOT NULL, pinned INTEGER NOT NULL DEFAULT " &
        "0, muted INTEGER NOT NULL DEFAULT 0, blocked INTEGER NOT NULL " &
        "DEFAULT 0, FOREIGN KEY(network) REFERENCES " &
        "Network(id), UNIQUE(network, target))"),
      11 => To_Unbounded_String
       ("CREATE VIRTUAL TABLE MessageFTS USING fts5 (text, " &
        "content=Message, content_rowid=id)"),
      12 => To_Unbounded_String
       ("CREATE TRIGGER MessageFTSInsert AFTER INSERT ON Message " &
        "BEGIN INSERT INTO MessageFTS(rowid, text) VALUES (new.id, " &
        "new.text); END"),
      13 => To_Unbounded_String
       ("CREATE TRIGGER MessageFTSDelete AFTER DELETE ON Message " &
        "BEGIN INSERT INTO MessageFTS(MessageFTS, rowid, text) " &
        "VALUES ('delete', old.id, old.text); END"),
      14 => To_Unbounded_String
       ("CREATE TRIGGER MessageFTSUpdate AFTER UPDATE ON Message " &
        "BEGIN INSERT INTO MessageFTS(MessageFTS, rowid, text) " &
        "VALUES ('delete', old.id, old.text); INSERT INTO " &
        "MessageFTS(rowid, text) VALUES (new.id, new.text); END"),
      15 => To_Unbounded_String
       ("CREATE TABLE DeviceCertificate (id INTEGER PRIMARY KEY, user " &
        "INTEGER NOT NULL, label TEXT NOT NULL, fingerprint BLOB NOT NULL " &
        "UNIQUE, last_used TEXT NOT NULL, last_ip TEXT NOT NULL, FOREIGN " &
        "KEY(user) REFERENCES User(id))"),
      16 => To_Unbounded_String
       ("CREATE INDEX Network_user_index ON Network(user)"),
      17 => To_Unbounded_String
       ("CREATE INDEX Channel_network_index ON Channel(network)"),
      18 => To_Unbounded_String
       ("CREATE INDEX DeliveryReceipt_network_index ON " &
        "DeliveryReceipt(network)"),
      19 => To_Unbounded_String
       ("CREATE INDEX ReadReceipt_network_index ON ReadReceipt(network)"),
      20 => To_Unbounded_String
       ("CREATE INDEX WebPushSubscription_user_index ON " &
        "WebPushSubscription(user)"),
      21 => To_Unbounded_String
       ("CREATE INDEX WebPushSubscription_network_index ON " &
        "WebPushSubscription(network)"),
      22 => To_Unbounded_String
       ("CREATE INDEX Message_target_index ON Message(target)"),
      23 => To_Unbounded_String
       ("CREATE INDEX MessageTarget_network_index ON MessageTarget(network)")];

   --  MessageFTS and its triggers (the full-text index over Message.text,
   --  for `SEARCH`) are part of the schema and of the last migration; they
   --  need the FTS5 of the system SQLite (see PORTING.md).

   --  The migrations, flattened into individual statements.  Migration_Start
   --  (V) is the index into Migration_Stmts of migration V's first statement;
   --  Migration_Start (Migration_Count) is one past the last.
   Migration_Count : constant := 31;

   Migration_Stmts : constant Stmt_Array :=
     [1  => To_Unbounded_String
       ("ALTER TABLE Network ADD COLUMN connect_commands VARCHAR(1023)"),
      2  => To_Unbounded_String
       ("ALTER TABLE Channel ADD COLUMN detached INTEGER NOT NULL DEFAULT 0"),
      3  => To_Unbounded_String
       ("ALTER TABLE Network ADD COLUMN sasl_external_cert BLOB DEFAULT NULL"),
      4  => To_Unbounded_String
       ("ALTER TABLE Network ADD COLUMN sasl_external_key BLOB DEFAULT NULL"),
      5  => To_Unbounded_String
       ("ALTER TABLE User ADD COLUMN admin INTEGER NOT NULL DEFAULT 0"),
      6  => To_Unbounded_String
       ("CREATE TABLE UserNew (id INTEGER PRIMARY KEY, username " &
       "VARCHAR(255) " &
        "NOT NULL UNIQUE, password VARCHAR(255), admin INTEGER NOT NULL " &
        "DEFAULT 0)"),
      7  => To_Unbounded_String
       ("INSERT INTO UserNew SELECT rowid, username, password, admin FROM " &
       "User"),
      8  => To_Unbounded_String ("DROP TABLE User"),
      9  => To_Unbounded_String ("ALTER TABLE UserNew RENAME TO User"),
      10 => To_Unbounded_String
       ("CREATE TABLE NetworkNew (id INTEGER PRIMARY KEY, name " &
       "VARCHAR(255), " &
        "user INTEGER NOT NULL, addr VARCHAR(255) NOT NULL, nick " &
        "VARCHAR(255) " &
        "NOT NULL, username VARCHAR(255), realname VARCHAR(255), pass " &
        "VARCHAR(255), connect_commands VARCHAR(1023), sasl_mechanism " &
        "VARCHAR(255), sasl_plain_username VARCHAR(255), " &
        "sasl_plain_password " &
        "VARCHAR(255), sasl_external_cert BLOB DEFAULT NULL, " &
        "sasl_external_key " &
        "BLOB DEFAULT NULL, FOREIGN KEY(user) REFERENCES User(id), " &
        "UNIQUE(user, " &
        "addr, nick), UNIQUE(user, name))"),
      11 => To_Unbounded_String
       ("INSERT INTO NetworkNew SELECT Network.id, name, User.id as user, " &
        "addr, nick, Network.username, realname, pass, connect_commands, " &
        "sasl_mechanism, sasl_plain_username, sasl_plain_password, " &
        "sasl_external_cert, sasl_external_key FROM Network JOIN User ON " &
        "Network.user = User.username"),
      12 => To_Unbounded_String ("DROP TABLE Network"),
      13 => To_Unbounded_String ("ALTER TABLE NetworkNew RENAME TO Network"),
      14 => To_Unbounded_String
       ("ALTER TABLE Channel ADD COLUMN relay_detached INTEGER NOT NULL " &
        "DEFAULT 0"),
      15 => To_Unbounded_String
       ("ALTER TABLE Channel ADD COLUMN reattach_on INTEGER NOT NULL " &
       "DEFAULT 0"),
      16 => To_Unbounded_String
       ("ALTER TABLE Channel ADD COLUMN detach_after INTEGER NOT NULL " &
       "DEFAULT 0"),
      17 => To_Unbounded_String
       ("ALTER TABLE Channel ADD COLUMN detach_on INTEGER NOT NULL DEFAULT 0"),
      18 => To_Unbounded_String
       ("CREATE TABLE DeliveryReceipt (id INTEGER PRIMARY KEY, network " &
        "INTEGER NOT NULL, target VARCHAR(255) NOT NULL, client " &
        "VARCHAR(255), " &
        "internal_msgid VARCHAR(255) NOT NULL, FOREIGN KEY(network) " &
        "REFERENCES " &
        "Network(id), UNIQUE(network, target, client))"),
      19 => To_Unbounded_String
       ("ALTER TABLE Channel ADD COLUMN detached_internal_msgid VARCHAR(255)"),
      20 => To_Unbounded_String
       ("ALTER TABLE Network ADD COLUMN enabled INTEGER NOT NULL DEFAULT 1"),
      21 => To_Unbounded_String
       ("ALTER TABLE User ADD COLUMN realname VARCHAR(255)"),
      22 => To_Unbounded_String
       ("CREATE TABLE NetworkNew (id INTEGER PRIMARY KEY, name TEXT, user " &
        "INTEGER NOT NULL, addr TEXT NOT NULL, nick TEXT, username TEXT, " &
        "realname TEXT, pass TEXT, connect_commands TEXT, sasl_mechanism " &
        "TEXT, " &
        "sasl_plain_username TEXT, sasl_plain_password TEXT, " &
        "sasl_external_cert " &
        "BLOB, sasl_external_key BLOB, enabled INTEGER NOT NULL DEFAULT 1, " &
        "FOREIGN KEY(user) REFERENCES User(id), UNIQUE(user, addr, nick), " &
        "UNIQUE(user, name))"),
      23 => To_Unbounded_String
       ("INSERT INTO NetworkNew SELECT id, name, user, addr, nick, " &
       "username, " &
        "realname, pass, connect_commands, sasl_mechanism, " &
        "sasl_plain_username, " &
        "sasl_plain_password, sasl_external_cert, sasl_external_key, " &
        "enabled " &
        "FROM Network"),
      24 => To_Unbounded_String ("DROP TABLE Network"),
      25 => To_Unbounded_String ("ALTER TABLE NetworkNew RENAME TO Network"),
      26 => To_Unbounded_String
       ("CREATE TABLE ReadReceipt (id INTEGER PRIMARY KEY, network INTEGER " &
        "NOT NULL, target TEXT NOT NULL, timestamp TEXT NOT NULL, FOREIGN " &
        "KEY(network) REFERENCES Network(id), UNIQUE(network, target))"),
      27 => To_Unbounded_String
       ("CREATE TABLE WebPushConfig (id INTEGER PRIMARY KEY, created_at " &
       "TEXT " &
        "NOT NULL, vapid_key_public TEXT NOT NULL, vapid_key_private TEXT " &
        "NOT " &
        "NULL, UNIQUE(vapid_key_public))"),
      28 => To_Unbounded_String
       ("CREATE TABLE WebPushSubscription (id INTEGER PRIMARY KEY, " &
       "created_at " &
        "TEXT NOT NULL, updated_at TEXT NOT NULL, network INTEGER, endpoint " &
        "TEXT NOT NULL, key_vapid TEXT, key_auth TEXT, key_p256dh TEXT, " &
        "FOREIGN KEY(network) REFERENCES Network(id), UNIQUE(network, " &
        "endpoint))"),
      29 => To_Unbounded_String
       ("ALTER TABLE WebPushSubscription ADD COLUMN user INTEGER REFERENCES " &
        "User(id)"),
      30 => To_Unbounded_String
       ("UPDATE WebPushSubscription AS wps SET user = (SELECT n.user FROM " &
        "Network AS n WHERE n.id = wps.network)"),
      31 => To_Unbounded_String ("ALTER TABLE User ADD COLUMN nick TEXT"),
      32 => To_Unbounded_String
       ("ALTER TABLE Network ADD COLUMN auto_away INTEGER NOT NULL DEFAULT 1"),
      33 => To_Unbounded_String ("ALTER TABLE Network ADD COLUMN certfp TEXT"),
      34 => To_Unbounded_String
       ("ALTER TABLE User ADD COLUMN created_at TEXT NOT NULL DEFAULT ''"),
      35 => To_Unbounded_String
       ("UPDATE User SET created_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now')"),
      36 => To_Unbounded_String
       ("ALTER TABLE User ADD COLUMN enabled INTEGER NOT NULL DEFAULT 1"),
      37 => To_Unbounded_String
       ("ALTER TABLE User ADD COLUMN downstream_interacted_at TEXT"),
      38 => To_Unbounded_String
       ("CREATE TABLE Message (id INTEGER PRIMARY KEY, target INTEGER NOT " &
        "NULL, raw TEXT NOT NULL, time TEXT NOT NULL, sender TEXT NOT NULL, " &
        "text TEXT, FOREIGN KEY(target) REFERENCES MessageTarget(id))"),
      39 => To_Unbounded_String
       ("CREATE INDEX MessageIndex ON Message(target, time)"),
      40 => To_Unbounded_String
       ("CREATE TABLE MessageTarget (id INTEGER PRIMARY KEY, network " &
       "INTEGER " &
        "NOT NULL, target TEXT NOT NULL, FOREIGN KEY(network) REFERENCES " &
        "Network(id), UNIQUE(network, target))"),
      41 => To_Unbounded_String
       ("CREATE VIRTUAL TABLE MessageFTS USING fts5 (text, " &
        "content=Message, content_rowid=id)"),
      42 => To_Unbounded_String
       ("CREATE TRIGGER MessageFTSInsert AFTER INSERT ON Message " &
        "BEGIN INSERT INTO MessageFTS(rowid, text) VALUES (new.id, " &
        "new.text); END"),
      43 => To_Unbounded_String
       ("CREATE TRIGGER MessageFTSDelete AFTER DELETE ON Message " &
        "BEGIN INSERT INTO MessageFTS(MessageFTS, rowid, text) " &
        "VALUES ('delete', old.id, old.text); END"),
      44 => To_Unbounded_String
       ("CREATE TRIGGER MessageFTSUpdate AFTER UPDATE ON Message " &
        "BEGIN INSERT INTO MessageFTS(MessageFTS, rowid, text) " &
        "VALUES ('delete', old.id, old.text); INSERT INTO " &
        "MessageFTS(rowid, text) VALUES (new.id, new.text); END"),
      --  25: User.max_networks (soju's per-user network limit).
      45 => To_Unbounded_String
       ("ALTER TABLE User ADD COLUMN max_networks INTEGER NOT NULL " &
        "DEFAULT -1"),
      --  26: MessageTarget.pinned and .muted (METADATA).
      46 => To_Unbounded_String
       ("ALTER TABLE MessageTarget ADD COLUMN pinned INTEGER NOT NULL " &
        "DEFAULT 0"),
      47 => To_Unbounded_String
       ("ALTER TABLE MessageTarget ADD COLUMN muted INTEGER NOT NULL " &
        "DEFAULT 0"),
      --  27: indexes on the foreign keys.
      48 => To_Unbounded_String
       ("CREATE INDEX Network_user_index ON Network(user)"),
      49 => To_Unbounded_String
       ("CREATE INDEX Channel_network_index ON Channel(network)"),
      50 => To_Unbounded_String
       ("CREATE INDEX DeliveryReceipt_network_index ON " &
        "DeliveryReceipt(network)"),
      51 => To_Unbounded_String
       ("CREATE INDEX ReadReceipt_network_index ON ReadReceipt(network)"),
      52 => To_Unbounded_String
       ("CREATE INDEX WebPushSubscription_user_index ON " &
        "WebPushSubscription(user)"),
      53 => To_Unbounded_String
       ("CREATE INDEX WebPushSubscription_network_index ON " &
        "WebPushSubscription(network)"),
      54 => To_Unbounded_String
       ("CREATE INDEX Message_target_index ON Message(target)"),
      55 => To_Unbounded_String
       ("CREATE INDEX MessageTarget_network_index ON MessageTarget(network)"),
      --  28: MessageTarget.blocked.
      56 => To_Unbounded_String
       ("ALTER TABLE MessageTarget ADD COLUMN blocked INTEGER NOT NULL " &
        "DEFAULT 0"),
      --  29: device certificates.
      57 => To_Unbounded_String
       ("CREATE TABLE DeviceCertificate (id INTEGER PRIMARY KEY, user " &
        "INTEGER NOT NULL, label TEXT NOT NULL, fingerprint BLOB NOT NULL " &
        "UNIQUE, last_used TEXT NOT NULL, FOREIGN KEY(user) REFERENCES " &
        "User(id))"),
      --  30: the address a device certificate was last used from.
      58 => To_Unbounded_String
       ("ALTER TABLE DeviceCertificate ADD COLUMN last_ip TEXT NOT NULL " &
        "DEFAULT ''")];

   Migration_Start : constant array (1 .. Migration_Count) of Positive :=
     [1, 2, 3, 4, 5, 6, 10, 14, 18, 19, 20, 21, 22, 26, 27, 29, 31, 32, 33,
      34, 36, 37, 38, 40, 45, 46, 48, 56, 57, 58, 59];

   -----------------
   --  Time helpers
   -----------------

   --  Format N to Width digits, zero-padded on the left.
   function Pad (N : Integer; Width : Positive) return String is
      T : constant String := Integer'Image (N);
      S : constant String :=
        (if T (T'First) = ' ' then T (T'First + 1 .. T'Last) else T);
      R : String (1 .. Width) := (others => '0');
   begin
      R (Width - S'Length + 1 .. Width) := S;
      return R;
   end Pad;

   --  sqliteTimeLayout = "2006-01-02T15:04:05.000Z" (millisecond precision,
   --  UTC).  The strings are compared lexicographically by the store, so the
   --  layout is fixed-width and sortable.
   function Format_Time (T : Time) return String is
      use Ada.Calendar;
      use Ada.Calendar.Formatting;
      Year   : Year_Number;
      Month  : Month_Number;
      Day    : Day_Number;
      Hour   : Hour_Number;
      Minute : Minute_Number;
      Second : Second_Number;
      Sub    : Second_Duration;
      MS     : Integer;
   begin
      Ada.Calendar.Formatting.Split (T, Year, Month, Day, Hour, Minute, Second,
                                     Sub, Time_Zone => 0);
      MS := Integer (Sub * 1000.0);
      if MS > 999 then
         MS := 999;
      end if;
      return Pad (Integer (Year), 4) & "-" & Pad (Integer (Month), 2) & "-" &
        Pad (Integer (Day), 2) & "T" & Pad (Integer (Hour), 2) & ":" &
        Pad (Integer (Minute), 2) & ":" & Pad (Integer (Second), 2) & "." &
        Pad (MS, 3) & "Z";
   end Format_Time;

   function Parse_Time (S : String) return Time is
      F : constant Positive := S'First;
      Year   : constant Ada.Calendar.Year_Number :=
        Ada.Calendar.Year_Number   (Integer'Value (S (F + 0  .. F + 3)));
      Month  : constant Ada.Calendar.Month_Number :=
        Ada.Calendar.Month_Number  (Integer'Value (S (F + 5  .. F + 6)));
      Day    : constant Ada.Calendar.Day_Number :=
        Ada.Calendar.Day_Number    (Integer'Value (S (F + 8  .. F + 9)));
      Hour   : constant Ada.Calendar.Formatting.Hour_Number :=
        Ada.Calendar.Formatting.Hour_Number
          (Integer'Value (S (F + 11 .. F + 12)));
      Minute : constant Ada.Calendar.Formatting.Minute_Number :=
        Ada.Calendar.Formatting.Minute_Number
          (Integer'Value (S (F + 14 .. F + 15)));
      Second : constant Ada.Calendar.Formatting.Second_Number :=
        Ada.Calendar.Formatting.Second_Number
          (Integer'Value (S (F + 17 .. F + 18)));
      MS     : constant Integer := Integer'Value (S (F + 20 .. F + 22));
   begin
      return Ada.Calendar.Formatting.Time_Of
        (Year, Month, Day, Hour, Minute, Second,
         Duration (MS) / 1000.0, Leap_Second => False, Time_Zone => 0);
   end Parse_Time;

   -------------------------
   --  connect_commands  --
   -------------------------

   CRLF : constant String := ASCII.CR & ASCII.LF;

   function Join_Crlf
     (V : Connect_Command_Vectors.Vector) return Unbounded_String
   is
      R : Unbounded_String := Null_Unbounded_String;
   begin
      for I in 1 .. Natural (V.Length) loop
         if I > 1 then
            Append (R, CRLF);
         end if;
         Append (R, V (I));
      end loop;
      return R;
   end Join_Crlf;

   function Split_Crlf
     (S : Unbounded_String) return Connect_Command_Vectors.Vector
   is
      V : Connect_Command_Vectors.Vector :=
        Connect_Command_Vectors.Empty_Vector;
      T : constant String := To_String (S);
      Start : Positive;
      I     : Positive;
   begin
      if T = "" then
         return V;
      end if;
      Start := T'First;
      I := T'First;
      while I <= T'Last loop
         if I + 1 <= T'Last and then T (I) = ASCII.CR
           and then T (I + 1) = ASCII.LF
         then
            Connect_Command_Vectors.Append
              (V, To_Unbounded_String (T (Start .. I - 1)));
            I := I + 2;
            Start := I;
         else
            I := I + 1;
         end if;
      end loop;
      if Start <= T'Last then
         Connect_Command_Vectors.Append
           (V, To_Unbounded_String (T (Start .. T'Last)));
      end if;
      return V;
   end Split_Crlf;

   ----------------------------
   --  Parameter/column helpers
   ----------------------------

   --  toNullString: an empty string is stored as NULL.
   function P_Str (S : Unbounded_String) return SQL_Parameter is
   begin
      if S = Null_Unbounded_String then
         return Null_Parameter;
      end if;
      return +To_String (S);
   end P_Str;

   --  sqliteTime.Value: the zero time is stored as NULL.
   function P_Time (T : Time) return SQL_Parameter is
   begin
      if T = Null_Time then
         return Null_Parameter;
      end if;
      return +Format_Time (T);
   end P_Time;

   --  sql.NullInt64 for the WebPushSubscription.network column.
   function P_Network_Null (ID : Long_Long_Integer) return SQL_Parameter is
   begin
      if ID = 0 then
         return Null_Parameter;
      end if;
      return As_Bigint (ID);
   end P_Network_Null;

   --  The bytes a hexadecimal text spells (SQLite's hex()): the certificate
   --  and key of a network are binary, and a column read as text stops at
   --  its first NUL byte.
   function From_Hex (Text : Unbounded_String) return Unbounded_String is
      S      : constant String := To_String (Text);
      Result : Unbounded_String;

      function Digit (C : Character) return Natural is
        (case C is
            when '0' .. '9' => Character'Pos (C) - Character'Pos ('0'),
            when 'a' .. 'f' => Character'Pos (C) - Character'Pos ('a') + 10,
            when 'A' .. 'F' => Character'Pos (C) - Character'Pos ('A') + 10,
            when others     => 0);
   begin
      for I in 1 .. S'Length / 2 loop
         Append (Result, Character'Val
           (Digit (S (S'First + 2 * (I - 1))) * 16
            + Digit (S (S'First + 2 * (I - 1) + 1))));
      end loop;
      return Result;
   end From_Hex;

   function Col_Str (C : Forward_Cursor; F : Field_Index)
      return Unbounded_String
   is
   begin
      if Is_Null (C, F) then
         return Null_Unbounded_String;
      end if;
      return Unbounded_Value (C, F);
   end Col_Str;

   function Col_Time (C : Forward_Cursor; F : Field_Index) return Time is
   begin
      if Is_Null (C, F) then
         return Null_Time;
      end if;
      return Parse_Time (Value (C, F));
   end Col_Time;

   -----------
   --  Check --
   -----------

   procedure Check (DB : access Sqlite_DB) is
   begin
      if not Success (DB.DB) then
         raise Database_Error with Last_Error_Message (DB.DB);
      end if;
   end Check;

   procedure Commit_Check (DB : access Sqlite_DB) is
   begin
      Commit_Or_Rollback (DB.DB);
      if not Success (DB.DB) then
         raise Database_Error with Last_Error_Message (DB.DB);
      end if;
   end Commit_Check;

   function Last_ID (DB : access Sqlite_DB) return Long_Long_Integer is
      C : Forward_Cursor;
   begin
      Fetch (C, DB.DB, "SELECT last_insert_rowid()");
      Check (DB);
      if Has_Row (C) then
         return Bigint_Value (C, 0);
      end if;
      return 0;
   end Last_ID;

   -----------------------------------------------------------------
   --  Kick records (soja-specific; not part of soju's schema)
   -----------------------------------------------------------------

   --  A table of its own, created with IF NOT EXISTS after the usual
   --  upgrade and without touching PRAGMA user_version, so that upstream
   --  soju (which refuses a database whose version it does not know) keeps
   --  working on the same file, and simply ignores the table.
   --  A database that soja created before it had FTS5 (or that is missing
   --  the index for any reason) has the Message tables but no MessageFTS:
   --  create it and its triggers, and index what is there, so that SEARCH
   --  works and the same file stays valid for soju (whose triggers and index
   --  these are, to the letter).
   procedure Ensure_Message_FTS (DB : access Sqlite_DB) is
      C : Forward_Cursor;
      Missing : Boolean := False;
   begin
      Fetch (C, DB.DB,
        "SELECT COUNT(*) FROM sqlite_master WHERE name = 'MessageFTS'");
      Check (DB);
      Missing := Has_Row (C) and then Bigint_Value (C, 0) = 0;
      if not Missing then
         return;
      end if;
      for I in Schema_Stmts'Last - 3 .. Schema_Stmts'Last loop
         Execute (DB.DB, To_String (Schema_Stmts (I)));
         Check (DB);
      end loop;
      Execute (DB.DB, "INSERT INTO MessageFTS(MessageFTS) VALUES ('rebuild')");
      Check (DB);
      Commit_Check (DB);
   end Ensure_Message_FTS;

   procedure Ensure_Soja_Tables (DB : access Sqlite_DB) is
   begin
      Execute (DB.DB,
        "CREATE TABLE IF NOT EXISTS KickRecord (id INTEGER PRIMARY KEY, " &
        "network INTEGER NOT NULL, channel TEXT NOT NULL, kicked_by TEXT " &
        "NOT NULL, reason TEXT, kicked_at TEXT NOT NULL, rejoined_at TEXT, " &
        "FOREIGN KEY(network) REFERENCES Network(id))");
      Check (DB);
      Execute (DB.DB,
        "CREATE INDEX IF NOT EXISTS KickRecordNetwork ON " &
        "KickRecord(network, rejoined_at)");
      Check (DB);
      Commit_Check (DB);
      Ensure_Message_FTS (DB);
   end Ensure_Soja_Tables;

   overriding procedure Store_Kick (DB : in out Sqlite_DB;
      Network_ID : Long_Long_Integer; Kick : in out Kick_Record)
   is
      G : Guard;
   begin
      Acquire (G, DB.Lock);
      if Kick.ID /= 0 then
         --  Only the rejoin time ever changes: a kick is history.
         Execute (DB.DB,
           "UPDATE KickRecord SET rejoined_at = ?1 WHERE id = ?2",
           [1 => P_Time (Kick.Rejoined_At), 2 => As_Bigint (Kick.ID)]);
         Check (DB'Access);
      else
         Execute (DB.DB,
           "INSERT INTO KickRecord(network, channel, kicked_by, reason, " &
           "kicked_at, rejoined_at) VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
           [1 => As_Bigint (Network_ID),
            2 => +To_String (Kick.Channel),
            3 => +To_String (Kick.Kicked_By),
            4 => P_Str (Kick.Reason),
            5 => P_Time (Kick.Kicked_At),
            6 => P_Time (Kick.Rejoined_At)]);
         Check (DB'Access);
         Kick.ID := Last_ID (DB'Access);
      end if;
      Commit_Check (DB'Access);
   end Store_Kick;

   overriding function List_Kicks (DB : in out Sqlite_DB;
      Network_ID : Long_Long_Integer; Active_Only : Boolean)
      return Kick_Lists.Vector
   is
      G : Guard;
      C : Forward_Cursor;
      V : Kick_Lists.Vector := Kick_Lists.Empty_Vector;
   begin
      Acquire (G, DB.Lock);
      Fetch (C, DB.DB,
        "SELECT id, channel, kicked_by, reason, kicked_at, rejoined_at " &
        "FROM KickRecord WHERE network = ?1 " &
        (if Active_Only then "AND rejoined_at IS NULL " else "") &
        "ORDER BY id",
        [1 => As_Bigint (Network_ID)]);
      Check (DB'Access);
      while Has_Row (C) loop
         declare
            K : Kick_Record;
         begin
            K.ID := Bigint_Value (C, 0);
            K.Channel := Unbounded_Value (C, 1);
            K.Kicked_By := Unbounded_Value (C, 2);
            K.Reason := Col_Str (C, 3);
            K.Kicked_At := Col_Time (C, 4);
            K.Rejoined_At := Col_Time (C, 5);
            V.Append (K);
         end;
         Next (C);
      end loop;
      return V;
   end List_Kicks;

   -------------
   --  Upgrade --
   -------------

   procedure Upgrade (DB : access Sqlite_DB) is
      C       : Forward_Cursor;
      Version : Long_Long_Integer := 0;
      Count : constant Long_Long_Integer :=
        Long_Long_Integer (Migration_Count);
      Version_Image : constant String :=
        Ada.Strings.Fixed.Trim (Integer'Image (Migration_Count),
                                Ada.Strings.Left);
   begin
      Fetch (C, DB.DB, "PRAGMA user_version");
      Check (DB);
      if Has_Row (C) then
         Version := Bigint_Value (C, 0);
      end if;

      if Version = Count then
         return;
      elsif Version > Count then
         raise Database_Error with "soja (version" & Count'Image &
           ") older than schema (version" & Version'Image & ")";
      end if;

      if Version = 0 then
         for I in Schema_Stmts'Range loop
            Execute (DB.DB, To_String (Schema_Stmts (I)));
            Check (DB);
         end loop;
      else
         for V in Integer (Version) .. Migration_Count - 1 loop
            for J in Migration_Start (V) .. Migration_Start (V + 1) - 1 loop
               Execute (DB.DB, To_String (Migration_Stmts (J)));
               Check (DB);
            end loop;
         end loop;
      end if;

      Execute (DB.DB, "PRAGMA user_version = " & Version_Image);
      Check (DB);

      Commit_Check (DB);
   end Upgrade;

   ----------
   --  Open --
   ----------

   procedure Free_Mutex is
     new Ada.Unchecked_Deallocation (Mutex, Mutex_Access);

   type Sqlite_DB_Access is access Sqlite_DB;

   --  What soju sets in its connection string: write-ahead logging (a
   --  property of the file, which a database made by soju already has) and
   --  the "normal" synchronous mode.
   procedure Set_Pragmas (DB : Sqlite_DB_Access) is
      C : Forward_Cursor;
   begin
      Fetch (C, DB.DB, "PRAGMA journal_mode = WAL");
      Check (DB);
      Execute (DB.DB, "PRAGMA synchronous = NORMAL");
      Check (DB);
   end Set_Pragmas;

   function Open_Sqlite_DB (Source : String) return Database_Access is
      Desc : constant Database_Description :=
        GNATCOLL.SQL.Sqlite.Setup (Source);
      Self : constant Sqlite_DB_Access := new Sqlite_DB;
   begin
      if Desc = null then
         raise Database_Error with "failed to set up sqlite database";
      end if;

      GNATCOLL.SQL.Sqlite.Max_Ms_On_Busy := 5000;

      Self.Description := Desc;
      Self.Lock := new Mutex;
      Self.DB := Build_Connection (Desc);
      if Self.DB = null then
         raise Database_Error with "failed to build sqlite connection";
      end if;

      Set_Pragmas (Self);
      Upgrade (Self);
      Ensure_Soja_Tables (Self);

      return Database_Access (Self);
   exception
      when others =>
         if Self.DB /= null then
            GNATCOLL.SQL.Exec.Free (Self.DB);
         end if;
         if Self.Description /= null then
            GNATCOLL.SQL.Exec.Free (Self.Description);
         end if;
         if Self.Lock /= null then
            Free_Mutex (Self.Lock);
         end if;
         raise;
   end Open_Sqlite_DB;

   function Open_Temp_Sqlite_DB return Database_Access is
   begin
      return Open_Sqlite_DB (":memory:");
   end Open_Temp_Sqlite_DB;

   -----------
   --  Close --
   -----------

   overriding procedure Close (DB : in out Sqlite_DB) is
   begin
      if DB.DB /= null then
         GNATCOLL.SQL.Exec.Free (DB.DB);
         DB.DB := null;
      end if;
      if DB.Description /= null then
         GNATCOLL.SQL.Exec.Free (DB.Description);
         DB.Description := null;
      end if;
      if DB.Lock /= null then
         Free_Mutex (DB.Lock);
      end if;
   end Close;

   -----------
   --  Stats --
   -----------

   overriding function Stats (DB : in out Sqlite_DB) return Database_Stats is
      G : Guard;
      C : Forward_Cursor;
      S : Database_Stats;
   begin
      Acquire (G, DB.Lock);
      Fetch (C, DB.DB,
        "SELECT (SELECT COUNT(*) FROM User) AS users, " &
        "(SELECT COUNT(*) FROM Network) AS networks, " &
        "(SELECT COUNT(*) FROM Channel) AS channels");
      Check (DB'Access);
      if Has_Row (C) then
         S.Users    := Bigint_Value (C, 0);
         S.Networks := Bigint_Value (C, 1);
         S.Channels := Bigint_Value (C, 2);
      end if;
      return S;
   end Stats;

   ---------------
   --  List_Users --
   ---------------

   overriding function List_Users (DB : in out Sqlite_DB)
      return User_Lists.Vector
   is
      G : Guard;
      C : Forward_Cursor;
      V : User_Lists.Vector := User_Lists.Empty_Vector;
   begin
      Acquire (G, DB.Lock);
      Fetch (C, DB.DB,
        "SELECT id, username, password, admin, nick, realname, enabled, " &
        "downstream_interacted_at, max_networks FROM User");
      Check (DB'Access);
      while Has_Row (C) loop
         declare
            U : User;
         begin
            U.ID := Bigint_Value (C, 0);
            U.Username := Unbounded_Value (C, 1);
            U.Password := Col_Str (C, 2);
            U.Admin := Boolean_Value (C, 3);
            U.Nick := Col_Str (C, 4);
            U.Realname := Col_Str (C, 5);
            U.Enabled := Boolean_Value (C, 6);
            U.Downstream_Interacted_At := Col_Time (C, 7);
            U.Max_Networks := Integer (Bigint_Value (C, 8));
            V.Append (U);
         end;
         Next (C);
      end loop;
      return V;
   end List_Users;

   -------------
   --  Get_User --
   -------------

   overriding function Get_User (DB : in out Sqlite_DB; Username : String)
      return User
   is
      G : Guard;
      C : Forward_Cursor;
      U : User := New_User (Username);
   begin
      Acquire (G, DB.Lock);
      Fetch (C, DB.DB,
        "SELECT id, password, admin, nick, realname, enabled, " &
        "downstream_interacted_at, max_networks FROM User WHERE username = ?1",
        [1 => +Username]);
      Check (DB'Access);
      if not Has_Row (C) then
         raise Not_Found;
      end if;
      U.ID := Bigint_Value (C, 0);
      U.Password := Col_Str (C, 1);
      U.Admin := Boolean_Value (C, 2);
      U.Nick := Col_Str (C, 3);
      U.Realname := Col_Str (C, 4);
      U.Enabled := Boolean_Value (C, 5);
      U.Downstream_Interacted_At := Col_Time (C, 6);
      U.Max_Networks := Integer (Bigint_Value (C, 7));
      return U;
   end Get_User;

   ---------------
   --  Store_User --
   ---------------

   overriding procedure Store_User (DB : in out Sqlite_DB; U : in out User) is
      G : Guard;
   begin
      Acquire (G, DB.Lock);
      if U.ID /= 0 then
         Execute (DB.DB,
           "UPDATE User SET password = ?1, admin = ?2, nick = ?3, " &
           "realname = ?4, enabled = ?5, downstream_interacted_at = ?6, " &
           "max_networks = ?8 WHERE username = ?7",
           [1 => P_Str (U.Password),
            2 => +U.Admin,
            3 => P_Str (U.Nick),
            4 => P_Str (U.Realname),
            5 => +U.Enabled,
            6 => P_Time (U.Downstream_Interacted_At),
            7 => +To_String (U.Username),
            8 => +U.Max_Networks]);
         Check (DB'Access);
      else
         Execute (DB.DB,
           "INSERT INTO User(username, password, admin, nick, realname, " &
           "created_at, enabled, downstream_interacted_at, max_networks) " &
           "VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)",
           [1 => +To_String (U.Username),
            2 => P_Str (U.Password),
            3 => +U.Admin,
            4 => P_Str (U.Nick),
            5 => P_Str (U.Realname),
            6 => +Format_Time (Ada.Calendar.Clock),
            7 => +U.Enabled,
            8 => P_Time (U.Downstream_Interacted_At),
            9 => +U.Max_Networks]);
         Check (DB'Access);
         U.ID := Last_ID (DB'Access);
      end if;
      Commit_Check (DB'Access);
   end Store_User;

   ---------------
   --  Delete_User --
   ---------------

   overriding procedure Delete_User (DB : in out Sqlite_DB;
      ID : Long_Long_Integer)
   is
      G : Guard;

      procedure Del (Stmt : String) is
      begin
         Execute (DB.DB, Stmt, [1 => As_Bigint (ID)]);
         Check (DB'Access);
      end Del;
   begin
      Acquire (G, DB.Lock);
      Del ("DELETE FROM DeliveryReceipt WHERE id IN (SELECT " &
        "DeliveryReceipt.id FROM DeliveryReceipt JOIN Network ON " &
        "DeliveryReceipt.network = Network.id WHERE Network.user = ?1)");
      Del ("DELETE FROM ReadReceipt WHERE id IN (SELECT ReadReceipt.id FROM " &
        "ReadReceipt JOIN Network ON ReadReceipt.network = Network.id WHERE " &
        "Network.user = ?1)");
      Del ("DELETE FROM Message WHERE id IN (SELECT Message.id FROM " &
        "Message, MessageTarget, Network WHERE Message.target = " &
        "MessageTarget.id AND MessageTarget.network = Network.id AND " &
        "Network.user = ?1)");
      Del ("DELETE FROM MessageTarget WHERE id IN (SELECT " &
        "MessageTarget.id FROM MessageTarget, Network WHERE " &
        "MessageTarget.network = Network.id AND Network.user = ?1)");
      Del ("DELETE FROM KickRecord WHERE id IN (SELECT KickRecord.id FROM " &
        "KickRecord JOIN Network ON KickRecord.network = Network.id WHERE " &
        "Network.user = ?1)");
      Del ("DELETE FROM WebPushSubscription WHERE user = ?1");
      Del ("DELETE FROM Channel WHERE id IN (SELECT Channel.id FROM Channel " &
        "JOIN Network ON Channel.network = Network.id WHERE Network.user = " &
        "?1)");
      Del ("DELETE FROM Network WHERE user = ?1");
      Del ("DELETE FROM User WHERE id = ?1");
      Commit_Check (DB'Access);
   end Delete_User;

   --------------------
   --  List_Inactive_Usernames --
   --------------------

   overriding function List_Inactive_Usernames
     (DB : in out Sqlite_DB; Limit : Time) return Username_Lists.Vector
   is
      G : Guard;
      C : Forward_Cursor;
      V : Username_Lists.Vector := Username_Lists.Empty_Vector;
   begin
      Acquire (G, DB.Lock);
      Fetch (C, DB.DB,
        "SELECT username FROM User WHERE coalesce(downstream_interacted_at, " &
        "created_at) < ?1",
        [1 => P_Time (Limit)]);
      Check (DB'Access);
      while Has_Row (C) loop
         V.Append (Unbounded_Value (C, 0));
         Next (C);
      end loop;
      return V;
   end List_Inactive_Usernames;

   ----------------
   --  List_Networks --
   ----------------

   overriding function List_Networks (DB : in out Sqlite_DB;
      User_ID : Long_Long_Integer) return Network_Lists.Vector
   is
      G : Guard;
      C : Forward_Cursor;
      V : Network_Lists.Vector := Network_Lists.Empty_Vector;
   begin
      Acquire (G, DB.Lock);
      Fetch (C, DB.DB,
        "SELECT id, name, addr, nick, username, realname, certfp, pass, " &
        "connect_commands, sasl_mechanism, sasl_plain_username, " &
        "sasl_plain_password, hex(sasl_external_cert), " &
        "hex(sasl_external_key), " &
        "auto_away, enabled FROM Network WHERE user = ?1",
        [1 => As_Bigint (User_ID)]);
      Check (DB'Access);
      while Has_Row (C) loop
         declare
            Net : Network;
         begin
            Net.ID := Bigint_Value (C, 0);
            Net.Name := Col_Str (C, 1);
            Net.Addr := Unbounded_Value (C, 2);
            Net.Nick := Col_Str (C, 3);
            Net.Username := Col_Str (C, 4);
            Net.Realname := Col_Str (C, 5);
            Net.Cert_FP := Col_Str (C, 6);
            Net.Pass := Col_Str (C, 7);
            Net.Connect_Commands := Split_Crlf (Col_Str (C, 8));
            Net.SASL.Mechanism := Col_Str (C, 9);
            Net.SASL.Plain_Username := Col_Str (C, 10);
            Net.SASL.Plain_Password := Col_Str (C, 11);
            Net.SASL.External_Cert := From_Hex (Col_Str (C, 12));
            Net.SASL.External_Key := From_Hex (Col_Str (C, 13));
            Net.Auto_Away := Boolean_Value (C, 14);
            Net.Enabled := Boolean_Value (C, 15);
            V.Append (Net);
         end;
         Next (C);
      end loop;
      return V;
   end List_Networks;

   ----------------
   --  Store_Network --
   ----------------

   overriding procedure Store_Network (DB : in out Sqlite_DB;
      User_ID : Long_Long_Integer; Net : in out Network)
   is
      G : Guard;
      Plain_User : Unbounded_String := Null_Unbounded_String;
      Plain_Pass : Unbounded_String := Null_Unbounded_String;
      Cert : Unbounded_String := Net.SASL.External_Cert;
      Key  : Unbounded_String := Net.SASL.External_Key;
   begin
      Acquire (G, DB.Lock);

      if Net.SASL.Mechanism /= Null_Unbounded_String then
         if To_String (Net.SASL.Mechanism) = "PLAIN" then
            Plain_User := Net.SASL.Plain_Username;
            Plain_Pass := Net.SASL.Plain_Password;
            Net.SASL.External_Cert := Null_Unbounded_String;
            Net.SASL.External_Key := Null_Unbounded_String;
            Cert := Null_Unbounded_String;
            Key := Null_Unbounded_String;
         elsif To_String (Net.SASL.Mechanism) = "EXTERNAL" then
            null;
         else
            raise Database_Error with
              "soju: cannot store network: unsupported SASL mechanism " &
              To_String (Net.SASL.Mechanism);
         end if;
      end if;

      if Net.ID /= 0 then
         Execute (DB.DB,
           "UPDATE Network SET name = ?1, addr = ?2, nick = ?3, username = " &
           "?4, realname = ?5, certfp = ?6, pass = ?7, connect_commands = " &
           "?8, " &
           "sasl_mechanism = ?9, sasl_plain_username = ?10, " &
           "sasl_plain_password = ?11, " &
           "sasl_external_cert = CAST(?12 AS BLOB), " &
           "sasl_external_key = CAST(?13 AS BLOB), auto_away = ?14, " &
           "enabled = ?15 " &
           "WHERE id = ?16",
           [1 => P_Str (Net.Name),
            2 => +To_String (Net.Addr),
            3 => P_Str (Net.Nick),
            4 => P_Str (Net.Username),
            5 => P_Str (Net.Realname),
            6 => P_Str (Net.Cert_FP),
            7 => P_Str (Net.Pass),
            8 => P_Str (Join_Crlf (Net.Connect_Commands)),
            9 => P_Str (Net.SASL.Mechanism),
            10 => P_Str (Plain_User),
            11 => P_Str (Plain_Pass),
            12 => P_Str (Cert),
            13 => P_Str (Key),
            14 => +Net.Auto_Away,
            15 => +Net.Enabled,
            16 => As_Bigint (Net.ID)]);
         Check (DB'Access);
      else
         Execute (DB.DB,
           "INSERT INTO Network(user, name, addr, nick, username, realname, " &
           "certfp, pass, connect_commands, sasl_mechanism, " &
           "sasl_plain_username, sasl_plain_password, sasl_external_cert, " &
           "sasl_external_key, auto_away, enabled) VALUES " &
           "(?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, " &
           "CAST(?13 AS BLOB), CAST(?14 AS BLOB), ?15, ?16)",
           [1 => As_Bigint (User_ID),
            2 => P_Str (Net.Name),
            3 => +To_String (Net.Addr),
            4 => P_Str (Net.Nick),
            5 => P_Str (Net.Username),
            6 => P_Str (Net.Realname),
            7 => P_Str (Net.Cert_FP),
            8 => P_Str (Net.Pass),
            9 => P_Str (Join_Crlf (Net.Connect_Commands)),
            10 => P_Str (Net.SASL.Mechanism),
            11 => P_Str (Plain_User),
            12 => P_Str (Plain_Pass),
            13 => P_Str (Cert),
            14 => P_Str (Key),
            15 => +Net.Auto_Away,
            16 => +Net.Enabled]);
         Check (DB'Access);
         Net.ID := Last_ID (DB'Access);
      end if;
      Commit_Check (DB'Access);
   end Store_Network;

   ----------------
   --  Delete_Network --
   ----------------

   overriding procedure Delete_Network (DB : in out Sqlite_DB;
      ID : Long_Long_Integer)
   is
      G : Guard;

      procedure Del (Stmt : String) is
      begin
         Execute (DB.DB, Stmt, [1 => As_Bigint (ID)]);
         Check (DB'Access);
      end Del;
   begin
      Acquire (G, DB.Lock);
      Del ("DELETE FROM Message WHERE target IN (SELECT id " &
        "FROM MessageTarget WHERE network = ?1)");
      Del ("DELETE FROM MessageTarget WHERE network = ?1");
      Del ("DELETE FROM WebPushSubscription WHERE network = ?1");
      Del ("DELETE FROM DeliveryReceipt WHERE network = ?1");
      Del ("DELETE FROM ReadReceipt WHERE network = ?1");
      Del ("DELETE FROM KickRecord WHERE network = ?1");
      Del ("DELETE FROM Channel WHERE network = ?1");
      Del ("DELETE FROM Network WHERE id = ?1");
      Commit_Check (DB'Access);
   end Delete_Network;

   ----------------
   --  List_Channels --
   ----------------

   overriding function List_Channels (DB : in out Sqlite_DB;
      Network_ID : Long_Long_Integer) return Channel_Lists.Vector
   is
      G : Guard;
      C : Forward_Cursor;
      V : Channel_Lists.Vector := Channel_Lists.Empty_Vector;
   begin
      Acquire (G, DB.Lock);
      Fetch (C, DB.DB,
        "SELECT id, name, key, detached, detached_internal_msgid, " &
        "relay_detached, reattach_on, detach_after, detach_on FROM Channel " &
        "WHERE network = ?1",
        [1 => As_Bigint (Network_ID)]);
      Check (DB'Access);
      while Has_Row (C) loop
         declare
            Ch : Channel;
         begin
            Ch.ID := Bigint_Value (C, 0);
            Ch.Name := Unbounded_Value (C, 1);
            Ch.Key := Col_Str (C, 2);
            Ch.Detached := Boolean_Value (C, 3);
            Ch.Detached_Internal_Msg_ID := Col_Str (C, 4);
            Ch.Relay_Detached := Message_Filter'Val (Integer_Value (C, 5));
            Ch.Reattach_On := Message_Filter'Val (Integer_Value (C, 6));
            Ch.Detach_After := Duration (Bigint_Value (C, 7));
            Ch.Detach_On := Message_Filter'Val (Integer_Value (C, 8));
            V.Append (Ch);
         end;
         Next (C);
      end loop;
      return V;
   end List_Channels;

   ----------------
   --  Store_Channel --
   ----------------

   overriding procedure Store_Channel (DB : in out Sqlite_DB;
      Network_ID : Long_Long_Integer; Ch : in out Channel)
   is
      G : Guard;
      Detach_After : constant Long_Long_Integer :=
        Long_Long_Integer (Float'Ceiling (Float (Ch.Detach_After)));
   begin
      Acquire (G, DB.Lock);
      if Ch.ID /= 0 then
         Execute (DB.DB,
           "UPDATE Channel SET network = ?1, name = ?2, key = ?3, detached " &
           "= ?4, detached_internal_msgid = ?5, relay_detached = ?6, " &
           "reattach_on = ?7, detach_after = ?8, detach_on = ?9 WHERE id = " &
           "?10",
           [1 => As_Bigint (Network_ID),
            2 => +To_String (Ch.Name),
            3 => P_Str (Ch.Key),
            4 => +Ch.Detached,
            5 => P_Str (Ch.Detached_Internal_Msg_ID),
            6 => +Message_Filter'Pos (Ch.Relay_Detached),
            7 => +Message_Filter'Pos (Ch.Reattach_On),
            8 => As_Bigint (Detach_After),
            9 => +Message_Filter'Pos (Ch.Detach_On),
            10 => As_Bigint (Ch.ID)]);
         Check (DB'Access);
      else
         Execute (DB.DB,
           "INSERT INTO Channel(network, name, key, detached, " &
           "detached_internal_msgid, relay_detached, reattach_on, " &
           "detach_after, detach_on) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, " &
           "?8, " &
           "?9)",
           [1 => As_Bigint (Network_ID),
            2 => +To_String (Ch.Name),
            3 => P_Str (Ch.Key),
            4 => +Ch.Detached,
            5 => P_Str (Ch.Detached_Internal_Msg_ID),
            6 => +Message_Filter'Pos (Ch.Relay_Detached),
            7 => +Message_Filter'Pos (Ch.Reattach_On),
            8 => As_Bigint (Detach_After),
            9 => +Message_Filter'Pos (Ch.Detach_On)]);
         Check (DB'Access);
         Ch.ID := Last_ID (DB'Access);
      end if;
      Commit_Check (DB'Access);
   end Store_Channel;

   ----------------
   --  Delete_Channel --
   ----------------

   overriding procedure Delete_Channel (DB : in out Sqlite_DB;
      ID : Long_Long_Integer)
   is
      G : Guard;
   begin
      Acquire (G, DB.Lock);
      Execute (DB.DB, "DELETE FROM Channel WHERE id = ?1",
        [1 => As_Bigint (ID)]);
      Check (DB'Access);
      Commit_Check (DB'Access);
   end Delete_Channel;

   --------------------------
   --  List_Delivery_Receipts --
   --------------------------

   overriding function List_Delivery_Receipts (DB : in out Sqlite_DB;
      Network_ID : Long_Long_Integer) return Delivery_Receipt_Lists.Vector
   is
      G : Guard;
      C : Forward_Cursor;
      V : Delivery_Receipt_Lists.Vector := Delivery_Receipt_Lists.Empty_Vector;
   begin
      Acquire (G, DB.Lock);
      Fetch (C, DB.DB,
        "SELECT id, target, client, internal_msgid FROM DeliveryReceipt " &
        "WHERE network = ?1",
        [1 => As_Bigint (Network_ID)]);
      Check (DB'Access);
      while Has_Row (C) loop
         declare
            R : Delivery_Receipt;
         begin
            R.ID := Bigint_Value (C, 0);
            R.Target := Unbounded_Value (C, 1);
            R.Client := Col_Str (C, 2);
            R.Internal_Msg_ID := Unbounded_Value (C, 3);
            V.Append (R);
         end;
         Next (C);
      end loop;
      return V;
   end List_Delivery_Receipts;

   --------------------------------
   --  Store_Client_Delivery_Receipts --
   --------------------------------

   overriding procedure Store_Client_Delivery_Receipts (DB : in out Sqlite_DB;
      Network_ID : Long_Long_Integer; Client : String;
      Receipts : in out Delivery_Receipt_Lists.Vector)
   is
      G : Guard;
      Client_UB : constant Unbounded_String := To_Unbounded_String (Client);
   begin
      Acquire (G, DB.Lock);
      Execute (DB.DB,
        "DELETE FROM DeliveryReceipt WHERE network = ?1 AND client IS ?2",
        [1 => As_Bigint (Network_ID), 2 => P_Str (Client_UB)]);
      Check (DB'Access);
      for I in 1 .. Natural (Receipts.Length) loop
         declare
            Rcpt : Delivery_Receipt := Receipts (I);
         begin
            Execute (DB.DB,
              "INSERT INTO DeliveryReceipt(network, target, client, " &
              "internal_msgid) VALUES (?1, ?2, ?3, ?4)",
              [1 => As_Bigint (Network_ID),
               2 => +To_String (Rcpt.Target),
               3 => P_Str (Client_UB),
               4 => +To_String (Rcpt.Internal_Msg_ID)]);
            Check (DB'Access);
            Rcpt.ID := Last_ID (DB'Access);
            Receipts.Replace_Element (I, Rcpt);
         end;
      end loop;
      Commit_Check (DB'Access);
   end Store_Client_Delivery_Receipts;

   ----------------------------------------------------------------------
   --  The message store
   ----------------------------------------------------------------------

   function Img (N : Integer) return String is
     (Ada.Strings.Fixed.Trim (Integer'Image (N), Ada.Strings.Left));

   --  quoteFTSQuery: FTS5 would read the user's text as a query with
   --  operators; quote each token ("foo" "bar") so that it is matched as
   --  words.  A token is a run of letters, digits and private-use characters
   --  (the unicode61 tokenizer's definition); the rest separates.  The
   --  characters of a token that matter for the quoting (") are doubled.
   function Quote_FTS_Query (Query : String) return String is
      use Ada.Strings.UTF_Encoding.Wide_Wide_Strings;
      use Ada.Wide_Wide_Characters.Handling;
      Wide : constant Wide_Wide_String := Decode (Query);
      Result : Unbounded_String;
      Token  : Wide_Wide_String (1 .. Wide'Length) := [others => ' '];
      Count  : Natural := 0;

      procedure Flush is
      begin
         if Count = 0 then
            return;
         end if;
         if Length (Result) > 0 then
            Append (Result, ' ');
         end if;
         Append (Result, '"');
         declare
            Bytes : constant String := Encode (Token (1 .. Count));
         begin
            for C of Bytes loop
               if C = '"' then
                  Append (Result, '"');   --  a doubled quote, SQL-style
               end if;
               Append (Result, C);
            end loop;
         end;
         Append (Result, '"');
         Count := 0;
      end Flush;

      function Is_Token_Char (C : Wide_Wide_Character) return Boolean is
        (Is_Letter (C) or else Is_Digit (C)
         or else Wide_Wide_Character'Pos (C) in 16#E000# .. 16#F8FF#
              | 16#F0000# .. 16#FFFFD# | 16#100000# .. 16#10FFFD#);
   begin
      for C of Wide loop
         if Is_Token_Char (C) then
            Count := Count + 1;
            Token (Count) := C;
         else
            Flush;
         end if;
      end loop;
      Flush;
      return To_String (Result);
   end Quote_FTS_Query;

   --  A growing list of positional parameters: Add returns "?<n>".
   type Param_List is record
      Items : SQL_Parameters (1 .. 12);
      Count : Natural := 0;
   end record;

   procedure Add (P : in out Param_List; Item : SQL_Parameter;
                  Ref : out Unbounded_String) is
   begin
      P.Count := P.Count + 1;
      P.Items (P.Count) := Item;
      Ref := To_Unbounded_String ("?" & Img (P.Count));
   end Add;

   function Ref_Of (P : in out Param_List; Item : SQL_Parameter) return String
   is
      Ref : Unbounded_String;
   begin
      Add (P, Item, Ref);
      return To_String (Ref);
   end Ref_Of;

   overriding function Get_Message_Last_ID (DB : in out Sqlite_DB;
      Network_ID : Long_Long_Integer; Name : String) return Long_Long_Integer
   is
      G : Guard;
      C : Forward_Cursor;
   begin
      Acquire (G, DB.Lock);
      Fetch (C, DB.DB,
        "SELECT m.id FROM Message AS m, MessageTarget AS t " &
        "WHERE t.network = ?1 AND t.target = ?2 AND m.target = t.id " &
        "ORDER BY m.time DESC LIMIT 1",
        [1 => As_Bigint (Network_ID), 2 => +Name]);
      Check (DB'Access);
      return (if Has_Row (C) then Bigint_Value (C, 0) else 0);
   end Get_Message_Last_ID;

   overriding function Store_Messages (DB : in out Sqlite_DB;
      Network_ID : Long_Long_Integer; Name : String;
      Msgs : Soja.Irc.Messages.Message_Vectors.Vector)
      return Id_Lists.Vector
   is
      use Soja.Irc.Messages;
      G   : Guard;
      Ids : Id_Lists.Vector;
   begin
      if Msgs.Is_Empty then
         return Ids;
      end if;
      Acquire (G, DB.Lock);
      begin
         Execute (DB.DB,
           "INSERT INTO MessageTarget(network, target) VALUES (?1, ?2) " &
           "ON CONFLICT DO NOTHING",
           [1 => As_Bigint (Network_ID), 2 => +Name]);
         Check (DB'Access);

         for Msg of Msgs loop
            declare
               Stamp : Time := Ada.Calendar.Clock;
               Cmd   : constant String := To_String (Msg.Command);
               Text  : SQL_Parameter := Null_Parameter;
            begin
               if Has_Tag (Msg.Tags, "time") then
                  declare
                     Valid : Boolean;
                     T     : constant Time :=
                       Soja.Irc.Helpers.Parse_Server_Time
                         (Get_Tag (Msg.Tags, "time"), Valid);
                  begin
                     if not Valid then
                        raise Database_Error with
                          "failed to parse message time tag";
                     end if;
                     Stamp := T;
                  end;
               end if;

               if (Cmd = "PRIVMSG" or else Cmd = "NOTICE")
                 and then Natural (Msg.Params.Length) > 1
               then
                  Text := +To_String (Msg.Params (2));
               end if;

               Execute (DB.DB,
                 "INSERT INTO Message(target, raw, time, sender, text) " &
                 "SELECT id, ?1, ?2, ?3, ?4 FROM MessageTarget AS t " &
                 "WHERE network = ?5 AND target = ?6",
                 [1 => +Image (Msg),
                  2 => +Format_Time (Stamp),
                  3 => +(if Msg.Prefix = null then ""
                         else To_String (Msg.Prefix.Name)),
                  4 => Text,
                  5 => As_Bigint (Network_ID),
                  6 => +Name]);
               Check (DB'Access);
               Ids.Append (Last_ID (DB'Access));
            end;
         end loop;
         Commit_Check (DB'Access);
      exception
         when others =>
            Rollback (DB.DB);   --  all or none
            raise;
      end;
      return Ids;
   end Store_Messages;

   overriding function List_Message_Last_Per_Target (DB : in out Sqlite_DB;
      Network_ID : Long_Long_Integer; Options : Message_Options)
      return Message_Target_Lists.Vector
   is
      G : Guard;
      C : Forward_Cursor;
      P : Param_List;
      Q : Unbounded_String;
      V : Message_Target_Lists.Vector;
   begin
      Acquire (G, DB.Lock);
      Q := To_Unbounded_String
        ("SELECT target, (SELECT time FROM Message " &
         "WHERE target = MessageTarget.id ");
      if not Options.Events then
         Append (Q, "AND text IS NOT NULL ");
      end if;
      Append (Q, "ORDER BY time DESC LIMIT 1) latest FROM MessageTarget " &
                 "WHERE network = "
                 & Ref_Of (P, As_Bigint (Network_ID)) & " ");
      --  A target with no message to report has no latest time: leave it
      --  out (soju lists it, with the zero time, SOJU-BUGS.md).
      Append (Q, "AND latest IS NOT NULL ");
      --  (time strings compare in lexicographic order)
      if Options.After_Time /= Null_Time then
         Append (Q, "AND latest > "
                 & Ref_Of (P, +Format_Time (Options.After_Time)) & " ");
      end if;
      if Options.Before_Time /= Null_Time then
         Append (Q, "AND latest < "
                 & Ref_Of (P, +Format_Time (Options.Before_Time)) & " ");
      end if;
      Append (Q, (if Options.Take_Last then "ORDER BY latest DESC "
                  else "ORDER BY latest ASC "));
      Append (Q, "LIMIT "
              & Ref_Of (P, As_Bigint (Long_Long_Integer (Options.Limit))));

      Fetch (C, DB.DB, To_String (Q), P.Items (1 .. P.Count));
      Check (DB'Access);
      while Has_Row (C) loop
         V.Append
           (Message_Target'(Name => Unbounded_Value (C, 0),
                            Latest_Message => Col_Time (C, 1)));
         Next (C);
      end loop;

      if Options.Take_Last then
         V.Reverse_Elements;   --  we ordered DESC to limit to the last ones
      end if;
      return V;
   end List_Message_Last_Per_Target;

   overriding function List_Messages (DB : in out Sqlite_DB;
      Network_ID : Long_Long_Integer; Name : String; Options : Message_Options)
      return Soja.Irc.Messages.Message_Vectors.Vector
   is
      G : Guard;
      C : Forward_Cursor;
      P : Param_List;
      Q : Unbounded_String;
      V : Soja.Irc.Messages.Message_Vectors.Vector;
   begin
      Acquire (G, DB.Lock);
      Q := To_Unbounded_String
        ("SELECT m.raw FROM Message AS m, MessageTarget AS t " &
         "WHERE m.target = t.id AND t.network = "
         & Ref_Of (P, As_Bigint (Network_ID)) & " AND t.target = "
         & Ref_Of (P, +Name) & " ");
      if Options.After_ID > 0 then
         Append (Q, "AND m.id > "
                 & Ref_Of (P, As_Bigint (Options.After_ID)) & " ");
      end if;
      if Options.After_Time /= Null_Time then
         Append (Q, "AND m.time > "
                 & Ref_Of (P, +Format_Time (Options.After_Time)) & " ");
      end if;
      if Options.Before_Time /= Null_Time then
         Append (Q, "AND m.time < "
                 & Ref_Of (P, +Format_Time (Options.Before_Time)) & " ");
      end if;
      if Length (Options.Sender) > 0 then
         Append (Q, "AND m.sender = "
                 & Ref_Of (P, +To_String (Options.Sender)) & " ");
      end if;
      if Length (Options.Text) > 0 then
         declare
            Quoted : constant String :=
              Quote_FTS_Query (To_String (Options.Text));
         begin
            --  Text without a single word in it (only punctuation, say)
            --  matches nothing; FTS5 would refuse the empty query, and soju
            --  fails the whole request on it (SOJU-BUGS.md).
            if Quoted = "" then
               return V;
            end if;
            Append (Q, "AND m.id IN (SELECT ROWID FROM MessageFTS WHERE " &
                       "MessageFTS MATCH " & Ref_Of (P, +Quoted) & ") ");
         end;
      end if;
      if not Options.Events then
         Append (Q, "AND m.text IS NOT NULL ");
      end if;
      Append (Q, (if Options.Take_Last then "ORDER BY m.time DESC "
                  else "ORDER BY m.time ASC "));
      Append (Q, "LIMIT "
              & Ref_Of (P, As_Bigint (Long_Long_Integer (Options.Limit))));

      Fetch (C, DB.DB, To_String (Q), P.Items (1 .. P.Count));
      Check (DB'Access);
      while Has_Row (C) loop
         begin
            V.Append (Soja.Irc.Messages.Parse_Message (Value (C, 0)));
         exception
            when Soja.Irc.Messages.Parse_Error =>
               raise Database_Error with "invalid stored message";
         end;
         Next (C);
      end loop;

      if Options.Take_Last then
         V.Reverse_Elements;
      end if;
      return V;
   end List_Messages;

   --------------------
   --  Get_Read_Receipt --
   --------------------

   overriding function Get_Read_Receipt (DB : in out Sqlite_DB;
      Network_ID : Long_Long_Integer; Name : String)
      return Read_Receipt_Access
   is
      G : Guard;
      C : Forward_Cursor;
   begin
      Acquire (G, DB.Lock);
      Fetch (C, DB.DB,
        "SELECT id, timestamp FROM ReadReceipt WHERE network = ?1 AND " &
        "target " &
        "= ?2",
        [1 => As_Bigint (Network_ID), 2 => +Name]);
      Check (DB'Access);
      if not Has_Row (C) then
         return null;
      end if;
      declare
         R : constant Read_Receipt_Access := new Read_Receipt;
      begin
         R.ID := Bigint_Value (C, 0);
         R.Target := To_Unbounded_String (Name);
         R.Timestamp := Col_Time (C, 1);
         return R;
      end;
   end Get_Read_Receipt;

   ----------------------
   --  Store_Read_Receipt --
   ----------------------

   overriding procedure Store_Read_Receipt (DB : in out Sqlite_DB;
      Network_ID : Long_Long_Integer; Receipt : in out Read_Receipt)
   is
      G : Guard;
   begin
      Acquire (G, DB.Lock);
      if Receipt.ID /= 0 then
         Execute (DB.DB,
           "UPDATE ReadReceipt SET timestamp = ?1 WHERE id = ?2",
           [1 => P_Time (Receipt.Timestamp), 2 => As_Bigint (Receipt.ID)]);
         Check (DB'Access);
      else
         Execute (DB.DB,
           "INSERT INTO ReadReceipt(network, target, timestamp) VALUES " &
           "(?1, ?2, ?3)",
           [1 => As_Bigint (Network_ID),
            2 => +To_String (Receipt.Target),
            3 => P_Time (Receipt.Timestamp)]);
         Check (DB'Access);
         Receipt.ID := Last_ID (DB'Access);
      end if;
      Commit_Check (DB'Access);
   end Store_Read_Receipt;

   ------------------------
   --  List_WebPush_Configs --
   ------------------------

   overriding function List_WebPush_Configs (DB : in out Sqlite_DB)
      return WebPush_Config_Lists.Vector
   is
      G : Guard;
      C : Forward_Cursor;
      V : WebPush_Config_Lists.Vector := WebPush_Config_Lists.Empty_Vector;
   begin
      Acquire (G, DB.Lock);
      Fetch (C, DB.DB,
        "SELECT id, vapid_key_public, vapid_key_private FROM WebPushConfig");
      Check (DB'Access);
      while Has_Row (C) loop
         declare
            Cfg : WebPush_Config;
         begin
            Cfg.ID := Bigint_Value (C, 0);
            Cfg.VAPID_Public := Unbounded_Value (C, 1);
            Cfg.VAPID_Private := Unbounded_Value (C, 2);
            V.Append (Cfg);
         end;
         Next (C);
      end loop;
      return V;
   end List_WebPush_Configs;

   ------------------------
   --  Store_WebPush_Config --
   ------------------------

   overriding procedure Store_WebPush_Config (DB : in out Sqlite_DB;
      Config : in out WebPush_Config)
   is
      G : Guard;
   begin
      Acquire (G, DB.Lock);
      if Config.ID /= 0 then
         raise Database_Error with "cannot update a WebPushConfig";
      end if;
      Execute (DB.DB,
        "INSERT INTO WebPushConfig(created_at, vapid_key_public, " &
        "vapid_key_private) VALUES (?1, ?2, ?3)",
        [1 => +Format_Time (Ada.Calendar.Clock),
         2 => +To_String (Config.VAPID_Public),
         3 => +To_String (Config.VAPID_Private)]);
      Check (DB'Access);
      Config.ID := Last_ID (DB'Access);
      Commit_Check (DB'Access);
   end Store_WebPush_Config;

   --------------------------------
   --  List_WebPush_Subscriptions --
   --------------------------------

   overriding function List_WebPush_Subscriptions (DB : in out Sqlite_DB;
      User_ID : Long_Long_Integer; Network_ID : Long_Long_Integer)
      return WebPush_Subscription_Lists.Vector
   is
      G : Guard;
      C : Forward_Cursor;
      V : WebPush_Subscription_Lists.Vector :=
        WebPush_Subscription_Lists.Empty_Vector;
   begin
      Acquire (G, DB.Lock);
      Fetch (C, DB.DB,
        "SELECT id, endpoint, created_at, updated_at, key_auth, key_p256dh, " &
        "key_vapid FROM WebPushSubscription WHERE user = ?1 AND network IS ?2",
        [1 => As_Bigint (User_ID), 2 => P_Network_Null (Network_ID)]);
      Check (DB'Access);
      while Has_Row (C) loop
         declare
            Sub : WebPush_Subscription;
         begin
            Sub.ID := Bigint_Value (C, 0);
            Sub.Endpoint := Unbounded_Value (C, 1);
            Sub.Created_At := Col_Time (C, 2);
            Sub.Updated_At := Col_Time (C, 3);
            Sub.Key_Auth := Col_Str (C, 4);
            Sub.Key_P256DH := Col_Str (C, 5);
            Sub.Key_VAPID := Col_Str (C, 6);
            V.Append (Sub);
         end;
         Next (C);
      end loop;
      return V;
   end List_WebPush_Subscriptions;

   --------------------------------
   --  Store_WebPush_Subscription --
   --------------------------------

   overriding procedure Store_WebPush_Subscription (DB : in out Sqlite_DB;
      User_ID : Long_Long_Integer; Network_ID : Long_Long_Integer;
      Sub : in out WebPush_Subscription)
   is
      G : Guard;
   begin
      Acquire (G, DB.Lock);
      if Sub.ID /= 0 then
         Execute (DB.DB,
           "UPDATE WebPushSubscription SET updated_at = ?1, key_auth = ?2, " &
           "key_p256dh = ?3, key_vapid = ?4 WHERE id = ?5",
           [1 => +Format_Time (Ada.Calendar.Clock),
            2 => P_Str (Sub.Key_Auth),
            3 => P_Str (Sub.Key_P256DH),
            4 => P_Str (Sub.Key_VAPID),
            5 => As_Bigint (Sub.ID)]);
         Check (DB'Access);
      else
         Execute (DB.DB,
           "INSERT INTO WebPushSubscription(created_at, updated_at, user, " &
           "network, endpoint, key_auth, key_p256dh, key_vapid) VALUES " &
           "(?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)",
           [1 => +Format_Time (Ada.Calendar.Clock),
            2 => +Format_Time (Ada.Calendar.Clock),
            3 => As_Bigint (User_ID),
            4 => P_Network_Null (Network_ID),
            5 => +To_String (Sub.Endpoint),
            6 => P_Str (Sub.Key_Auth),
            7 => P_Str (Sub.Key_P256DH),
            8 => P_Str (Sub.Key_VAPID)]);
         Check (DB'Access);
         Sub.ID := Last_ID (DB'Access);
      end if;
      Commit_Check (DB'Access);
   end Store_WebPush_Subscription;

   --------------------------------
   --  Delete_WebPush_Subscription --
   --------------------------------

   overriding procedure Delete_WebPush_Subscription (DB : in out Sqlite_DB;
      ID : Long_Long_Integer)
   is
      G : Guard;
   begin
      Acquire (G, DB.Lock);
      Execute (DB.DB, "DELETE FROM WebPushSubscription WHERE id = ?1",
        [1 => As_Bigint (ID)]);
      Check (DB'Access);
      Commit_Check (DB'Access);
   end Delete_WebPush_Subscription;

end Soja.Database.Sqlite;
