--  Soja.Core.Push -- soju's Web Push glue: server.go's loadWebPushConfig and
--  sendWebPush, and user.go's network.broadcastWebPush.
pragma Ada_2022;

with Ada.Calendar;

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

   --  How long a message's notification waits for a client to say that the
   --  buffer was read (a variable, so that tests need not wait).
   Check_Delay : Duration := 5.0;

   --  What soju does with time.AfterFunc(5*time.Second): after Check_Delay,
   --  the user's task is told (Push_Check_Event) to run Handle_Check.
   procedure Defer_Check
     (Net    : not null Network_Access;
      Buffer : String;
      Stamp  : Ada.Calendar.Time;
      Msg    : Soja.Irc.Messages.Message);

   --  Ends the waits that are still going (the bouncer is shutting down).
   procedure Cancel_Checks;

   --  The read receipt of the buffer is looked at again: when it is not as new
   --  as the message, the message is pushed, and remembered as the last one
   --  of its buffer.
   procedure Handle_Check (E : Push_Check_Event);

   --  network.broadcastWebPush: sends Msg to each Web Push endpoint of the
   --  network's user.  It returns at once: a task of its own does the sending
   --  (it can take a while).
   procedure Broadcast
     (Net : not null Network_Access; Msg : Soja.Irc.Messages.Message);

end Soja.Core.Push;
