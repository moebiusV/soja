pragma Ada_2022;

with Soja.Irc.Messages;

--  The upstreamConn message handling of upstream.go: uc.handleMessage and
--  the helpers around it (pending commands, capability negotiation, SASL,
--  MONITOR).  A child of Soja.Core because it shares its connection types.
--
--  Slice 4a: the message preamble (label / batch / time tag), PING, CAP,
--  AUTHENTICATE and the SASL/account numerics, registration (001, 004, 005,
--  end of MOTD, nick-in-use, registration errors) with the autojoin of the
--  network's saved channels, and the generic forwarding fallbacks.  The
--  channel-state, chat-message and pending-reply cases follow in 4b - 4d;
--  until then those commands take the default branch, which forwards them to
--  the downstream connections unchanged.
package Soja.Core.Upstream_Dispatch is

   --  uc.handleMessage.
   function Handle_Message
     (UC : not null Upstream_Conn_Access;
      M  : Soja.Irc.Messages.Message) return Handle_Result;

   ----------------------
   --  Forwarding --
   ----------------------

   function Downstream_By_ID
     (UC : not null Upstream_Conn_Access; ID : Long_Long_Integer)
      return Downstream_Conn_Access;

   --  uc.forwardMessage / forwardMsgByID (ID 0 = every downstream).
   procedure Forward_Message
     (UC : not null Upstream_Conn_Access; M : Soja.Irc.Messages.Message);
   procedure Forward_Msg_By_ID
     (UC : not null Upstream_Conn_Access;
      ID : Long_Long_Integer;
      M  : Soja.Irc.Messages.Message);

   --  uc.isChannel.
   function Is_Channel
     (UC : not null Upstream_Conn_Access; Entity : String) return Boolean;

   --  uc.SendMessageLabeled: tag the message so the reply can be routed back
   --  to the downstream (ID) that asked, when the server supports it.
   procedure Send_Message_Labeled
     (UC : not null Upstream_Conn_Access;
      ID : Long_Long_Integer;
      M  : Soja.Irc.Messages.Message);

   ------------------------
   --  Pending commands --
   ------------------------

   --  Commands forwarded for a downstream whose reply is awaited, per command
   --  name: the first has been sent, the rest are queued.

   procedure Enqueue_Command
     (UC : not null Upstream_Conn_Access;
      DC : not null Downstream_Conn_Access;
      M  : Soja.Irc.Messages.Message);

   type Pending_Command is record
      Found : Boolean := False;
      DC    : Downstream_Conn_Access;   --  null when it disconnected
      Msg   : Soja.Irc.Messages.Message;
   end record;

   function Current_Pending_Command
     (UC : not null Upstream_Conn_Access; Cmd : String) return Pending_Command;
   function Dequeue_Command
     (UC : not null Upstream_Conn_Access; Cmd : String) return Pending_Command;

   procedure Abort_Pending_Commands (UC : not null Upstream_Conn_Access);
   procedure Cancel_Pending_Commands_By_Downstream_ID
     (UC : not null Upstream_Conn_Access; ID : Long_Long_Integer);

   ----------------------------------
   --  Capabilities, SASL, MONITOR --
   ----------------------------------

   procedure Handle_Supported_Caps
     (UC : not null Upstream_Conn_Access; Caps : String);
   procedure Update_Caps (UC : not null Upstream_Conn_Access);

   --  uc.supportsSASL.  (Go's version compares the mechanism with itself, so
   --  it is true whenever the server advertises "sasl" at all; kept.)
   function Supports_SASL
     (UC : not null Upstream_Conn_Access; Mech : String) return Boolean;
   function Request_SASL (UC : not null Upstream_Conn_Access) return Boolean;

   --  uc.updateMonitor: sync the MONITOR list with what the clients watch.
   procedure Update_Monitor (UC : not null Upstream_Conn_Access);

   --  uc.shouldCacheUserInfo.
   function Should_Cache_User_Info
     (UC : not null Upstream_Conn_Access; Nick : String) return Boolean;

end Soja.Core.Upstream_Dispatch;
