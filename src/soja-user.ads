pragma Ada_2022;

with Ada.Containers.Indefinite_Hashed_Maps;
with Ada.Strings.Hash;
with Ada.Strings.Unbounded;

with Soja.Irc.Case_Mapping;
with Soja.Irc.Case_Mapping_Maps;

--  Soja.User — user.go.  This first slice carries deliveredStore, the
--  per-target/per-client delivery-receipt map; the user and network structs
--  and their event loop follow.
package Soja.User is

   --  deliveredStore: per-target, per-client message delivery receipts
   --  (client name -> msg ID), keyed by casemapped target.
   type Delivered_Store is private;

   function New_Delivered_Store
     (CM : Soja.Irc.Case_Mapping.Kind) return Delivered_Store;

   function Has_Target (DS : Delivered_Store; Target : String) return Boolean;

   function Load_ID (DS : Delivered_Store; Target, Client_Name : String)
      return String;

   procedure Store_ID (DS : in out Delivered_Store;
      Target, Client_Name, Msg_ID : String);

   procedure Set_Case_Mapping
     (DS : in out Delivered_Store; CM : Soja.Irc.Case_Mapping.Kind);

   procedure For_Each_Target
     (DS : Delivered_Store;
      Process : not null access procedure (Target : String));

   procedure For_Each_Client
     (DS : Delivered_Store;
      Process : not null access procedure (Client_Name : String));

private

   use Ada.Strings.Unbounded;

   --  deliveredClientMap: client name -> msg ID.
   package Client_Maps is new Ada.Containers.Indefinite_Hashed_Maps
     (Key_Type        => String,
      Element_Type    => Unbounded_String,
      Hash            => Ada.Strings.Hash,
      Equivalent_Keys => "=");

   type Client_Map_Access is access Client_Maps.Map;

   package Delivered_Maps is new Soja.Irc.Case_Mapping_Maps
     (Element      => Client_Map_Access,
      Null_Element => null);

   type Delivered_Store is record
      M : Delivered_Maps.Map;
   end record;

end Soja.User;
