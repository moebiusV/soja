pragma Ada_2022;

with Ada.Calendar;
with Ada.Containers.Doubly_Linked_Lists;
with Ada.Exceptions;
with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;
with Ada.Unchecked_Deallocation;

with Soja.Logging;
with Soja.Webpush;

package body Soja.Core.Push is

   use type Ada.Calendar.Time;

   Prune_Delay : constant Duration :=
     Soja.Server.Webpush_Prune_Subscription_Delay;

   ----------------------------------------------------------------------
   --  loadWebPushConfig
   ----------------------------------------------------------------------

   procedure Load_Config (Srv : in out Soja.Server.Server) is
      DB : constant Soja.Database.Database_Access := Srv.DB;
   begin
      declare
         Configs : constant Soja.Database.WebPush_Config_Lists.Vector :=
           DB.List_WebPush_Configs;
      begin
         if Natural (Configs.Length) > 1 then
            raise Constraint_Error with
              "expected zero or one Web push config, got"
              & Natural'Image (Natural (Configs.Length));
         elsif Natural (Configs.Length) = 1 then
            Srv.Set_Web_Push (Configs.First_Element);
            return;
         end if;
      end;

      Srv.Logger.Print ("generating Web push VAPID key pair");
      declare
         Config : Soja.Database.WebPush_Config;
      begin
         begin
            Soja.Webpush.Generate_VAPID_Keys
              (Config.VAPID_Private, Config.VAPID_Public);
         exception
            when E : Soja.Webpush.Webpush_Error =>
               raise Constraint_Error with
                 "failed to generate Web push VAPID key pair: "
                 & Ada.Exceptions.Exception_Message (E);
         end;
         DB.Store_WebPush_Config (Config);
         Srv.Set_Web_Push (Config);
      end;
   end Load_Config;

   ----------------------------------------------------------------------
   --  sendWebPush
   ----------------------------------------------------------------------

   procedure Send
     (Srv : Soja.Server.Server;
      Sub : Soja.Database.WebPush_Subscription;
      Msg : Soja.Irc.Messages.Message)
   is
      Config  : constant Soja.Database.WebPush_Config := Srv.Web_Push;
      Command : constant String := To_String (Msg.Command);
      Status  : Natural;
   begin
      if To_String (Sub.Key_VAPID) /= To_String (Config.VAPID_Public) then
         raise Push_Error with
           "unknown VAPID public key """ & To_String (Sub.Key_VAPID) & '"';
      end if;
      begin
         Status := Soja.Webpush.Send
           (Endpoint   => To_String (Sub.Endpoint),
            Auth       => To_String (Sub.Key_Auth),
            P256DH     => To_String (Sub.Key_P256DH),
            VAPID_Pub  => To_String (Config.VAPID_Public),
            VAPID_Priv => To_String (Config.VAPID_Private),
            Payload    => Soja.Irc.Messages.Image (Msg),
            Priority   =>
              (if Command = "PRIVMSG" or else Command = "NOTICE"
                 or else Command = "INVITE"
               then Soja.Webpush.High else Soja.Webpush.Normal));
      exception
         when E : others =>
            raise Push_Error with Ada.Exceptions.Exception_Message (E);
      end;
      if Status = 404 then
         raise Subscription_Expired;
      elsif Status / 100 /= 2 then
         raise Push_Error with "HTTP error:" & Natural'Image (Status);
      end if;
   end Send;

   ----------------------------------------------------------------------
   --  broadcastWebPush
   ----------------------------------------------------------------------

   --  What a worker needs, copied so that the network may go away meanwhile.
   type Job is record
      Srv        : Soja.Server.Server_Access;
      Logger     : Soja.Logging.Logger_Access;
      User_ID    : Long_Long_Integer;
      Network_ID : Long_Long_Integer;
      Msg        : Soja.Irc.Messages.Message;
   end record;

   procedure Run (J : Job) is
      DB   : constant Soja.Database.Database_Access := J.Srv.DB;
      Subs : Soja.Database.WebPush_Subscription_Lists.Vector;
      Start : constant Ada.Calendar.Time := Ada.Calendar.Clock;
   begin
      Subs := DB.List_WebPush_Subscriptions (J.User_ID, J.Network_ID);
      for Sub of Subs loop
         --  (5 minutes for the whole broadcast, as Go's context has.)
         exit when Ada.Calendar.Clock - Start > 300.0;
         begin
            Send (J.Srv.all, Sub, J.Msg);
         exception
            when Subscription_Expired =>
               begin
                  DB.Delete_WebPush_Subscription (Sub.ID);
                  J.Logger.Debug
                    ("deleted expired Web Push subscription """
                     & To_String (Sub.Endpoint) & '"');
               exception
                  when E : others =>
                     J.Logger.Print
                       ("failed to delete expired Web Push subscription """
                        & To_String (Sub.Endpoint) & """: "
                        & Ada.Exceptions.Exception_Message (E));
               end;
            when E : Push_Error =>
               J.Logger.Print
                 ("failed to send Web push notification to endpoint """
                  & To_String (Sub.Endpoint) & """: "
                  & Ada.Exceptions.Exception_Message (E));
               --  If it failed for any reason and is old, delete it.
               if Ada.Calendar.Clock - Sub.Updated_At > Prune_Delay then
                  begin
                     DB.Delete_WebPush_Subscription (Sub.ID);
                     J.Logger.Print
                       ("deleted pruned Web Push subscription """
                        & To_String (Sub.Endpoint) & '"');
                  exception
                     when E2 : others =>
                        J.Logger.Print
                          ("failed to delete pruned Web Push subscription """
                           & To_String (Sub.Endpoint) & """: "
                           & Ada.Exceptions.Exception_Message (E2));
                  end;
               end if;
         end;
      end loop;
   exception
      when E : others =>
         J.Logger.Print
           ("failed to list Web push subscriptions: "
            & Ada.Exceptions.Exception_Message (E));
   end Run;

   --  One short-lived task per broadcast (as Go has a goroutine); the ones
   --  that ended are freed at the next broadcast.
   type Job_Access is access Job;
   procedure Free_Job is new Ada.Unchecked_Deallocation (Job, Job_Access);

   task type Sender (J : Job_Access);
   type Sender_Access is access Sender;

   task body Sender is
      Mine : Job_Access := J;
   begin
      Run (Mine.all);
      Free_Job (Mine);
   end Sender;

   package Sender_Lists is new Ada.Containers.Doubly_Linked_Lists
     (Sender_Access);

   protected Registry is
      procedure Add (T : Sender_Access);
      procedure Reap;
   private
      Items : Sender_Lists.List;
   end Registry;

   procedure Free_Sender is new Ada.Unchecked_Deallocation
     (Sender, Sender_Access);

   protected body Registry is
      procedure Add (T : Sender_Access) is
      begin
         Items.Append (T);
      end Add;

      procedure Reap is
         use Sender_Lists;
         C : Cursor := Items.First;
         N : Cursor;
         T : Sender_Access;
      begin
         while Has_Element (C) loop
            N := Next (C);
            T := Element (C);
            if T'Terminated then
               Items.Delete (C);
               Free_Sender (T);
            end if;
            C := N;
         end loop;
      end Reap;
   end Registry;

   procedure Broadcast
     (Net : not null Network_Access; Msg : Soja.Irc.Messages.Message)
   is
      J : constant Job_Access := new Job'
        (Srv        => Net.User.Srv,
         Logger     => Net.Logger,
         User_ID    => Net.User.User_Record.ID,
         Network_ID => Net.Network_Record.ID,
         Msg        => Msg);
   begin
      Registry.Reap;
      Registry.Add (new Sender (J));
   end Broadcast;

end Soja.Core.Push;
