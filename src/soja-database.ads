--  Soja.Database — the data model and helpers of database/database.go: the
--  User / Network / Channel / receipts types, the SQL-free helper functions,
--  and the bcrypt password handling.  The Database interface and the SQLite
--  implementation follow in a later slice (SQLite-only; PostgreSQL is
--  dropped for v1).
pragma Ada_2022;

with Ada.Calendar;
with Ada.Containers.Indefinite_Vectors;
with Ada.Containers.Vectors;
with Ada.Strings.Unbounded;

package Soja.Database is

   use Ada.Strings.Unbounded;

   Database_Error : exception;

   --  A timestamp: Go's time.Time, the zero value meaning "never".
   subtype Time is Ada.Calendar.Time;

   --  Message filtering policy (a Channel's RelayDetached/ReattachOn/DetachOn
   --  and DetachAfter is a duration).
   type Message_Filter is
     (Filter_Default, Filter_None, Filter_Highlight, Filter_Message);

   --  A network's connect commands ([]string in Go).
   package Connect_Command_Vectors is new Ada.Containers.Indefinite_Vectors
     (Positive, Unbounded_String);

   ---------
   -- User --
   ---------

   type User is record
      ID                       : Long_Long_Integer := 0;
      Username                 : Unbounded_String;
      Password                 : Unbounded_String;   -- bcrypt hash
      Nick                     : Unbounded_String;
      Realname                 : Unbounded_String;
      Admin                    : Boolean := False;
      Enabled                  : Boolean := False;
      Downstream_Interacted_At : Time;               -- zero = never
   end record;

   function New_User (Username : String) return User;

   --  Hash Password into U.Password (bcrypt, default cost).  Raises
   --  Database_Error on failure (e.g. an over-long password).
   procedure Set_Password (U : in out User; Password : String);

   --  Verify Password against U.Password.  Raises Database_Error when password
   --  auth is disabled or the password is wrong.  Returns True when the hash
   --  was re-computed at the default cost (a cheap stored hash was upgraded).
   function Check_Password (U : in out User; Password : String) return Boolean;

   -----------
   -- SASL --
   -----------

   type SASL is record
      Mechanism      : Unbounded_String;
      Plain_Username : Unbounded_String;
      Plain_Password : Unbounded_String;
      --  TLS client-certificate auth (DER cert, PKCS#8 key).
      External_Cert  : Unbounded_String;
      External_Key   : Unbounded_String;
   end record;

   -----------
   -- Network --
   -----------

   type Network is record
      ID              : Long_Long_Integer := 0;
      Name            : Unbounded_String;
      Addr            : Unbounded_String;
      Nick            : Unbounded_String;
      Username        : Unbounded_String;
      Realname        : Unbounded_String;
      Pass            : Unbounded_String;
      Connect_Commands : Connect_Command_Vectors.Vector;
      Cert_FP         : Unbounded_String;
      SASL            : Soja.Database.SASL;
      Auto_Away       : Boolean := False;
      Enabled         : Boolean := False;
   end record;

   function New_Network (Addr : String) return Network;

   function Get_Name (Net : Network) return String;

   function Get_Nick (U : User; Net : Network) return String;
   function Get_Username (U : User; Net : Network) return String;
   function Get_Realname (U : User; Net : Network) return String;

   -----------
   -- Channel --
   -----------

   type Channel is record
      ID                     : Long_Long_Integer := 0;
      Name                   : Unbounded_String;
      Key                    : Unbounded_String;
      Detached               : Boolean := False;
      Detached_Internal_Msg_ID : Unbounded_String;
      Relay_Detached         : Message_Filter := Filter_Default;
      Reattach_On            : Message_Filter := Filter_Default;
      Detach_After           : Duration := 0.0;
      Detach_On              : Message_Filter := Filter_Default;
   end record;

   ------------
   -- Receipts --
   ------------

   type Delivery_Receipt is record
      ID             : Long_Long_Integer := 0;
      Target         : Unbounded_String;   -- channel or nick
      Client         : Unbounded_String;
      Internal_Msg_ID : Unbounded_String;
   end record;

   type Read_Receipt is record
      ID        : Long_Long_Integer := 0;
      Target    : Unbounded_String;   -- channel or nick
      Timestamp : Time;
   end record;

   ------------
   -- Web Push --
   ------------

   type WebPush_Config is record
      ID            : Long_Long_Integer := 0;
      VAPID_Public  : Unbounded_String;
      VAPID_Private : Unbounded_String;
   end record;

   type WebPush_Subscription is record
      ID         : Long_Long_Integer := 0;
      Endpoint   : Unbounded_String;
      Created_At : Time;
      Updated_At : Time;
      Key_Auth   : Unbounded_String;
      Key_P256DH : Unbounded_String;
      Key_VAPID  : Unbounded_String;
   end record;

   -----------
   -- Messages --
   -----------

   type Message_Target is record
      Name           : Unbounded_String;
      Latest_Message : Time;
   end record;

   type Message_Options is record
      After_ID   : Long_Long_Integer := 0;
      After_Time : Time;
      Before_Time : Time;
      Limit      : Integer := 0;
      Events     : Boolean := False;
      Sender     : Unbounded_String;
      Text       : Unbounded_String;
      Take_Last  : Boolean := False;
   end record;

   --  Result containers (Go's []T slices).
   package User_Lists is new Ada.Containers.Vectors (Positive, User);
   package Network_Lists is new Ada.Containers.Vectors (Positive, Network);
   package Channel_Lists is new Ada.Containers.Vectors (Positive, Channel);
   package Delivery_Receipt_Lists is
     new Ada.Containers.Vectors (Positive, Delivery_Receipt);
   package WebPush_Config_Lists is
     new Ada.Containers.Vectors (Positive, WebPush_Config);
   package WebPush_Subscription_Lists is
     new Ada.Containers.Vectors (Positive, WebPush_Subscription);
   package Username_Lists is
     new Ada.Containers.Indefinite_Vectors (Positive, Unbounded_String);

   Not_Found : exception;   --  a lookup returned no row (sql.ErrNoRows)

   type Read_Receipt_Access is access all Read_Receipt;

   type Database_Stats is record
      Users    : Long_Long_Integer := 0;
      Networks : Long_Long_Integer := 0;
      Channels : Long_Long_Integer := 0;
   end record;

   --  The Database interface (database/database.go).  The implementation is
   --  SQLite-only (PostgreSQL is dropped); the message-store methods
   --  (StoreMessages, ListMessages, ListMessageLastPerTarget,
   --  GetMessageLastID) are deferred until Soja.Irc.Message is ported.
   type Database_Interface is abstract tagged null record;
   type Database_Access is access all Database_Interface'Class;

   procedure Close (DB : in out Database_Interface) is abstract;

   function Stats (DB : in out Database_Interface) return Database_Stats
     is abstract;

   function List_Users (DB : in out Database_Interface)
      return User_Lists.Vector is abstract;
   function Get_User (DB : in out Database_Interface; Username : String)
      return User is abstract;
   procedure Store_User (DB : in out Database_Interface; U : in out User)
     is abstract;
   procedure Delete_User (DB : in out Database_Interface;
      ID : Long_Long_Integer) is abstract;
   function List_Inactive_Usernames
     (DB : in out Database_Interface; Limit : Time)
      return Username_Lists.Vector is abstract;

   function List_Networks (DB : in out Database_Interface;
      User_ID : Long_Long_Integer) return Network_Lists.Vector is abstract;
   procedure Store_Network (DB : in out Database_Interface;
      User_ID : Long_Long_Integer; Net : in out Network) is abstract;
   procedure Delete_Network (DB : in out Database_Interface;
      ID : Long_Long_Integer) is abstract;
   function List_Channels (DB : in out Database_Interface;
      Network_ID : Long_Long_Integer) return Channel_Lists.Vector is abstract;
   procedure Store_Channel (DB : in out Database_Interface;
      Network_ID : Long_Long_Integer; Ch : in out Channel) is abstract;
   procedure Delete_Channel (DB : in out Database_Interface;
      ID : Long_Long_Integer) is abstract;

   function List_Delivery_Receipts (DB : in out Database_Interface;
      Network_ID : Long_Long_Integer)
      return Delivery_Receipt_Lists.Vector is abstract;
   procedure Store_Client_Delivery_Receipts (DB : in out Database_Interface;
      Network_ID : Long_Long_Integer; Client : String;
      Receipts : in out Delivery_Receipt_Lists.Vector) is abstract;

   function Get_Read_Receipt (DB : in out Database_Interface;
      Network_ID : Long_Long_Integer; Name : String)
      return Read_Receipt_Access is abstract;
   procedure Store_Read_Receipt (DB : in out Database_Interface;
      Network_ID : Long_Long_Integer; Receipt : in out Read_Receipt)
     is abstract;

   function List_WebPush_Configs (DB : in out Database_Interface)
      return WebPush_Config_Lists.Vector is abstract;
   procedure Store_WebPush_Config (DB : in out Database_Interface;
      Config : in out WebPush_Config) is abstract;

   function List_WebPush_Subscriptions (DB : in out Database_Interface;
      User_ID : Long_Long_Integer; Network_ID : Long_Long_Integer)
      return WebPush_Subscription_Lists.Vector is abstract;
   procedure Store_WebPush_Subscription (DB : in out Database_Interface;
      User_ID : Long_Long_Integer; Network_ID : Long_Long_Integer;
      Sub : in out WebPush_Subscription) is abstract;
   procedure Delete_WebPush_Subscription (DB : in out Database_Interface;
      ID : Long_Long_Integer) is abstract;

   --  Go's time.Time{} zero value: means "never"/"unset".
   Null_Time : constant Time := Ada.Calendar.Time_Of (1901, 1, 1, 0.0);

end Soja.Database;
