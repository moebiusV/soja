pragma Ada_2022;

with Soja.Irc.Messages;
with Soja.Server;

--  downstream.go's handleMessageRegistered: what the bouncer does with each
--  command of a registered client -- answer it itself, or relay it to the
--  upstream network.  A child of Soja.Core.
package Soja.Core.Downstream_Commands is

   --  BouncerServ (service.go).  A message sent to the service by a client
   --  is handed to Service_Handler, which answers through
   --  Downstream_Helpers.Send_Service_Privmsg.  The command set arrives with
   --  the service port; until then this default says so.
   type Service_Handler_Access is access procedure
     (DC : not null Downstream_Conn_Access; Text : String);

   procedure Default_Service_Handler
     (DC : not null Downstream_Conn_Access; Text : String);

   Service_Handler : Service_Handler_Access := Default_Service_Handler'Access;

   --   + eventBroadcast: deliver Msg to every bouncer user's
   --  clients (a bouncer-wide NOTICE by an admin).  The server's user table
   --  does not exist yet (Server.Handle); until it registers this, only the
   --  sender's own user is reached.
   type Broadcast_Hook_Access is access procedure
     (Srv  : not null Soja.Server.Server_Access;
      From : not null User_Access;
      Msg  : Soja.Irc.Messages.Message);

   Broadcast_Hook : Broadcast_Hook_Access := null;

   procedure Broadcast_To_All_Users
     (Srv  : not null Soja.Server.Server_Access;
      From : not null User_Access;
      Msg  : Soja.Irc.Messages.Message);

   --  dc.handleMessageRegistered.
   function Handle_Message_Registered
     (DC : not null Downstream_Conn_Access;
      M  : Soja.Irc.Messages.Message) return Irc_Error_Result;

end Soja.Core.Downstream_Commands;
