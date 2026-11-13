pragma Ada_2022;

with Soja.Irc.Messages;

--  The `network` methods of user.go that decide how chat messages and
--  detached channels are handled: isHighlight, detachedMessageNeedsRelay,
--  detach and attach.  A child of Soja.Core (they share its types).
package Soja.Core.Network_Ops is

   --  net.isHighlight: a PRIVMSG/NOTICE that mentions our nick, sent by
   --  someone else.  (An empty nick, which Go would panic on, is never a
   --  highlight.)
   function Is_Highlight
     (Net : not null Network_Access;
      Msg : Soja.Irc.Messages.Message) return Boolean;

   --  net.detachedMessageNeedsRelay: whether a message in a detached channel
   --  must be relayed to the clients as a service notice.
   function Detached_Message_Needs_Relay
     (Net : not null Network_Access;
      Ch  : not null Channel_Access;
      Msg : Soja.Irc.Messages.Message) return Boolean;

   --  net.detach: mark the channel detached (clients get a PART "Detach"),
   --  remember where its history stood, and stop its idle timer.  The caller
   --  persists the channel record.
   procedure Detach
     (Net : not null Network_Access; Ch : not null Channel_Access);

   --  net.attach: undo Detach (clients get a JOIN, the channel replay and the
   --  backlog since it was detached).  The caller persists the record.
   procedure Attach
     (Net : not null Network_Access; Ch : not null Channel_Access);

   --  net.deleteChannel: forget a saved channel (and its idle timer).  Raises
   --  Soja.Core.User_Ops.Operation_Error when it is not saved or the database
   --  refuses.
   procedure Delete_Channel
     (Net : not null Network_Access; Name : String);

end Soja.Core.Network_Ops;
