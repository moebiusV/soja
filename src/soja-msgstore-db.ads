--  Soja.Msgstore.Db -- msgstore/db.go: a persistent message store that keeps
--  the messages in the soju database (the Message / MessageTarget tables).
--  It has chat history and full-text search.  A message's ID is its row ID.
pragma Ada_2022;

with Soja.Database;

package Soja.Msgstore.Db is

   type Db_Store is new Store with private;

   --  The store of one user; it uses (and does not own) DB.
   function New_Db_Store (DB : Soja.Database.Database_Access)
      return Store_Access;

   --  IsDBStore, for the places that treat a persistent store differently.
   function Is_Db_Store (S : Store'Class) return Boolean;

   overriding procedure Close (S : in out Db_Store);

   overriding function Supports_Chat_History (S : Db_Store) return Boolean;
   overriding function Supports_Search (S : Db_Store) return Boolean;

   overriding function Last_Msg_ID
     (S : in out Db_Store; Network : Soja.Database.Network;
      Entity : String; T : Ada.Calendar.Time) return String;

   overriding function Load_Latest_ID
     (S : in out Db_Store; ID : String; Options : Load_Message_Options)
      return Soja.Irc.Messages.Message_Vectors.Vector;

   overriding function Append
     (S : in out Db_Store; Network : Soja.Database.Network;
      Entity : String; Msg : Soja.Irc.Messages.Message) return String;

   overriding function List_Targets
     (S : in out Db_Store; Network : Soja.Database.Network;
      Start, End_Time : Ada.Calendar.Time; Limit : Natural; Events : Boolean)
      return Target_Vectors.Vector;

   overriding function Load_Before_Time
     (S : in out Db_Store; Start, End_Time : Ada.Calendar.Time;
      Options : Load_Message_Options) return Message_Vector;

   overriding function Load_After_Time
     (S : in out Db_Store; Start, End_Time : Ada.Calendar.Time;
      Options : Load_Message_Options) return Message_Vector;

   overriding function Search
     (S : in out Db_Store; Network : Soja.Database.Network;
      Options : Search_Options) return Message_Vector;

private

   type Db_Store is new Store with record
      DB : Soja.Database.Database_Access;
   end record;

end Soja.Msgstore.Db;
