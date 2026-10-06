pragma Ada_2022;

with Ada.Containers.Indefinite_Hashed_Maps;
with Ada.Strings.Hash;
with Ada.Strings.Unbounded;

with Soja.Irc.Case_Mapping;

--  xirc.CaseMappingMap[V]: a map whose keys are canonicalised with an IRC
--  case-mapping, so "Nick" and "nick" address the same entry.  The original
--  (unfolded) key is retained and returned by For_Each, matching Go.
--
--  Null_Element is the value Get returns for an absent key (Go's zero value;
--  for pointer instantiations this is null).
generic
   type Element is private;
   Null_Element : Element;
package Soja.Irc.Case_Mapping_Maps is

   type Map is tagged private;

   function New_Map (CM : Case_Mapping.Kind) return Map;

   function Has (M : Map; Name : String) return Boolean;
   function Length (M : Map) return Natural;
   function Get (M : Map; Name : String) return Element;
   procedure Set (M : in out Map; Name : String; Value : Element);
   procedure Del (M : in out Map; Name : String);
   procedure For_Each
     (M : Map;
      Process : not null access procedure (Name : String; Value : Element));
   procedure Set_Case_Mapping (M : in out Map; CM : Case_Mapping.Kind);

private

   type Entry_Record is record
      Original_Key : Ada.Strings.Unbounded.Unbounded_String;
      Value        : Element;
   end record;

   package Entry_Maps is new Ada.Containers.Indefinite_Hashed_Maps
     (Key_Type        => String,
      Element_Type    => Entry_Record,
      Hash            => Ada.Strings.Hash,
      Equivalent_Keys => "=");

   type Map is tagged record
      Data : Entry_Maps.Map;
      CM   : Case_Mapping.Kind;
   end record;

end Soja.Irc.Case_Mapping_Maps;
