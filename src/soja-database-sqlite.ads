--  Soja.Database.Sqlite — the SQLite implementation of Soja.Database's
--  Database interface, a port of database/sqlite.go.  Built on gnatcoll-db
--  (gnatcoll-sql + gnatcoll-sqlite, which bundle the sqlite3 C API).  There is
--  no PostgreSQL backend: v1 is SQLite-only.
--
--  Like Go's OpenSqliteDB (which uses SetMaxOpenConns(1)), a Sqlite_DB owns a
--  single connection and serialises all access through a mutex.  This is what
--  makes ":memory:" usable and keeps multi-statement operations (DeleteUser,
--  DeleteNetwork, StoreClientDeliveryReceipts) atomic.
--
--  The message-store methods are deferred until Soja.Irc.Message is ported.
pragma Ada_2022;

private with Ada.Finalization;
private with GNATCOLL.SQL.Exec;

package Soja.Database.Sqlite is

   use Soja.Database;

   type Sqlite_DB is new Database_Interface with private;

   --  Open the SQLite database at Source (a file path, or ":memory:").
   --  Runs the schema/migrations.  Raises Database_Error on failure.
   function Open_Sqlite_DB (Source : String) return Database_Access;

   --  An in-memory database (Go's OpenTempSqliteDB).
   function Open_Temp_Sqlite_DB return Database_Access;

   overriding procedure Close (DB : in out Sqlite_DB);

   overriding function Stats (DB : in out Sqlite_DB) return Database_Stats;

   overriding function List_Users (DB : in out Sqlite_DB)
      return User_Lists.Vector;
   overriding function Get_User (DB : in out Sqlite_DB; Username : String)
      return User;
   overriding procedure Store_User (DB : in out Sqlite_DB; U : in out User);
   overriding procedure Delete_User (DB : in out Sqlite_DB;
      ID : Long_Long_Integer);
   overriding function List_Inactive_Usernames
     (DB : in out Sqlite_DB; Limit : Time) return Username_Lists.Vector;

   overriding function List_Networks (DB : in out Sqlite_DB;
      User_ID : Long_Long_Integer) return Network_Lists.Vector;
   overriding procedure Store_Network (DB : in out Sqlite_DB;
      User_ID : Long_Long_Integer; Net : in out Network);
   overriding procedure Delete_Network (DB : in out Sqlite_DB;
      ID : Long_Long_Integer);
   overriding function List_Channels (DB : in out Sqlite_DB;
      Network_ID : Long_Long_Integer) return Channel_Lists.Vector;
   overriding procedure Store_Channel (DB : in out Sqlite_DB;
      Network_ID : Long_Long_Integer; Ch : in out Channel);
   overriding procedure Delete_Channel (DB : in out Sqlite_DB;
      ID : Long_Long_Integer);

   overriding function List_Delivery_Receipts (DB : in out Sqlite_DB;
      Network_ID : Long_Long_Integer) return Delivery_Receipt_Lists.Vector;
   overriding procedure Store_Client_Delivery_Receipts (DB : in out Sqlite_DB;
      Network_ID : Long_Long_Integer; Client : String;
      Receipts : in out Delivery_Receipt_Lists.Vector);

   overriding function Get_Read_Receipt (DB : in out Sqlite_DB;
      Network_ID : Long_Long_Integer; Name : String)
      return Read_Receipt_Access;
   overriding procedure Store_Read_Receipt (DB : in out Sqlite_DB;
      Network_ID : Long_Long_Integer; Receipt : in out Read_Receipt);

   overriding function List_WebPush_Configs (DB : in out Sqlite_DB)
      return WebPush_Config_Lists.Vector;
   overriding procedure Store_WebPush_Config (DB : in out Sqlite_DB;
      Config : in out WebPush_Config);

   overriding function List_WebPush_Subscriptions (DB : in out Sqlite_DB;
      User_ID : Long_Long_Integer; Network_ID : Long_Long_Integer)
      return WebPush_Subscription_Lists.Vector;
   overriding procedure Store_WebPush_Subscription (DB : in out Sqlite_DB;
      User_ID : Long_Long_Integer; Network_ID : Long_Long_Integer;
      Sub : in out WebPush_Subscription);
   overriding procedure Delete_WebPush_Subscription (DB : in out Sqlite_DB;
      ID : Long_Long_Integer);

private

   --  A binary mutex serialising access to the single connection.
   protected type Mutex is
      entry Seize;
      procedure Release;
   private
      Locked : Boolean := False;
   end Mutex;

   type Mutex_Access is access Mutex;

   --  Exception-safe lock holder: Finalize releases the mutex when the
   --  declaring scope is left (normally or via an exception).  It must live in
   --  the spec so Finalize is a proper dispatching primitive.
   type Guard is new Ada.Finalization.Limited_Controlled with record
      M : Mutex_Access;
   end record;

   overriding procedure Finalize (G : in out Guard);
   procedure Acquire (G : in out Guard; M : Mutex_Access);

   type Sqlite_DB is new Database_Interface with record
      Description : GNATCOLL.SQL.Exec.Database_Description;
      DB          : GNATCOLL.SQL.Exec.Database_Connection;
      Lock        : Mutex_Access;
   end record;

end Soja.Database.Sqlite;
