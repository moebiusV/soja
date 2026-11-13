pragma Ada_2022;

with Soja.Irc.Messages;

--  The downstreamConn methods the upstream message handler calls to keep
--  its clients in sync (downstream.go: prefix, upstream, setSupportedCap ...
--  updateAccount, endSASL).  A child of Soja.Core because they share its
--  connection types.
package Soja.Core.Downstream_Helpers is

   --  dc.prefix(): nick!username@hostname.
   function Prefix_Of (DC : not null Downstream_Conn_Access)
      return Soja.Irc.Messages.Prefix;

   --  dc.upstream(): the network's upstream connection, or null (also when
   --  the client is on the bouncer connection, with no network).
   function Upstream_Of (DC : not null Downstream_Conn_Access)
      return Upstream_Conn_Access;

   --  dc.setSupportedCap / unsetSupportedCap: (un)advertise a capability,
   --  telling clients that enabled cap-notify.
   procedure Set_Supported_Cap
     (DC : not null Downstream_Conn_Access; Name, Value : String);
   procedure Unset_Supported_Cap
     (DC : not null Downstream_Conn_Access; Name : String);

   --  dc.updateSupportedCaps: recompute the capabilities that depend on the
   --  upstream's (those every upstream must support, sasl, account
   --  registration, event playback).
   procedure Update_Supported_Caps (DC : not null Downstream_Conn_Access);

   procedure Update_Nick (DC : not null Downstream_Conn_Access);
   procedure Update_Host (DC : not null Downstream_Conn_Access);
   procedure Update_Realname (DC : not null Downstream_Conn_Access);
   procedure Update_Account (DC : not null Downstream_Conn_Access);

   --  dc.endSASL: finish a client's SASL exchange, relaying M (the upstream's
   --  verdict), or a "successful" 903 when none is given.
   procedure End_SASL
     (DC : not null Downstream_Conn_Access;
      M  : Soja.Irc.Messages.Message);
   procedure End_SASL (DC : not null Downstream_Conn_Access);


   ------------------------------------------------------------------
   --  Message IDs (delivery receipts) and channel replay
   ------------------------------------------------------------------

   --  dc.messageSupportsBacklog: only PRIVMSG and NOTICE are replayed,
   --  because replaying anything else would mess up client state.
   function Message_Supports_Backlog
     (M : Soja.Irc.Messages.Message) return Boolean;

   --  dc.sendMessageWithID: send M, then (for clients without
   --  draft/chathistory) a PING whose token carries the message's internal
   --  ID, so the client's PONG acknowledges delivery.  ID "" sends no PING.
   procedure Send_Message_With_ID
     (DC : not null Downstream_Conn_Access;
      M  : Soja.Irc.Messages.Message;
      ID : String);

   --  dc.advanceMessageWithID: advance history to ID without sending M (e.g.
   --  for self-messages when echo-message isn't enabled).
   procedure Advance_Message_With_ID
     (DC : not null Downstream_Conn_Access;
      M  : Soja.Irc.Messages.Message;
      ID : String);

   --  dc.ackMsgID / handlePong: record that this client received ID.
   procedure Ack_Msg_ID (DC : not null Downstream_Conn_Access; ID : String);
   procedure Handle_Pong (DC : not null Downstream_Conn_Access; Token : String);

   --  sendTopic / sendNames / forwardChannel (downstream.go): replay a joined
   --  channel's topic, read marker and member list to a client.
   procedure Send_Topic
     (DC : not null Downstream_Conn_Access;
      Ch : not null Upstream_Channel_Access);
   procedure Send_Names
     (DC : not null Downstream_Conn_Access;
      Ch : not null Upstream_Channel_Access);
   procedure Forward_Channel
     (DC : not null Downstream_Conn_Access;
      Ch : not null Upstream_Channel_Access);

end Soja.Core.Downstream_Helpers;
