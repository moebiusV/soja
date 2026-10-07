pragma Ada_2022;

with Ada.Text_IO;
with Ada.Strings.Unbounded;

with Soja.Core;
with Soja.Database;
with Soja.Database.Sqlite;
with Soja.Irc.Case_Mapping;
with Soja.Server;

procedure Core_Run_Check is
   use Ada.Strings.Unbounded;
   use Soja.Core;
   use Soja.Irc.Case_Mapping;

   --  Counts the downstream connections passed to For_Each_Downstream.
   Ctr : Natural := 0;

   procedure Count_DC (DC : Downstream_Conn_Access) is
      pragma Unreferenced (DC);
   begin
      Ctr := Ctr + 1;
   end Count_DC;

begin

   --  For_Each_Downstream: only the network's own connections are visited.
   declare
      U    : User_Access := new User;
      Net1 : Network_Access := new Network;
      Net2 : Network_Access := new Network;
      DC   : Downstream_Conn_Access := new Downstream_Conn;
   begin
      Net1.User := U;
      Net2.User := U;
      DC.Network := Net1;
      U.Downstream_Conns.Append (DC);
      Ctr := 0;
      For_Each_Downstream (Net1, Count_DC'Unrestricted_Access);
      if Ctr /= 1 then
         raise Program_Error with "forEachDownstream net1 count wrong";
      end if;
      Ctr := 0;
      For_Each_Downstream (Net2, Count_DC'Unrestricted_Access);
      if Ctr /= 0 then
         raise Program_Error with "forEachDownstream net2 count wrong";
      end if;
   end;

   --  Is_Stopped / Stop_Network (idempotent).
   declare
      Net : Network_Access := new Network;
   begin
      Net.Stopped := new Signal;
      if Is_Stopped (Net) then
         raise Program_Error with "fresh network must not be stopped";
      end if;
      Stop_Network (Net);
      if not Is_Stopped (Net) then
         raise Program_Error with "network must be stopped after Stop";
      end if;
      Stop_Network (Net);
   end;

   --  Equal_Casemap folds both operands under the network's case-mapping.
   declare
      Net : Network_Access := new Network;
   begin
      Net.Casemap := Case_RFC1459;
      if not Equal_Casemap (Net, "#Foo", "#foo") then
         raise Program_Error with "rfc1459 ascii fold";
      end if;
      if Equal_Casemap (Net, "#Foo", "#bar") then
         raise Program_Error with "distinct names must not fold equal";
      end if;
   end;

   --  Get_Network (by addr, then name) and Get_Network_By_ID.
   declare
      U     : User_Access := new User;
      Net   : Network_Access := new Network;
      Found : Network_Access;
   begin
      Net.Network_Record.Addr := To_Unbounded_String ("irc.example");
      Net.Network_Record.Name := To_Unbounded_String ("home");
      Net.Network_Record.ID := 42;
      U.Networks.Append (Net);
      if Get_Network (U, "irc.example") /= Net then
         raise Program_Error with "getNetwork by addr";
      end if;
      if Get_Network (U, "home") /= Net then
         raise Program_Error with "getNetwork by name";
      end if;
      Found := Get_Network (U, "missing");
      if Found /= null then
         raise Program_Error with "getNetwork missing must be null";
      end if;
      if Get_Network_By_ID (U, 42) /= Net then
         raise Program_Error with "getNetworkByID";
      end if;
   end;

   --  Load_Networks against a real (temp) database.
   declare
      DB  : Soja.Database.Database_Access :=
        Soja.Database.Sqlite.Open_Temp_Sqlite_DB;
      Rec : Soja.Database.User := Soja.Database.New_User ("alice");
      N1  : Soja.Database.Network := Soja.Database.New_Network ("irc.one");
      N2  : Soja.Database.Network := Soja.Database.New_Network ("irc.two");
      Ch  : Soja.Database.Channel :=
        (Name => To_Unbounded_String ("#chan"), others => <>);
      S   : aliased Soja.Server.Server;
      U   : User_Access;
   begin
      Rec.Enabled := False;   --  keep the spawned run tasks from looping
      Soja.Database.Set_Password (Rec, "hunter2");
      Soja.Database.Store_User (DB.all, Rec);
      N1.Name := To_Unbounded_String ("one");
      N2.Name := To_Unbounded_String ("two");
      Soja.Database.Store_Network (DB.all, Rec.ID, N1);
      Soja.Database.Store_Network (DB.all, Rec.ID, N2);
      Soja.Database.Store_Channel (DB.all, N1.ID, Ch);

      S.Initialize (null);
      Soja.Server.Set_DB (S, DB);

      U := New_User (S'Unchecked_Access, Rec);
      Load_Networks (U);

      if Natural (U.Networks.Length) /= 2 then
         raise Program_Error with "Load_Networks must load two networks";
      end if;
      if To_String (U.Networks.Element (1).Network_Record.Name) /= "one" then
         raise Program_Error with "networks must be sorted by ID";
      end if;
      if not U.Networks.Element (1).Channels.Has ("#chan") then
         raise Program_Error with "channel not loaded onto its network";
      end if;
      if U.Networks.Element (2).Channels.Has ("#chan") then
         raise Program_Error with "channel leaked onto wrong network";
      end if;
   end;

   Ada.Text_IO.Put_Line ("ALL PASS");
end Core_Run_Check;
