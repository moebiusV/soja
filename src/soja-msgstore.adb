pragma Ada_2022;

with Ada.Exceptions;
with Interfaces;

with Soja.Bare;
with Soja.Base64;

package body Soja.Msgstore is

   use Ada.Strings.Unbounded;
   use Interfaces;

   -------------------
   -- Format_Msg_ID --
   -------------------

   function Format_Msg_ID
     (Net_ID : Long_Long_Integer; Target : String; Typ : Msg_ID_Type;
      Body_Bytes : String) return String
   is
      Buf : Unbounded_String;
   begin
      Soja.Bare.Write_Uint (Buf, Unsigned_64 (Msg_ID_Version));
      Soja.Bare.Write_Int (Buf, Integer_64 (Net_ID));
      Soja.Bare.Write_String (Buf, Target);
      Soja.Bare.Write_Uint (Buf, Unsigned_64 (Typ));
      Append (Buf, Body_Bytes);
      return Soja.Base64.Encode
        (To_String (Buf), URL_Safe => True, Padded => False);
   end Format_Msg_ID;

   ------------------
   -- Parse_Msg_ID --
   ------------------

   procedure Parse_Msg_ID
     (S          : String;
      Net_ID     : out Long_Long_Integer;
      Target     : out Unbounded_String;
      Body_Bytes : out Unbounded_String;
      Expected   : Msg_ID_Type := Msg_ID_None)
   is
      Valid : Boolean;
      Raw   : constant String :=
        Soja.Base64.Decode (S, Valid, URL_Safe => True, Padded => False);
   begin
      Net_ID := 0;
      Target := Null_Unbounded_String;
      Body_Bytes := Null_Unbounded_String;
      if not Valid then
         raise Store_Error with
           "invalid internal message ID: illegal base64 data";
      end if;

      declare
         R       : Soja.Bare.Reader := Soja.Bare.New_Reader (Raw);
         Version : Unsigned_64;
         Network : Integer_64;
         Typ     : Unsigned_64;
      begin
         Version := Soja.Bare.Read_Uint (R);
         Network := Soja.Bare.Read_Int (R);
         Target := To_Unbounded_String (Soja.Bare.Read_String (R));
         Typ := Soja.Bare.Read_Uint (R);

         if Version /= Unsigned_64 (Msg_ID_Version) then
            raise Store_Error with
              "invalid internal message ID: got version"
              & Unsigned_64'Image (Version) & ", want"
              & Integer'Image (Msg_ID_Version);
         end if;
         if Expected /= Msg_ID_None and then Typ /= Unsigned_64 (Expected)
         then
            raise Store_Error with
              "invalid internal message ID: got type"
              & Unsigned_64'Image (Typ) & ", want"
              & Msg_ID_Type'Image (Expected);
         end if;

         Net_ID := Long_Long_Integer (Network);
         Body_Bytes := To_Unbounded_String (Soja.Bare.Rest (R));
      exception
         when E : Soja.Bare.Bare_Error =>
            raise Store_Error with
              "invalid internal message ID: "
              & Ada.Exceptions.Exception_Message (E);
      end;
   end Parse_Msg_ID;

   --  The operations a store may not have (see Supports_*).

   function List_Targets
     (S : in out Store; Network : Soja.Database.Network;
      Start, End_Time : Ada.Calendar.Time; Limit : Natural; Events : Boolean)
      return Target_Vectors.Vector
   is
      pragma Unreferenced (S, Network, Start, End_Time, Limit, Events);
   begin
      raise Store_Error with "this store has no chat history";
      return Target_Vectors.Empty_Vector;
   end List_Targets;

   function Load_Before_Time
     (S : in out Store; Start, End_Time : Ada.Calendar.Time;
      Options : Load_Message_Options) return Message_Vector
   is
      pragma Unreferenced (S, Start, End_Time, Options);
   begin
      raise Store_Error with "this store has no chat history";
      return Soja.Irc.Messages.Message_Vectors.Empty_Vector;
   end Load_Before_Time;

   function Load_After_Time
     (S : in out Store; Start, End_Time : Ada.Calendar.Time;
      Options : Load_Message_Options) return Message_Vector
   is
      pragma Unreferenced (S, Start, End_Time, Options);
   begin
      raise Store_Error with "this store has no chat history";
      return Soja.Irc.Messages.Message_Vectors.Empty_Vector;
   end Load_After_Time;

   function Search
     (S : in out Store; Network : Soja.Database.Network;
      Options : Search_Options) return Message_Vector
   is
      pragma Unreferenced (S, Network, Options);
   begin
      raise Store_Error with "this store cannot search";
      return Soja.Irc.Messages.Message_Vectors.Empty_Vector;
   end Search;

   procedure Rename_Network
     (S : in out Store; Old_Net, New_Net : Soja.Database.Network)
   is
      pragma Unreferenced (S, Old_Net, New_Net);
   begin
      raise Store_Error with "this store does not need network renames";
   end Rename_Network;

end Soja.Msgstore;
