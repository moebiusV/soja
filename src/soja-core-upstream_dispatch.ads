pragma Ada_2022;

with Ada.Strings.Unbounded;

with Soja.Irc.Members;
with Soja.Irc.Messages;
with Soja.Upstream;

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

   --  uc.cacheUserInfo: remember (or merge) what is known about a user.
   procedure Cache_User_Info
     (UC   : not null Upstream_Conn_Access;
      Nick : String;
      Info : Soja.Upstream.Upstream_User);

   --  uc.updateChannelAutoDetach: (re)arm the idle-detach timer of a channel
   --  that is attached.
   procedure Update_Channel_Auto_Detach
     (UC : not null Upstream_Conn_Access; Name : String);

   --  uc.produce: append Msg to the logs of Target (when non-empty) and send
   --  it to the downstream connections -- or only advance their history when
   --  the channel is detached, or the message is the echo of what a client
   --  sent without echo-message.  Origin_ID is the downstream that sent it
   --  (0 for none).
   procedure Produce
     (UC        : not null Upstream_Conn_Access;
      Target    : String;
      Msg       : Soja.Irc.Messages.Message;
      Origin_ID : Long_Long_Integer);

   --  uc.parseMembershipPrefix: split a NAMES entry ("@+nick") into its
   --  memberships and the nick.
   procedure Parse_Membership_Prefix
     (UC          : not null Upstream_Conn_Access;
      S           : String;
      Memberships : out Soja.Irc.Members.Membership_Vectors.Vector;
      Nick        : out Ada.Strings.Unbounded.Unbounded_String);

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

   --  uc.supportsSASL: the server advertises SASL with that mechanism (or
   --  with no mechanism list).
   function Supports_SASL
     (UC : not null Upstream_Conn_Access; Mech : String) return Boolean;
   function Request_SASL (UC : not null Upstream_Conn_Access) return Boolean;

   --  uc.updateMonitor: sync the MONITOR list with what the clients watch.
   procedure Update_Monitor (UC : not null Upstream_Conn_Access);

   --  uc.shouldCacheUserInfo.
   function Should_Cache_User_Info
     (UC : not null Upstream_Conn_Access; Nick : String) return Boolean;

end Soja.Core.Upstream_Dispatch;
