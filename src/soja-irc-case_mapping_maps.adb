pragma Ada_2022;

package body Soja.Irc.Case_Mapping_Maps is

   use Ada.Strings.Unbounded;

   function Fold (M : Map; Name : String) return String is
   begin
      return Case_Mapping.Fold (M.CM, Name);
   end Fold;

   ------------
   -- New_Map --
   ------------

   function New_Map (CM : Case_Mapping.Kind) return Map is
   begin
      return (Data => Entry_Maps.Empty_Map, CM => CM);
   end New_Map;

   ---------
   -- Has --
   ---------

   function Has (M : Map; Name : String) return Boolean is
   begin
      return M.Data.Contains (Fold (M, Name));
   end Has;

   ------------
   -- Length --
   ------------

   function Length (M : Map) return Natural is
   begin
      return Natural (M.Data.Length);
   end Length;

   ---------
   -- Get --
   ---------

   function Get (M : Map; Name : String) return Element is
      C : constant Entry_Maps.Cursor := M.Data.Find (Fold (M, Name));
   begin
      if Entry_Maps.Has_Element (C) then
         return Entry_Maps.Element (C).Value;
      end if;
      return Null_Element;
   end Get;

   ---------
   -- Set --
   ---------

   procedure Set (M : in out Map; Name : String; Value : Element) is
      Key : constant String := Fold (M, Name);
      C   : constant Entry_Maps.Cursor := M.Data.Find (Key);
   begin
      if Entry_Maps.Has_Element (C) then
         declare
            E : Entry_Record := Entry_Maps.Element (C);
         begin
            E.Value := Value;
            M.Data.Replace_Element (C, E);
         end;
      else
         M.Data.Insert
           (Key, (Original_Key => To_Unbounded_String (Name), Value => Value));
      end if;
   end Set;

   ---------
   -- Del --
   ---------

   procedure Del (M : in out Map; Name : String) is
   begin
      M.Data.Exclude (Fold (M, Name));
   end Del;

   --------------
   -- For_Each --
   --------------

   procedure For_Each
     (M : Map;
      Process : not null access procedure (Name : String; Value : Element))
   is
      C : Entry_Maps.Cursor := M.Data.First;
   begin
      while Entry_Maps.Has_Element (C) loop
         declare
            E : constant Entry_Record := Entry_Maps.Element (C);
         begin
            Process (To_String (E.Original_Key), E.Value);
         end;
         Entry_Maps.Next (C);
      end loop;
   end For_Each;

   ----------------------
   -- Set_Case_Mapping --
   ----------------------

   procedure Set_Case_Mapping (M : in out Map; CM : Case_Mapping.Kind) is
      Old      : constant Entry_Maps.Map := M.Data;
      New_Data : Entry_Maps.Map := Entry_Maps.Empty_Map;
      C        : Entry_Maps.Cursor := Old.First;
   begin
      M.CM := CM;
      while Entry_Maps.Has_Element (C) loop
         declare
            E : constant Entry_Record := Entry_Maps.Element (C);
         begin
            New_Data.Include (Fold (M, To_String (E.Original_Key)), E);
         end;
         Entry_Maps.Next (C);
      end loop;
      M.Data := New_Data;
   end Set_Case_Mapping;

end Soja.Irc.Case_Mapping_Maps;
