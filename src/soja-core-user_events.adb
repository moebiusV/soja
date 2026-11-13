pragma Ada_2022;

with Ada.Exceptions;

with Soja.Core.Downstream_Helpers;
with Soja.Core.Network_Ops;
with Soja.Core.Upstream_Dispatch;
with Soja.Core.User_Ops;
with Soja.Irc.Cap_Registry;
with Soja.Irc.Genmsg;
with Soja.Irc.Helpers;
with Soja.Irc.Messages;
with Soja.Server;
with Soja.User;

package body Soja.Core.User_Events is

   use Soja.Core.Downstream_Helpers;
   use Soja.Core.User_Ops;
   use Soja.Irc.Genmsg;
   use Soja.Irc.Messages;
   use type Soja.Database.Database_Access;

   function Quote (S : String) return String renames Soja.Irc.Helpers.Quote;

   --  user.forEachUpstream: the upstream connections that are up.
   function Upstreams (U : not null User_Access)
      return Soja.Core.Upstream_Conn_Access_Vectors.Vector
   is
      V : Soja.Core.Upstream_Conn_Access_Vectors.Vector;
   begin
      for Net of U.Networks loop
         if Net.Conn /= null then
            V.Append (Net.Conn);
         end if;
      end loop;
      return V;
   end Upstreams;

   ----------------------------------------------------------------------
   --  Upstream events
   ----------------------------------------------------------------------

   procedure Upstream_Connected (UC : not null Upstream_Conn_Access) is
      Net : constant Network_Access := UC.Network;
      use Soja.Core.Upstream_Dispatch;
   begin
      Net.Conn := UC;

      Update_Away (UC);
      Update_Monitor (UC);

      for DC of Downstreams (Net) loop
         Update_Supported_Caps (DC);

         if not Soja.Irc.Cap_Registry.Is_Enabled
                  (DC.Caps, "soju.im/bouncer-networks")
         then
            Send_Service_Notice
              (DC, "connected to " & Soja.Database.Get_Name (Net.Network_Record));
         end if;

         Update_Nick (DC);
         Update_Host (DC);
         Update_Realname (DC);
         Update_Account (DC);
         Update_Casemapping (DC);
      end loop;

      declare
         Attrs : Tag_Map;
      begin
         Set_Tag (Attrs, "state", "connected");
         Set_Tag (Attrs, "error", "");
         Notify_Bouncer_Network_State (Net.User, Net.Network_Record.ID, Attrs);
      end;
      Net.Has_Last_Error := False;
      Net.Last_Error := Null_Unbounded_String;
   end Upstream_Connected;

   procedure Upstream_Connection_Error
     (Net : not null Network_Access; Error : String)
   is
      Attrs : Tag_Map;
   begin
      if not Is_Stopped (Net)
        and then (not Net.Has_Last_Error
                  or else To_String (Net.Last_Error) /= Error)
      then
         for DC of Downstreams (Net) loop
            Send_Service_Notice
              (DC, "failed connecting/registering to "
                   & Soja.Database.Get_Name (Net.Network_Record) & ": "
                   & Error);
         end loop;
      end if;
      Net.Has_Last_Error := True;
      Net.Last_Error := To_Unbounded_String (Error);
      Set_Tag (Attrs, "error", Error);
      Notify_Bouncer_Network_State (Net.User, Net.Network_Record.ID, Attrs);
   end Upstream_Connection_Error;

   procedure Upstream_Error
     (UC : not null Upstream_Conn_Access; Error : String)
   is
      Net   : constant Network_Access := UC.Network;
      Attrs : Tag_Map;
   begin
      for DC of Downstreams (Net) loop
         Send_Service_Notice
           (DC, "disconnected from "
                & Soja.Database.Get_Name (Net.Network_Record) & ": " & Error);
      end loop;
      Net.Has_Last_Error := True;
      Net.Last_Error := To_Unbounded_String (Error);
      Set_Tag (Attrs, "error", Error);
      Notify_Bouncer_Network_State (Net.User, Net.Network_Record.ID, Attrs);
   end Upstream_Error;

   procedure Upstream_Message
     (UC : not null Upstream_Conn_Access; Msg : Message)
   is
      R : Soja.Core.Handle_Result;
   begin
      if Soja.Conn.Is_Closed (UC.Conn) then
         UC.Logger.Print
           ("ignoring message on closed connection: " & Image (Msg));
         return;
      end if;
      R := Soja.Core.Upstream_Dispatch.Handle_Message (UC, Msg);
      if R.Failed then
         UC.Logger.Print
           ("failed to handle message " & Quote (Image (Msg)) & ": "
            & To_String (R.Reason));
      end if;
   end Upstream_Message;

   procedure Channel_Detach
     (UC : not null Upstream_Conn_Access; Name : String)
   is
      Net : constant Network_Access := UC.Network;
      C   : constant Channel_Access := Net.Channels.Get (Name);
      DB  : constant Soja.Database.Database_Access :=
        Soja.Server.DB (UC.Srv.all);
   begin
      if C = null or else C.Detached then
         return;
      end if;
      Soja.Core.Network_Ops.Detach (Net, C);
      if DB /= null then
         Soja.Database.Store_Channel (DB.all, Net.Network_Record.ID, C.all);
      end if;
   exception
      when E : Soja.Database.Database_Error =>
         UC.User.Logger.Print
           ("failed to store updated detached channel "
            & Quote (Name) & ": " & Ada.Exceptions.Exception_Message (E));
   end Channel_Detach;

   ----------------------------------------------------------------------
   --  Downstream events
   ----------------------------------------------------------------------

   procedure Downstream_Connected
     (U : not null User_Access; DC : not null Downstream_Conn_Access)
   is
      procedure Enable (Rec : in out Soja.Database.User) is
      begin
         Rec.Enabled := True;
      end Enable;

      Res : Soja.Core.Irc_Error_Result;
   begin
      if DC.Network /= null then
         DC.Monitored.Set_Case_Mapping (DC.Network.Casemap);
      end if;

      if not U.User_Record.Enabled
        and then Soja.Server.Config (U.Srv.all).Enable_Users_On_Auth
      then
         begin
            Update_User (U, Enable'Access);
         exception
            when E : Operation_Error =>
               DC.Logger.Print
                 ("failed to enable user after successful authentication: "
                  & Ada.Exceptions.Exception_Message (E));
         end;
      end if;

      if not U.User_Record.Enabled then
         Send_Message
           (DC, Make ("ERROR", ["This bouncer account is disabled"]));
         --  TODO (Go): close DC after the error message is sent.
         return;
      end if;

      Res := Welcome (DC, U);
      if Res.Failed then
         declare
            M : Message := Copy (Res.Err.Message);
         begin
            M.Prefix := Server_Prefix (DC.Srv);
            Send_Message (DC, M);
         end;
         DC.Logger.Print
           ("failed to handle new registered connection: "
            & Soja.Downstream.Image (Res.Err));
         --  TODO (Go): close DC after the error message is sent.
         return;
      end if;

      U.Downstream_Conns.Append (DC);
      U.Num_Downstream_Conns := U.Num_Downstream_Conns + 1;

      if DC.Network /= null and then DC.Network.Has_Last_Error then
         Send_Service_Notice
           (DC, "disconnected from "
                & Soja.Database.Get_Name (DC.Network.Network_Record) & ": "
                & To_String (DC.Network.Last_Error));
      end if;

      for UC of Upstreams (U) loop
         Soja.Core.Upstream_Dispatch.Update_Away (UC);
      end loop;

      Bump_Downstream_Interaction_Time (U);
   end Downstream_Connected;

   procedure Downstream_Disconnected
     (U : not null User_Access; DC : not null Downstream_Conn_Access) is
   begin
      for I in 1 .. Natural (U.Downstream_Conns.Length) loop
         if U.Downstream_Conns (I) = DC then
            U.Downstream_Conns.Delete (I);
            U.Num_Downstream_Conns := U.Num_Downstream_Conns - 1;
            exit;
         end if;
      end loop;

      if DC.Network /= null then
         Store_Client_Delivery_Receipts (DC.Network, To_String (DC.Client_Name));
      end if;

      for UC of Upstreams (U) loop
         Soja.Core.Upstream_Dispatch.Cancel_Pending_Commands_By_Downstream_ID
           (UC, DC.ID);
         Soja.Core.Upstream_Dispatch.Update_Away (UC);
         Soja.Core.Upstream_Dispatch.Update_Monitor (UC);
      end loop;

      Bump_Downstream_Interaction_Time (U);
   end Downstream_Disconnected;

   procedure Downstream_Message
     (DC : not null Downstream_Conn_Access; Msg : Message)
   is
      Res : Soja.Core.Irc_Error_Result;
   begin
      if Soja.Conn.Is_Closed (DC.Conn) then
         DC.Logger.Print
           ("ignoring message on closed connection: " & Image (Msg));
         return;
      end if;
      Res := Handle_Downstream_Message (DC, Msg);
      if Res.Failed then
         declare
            M : Message := Copy (Res.Err.Message);
         begin
            M.Prefix := Server_Prefix (DC.Srv);
            Send_Message (DC, M);
         end;
      end if;
   end Downstream_Message;

   ----------------------------------------------------------------------
   --  Other events
   ----------------------------------------------------------------------

   procedure User_Update (U : not null User_Access; E : User_Update_Event) is
      procedure Apply (Rec : in out Soja.Database.User) is
      begin
         if E.Has_Password then
            Soja.Database.Set_Password (Rec, To_String (E.Password));
         end if;
         if E.Has_Admin then
            Rec.Admin := E.Admin;
         end if;
         if E.Has_Enabled then
            Rec.Enabled := E.Enabled;
         end if;
      end Apply;
   begin
      begin
         Update_User (U, Apply'Access);
         if E.Result /= null then
            E.Result.Finish ("");
         end if;
      exception
         when Err : Operation_Error =>
            if E.Result /= null then
               E.Result.Finish (Ada.Exceptions.Exception_Message (Err));
            end if;
      end;

      --  If the password was updated, kill all the clients to force them to
      --  re-authenticate with the new credentials.
      if E.Has_Password then
         for DC of U.Downstream_Conns loop
            Soja.Conn.Close (DC.Conn);
         end loop;
      end if;
   end User_Update;

   procedure Stop_User (U : not null User_Access) is
   begin
      for DC of U.Downstream_Conns loop
         Soja.Conn.Close (DC.Conn);
      end loop;
      for Net of U.Networks loop
         declare
            Network : constant Network_Access := Net;

            procedure Store (Client_Name : String) is
            begin
               Store_Client_Delivery_Receipts (Network, Client_Name);
            end Store;
         begin
            Stop_Network (Network);
            Soja.User.For_Each_Client (Network.Delivered, Store'Access);
         end;
      end loop;
   end Stop_User;

   ------------------
   -- Handle_Event --
   ------------------

   procedure Handle_Event
     (U    : not null User_Access;
      E    : not null Event_Access;
      Stop : out Boolean)
   is
   begin
      Stop := False;

      if E.all in Upstream_Connected_Event then
         Upstream_Connected (Upstream_Connected_Event (E.all).UC);
      elsif E.all in Upstream_Disconnected_Event then
         Handle_Upstream_Disconnected (U, Upstream_Disconnected_Event (E.all).UC);
      elsif E.all in Upstream_Connection_Error_Event then
         Upstream_Connection_Error
           (Upstream_Connection_Error_Event (E.all).Net,
            To_String (Upstream_Connection_Error_Event (E.all).Error));
      elsif E.all in Upstream_Error_Event then
         Upstream_Error
           (Upstream_Error_Event (E.all).UC,
            To_String (Upstream_Error_Event (E.all).Error));
      elsif E.all in Upstream_Message_Event then
         Upstream_Message
           (Upstream_Message_Event (E.all).UC, Upstream_Message_Event (E.all).Msg);
      elsif E.all in Channel_Detach_Event then
         Channel_Detach
           (Channel_Detach_Event (E.all).UC,
            To_String (Channel_Detach_Event (E.all).Name));
      elsif E.all in Downstream_Connected_Event then
         Downstream_Connected (U, Downstream_Connected_Event (E.all).DC);
      elsif E.all in Downstream_Disconnected_Event then
         Downstream_Disconnected (U, Downstream_Disconnected_Event (E.all).DC);
      elsif E.all in Downstream_Message_Event then
         Downstream_Message
           (Downstream_Message_Event (E.all).DC,
            Downstream_Message_Event (E.all).Msg);
      elsif E.all in Broadcast_Event then
         for DC of U.Downstream_Conns loop
            Send_Message (DC, Broadcast_Event (E.all).Msg);
         end loop;
      elsif E.all in User_Update_Event then
         User_Update (U, User_Update_Event (E.all));
      elsif E.all in Try_Regain_Nick_Event then
         Try_Regain_Nick
           (Try_Regain_Nick_Event (E.all).UC,
            To_String (Try_Regain_Nick_Event (E.all).Nick));
      elsif E.all in Retry_Join_Event then
         Soja.Core.Upstream_Dispatch.Retry_Join
           (Retry_Join_Event (E.all).UC,
            To_String (Retry_Join_Event (E.all).Name));
      elsif E.all in Stop_Event then
         Stop_User (U);
         Stop := True;
      else
         raise Program_Error with "received unknown event type";
      end if;
   end Handle_Event;

end Soja.Core.User_Events;
