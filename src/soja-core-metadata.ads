pragma Ada_2022;

with Soja.Database;
with Soja.Irc.Messages;

--  The METADATA command (IRCv3 draft/metadata-2) for what the user says of a
--  target: soju.im/pinned, soju.im/muted and soju.im/blocked (doc/ext/
--  metadata.md).  downstream.go's handleMetadataSub, setMessageTargetMetadata,
--  sendTargetMetadata and the METADATA cases of its handlers.  A child of
--  Soja.Core.
package Soja.Core.Metadata is

   --  dc.handleMetadataSub: SUB, UNSUB and SUBS.  Handled is False for any
   --  other subcommand.
   function Handle_Sub
     (DC      : not null Downstream_Conn_Access;
      M       : Soja.Irc.Messages.Message;
      Handled : out Boolean) return Irc_Error_Result;

   --  METADATA before registration: the subscriptions only.
   function Handle_Unregistered
     (DC : not null Downstream_Conn_Access;
      M  : Soja.Irc.Messages.Message) return Irc_Error_Result;

   --  METADATA of a registered client.
   function Handle_Registered
     (DC : not null Downstream_Conn_Access;
      M  : Soja.Irc.Messages.Message) return Irc_Error_Result;

   --  What welcome() sends: the (empty) metadata of the user, and the targets
   --  of the network.
   procedure Send_Welcome (DC : not null Downstream_Conn_Access);

   --  dc.sendTargetMetadata.
   procedure Send_Target_Metadata
     (DC   : not null Downstream_Conn_Access;
      Info : Soja.Database.Message_Target_Info);

   --  getMessageTargetMetadata: key and value ("0" or "1") of each.
   function Pinned_Key return String is ("soju.im/pinned");
   function Muted_Key return String is ("soju.im/muted");
   function Blocked_Key return String is ("soju.im/blocked");

end Soja.Core.Metadata;
