pragma Ada_2022;

with Soja.Irc.Messages;

--  downstream.go's handleMessageRegistered: what the bouncer does with each
--  command of a registered client -- answer it itself, or relay it to the
--  upstream network.  A child of Soja.Core.
package Soja.Core.Downstream_Commands is

   --  dc.handleMessageRegistered.
   function Handle_Message_Registered
     (DC : not null Downstream_Conn_Access;
      M  : Soja.Irc.Messages.Message) return Irc_Error_Result;

end Soja.Core.Downstream_Commands;
