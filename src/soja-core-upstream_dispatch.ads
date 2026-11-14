pragma Ada_2022;

with Ada.Containers.Vectors;
with Ada.Strings.Unbounded;

with Soja.Irc.Genmsg;
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

   --  The ISUPPORT tokens the server sent that clients get as they are
   --  ("NAME=value" or "NAME"), for the welcome burst.
   function Passthrough_Isupport_Tokens
     (UC : not null Upstream_Conn_Access)
      return Soja.Irc.Genmsg.String_Vectors.Vector;

   --  dc.buildIsupport: the tokens this client is to be sent now.
   function Build_Isupport
     (DC : not null Downstream_Conn_Access) return Isupport_Maps.Map;

   --  sendIsupport: the tokens, sorted, in RPL_ISUPPORT messages (in a
   --  draft/isupport batch for a client with draft/extended-isupport).
   procedure Send_Isupport
     (DC : not null Downstream_Conn_Access; Tokens : Isupport_Maps.Map);

   --  dc.updateIsupport: sends what changed since the client was last sent
   --  its tokens (a removed token as "-NAME").  A client that has not
   --  registered gets nothing, unless it asked for draft/extended-isupport.
   procedure Update_Isupport (DC : not null Downstream_Conn_Access);

   --  uc.getCachedWHO: answer a WHO from the user-info cache, when it holds
   --  every field asked for -- of the user the mask names, or of every member
   --  of the channel it names.  Found is False when the cache cannot answer.
   package User_Vectors is new Ada.Containers.Vectors
     (Positive, Soja.Upstream.Upstream_User, "=" => Soja.Upstream."=");

   type Cached_Who is record
      Found : Boolean := False;
      Users : User_Vectors.Vector;
   end record;

   function Get_Cached_Who
     (UC     : not null Upstream_Conn_Access;
      Mask   : String;
      Fields : String) return Cached_Who;

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

   --  uc.updateAway: with auto-away enabled, mark us away while no client is
   --  connected (or every client is away), and back otherwise.
   procedure Update_Away (UC : not null Upstream_Conn_Access);

   --  uc.updateMonitor: sync the MONITOR list with what the clients watch.
   procedure Update_Monitor (UC : not null Upstream_Conn_Access);

   --  Channel-full retries (soja-specific).  When a saved channel is full
   --  (ERR_CHANNELISFULL) soja retries joining it with an exponential
   --  backoff, until we are in, kicked from it, or it is no longer saved; it
   --  never retries other refusals (banned, bad key, invite-only, ...).
   --  Retry_Join runs when a Retry_Join_Event is handled; Stop_Join_Retries
   --  must be called when the upstream connection goes away.
   procedure Retry_Join (UC : not null Upstream_Conn_Access; Name : String);
   procedure Cancel_Join_Retry
     (UC : not null Upstream_Conn_Access; Name : String);
   procedure Stop_Join_Retries (UC : not null Upstream_Conn_Access);

   --  The retry delays (variables so that tests can shorten them).
   Join_Retry_Min    : Duration := 10.0;
   Join_Retry_Max    : Duration := 300.0;
   Join_Retry_Jitter : Duration := 5.0;

   --  uc.shouldCacheUserInfo.
   function Should_Cache_User_Info
     (UC : not null Upstream_Conn_Access; Nick : String) return Boolean;

end Soja.Core.Upstream_Dispatch;
