pragma Ada_2022;

package body Soja.User is

   use Soja.Irc.Case_Mapping;

   ------------------------
   -- New_Delivered_Store --
   ------------------------

   function New_Delivered_Store (CM : Kind) return Delivered_Store is
   begin
      return (M => Delivered_Maps.New_Map (CM));
   end New_Delivered_Store;

   ----------------
   -- Has_Target --
   ----------------

   function Has_Target (DS : Delivered_Store; Target : String)
      return Boolean
   is
   begin
      return Delivered_Maps.Get (DS.M, Target) /= null;
   end Has_Target;

   -------------
   -- Load_ID --
   -------------

   function Load_ID (DS : Delivered_Store; Target, Client_Name : String)
      return String
   is
      Clients : constant Client_Map_Access :=
        Delivered_Maps.Get (DS.M, Target);
   begin
      if Clients = null then
         return "";
      end if;
      if Clients.Contains (Client_Name) then
         return To_String (Clients.Element (Client_Name));
      end if;
      return "";
   end Load_ID;

   --------------
   -- Store_ID --
   --------------

   procedure Store_ID (DS : in out Delivered_Store;
      Target, Client_Name, Msg_ID : String)
   is
      Clients : Client_Map_Access := Delivered_Maps.Get (DS.M, Target);
   begin
      if Clients = null then
         Clients := new Client_Maps.Map;
         Delivered_Maps.Set (DS.M, Target, Clients);
      end if;
      Clients.Include (Client_Name, To_Unbounded_String (Msg_ID));
   end Store_ID;

   --------------------
   -- For_Each_Target --
   --------------------

   procedure For_Each_Target
     (DS : Delivered_Store;
      Process : not null access procedure (Target : String))
   is
      procedure Adapter (Name : String; Clients : Client_Map_Access) is
         pragma Unreferenced (Clients);
      begin
         Process (Name);
      end Adapter;
   begin
      Delivered_Maps.For_Each (DS.M, Adapter'Access);
   end For_Each_Target;

   --------------------
   -- For_Each_Client --
   --------------------

   procedure For_Each_Client
     (DS : Delivered_Store;
      Process : not null access procedure (Client_Name : String))
   is
      Seen : Client_Maps.Map;   --  client name -> dummy, used as a set

      procedure Adapter (Name : String; Clients : Client_Map_Access) is
         pragma Unreferenced (Name);
         C : Client_Maps.Cursor := Clients.First;
      begin
         while Client_Maps.Has_Element (C) loop
            Client_Maps.Include (Seen, Client_Maps.Key (C),
                                 Null_Unbounded_String);
            Client_Maps.Next (C);
         end loop;
      end Adapter;
   begin
      Delivered_Maps.For_Each (DS.M, Adapter'Access);
      declare
         C : Client_Maps.Cursor := Seen.First;
      begin
         while Client_Maps.Has_Element (C) loop
            Process (Client_Maps.Key (C));
            Client_Maps.Next (C);
         end loop;
      end;
   end For_Each_Client;

end Soja.User;
