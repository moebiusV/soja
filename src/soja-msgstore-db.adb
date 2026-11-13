pragma Ada_2022;

with Ada.Exceptions;
with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;
with Interfaces;

with Soja.Bare;

package body Soja.Msgstore.Db is

   use type Soja.Database.Time;

   function New_Db_Store (DB : Soja.Database.Database_Access)
      return Store_Access is
   begin
      return new Db_Store'(Store with DB => DB);
   end New_Db_Store;

   function Is_Db_Store (S : Store'Class) return Boolean is
     (S in Db_Store);

   --  formatDBMsgID / parseDBMsgID: the ID is the BARE uint of the row ID.
   function Format_DB_Msg_ID
     (Net_ID : Long_Long_Integer; Target : String; Row : Long_Long_Integer)
      return String
   is
      Buf : Ada.Strings.Unbounded.Unbounded_String;
   begin
      Soja.Bare.Write_Uint (Buf, Interfaces.Unsigned_64 (Row));
      return Format_Msg_ID (Net_ID, Target, Msg_ID_DB, To_String (Buf));
   end Format_DB_Msg_ID;

   function Parse_DB_Msg_ID (S : String) return Long_Long_Integer is
      Net_ID : Long_Long_Integer;
      Target : Unbounded_String;
      Bytes  : Unbounded_String;
   begin
      Parse_Msg_ID (S, Net_ID, Target, Bytes, Expected => Msg_ID_DB);
      declare
         R : Soja.Bare.Reader := Soja.Bare.New_Reader (To_String (Bytes));
      begin
         return Long_Long_Integer (Soja.Bare.Read_Uint (R));
      exception
         when E : Soja.Bare.Bare_Error =>
            raise Store_Error with
              "invalid internal message ID: "
              & Ada.Exceptions.Exception_Message (E);
      end;
   end Parse_DB_Msg_ID;

   --  A database failure is a store failure.
   function Wrap (E : Ada.Exceptions.Exception_Occurrence) return String is
     (Ada.Exceptions.Exception_Message (E));

   overriding procedure Close (S : in out Db_Store) is
      pragma Unreferenced (S);
   begin
      null;   --  the database is not ours
   end Close;

   overriding function Supports_Chat_History (S : Db_Store) return Boolean is
      pragma Unreferenced (S);
   begin
      return True;
   end Supports_Chat_History;

   overriding function Supports_Search (S : Db_Store) return Boolean is
      pragma Unreferenced (S);
   begin
      return True;
   end Supports_Search;

   overriding function Last_Msg_ID
     (S : in out Db_Store; Network : Soja.Database.Network;
      Entity : String; T : Ada.Calendar.Time) return String
   is
      pragma Unreferenced (T);   --  (soju: "what should we do with t?")
   begin
      return Format_DB_Msg_ID
        (Network.ID, Entity,
         Soja.Database.Get_Message_Last_ID (S.DB.all, Network.ID, Entity));
   exception
      when E : Soja.Database.Database_Error =>
         raise Store_Error with Wrap (E);
   end Last_Msg_ID;

   overriding function Load_Latest_ID
     (S : in out Db_Store; ID : String; Options : Load_Message_Options)
      return Soja.Irc.Messages.Message_Vectors.Vector
   is
      Row : constant Long_Long_Integer := Parse_DB_Msg_ID (ID);
   begin
      return Soja.Database.List_Messages
        (S.DB.all, Options.Network.ID, To_String (Options.Entity),
         (After_ID => Row, Limit => Options.Limit, Take_Last => True,
          others => <>));
   exception
      when E : Soja.Database.Database_Error =>
         raise Store_Error with Wrap (E);
   end Load_Latest_ID;

   overriding function Append
     (S : in out Db_Store; Network : Soja.Database.Network;
      Entity : String; Msg : Soja.Irc.Messages.Message) return String
   is
      Msgs : Soja.Irc.Messages.Message_Vectors.Vector;
   begin
      Msgs.Append (Msg);
      declare
         Ids : constant Soja.Database.Id_Lists.Vector :=
           Soja.Database.Store_Messages (S.DB.all, Network.ID, Entity, Msgs);
      begin
         return Format_DB_Msg_ID (Network.ID, Entity, Ids (1));
      end;
   exception
      when E : Soja.Database.Database_Error =>
         raise Store_Error with Wrap (E);
   end Append;

   overriding function List_Targets
     (S : in out Db_Store; Network : Soja.Database.Network;
      Start, End_Time : Ada.Calendar.Time; Limit : Natural; Events : Boolean)
      return Target_Vectors.Vector
   is
      use Ada.Calendar;
      Opts : Soja.Database.Message_Options;
      Result : Target_Vectors.Vector;
   begin
      if Start < End_Time then
         Opts := (After_Time => Start, Before_Time => End_Time,
                  Limit => Limit, Events => Events, others => <>);
      else
         Opts := (After_Time => End_Time, Before_Time => Start,
                  Limit => Limit, Events => Events, Take_Last => True,
                  others => <>);
      end if;
      for T of Soja.Database.List_Message_Last_Per_Target
                 (S.DB.all, Network.ID, Opts)
      loop
         Result.Append
           (Chat_History_Target'(Name => T.Name,
                                 Latest_Message => T.Latest_Message));
      end loop;
      return Result;
   exception
      when E : Soja.Database.Database_Error =>
         raise Store_Error with Wrap (E);
   end List_Targets;

   overriding function Load_Before_Time
     (S : in out Db_Store; Start, End_Time : Ada.Calendar.Time;
      Options : Load_Message_Options) return Message_Vector is
   begin
      return Soja.Database.List_Messages
        (S.DB.all, Options.Network.ID, To_String (Options.Entity),
         (After_Time => End_Time, Before_Time => Start,
          Limit => Options.Limit, Events => Options.Events,
          Take_Last => True, others => <>));
   exception
      when E : Soja.Database.Database_Error =>
         raise Store_Error with Wrap (E);
   end Load_Before_Time;

   overriding function Load_After_Time
     (S : in out Db_Store; Start, End_Time : Ada.Calendar.Time;
      Options : Load_Message_Options) return Message_Vector is
   begin
      return Soja.Database.List_Messages
        (S.DB.all, Options.Network.ID, To_String (Options.Entity),
         (After_Time => Start, Before_Time => End_Time,
          Limit => Options.Limit, Events => Options.Events,
          others => <>));
   exception
      when E : Soja.Database.Database_Error =>
         raise Store_Error with Wrap (E);
   end Load_After_Time;

   overriding function Search
     (S : in out Db_Store; Network : Soja.Database.Network;
      Options : Search_Options) return Message_Vector is
   begin
      return Soja.Database.List_Messages
        (S.DB.all, Network.ID, To_String (Options.In_Target),
         (After_Time => Options.Start, Before_Time => Options.End_Time,
          Limit => Options.Limit, Sender => Options.From,
          Text => Options.Text, Take_Last => True, others => <>));
   exception
      when E : Soja.Database.Database_Error =>
         raise Store_Error with Wrap (E);
   end Search;

end Soja.Msgstore.Db;
