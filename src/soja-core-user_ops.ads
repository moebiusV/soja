pragma Ada_2022;

with Soja.Database;
with Soja.Irc.Messages;

--  The `user` and `network` operations of user.go that change what a user
--  has: addNetwork / removeNetwork / checkNetwork / createNetwork /
--  updateNetwork / deleteNetwork, updateUser, the upstream-disconnect
--  bookkeeping and the delivery-receipt persistence.  They run on the
--  user's own task (the event loop), like their Go originals.
package Soja.Core.User_Ops is

   --  Go's `error` returns: the text is what the user is told.
   Operation_Error : exception;

   --  getNetworkAttrs (downstream.go): the BOUNCER NETWORK attributes.
   function Network_Attrs (Net : not null Network_Access)
      return Soja.Irc.Messages.Tag_Map;

   --  user.notifyBouncerNetworkState: BOUNCER NETWORK <id> <attrs> to the
   --  clients that asked for notifications (not for removed networks).
   procedure Notify_Bouncer_Network_State
     (U      : not null User_Access;
      Net_ID : Long_Long_Integer;
      Attrs  : Soja.Irc.Messages.Tag_Map);

   --  user.addNetwork / removeNetwork.  Add starts the network's task;
   --  Remove stops it and closes the clients that are on it.
   procedure Add_Network (U : not null User_Access; Net : not null Network_Access);
   procedure Remove_Network
     (U : not null User_Access; Net : not null Network_Access);

   --  user.checkNetwork: raises Operation_Error if the record is not
   --  acceptable (bad URL, empty or duplicate name, ...).
   procedure Check_Network
     (U : not null User_Access; Rec : Soja.Database.Network);

   --  user.createNetwork / updateNetwork / deleteNetwork.  Update reconnects
   --  with a fresh network built from the new record.
   function Create_Network
     (U : not null User_Access; Rec : Soja.Database.Network)
      return Network_Access;
   function Update_Network
     (U : not null User_Access; Rec : Soja.Database.Network)
      return Network_Access;
   procedure Delete_Network (U : not null User_Access; ID : Long_Long_Integer);

   --  user.updateUser: let Update change a copy of the record, store it, and
   --  apply the consequences (new nick / realname / enabled state).
   procedure Update_User
     (U      : not null User_Access;
      Update : not null access procedure
                 (Rec : in out Soja.Database.User));

   --  user.handleUpstreamDisconnected.
   procedure Handle_Upstream_Disconnected
     (U : not null User_Access; UC : not null Upstream_Conn_Access);

   --  network.storeClientDeliveryReceipts.
   procedure Store_Client_Delivery_Receipts
     (Net : not null Network_Access; Client_Name : String);

   --  user.bumpDownstreamInteractionTime.
   procedure Bump_Downstream_Interaction_Time (U : not null User_Access);

end Soja.Core.User_Ops;
