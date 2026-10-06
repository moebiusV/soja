--  Soja.Database — the data model and helpers of database/database.go: the
--  User / Network / Channel / receipts types, the SQL-free helper functions,
--  and the bcrypt password handling.  The Database interface and the SQLite
--  implementation follow in a later slice (SQLite-only; PostgreSQL is
--  dropped for v1).
pragma Ada_2022;

with Ada.Calendar;
with Ada.Containers.Indefinite_Vectors;
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

end Soja.Database;
