pragma Ada_2022;

with Soja.Irc.Messages;

--  The part of downstream.go that takes a freshly accepted client from its
--  first byte to a welcomed, registered connection: CAP negotiation, SASL
--  authentication, PASS authentication, registration, loading (or creating)
--  the network it wants, and the welcome burst.  A child of Soja.Core.
package Soja.Core.Downstream_Handshake is

   --  sanityCheckServer: when a client asks for a network we don't know by
   --  name ("user/irc.example"), soja first checks that a TLS connection to it
   --  works.  Returns "" when it does, otherwise the error text.  A variable
   --  so that tests can replace it.
   function Default_Sanity_Check (Addr : String) return String;
   type Sanity_Check_Function is access function (Addr : String) return String;
   Sanity_Check : Sanity_Check_Function := Default_Sanity_Check'Access;

   --  dc.handleCap.
   function Handle_Cap
     (DC : not null Downstream_Conn_Access;
      M  : Soja.Irc.Messages.Message) return Irc_Error_Result;

   --  dc.handleAuthenticate: one step of the client's SASL exchange.  Done is
   --  True when the client's credentials are complete (in DC.Sasl);
   --  otherwise the exchange goes on (a challenge may have been sent) or
   --  Result says why it failed (DC.Sasl is then reset).
   type Authenticate_Step is record
      Done   : Boolean := False;
      Result : Irc_Error_Result;
   end record;

   function Handle_Authenticate
     (DC : not null Downstream_Conn_Access;
      M  : Soja.Irc.Messages.Message) return Authenticate_Step;

   --  dc.handleMessageUnregistered: NICK, USER, PASS, CAP, AUTHENTICATE,
   --  BOUNCER BIND and AWAY.
   function Handle_Message_Unregistered
     (DC : not null Downstream_Conn_Access;
      M  : Soja.Irc.Messages.Message) return Irc_Error_Result;

   --  dc.register: authenticate (PASS, unless SASL did it) and mark the
   --  connection registered.
   function Register
     (DC : not null Downstream_Conn_Access) return Irc_Error_Result;

   --  dc.loadNetwork: attach the client to the network it asked for (by
   --  BOUNCER BIND or by "user/network"), creating it when it is a new
   --  address.  Runs on the user's task.
   function Load_Network
     (DC : not null Downstream_Conn_Access) return Irc_Error_Result;

   --  dc.welcome: the welcome burst of a newly registered client.
   function Welcome
     (DC : not null Downstream_Conn_Access; U : not null User_Access)
      return Irc_Error_Result;

   --  dc.runUntilRegistered: read and handle the client's commands until it
   --  is registered.  False when it went away, timed out, or failed.  Errors
   --  that are IRC replies are sent to the client.
   function Run_Until_Registered
     (DC : not null Downstream_Conn_Access) return Boolean;

end Soja.Core.Downstream_Handshake;
