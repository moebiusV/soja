pragma Ada_2022;

with Ada.Calendar;
with Ada.Exceptions;
with Ada.Strings.Fixed;

with Soja.Core.Downstream_Helpers;
with Soja.Core.Upstream_Dispatch;
with Soja.Irc.Genmsg;
with Soja.Irc.Helpers;
with Soja.Server;
with Soja.User;

package body Soja.Core.User_Ops is

   use Soja.Irc.Messages;
   use Soja.Irc.Genmsg;
   use type Soja.Database.Database_Access;

   function Image (N : Long_Long_Integer) return String is
     (Ada.Strings.Fixed.Trim (Long_Long_Integer'Image (N), Ada.Strings.Left));

   function DB_Of (U : not null User_Access) return Soja.Database.Database_Access
   is (Soja.Server.DB (U.Srv.all));

   function Lower (S : String) return String is
      R : String := S;
   begin
      for C of R loop
         if C in 'A' .. 'Z' then
            C := Character'Val (Character'Pos (C) + 32);
         end if;
      end loop;
      return R;
   end Lower;

   ------------------------------
   -- BOUNCER network attributes --
   ------------------------------

   --  net.SplitHostPort: Ok is False without a port.
   procedure Split_Host_Port
     (S : String; Host, Port : out Unbounded_String; Ok : out Boolean)
   is
      Colon : Natural := 0;
      Count : Natural := 0;
   begin
      Host := Null_Unbounded_String;
      Port := Null_Unbounded_String;
      Ok := False;
      if S'Length > 0 and then S (S'First) = '[' then
         for I in S'Range loop
            if S (I) = ']' then
               if I < S'Last and then S (I + 1) = ':' then
                  Host := To_Unbounded_String (S (S'First + 1 .. I - 1));
                  Port := To_Unbounded_String (S (I + 2 .. S'Last));
                  Ok := True;
               end if;
               return;
            end if;
         end loop;
         return;
      end if;
      for I in S'Range loop
         if S (I) = ':' then
            Count := Count + 1;
            Colon := I;
         end if;
      end loop;
      if Count = 1 then
         Host := To_Unbounded_String (S (S'First .. Colon - 1));
         Port := To_Unbounded_String (S (Colon + 1 .. S'Last));
         Ok := True;
      end if;
   end Split_Host_Port;

   function Network_Attrs (Net : not null Network_Access) return Tag_Map is
      Attrs : Tag_Map;
      Rec   : Soja.Database.Network renames Net.Network_Record;
   begin
      Set_Tag (Attrs, "name", Soja.Database.Get_Name (Rec));
      Set_Tag (Attrs, "state",
               (if Net.Conn /= null then "connected" else "disconnected"));
      Set_Tag (Attrs, "nickname",
               Soja.Database.Get_Nick (Net.User.User_Record, Rec));
      if Length (Rec.Username) > 0 then
         Set_Tag (Attrs, "username", To_String (Rec.Username));
      end if;
      declare
         Realname : constant String :=
           Soja.Database.Get_Realname (Net.User.User_Record, Rec);
      begin
         if Realname /= "" then
            Set_Tag (Attrs, "realname", Realname);
         end if;
      end;
      if Net.Has_Last_Error then
         Set_Tag (Attrs, "error", To_String (Net.Last_Error));
      end if;

      --  fillNetworkAddrAttrs
      declare
         U      : constant Soja.Database.Network_URL :=
           Soja.Database.URL (Rec);
         Scheme : constant String := Lower (To_String (U.Scheme));
         Has_Host_Port : Boolean := True;
      begin
         if Scheme = "ircs" then
            Set_Tag (Attrs, "tls", "1");
         elsif Scheme = "irc+insecure" then
            Set_Tag (Attrs, "tls", "0");
         else   --  e.g. unix://
            Has_Host_Port := False;
         end if;
         if Has_Host_Port then
            declare
               Host, Port : Unbounded_String;
               Ok         : Boolean;
            begin
               Split_Host_Port (To_String (U.Host), Host, Port, Ok);
               if Ok then
                  Set_Tag (Attrs, "host", To_String (Host));
                  Set_Tag (Attrs, "port", To_String (Port));
               else
                  Set_Tag (Attrs, "host", To_String (U.Host));
               end if;
            end;
         end if;
      end;
      return Attrs;
   end Network_Attrs;

   procedure Notify_Bouncer_Network_State
     (U : not null User_Access; Net_ID : Long_Long_Integer; Attrs : Tag_Map)
   is
      Found : Boolean := False;
   begin
      --  Don't send state updates for removed networks.
      for Net of U.Networks loop
         if Net.Network_Record.ID = Net_ID then
            Found := True;
            exit;
         end if;
      end loop;
      if not Found then
         return;
      end if;

      for DC of U.Downstream_Conns loop
         if Soja.Irc.Cap_Registry.Is_Enabled
              (DC.Caps, "soju.im/bouncer-networks-notify")
         then
            Send_Message
              (DC, Make ("BOUNCER", ["NETWORK", Image (Net_ID), Image (Attrs)]));
         end if;
      end loop;
   end Notify_Bouncer_Network_State;

   ----------------------------------
   -- Adding and removing networks --
   ----------------------------------

   procedure Add_Network
     (U : not null User_Access; Net : not null Network_Access) is
   begin
      U.Networks.Append (Net);

      --  Keep them sorted by ID (insertion sort; there are few).
      for I in 2 .. Natural (U.Networks.Length) loop
         declare
            Cur : constant Network_Access := U.Networks (I);
            J   : Integer := I - 1;
         begin
            while J >= 1
              and then U.Networks (J).Network_Record.ID
                       > Cur.Network_Record.ID
            loop
               U.Networks.Replace_Element (J + 1, U.Networks (J));
               J := J - 1;
            end loop;
            U.Networks.Replace_Element (J + 1, Cur);
         end;
      end loop;

      Spawn_Network (Net);
   end Add_Network;

   procedure Remove_Network
     (U : not null User_Access; Net : not null Network_Access) is
   begin
      Stop_Network (Net);

      for DC of U.Downstream_Conns loop
         if DC.Network /= null and then DC.Network = Net then
            Soja.Conn.Close (DC.Conn);
         end if;
      end loop;

      for I in 1 .. Natural (U.Networks.Length) loop
         if U.Networks (I) = Net then
            U.Networks.Delete (I);
            return;
         end if;
      end loop;

      raise Program_Error with "tried to remove a non-existing network";
   end Remove_Network;

   -------------------
   -- Check_Network --
   -------------------

   procedure Check_Network
     (U : not null User_Access; Rec : Soja.Database.Network)
   is
      Addr : constant String :=
        (if Ada.Strings.Fixed.Index (To_String (Rec.Addr), "://") = 0
         then "ircs://" & To_String (Rec.Addr) else To_String (Rec.Addr));
      Sep  : constant Natural := Ada.Strings.Fixed.Index (Addr, "://");
      Rest : constant String := Addr (Sep + 3 .. Addr'Last);

      --  Position of the first of the delimiters in Rest, or 0.
      function First_Of (Chars : String; From : Positive) return Natural is
      begin
         for I in From .. Rest'Last loop
            if Ada.Strings.Fixed.Index (Chars, [1 => Rest (I)]) > 0 then
               return I;
            end if;
         end loop;
         return 0;
      end First_Of;

      Auth_End : constant Natural := First_Of ("/?#", Rest'First);
      Authority : constant String :=
        (if Auth_End = 0 then Rest else Rest (Rest'First .. Auth_End - 1));
      Web : constant Soja.Database.Network_URL := Soja.Database.URL (Rec);
      Scheme : constant String := Lower (To_String (Web.Scheme));
      Name   : constant String := Soja.Database.Get_Name (Rec);
   begin
      if Ada.Strings.Fixed.Index (Authority, "@") > 0 then
         raise Operation_Error with
           Scheme & ":// URL must not have username and password information";
      end if;

      declare
         Q : constant Natural := First_Of ("?", Rest'First);
         F : constant Natural := First_Of ("#", Rest'First);
      begin
         if Q > 0 and then Q < Rest'Last
           and then Rest (Q + 1) /= '#'
         then
            raise Operation_Error with
              Scheme & ":// URL must not have query values";
         end if;
         if F > 0 and then F < Rest'Last then
            raise Operation_Error with
              Scheme & ":// URL must not have a fragment";
         end if;
      end;

      if Scheme = "ircs" or else Scheme = "irc+insecure" then
         if Length (Web.Host) = 0 then
            raise Operation_Error with Scheme & ":// URL must have a host";
         end if;
         if Length (Web.Path) > 0 then
            raise Operation_Error with
              Scheme & ":// URL must not have a path";
         end if;
      elsif Scheme = "irc+unix" or else Scheme = "unix" then
         if Length (Web.Host) > 0 then
            raise Operation_Error with
              Scheme & ":// URL must not have a host";
         end if;
         if Length (Web.Path) = 0 then
            raise Operation_Error with Scheme & ":// URL must have a path";
         end if;
      else
         raise Operation_Error with
           "unknown URL scheme " & Soja.Irc.Helpers.Quote (Scheme);
      end if;

      if Name = "" then
         raise Operation_Error with "network name cannot be empty";
      end if;
      if Name (Name'First) = '-' then
         --  Can be mixed up with flags when sending commands to the service.
         raise Operation_Error with
           "network name cannot start with a dash character";
      end if;

      for Net of U.Networks loop
         if Soja.Database.Get_Name (Net.Network_Record) = Name
           and then Net.Network_Record.ID /= Rec.ID
         then
            raise Operation_Error with
              "a network with the name " & Soja.Irc.Helpers.Quote (Name)
              & " already exists";
         end if;
      end loop;
   end Check_Network;

   ---------------------------------
   -- Create / update / delete --
   ---------------------------------

   function Create_Network
     (U : not null User_Access; Rec : Soja.Database.Network)
      return Network_Access
   is
      Max : constant Integer :=
        Soja.Server.Config (U.Srv.all).Max_User_Networks;
      DB  : constant Soja.Database.Database_Access := DB_Of (U);
   begin
      if Rec.ID /= 0 then
         raise Program_Error with "tried creating an already-existing network";
      end if;

      Check_Network (U, Rec);

      if Max >= 0 and then Integer (U.Networks.Length) >= Max then
         raise Operation_Error with "maximum number of networks reached";
      end if;

      declare
         Net : constant Network_Access :=
           New_Network (U, Rec, Soja.Database.Channel_Lists.Empty_Vector);
      begin
         if DB /= null then
            begin
               Soja.Database.Store_Network
                 (DB.all, U.User_Record.ID, Net.Network_Record);
            exception
               when E : Soja.Database.Database_Error =>
                  raise Operation_Error with
                    Ada.Exceptions.Exception_Message (E);
            end;
         end if;

         Add_Network (U, Net);
         Notify_Bouncer_Network_State
           (U, Net.Network_Record.ID, Network_Attrs (Net));
         return Net;
      end;
   end Create_Network;

   function Update_Network
     (U : not null User_Access; Rec : Soja.Database.Network)
      return Network_Access
   is
      Record_Copy : Soja.Database.Network := Rec;
      DB : constant Soja.Database.Database_Access := DB_Of (U);
   begin
      if Record_Copy.ID = 0 then
         raise Program_Error with "tried updating a new network";
      end if;

      --  If the nickname/realname is reset to the default, just wipe the
      --  per-network setting.
      if Record_Copy.Nick = U.User_Record.Nick then
         Record_Copy.Nick := Null_Unbounded_String;
      end if;
      if Record_Copy.Realname = U.User_Record.Realname then
         Record_Copy.Realname := Null_Unbounded_String;
      end if;

      Check_Network (U, Record_Copy);

      declare
         Old : constant Network_Access :=
           Get_Network_By_ID (U, Record_Copy.ID);
         Channels : Soja.Database.Channel_Lists.Vector;

         procedure Copy_Channel (Name : String; Ch : Channel_Access) is
            pragma Unreferenced (Name);
         begin
            Channels.Append (Ch.all);
         end Copy_Channel;
      begin
         if Old = null then
            raise Program_Error with "tried updating a non-existing network";
         end if;

         if DB /= null then
            begin
               Soja.Database.Store_Network
                 (DB.all, U.User_Record.ID, Record_Copy);
            exception
               when E : Soja.Database.Database_Error =>
                  raise Operation_Error with
                    Ada.Exceptions.Exception_Message (E);
            end;
         end if;

         --  Most network changes require us to re-connect to the upstream
         --  server.
         Old.Channels.For_Each (Copy_Channel'Access);

         declare
            Updated : constant Network_Access :=
              New_Network (U, Record_Copy, Channels);
         begin
            Load_Kicks (Updated);

            --  If we're currently connected, disconnect and perform the
            --  necessary bookkeeping.
            Stop_Network (Old);
            if Old.Conn /= null then
               --  (This sets Old.Conn to null.)
               Handle_Upstream_Disconnected (U, Old.Conn);
            end if;

            --  Patch the clients to use the fresh network.  This must happen
            --  before removing the old one, which closes its clients.
            for DC of U.Downstream_Conns loop
               if DC.Network /= null and then DC.Network = Old then
                  DC.Network := Updated;
               end if;
            end loop;

            Remove_Network (U, Old);

            --  (The filesystem message store would be told about a rename
            --  here; that store is not ported.)

            --  This re-connects to the upstream server.
            Add_Network (U, Updated);

            --  TODO (Go): only broadcast the attributes that changed.
            Notify_Bouncer_Network_State
              (U, Updated.Network_Record.ID, Network_Attrs (Updated));
            return Updated;
         end;
      end;
   end Update_Network;

   procedure Delete_Network
     (U : not null User_Access; ID : Long_Long_Integer)
   is
      Net : constant Network_Access := Get_Network_By_ID (U, ID);
      DB  : constant Soja.Database.Database_Access := DB_Of (U);
   begin
      if Net = null then
         raise Program_Error with "tried deleting a non-existing network";
      end if;

      if DB /= null then
         begin
            Soja.Database.Delete_Network (DB.all, ID);
         exception
            when E : Soja.Database.Database_Error =>
               raise Operation_Error with Ada.Exceptions.Exception_Message (E);
         end;
      end if;

      Remove_Network (U, Net);

      for DC of U.Downstream_Conns loop
         if Soja.Irc.Cap_Registry.Is_Enabled
              (DC.Caps, "soju.im/bouncer-networks-notify")
         then
            Send_Message (DC, Make ("BOUNCER", ["NETWORK", Image (ID), "*"]));
         end if;
      end loop;
   end Delete_Network;

   -----------------
   -- Update_User --
   -----------------

   procedure Update_User
     (U      : not null User_Access;
      Update : not null access procedure (Rec : in out Soja.Database.User))
   is
      Rec : Soja.Database.User := U.User_Record;   --  a copy
      DB  : constant Soja.Database.Database_Access := DB_Of (U);
   begin
      Update (Rec);

      declare
         Nick_Updated     : constant Boolean := U.User_Record.Nick /= Rec.Nick;
         Realname_Updated : constant Boolean :=
           U.User_Record.Realname /= Rec.Realname;
         Enabled_Updated  : constant Boolean :=
           U.User_Record.Enabled /= Rec.Enabled;
      begin
         if DB /= null then
            begin
               Soja.Database.Store_User (DB.all, Rec);
            exception
               when E : Soja.Database.Database_Error =>
                  raise Operation_Error with
                    "failed to update user "
                    & Soja.Irc.Helpers.Quote (To_String (U.User_Record.Username))
                    & ": " & Ada.Exceptions.Exception_Message (E);
            end;
         end if;
         U.User_Record := Rec;

         if Nick_Updated then
            for Net of U.Networks loop
               if Length (Net.Network_Record.Nick) = 0
                 and then Net.Conn /= null
               then
                  Send_Message
                    (Net.Conn,
                     Make ("NICK",
                           [Soja.Database.Get_Nick
                              (U.User_Record, Net.Network_Record)]));
               end if;
            end loop;
         end if;

         if Realname_Updated or else Enabled_Updated then
            --  Re-connect to the networks which use the default realname.
            declare
               Need_Update : Soja.Database.Network_Lists.Vector;
               Net_Error   : Unbounded_String;
            begin
               for Net of U.Networks loop
                  declare
                     Skip : Boolean := False;
                  begin
                     --  If only the realname was updated, maybe we can skip
                     --  the re-connect.
                     if Realname_Updated and then not Enabled_Updated then
                        --  A custom realname leaves the user-wide one unused.
                        if Length (Net.Network_Record.Realname) > 0 then
                           Skip := True;
                        --  Only upstreams without setname need a re-connect.
                        elsif Net.Conn /= null
                          and then Soja.Irc.Cap_Registry.Is_Enabled
                                     (Net.Conn.Caps, "setname")
                        then
                           Send_Message
                             (Net.Conn,
                              Make ("SETNAME",
                                    [Soja.Database.Get_Realname
                                       (U.User_Record, Net.Network_Record)]));
                           Skip := True;
                        end if;
                     end if;
                     if not Skip then
                        Need_Update.Append (Net.Network_Record);
                     end if;
                  end;
               end loop;

               for Net_Rec of Need_Update loop
                  declare
                     Ignored : Network_Access;
                     pragma Unreferenced (Ignored);
                  begin
                     Ignored := Update_Network (U, Net_Rec);
                  exception
                     when E : Operation_Error =>
                        Net_Error := To_Unbounded_String
                          (Ada.Exceptions.Exception_Message (E));
                  end;
               end loop;
               if Length (Net_Error) > 0 then
                  raise Operation_Error with To_String (Net_Error);
               end if;
            end;
         end if;

         if not U.User_Record.Enabled then
            --  TODO (Go): send an error message before disconnecting.
            for DC of U.Downstream_Conns loop
               Soja.Conn.Close (DC.Conn);
            end loop;
         end if;
      end;
   end Update_User;

   ----------------------------------
   -- Upstream disconnection --
   ----------------------------------

   procedure Handle_Upstream_Disconnected
     (U : not null User_Access; UC : not null Upstream_Conn_Access)
   is
      use Soja.Core.Downstream_Helpers;
      Net : constant Network_Access := UC.Network;

      procedure Stop_Idle (Name : String; Uch : Upstream_Channel_Access) is
         pragma Unreferenced (Name);
      begin
         Update_Auto_Detach (Uch, 0.0);
      end Stop_Idle;
   begin
      Net.Conn := null;

      Stop_Regain_Nick_Timer (UC);
      Soja.Core.Upstream_Dispatch.Stop_Join_Retries (UC);
      Soja.Core.Upstream_Dispatch.Abort_Pending_Commands (UC);

      UC.Channels.For_Each (Stop_Idle'Access);

      for DC of Downstreams (Net) loop
         Update_Supported_Caps (DC);
      end loop;

      --  If the network has been removed, don't send a state change
      --  notification.
      declare
         Found : Boolean := False;
      begin
         for N of U.Networks loop
            if N = Net then
               Found := True;
               exit;
            end if;
         end loop;
         if not Found then
            return;
         end if;
      end;

      declare
         Attrs : Tag_Map;
      begin
         Set_Tag (Attrs, "state", "disconnected");
         Notify_Bouncer_Network_State (U, Net.Network_Record.ID, Attrs);
      end;

      if not Net.Has_Last_Error then
         for DC of Downstreams (Net) loop
            if not Soja.Irc.Cap_Registry.Is_Enabled
                     (DC.Caps, "soju.im/bouncer-networks")
            then
               Send_Service_Notice
                 (DC, "disconnected from "
                      & Soja.Database.Get_Name (Net.Network_Record));
            end if;
         end loop;
      end if;
   end Handle_Upstream_Disconnected;

   ------------------------------------
   -- Delivery receipts, interaction time --
   ------------------------------------

   procedure Store_Client_Delivery_Receipts
     (Net : not null Network_Access; Client_Name : String)
   is
      Receipts : Soja.Database.Delivery_Receipt_Lists.Vector;
      DB       : constant Soja.Database.Database_Access := DB_Of (Net.User);

      procedure Collect (Target : String) is
         Msg_ID : constant String :=
           Soja.User.Load_ID (Net.Delivered, Target, Client_Name);
      begin
         if Msg_ID /= "" then
            Receipts.Append
              (Soja.Database.Delivery_Receipt'
                 (Target => To_Unbounded_String (Target),
                  Internal_Msg_ID => To_Unbounded_String (Msg_ID),
                  others => <>));
         end if;
      end Collect;
   begin
      if not Has_Persistent_Msg_Store (Net.User) then
         return;
      end if;

      Soja.User.For_Each_Target (Net.Delivered, Collect'Access);

      if DB /= null then
         Soja.Database.Store_Client_Delivery_Receipts
           (DB.all, Net.Network_Record.ID, Client_Name, Receipts);
      end if;
   exception
      when E : others =>
         Net.Logger.Print
           ("failed to store delivery receipts for client "
            & Soja.Irc.Helpers.Quote (Client_Name) & ": "
            & Ada.Exceptions.Exception_Message (E));
   end Store_Client_Delivery_Receipts;

   procedure Bump_Downstream_Interaction_Time (U : not null User_Access) is
      procedure Bump (Rec : in out Soja.Database.User) is
      begin
         Rec.Downstream_Interacted_At := Ada.Calendar.Clock;
      end Bump;
   begin
      Update_User (U, Bump'Access);
   exception
      when E : Operation_Error =>
         U.Logger.Print
           ("failed to bump downstream interaction time: "
            & Ada.Exceptions.Exception_Message (E));
   end Bump_Downstream_Interaction_Time;

end Soja.Core.User_Ops;
