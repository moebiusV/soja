--  Soja.Core.Push -- soju's Web Push glue: server.go's loadWebPushConfig and
--  sendWebPush, and user.go's network.broadcastWebPush.
pragma Ada_2022;

with Soja.Irc.Messages;
with Soja.Database;
with Soja.Server;

package Soja.Core.Push is

   Push_Error           : exception;   --  sendWebPush failed
   Subscription_Expired : exception;   --  the endpoint said 404 (RFC 8030 7.3)

   --  loadWebPushConfig: reads the key pair from the database, making one when
   --  there is none.  Raises Constraint_Error with Soju's text on failure.
   procedure Load_Config (Srv : in out Soja.Server.Server);

   --  sendWebPush: Push_Error, or Subscription_Expired.
   procedure Send
     (Srv : Soja.Server.Server;
      Sub : Soja.Database.WebPush_Subscription;
      Msg : Soja.Irc.Messages.Message);

   --  network.broadcastWebPush: sends Msg to each Web Push endpoint of the
   --  network's user.  It returns at once: a task of its own does the sending
   --  (it can take a while).
   procedure Broadcast
     (Net : not null Network_Access; Msg : Soja.Irc.Messages.Message);

end Soja.Core.Push;
