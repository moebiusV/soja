pragma Ada_2022;

with Ada.Strings.Unbounded;
with Soja.Irc.Messages;

--  Soja.Downstream — the downstream (client-facing) connection, translated
--  from downstream.go.  This first slice carries the ircError type and the
--  leaf helpers; the downstreamConn type and its message/registration logic
--  follow once the shared user/network/upstream types are ported.
package Soja.Downstream is

   use Ada.Strings.Unbounded;

   --  downstream.go's ircError: an error carrying the IRC reply to send back
   --  to the client (a numeric or a FAIL message).
   type Irc_Error is record
      Message : Soja.Irc.Messages.Message;
   end record;

   function Image (E : Irc_Error) return String;  -- Go's Error()

   function New_Unknown_Command_Error (Cmd : String) return Irc_Error;
   function New_Unknown_Irc_Error (Cmd, Text : String) return Irc_Error;
   function New_Need_More_Params_Error (Cmd : String) return Irc_Error;
   function New_Chat_History_Error (Subcommand, Target : String)
      return Irc_Error;

   --  parseBouncerNetID: a FAIL BOUNCER INVALID_NETID error on a non-positive
   --  or unparsable decimal network ID.
   type Parse_Net_ID_Result (Ok : Boolean := False) is record
      case Ok is
         when True  => ID  : Long_Long_Integer;
         when False => Err : Irc_Error;
      end case;
   end record;

   function Parse_Bouncer_Net_ID (Subcommand, S : String)
      return Parse_Net_ID_Result;

   --  unmarshalUsername: split "user@client/network" into its parts; empty
   --  Client/Network when absent.
   procedure Unmarshal_Username
     (Raw : String; Username, Client, Network : out Unbounded_String);

end Soja.Downstream;
