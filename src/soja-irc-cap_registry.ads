pragma Ada_2022;

with Ada.Containers.Indefinite_Ordered_Maps;
with Ada.Containers.Indefinite_Ordered_Sets;

--  IRCv3 capability registry, translated from soju's xirc/caps.go.  A
--  capability is either available (with an optional value string) or enabled
--  (a plain set); deleting a capability clears both.
package Soja.Irc.Cap_Registry is

   type Registry is private;

   function New_Registry return Registry;

   function Is_Available (R : Registry; Name : String) return Boolean;

   function Is_Enabled (R : Registry; Name : String) return Boolean;

   procedure Set_Available (R : in out Registry; Name, Value : String);

   function Value (R : Registry; Name : String) return String;

   procedure Set_Enabled
     (R : in out Registry; Name : String; Enabled : Boolean);

   procedure Delete (R : in out Registry; Name : String);

   --  Iterate (in name order) over the available capabilities with their
   --  values, and over the enabled ones.
   procedure For_Each_Available
     (R : Registry;
      Process : not null access procedure (Name, Value : String));
   procedure For_Each_Enabled
     (R : Registry;
      Process : not null access procedure (Name : String));

private

   package Value_Maps is new Ada.Containers.Indefinite_Ordered_Maps
     (Key_Type     => String,
      Element_Type => String);

   package Name_Sets is new Ada.Containers.Indefinite_Ordered_Sets
     (Element_Type => String);

   type Registry is record
      Available : Value_Maps.Map;
      Enabled   : Name_Sets.Set;
   end record;

end Soja.Irc.Cap_Registry;
