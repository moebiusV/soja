pragma Ada_2022;

with Ada.Calendar;
with Ada.Directories;
with Ada.Text_IO;
with Ada.Strings.Unbounded;

with Soja.Database;
with Soja.Database.Sqlite;

procedure Sqlite_Check is
   use Ada.Strings.Unbounded;
   use Soja.Database;
   use type Ada.Calendar.Time;

   DB : Database_Access := Soja.Database.Sqlite.Open_Temp_Sqlite_DB;

   function Get_Now return Time is (Ada.Calendar.Clock);

   --  Assert that two times are within T seconds of each other.
   procedure Assert_Near (A, B : Time; T : Duration; What : String) is
   begin
      if abs (A - B) > T then
         raise Program_Error with What & " differs too much";
      end if;
   end Assert_Near;
begin
   --  Stats on an empty database.
   declare
      S : constant Database_Stats := Stats (DB.all);
   begin
      if S.Users /= 0 or else S.Networks /= 0 or else S.Channels /= 0 then
         raise Program_Error with "empty Stats must be zero";
      end if;
   end;

   --  Store a fresh user (INSERT) and read it back.
   declare
      U : User := New_User ("alice");
   begin
      Set_Password (U, "hunter2");
      U.Nick := To_Unbounded_String ("bob");
      Store_User (DB.all, U);
      if U.ID = 0 then
         raise Program_Error with "StoreUser must assign an ID";
      end if;

      declare
         G : User := Get_User (DB.all, "alice");
      begin
         if G.Username /= "alice" or else G.Nick /= "bob" then
            raise Program_Error with "GetUser fields wrong";
         end if;
         if G.Downstream_Interacted_At /= Null_Time then
            raise Program_Error with "unset time must round-trip to Null_Time";
         end if;
         declare
            Upgraded : constant Boolean := Check_Password (G, "hunter2");
         begin
            if Upgraded then
               raise Program_Error with "stored password should not upgrade";
            end if;
         end;
      end;

      --  UPDATE path.
      U.Enabled := False;
      Store_User (DB.all, U);
      declare
         G : constant User := Get_User (DB.all, "alice");
      begin
         if G.Enabled then
            raise Program_Error with "StoreUser UPDATE did not persist";
         end if;
      end;
   end;

   --  ListUsers.
   if Natural (List_Users (DB.all).Length) /= 1 then
      raise Program_Error with "ListUsers should have one user";
   end if;

   --  GetUser on a missing user raises Not_Found.
   begin
      declare
         G : constant User := Get_User (DB.all, "nobody");
      begin
         raise Program_Error with "expected Not_Found for missing user";
      end;
   exception
      when Not_Found =>
         null;
   end;

   --  Store a network with connect commands and SASL PLAIN.
   declare
      User_ID : constant Long_Long_Integer := Get_User (DB.all, "alice").ID;
      Net : Network := New_Network ("irc.libera.chat");
   begin
      Net.Name := To_Unbounded_String ("liberachat");
      Net.Nick := To_Unbounded_String ("alice");
      Net.Connect_Commands.Append (To_Unbounded_String ("NICK alice"));
      Net.Connect_Commands.Append (To_Unbounded_String ("JOIN #soja"));
      Net.SASL.Mechanism := To_Unbounded_String ("PLAIN");
      Net.SASL.Plain_Username := To_Unbounded_String ("alice");
      Net.SASL.Plain_Password := To_Unbounded_String ("secret");
      Store_Network (DB.all, User_ID, Net);
      if Net.ID = 0 then
         raise Program_Error with "StoreNetwork must assign an ID";
      end if;

      declare
         Nets : constant Network_Lists.Vector :=
           List_Networks (DB.all, User_ID);
      begin
         if Natural (Nets.Length) /= 1 then
            raise Program_Error with "ListNetworks length wrong";
         end if;
         declare
            N2 : constant Network := Nets (1);
         begin
            if N2.Name /= "liberachat" or else
               N2.Addr /= "irc.libera.chat"
            then
               raise Program_Error with "network fields wrong";
            end if;
            if Natural (N2.Connect_Commands.Length) /= 2 or else
               N2.Connect_Commands (1) /= "NICK alice" or else
               N2.Connect_Commands (2) /= "JOIN #soja"
            then
               raise Program_Error with "connect_commands round-trip wrong";
            end if;
            if N2.SASL.Mechanism /= "PLAIN" or else
               N2.SASL.Plain_Username /= "alice"
            then
               raise Program_Error with "SASL round-trip wrong";
            end if;
         end;
      end;

      --  Store a channel.
      declare
         Net_ID : constant Long_Long_Integer := Net.ID;
         Ch : Channel := (ID => 0,
                          Name => To_Unbounded_String ("#soja"),
                          Key => To_Unbounded_String ("topsecret"),
                          Detached => True,
                          Detached_Internal_Msg_ID => Null_Unbounded_String,
                          Relay_Detached => Filter_Highlight,
                          Reattach_On => Filter_Message,
                          Detach_After => 30.0,
                          Detach_On => Filter_None);
      begin
         Store_Channel (DB.all, Net_ID, Ch);
         if Ch.ID = 0 then
            raise Program_Error with "StoreChannel must assign an ID";
         end if;

         declare
            Chs : constant Channel_Lists.Vector :=
              List_Channels (DB.all, Net_ID);
         begin
            if Natural (Chs.Length) /= 1 then
               raise Program_Error with "ListChannels length wrong";
            end if;
            declare
               C2 : constant Channel := Chs (1);
            begin
               if C2.Key /= "topsecret" or else not C2.Detached then
                  raise Program_Error with "channel fields wrong";
               end if;
               if C2.Relay_Detached /= Filter_Highlight or else
                  C2.Reattach_On /= Filter_Message or else
                  C2.Detach_On /= Filter_None
               then
                  raise Program_Error with "message filter round-trip wrong";
               end if;
               if C2.Detach_After /= 30.0 then
                  raise Program_Error with "detach_after round-trip wrong";
               end if;
            end;
         end;

         --  DeleteChannel.
         Delete_Channel (DB.all, Ch.ID);
         if Natural (List_Channels (DB.all, Net_ID).Length) /= 0 then
            raise Program_Error with "DeleteChannel did not delete";
         end if;
      end;

      --  Read receipts.
      declare
         R : Read_Receipt := (ID => 0,
                              Target => To_Unbounded_String ("#soja"),
                              Timestamp => Get_Now);
      begin
         Store_Read_Receipt (DB.all, Net.ID, R);
         if R.ID = 0 then
            raise Program_Error with "StoreReadReceipt must assign an ID";
         end if;

         declare
            G : constant Read_Receipt_Access :=
              Get_Read_Receipt (DB.all, Net.ID, "#soja");
         begin
            if G = null then
               raise Program_Error with "GetReadReceipt returned null";
            end if;
            Assert_Near (G.Timestamp, R.Timestamp, 2.0, "read receipt time");
         end;

         if Get_Read_Receipt (DB.all, Net.ID, "#none") /= null then
            raise Program_Error with "missing read receipt must be null";
         end if;
      end;

      --  Delivery receipts.
      declare
         Rcpts : Delivery_Receipt_Lists.Vector :=
           Delivery_Receipt_Lists.Empty_Vector;
      begin
         Rcpts.Append (Delivery_Receipt'
           (ID => 0,
            Target => To_Unbounded_String ("#soja"),
            Client => Null_Unbounded_String,
            Internal_Msg_ID => To_Unbounded_String ("m1")));
         Rcpts.Append (Delivery_Receipt'
           (ID => 0,
            Target => To_Unbounded_String ("#other"),
            Client => Null_Unbounded_String,
            Internal_Msg_ID => To_Unbounded_String ("m2")));
         Store_Client_Delivery_Receipts (DB.all, Net.ID, "down", Rcpts);
         if Natural (List_Delivery_Receipts (DB.all, Net.ID).Length) /= 2 then
            raise Program_Error with "delivery receipts length wrong";
         end if;
      end;

      --  WebPush config + subscription.
      declare
         Cfg : WebPush_Config := (ID => 0,
                                  VAPID_Public => To_Unbounded_String ("pub"),
                                  VAPID_Private =>
                                    To_Unbounded_String ("priv"));
         Sub : WebPush_Subscription :=
           (ID => 0,
            Endpoint => To_Unbounded_String ("https://push.example/x"),
            Created_At => Null_Time,
            Updated_At => Null_Time,
            Key_Auth => To_Unbounded_String ("auth"),
            Key_P256DH => To_Unbounded_String ("p256"),
            Key_VAPID => To_Unbounded_String ("vapid"));
      begin
         Store_WebPush_Config (DB.all, Cfg);
         if Cfg.ID = 0 then
            raise Program_Error with "StoreWebPushConfig must assign an ID";
         end if;
         if Natural (List_WebPush_Configs (DB.all).Length) /= 1 then
            raise Program_Error with "ListWebPushConfigs length wrong";
         end if;

         Store_WebPush_Subscription (DB.all, User_ID, Net.ID, Sub);
         if Sub.ID = 0 then
            raise Program_Error with
              "StoreWebPushSubscription must assign an ID";
         end if;
         if Natural (List_WebPush_Subscriptions
              (DB.all, User_ID, Net.ID).Length)
           /= 1
         then
            raise Program_Error with "ListWebPushSubscriptions length wrong";
         end if;
         Delete_WebPush_Subscription (DB.all, Sub.ID);
      end;
   end;

   --  ListInactiveUsernames (limit in the future -> everyone).
   declare
      Names : constant Username_Lists.Vector :=
        List_Inactive_Usernames (DB.all, Get_Now + 3600.0);
   begin
      if Natural (Names.Length) /= 1 then
         raise Program_Error with "ListInactiveUsernames length wrong";
      end if;
   end;

   --  Stats reflect one user and one network.
   declare
      S : constant Database_Stats := Stats (DB.all);
   begin
      if S.Users /= 1 or else S.Networks /= 1 then
         raise Program_Error with "Stats after inserts wrong";
      end if;
   end;

   --  Kick records: history is never deleted, only deactivated.
   declare
      Net_ID : constant Long_Long_Integer :=
        List_Networks (DB.all, Get_User (DB.all, "alice").ID) (1).ID;
      K1, K2, K3 : Kick_Record;
   begin
      K1.Channel := To_Unbounded_String ("#chan");
      K1.Kicked_By := To_Unbounded_String ("op");
      K1.Reason := To_Unbounded_String ("out");
      K1.Kicked_At := Get_Now;
      Store_Kick (DB.all, Net_ID, K1);
      if K1.ID = 0 then
         raise Program_Error with "Store_Kick must set the ID";
      end if;
      K2.Channel := To_Unbounded_String ("#other");
      K2.Kicked_By := To_Unbounded_String ("bot");
      K2.Kicked_At := Get_Now;
      Store_Kick (DB.all, Net_ID, K2);

      declare
         Active : constant Kick_Lists.Vector := List_Kicks (DB.all, Net_ID, True);
      begin
         if Natural (Active.Length) /= 2
           or else Active (1).ID /= K1.ID
           or else Active (1).Channel /= To_Unbounded_String ("#chan")
           or else Active (1).Kicked_By /= To_Unbounded_String ("op")
           or else Active (1).Reason /= To_Unbounded_String ("out")
           or else Active (2).Reason /= Null_Unbounded_String
           or else Active (1).Rejoined_At /= Null_Time
         then
            raise Program_Error with "active kicks wrong";
         end if;
         Assert_Near (Active (1).Kicked_At, K1.Kicked_At, 0.01, "kicked_at");
      end;

      --  Rejoining deactivates the record but keeps it.
      K1.Rejoined_At := Get_Now;
      Store_Kick (DB.all, Net_ID, K1);
      declare
         Active  : constant Kick_Lists.Vector := List_Kicks (DB.all, Net_ID, True);
         History : constant Kick_Lists.Vector := List_Kicks (DB.all, Net_ID, False);
      begin
         if Natural (Active.Length) /= 1
           or else Active (1).Channel /= To_Unbounded_String ("#other")
         then
            raise Program_Error with "a rejoined kick must not be active";
         end if;
         if Natural (History.Length) /= 2
           or else History (1).Rejoined_At = Null_Time
           or else History (2).Rejoined_At /= Null_Time
         then
            raise Program_Error with "history must keep rejoined kicks";
         end if;
         Assert_Near (History (1).Rejoined_At, K1.Rejoined_At, 0.01, "rejoined_at");
      end;

      --  Kicked from the same channel again: a new record, the old one stays.
      K3 := (ID => 0, Rejoined_At => Null_Time, Kicked_At => Get_Now,
             Channel => K1.Channel, Kicked_By => To_Unbounded_String ("op2"),
             Reason => To_Unbounded_String ("again"));
      Store_Kick (DB.all, Net_ID, K3);
      if K3.ID = K1.ID
        or else Natural (List_Kicks (DB.all, Net_ID, True).Length) /= 2
        or else Natural (List_Kicks (DB.all, Net_ID, False).Length) /= 3
      then
         raise Program_Error with "a new kick must be a new record";
      end if;

      --  Other networks are unaffected.
      if not List_Kicks (DB.all, Net_ID + 1000, False).Is_Empty then
         raise Program_Error with "kicks leaked across networks";
      end if;
   end;

   --  DeleteUser cascades to networks/channels/receipts.
   declare
      User_ID : constant Long_Long_Integer := Get_User (DB.all, "alice").ID;
      Net_ID  : constant Long_Long_Integer :=
        List_Networks (DB.all, User_ID) (1).ID;
   begin
      Delete_User (DB.all, User_ID);
      if not List_Kicks (DB.all, Net_ID, False).Is_Empty then
         raise Program_Error with "DeleteUser did not delete the kicks";
      end if;
      if Natural (List_Users (DB.all).Length) /= 0 then
         raise Program_Error with "DeleteUser did not delete the user";
      end if;
      if Natural (List_Networks (DB.all, User_ID).Length) /= 0 then
         raise Program_Error with "DeleteUser did not cascade to networks";
      end if;
   end;

   Close (DB.all);

   --  Kick records survive reopening the database file, and adding their
   --  table does not change the schema version soju checks.
   declare
      Path : constant String := "/tmp/soja_kick_check.db";
      Net_ID : Long_Long_Integer;
      U : User := New_User ("kicker");
      N : Network := New_Network ("irc.example");
      K : Kick_Record;
   begin
      if Ada.Directories.Exists (Path) then
         Ada.Directories.Delete_File (Path);
      end if;
      DB := Soja.Database.Sqlite.Open_Sqlite_DB (Path);
      Store_User (DB.all, U);
      Store_Network (DB.all, U.ID, N);
      Net_ID := N.ID;
      K.Channel := To_Unbounded_String ("#persist");
      K.Kicked_By := To_Unbounded_String ("op");
      K.Kicked_At := Get_Now;
      Store_Kick (DB.all, Net_ID, K);
      Close (DB.all);

      DB := Soja.Database.Sqlite.Open_Sqlite_DB (Path);
      declare
         Active : constant Kick_Lists.Vector := List_Kicks (DB.all, Net_ID, True);
      begin
         if Natural (Active.Length) /= 1
           or else Active (1).Channel /= To_Unbounded_String ("#persist")
         then
            raise Program_Error with "kick did not survive reopening";
         end if;
      end;

      --  Deleting the network removes its kicks with it.
      Delete_Network (DB.all, Net_ID);
      if not List_Kicks (DB.all, Net_ID, False).Is_Empty then
         raise Program_Error with "DeleteNetwork must delete its kicks";
      end if;
      Close (DB.all);
      Ada.Directories.Delete_File (Path);
   end;

   Ada.Text_IO.Put_Line ("ALL PASS");
end Sqlite_Check;
