pragma Ada_2022;

with Ada.Calendar;
with Ada.Containers.Vectors;
with Ada.Strings.Unbounded;

with Soja.Conn;
with Soja.Database;
with Soja.Irc.Cap_Registry;
with Soja.Irc.Case_Mapping;
with Soja.Irc.Case_Mapping_Maps;
with Soja.Irc.Members;
with Soja.Irc.Messages;
with Soja.Irc.User_Modes;
with Soja.Logging;
with Soja.Server;
with Soja.Upstream;
with Soja.User;

--  Soja.Core — the mutually-dependent connection types of the bouncer core,
--  consolidated from downstream.go, upstream.go and user.go (which in Go all
--  live in the single `package soju`).  This slice establishes the structs,
--  the event types, and the Signal primitive; the constructors and the
--  user.run() event loop follow.
package Soja.Core is

   use Ada.Strings.Unbounded;
   use Soja.Irc.Case_Mapping;

   --  Forward declarations for the mutually-referencing types.
   type User is tagged;
   type Network is tagged;
   type Downstream_Conn is tagged;
   type Upstream_Conn is tagged;
   type Upstream_Channel is tagged;

   type User_Access is access all User;
   type Network_Access is access all Network;
   type Downstream_Conn_Access is access all Downstream_Conn;
   type Upstream_Conn_Access is access all Upstream_Conn;
   type Upstream_Channel_Access is access all Upstream_Channel;
   type Channel_Access is access all Soja.Database.Channel;
   type Upstream_User_Access is access all Soja.Upstream.Upstream_User;

   --------------
   --  Signal --
   --------------

   --  A one-shot "closed" flag (Go's done/stopped channels): Wait blocks until
   --  Set, Is_Set is the non-blocking select-default check.
   protected type Signal is
      procedure Set;
      function Is_Set return Boolean;
      entry Wait;
   private
      Set_Flag : Boolean := False;
   end Signal;

   type Signal_Access is access all Signal;

   ----------------
   --  Containers --
   ----------------

   package Network_Vectors is new Ada.Containers.Vectors
     (Positive, Network_Access);
   package Downstream_Conn_Vectors is new Ada.Containers.Vectors
     (Positive, Downstream_Conn_Access);

   package Channel_Maps is new Soja.Irc.Case_Mapping_Maps
     (Element => Channel_Access, Null_Element => null);
   package Upstream_Channel_Maps is new Soja.Irc.Case_Mapping_Maps
     (Element => Upstream_Channel_Access, Null_Element => null);
   package Upstream_User_Maps is new Soja.Irc.Case_Mapping_Maps
     (Element => Upstream_User_Access, Null_Element => null);

   ---------------------------
   --  downstreamRegistration --
   ---------------------------

   type Downstream_Registration is record
      Nick              : Unbounded_String;
      Username          : Unbounded_String;
      Pass              : Unbounded_String;
      Network_Name      : Unbounded_String;
      Network_ID        : Long_Long_Integer := 0;
      Negotiating_Caps  : Boolean := False;
      Auth_Username     : Unbounded_String;
   end record;

   type Downstream_Registration_Access is access Downstream_Registration;

   --------------
   --  Events --
   --------------

   --  user.go's `event` interface, one tagged type per variant.
   type Event is abstract tagged null record;
   type Event_Access is access all Event'Class;

   type Upstream_Message_Event is new Event with record
      Msg : Soja.Irc.Messages.Message;
      UC  : Upstream_Conn_Access;
   end record;

   type Upstream_Connection_Error_Event is new Event with record
      Net   : Network_Access;
      Error : Unbounded_String;
   end record;

   type Upstream_Connected_Event is new Event with record
      UC : Upstream_Conn_Access;
   end record;

   type Upstream_Disconnected_Event is new Event with record
      UC : Upstream_Conn_Access;
   end record;

   type Upstream_Error_Event is new Event with record
      UC    : Upstream_Conn_Access;
      Error : Unbounded_String;
   end record;

   type Downstream_Message_Event is new Event with record
      Msg : Soja.Irc.Messages.Message;
      DC  : Downstream_Conn_Access;
   end record;

   type Downstream_Connected_Event is new Event with record
      DC : Downstream_Conn_Access;
   end record;

   type Downstream_Disconnected_Event is new Event with record
      DC : Downstream_Conn_Access;
   end record;

   type Channel_Detach_Event is new Event with record
      UC   : Upstream_Conn_Access;
      Name : Unbounded_String;
   end record;

   type Broadcast_Event is new Event with record
      Msg : Soja.Irc.Messages.Message;
   end record;

   type Stop_Event is new Event with null record;

   type Try_Regain_Nick_Event is new Event with record
      UC   : Upstream_Conn_Access;
      Nick : Unbounded_String;
   end record;

   --  eventUserUpdate and eventUserRun (synchronous request events, with their
   --  done/print/ret channels) are deferred to the event-loop slice.

   -------------------
   --  Event queue --
   -------------------

   --  user.go's `events chan event` (buffered 64) merged with `done chan
   --  struct{}`: the run loop selects on both, which Ada expresses as one
   --  protected object.  Enqueue blocks when full; Dequeue blocks when empty
   --  and returns Done once Close was called and the queue drains.
   Event_Capacity : constant := 64;
   type Event_Array is array (1 .. Event_Capacity) of Event_Access;

   protected type Event_Queue is
      entry Enqueue (E : Event_Access);
      entry Dequeue (E : out Event_Access; Done : out Boolean);
      procedure Close;
      function Is_Closed return Boolean;
   private
      Buf    : Event_Array;
      Head   : Positive := 1;
      Count  : Natural := 0;
      Closed : Boolean := False;
   end Event_Queue;

   type Event_Queue_Access is access all Event_Queue;

   -------------
   --  Structs --
   -------------

   type User is tagged record
      User_Record : Soja.Database.User;
      Srv         : Soja.Server.Server_Access;
      Logger      : Soja.Logging.Logger_Access;

      Networks         : Network_Vectors.Vector;
      Downstream_Conns : Downstream_Conn_Vectors.Vector;
      Num_Downstream_Conns : Long_Long_Integer := 0;

      Events : Event_Queue_Access;
      Done   : Signal_Access;

      --  Deferred: msgStore.
   end record;

   type Network is tagged record
      Network_Record : Soja.Database.Network;
      User           : User_Access;
      Logger         : Soja.Logging.Logger_Access;

      Stopped   : Signal_Access;
      Conn      : Upstream_Conn_Access;
      Channels  : Channel_Maps.Map;
      Delivered : Soja.User.Delivered_Store;
      Casemap   : Kind;

      --  Deferred: pushTargets, lastError.
   end record;

   type Downstream_Conn is tagged record
      Conn   : Soja.Conn.Conn_Access;
      Srv    : Soja.Server.Server_Access;
      Logger : Soja.Logging.Logger_Access;

      ID         : Long_Long_Integer := 0;
      Registered : Boolean := False;
      User       : User_Access;
      Network    : Network_Access;
      Client_Name : Unbounded_String;

      Nick     : Unbounded_String;
      Nick_CM  : Unbounded_String;
      Realname : Unbounded_String;
      Username : Unbounded_String;
      Hostname : Unbounded_String;
      Account  : Unbounded_String;
      Away     : Unbounded_String;   --  *string; null = not away

      Cap_Version : Integer := 0;
      Caps        : Soja.Irc.Cap_Registry.Registry;
      Registration : Downstream_Registration_Access;
      Last_Batch_Ref : Long_Long_Integer := 0;
      Casemap     : Kind;

      --  Deferred: sasl, monitored.
   end record;

   type Upstream_Conn is tagged record
      Conn   : Soja.Conn.Conn_Access;
      Srv    : Soja.Server.Server_Access;
      Logger : Soja.Logging.Logger_Access;

      Network : Network_Access;
      User    : User_Access;

      Server_Prefix           : Soja.Irc.Messages.Prefix_Access;
      Server_Name             : Unbounded_String;
      Available_User_Modes    : Unbounded_String;
      Available_Channel_Types : Unbounded_String;
      Available_Status_Msg    : Unbounded_String;
      Available_Memberships   : Soja.Irc.Members.Membership_Vectors.Vector;

      Registered : Boolean := False;
      Nick       : Unbounded_String;
      Username   : Unbounded_String;
      Realname   : Unbounded_String;
      Hostname   : Unbounded_String;
      Modes      : Soja.Irc.User_Modes.User_Modes;

      Channels : Upstream_Channel_Maps.Map;
      Users    : Upstream_User_Maps.Map;
      Caps     : Soja.Irc.Cap_Registry.Registry;

      Away           : Boolean := False;
      Account        : Unbounded_String;
      Next_Label_ID  : Long_Long_Integer := 0;
      Got_MOTD       : Boolean := False;
      Has_Desired_Nick : Boolean := False;

      --  Deferred: availableChannelModes, isupport, batches, monitored,
      --  saslClient, pendingCmds, regain-nick timer/backoff.
   end record;

   type Upstream_Channel is tagged record
      Name          : Unbounded_String;
      Conn          : Upstream_Conn_Access;
      Topic         : Unbounded_String;
      Topic_Who     : Soja.Irc.Messages.Prefix_Access;
      Topic_Time    : Ada.Calendar.Time;
      Status        : Soja.Irc.Members.Channel_Status;
      Creation_Time : Unbounded_String;
      Complete      : Boolean := False;

      --  Deferred: modes (channelModes), Members, detachTimer.
   end record;

   ------------------
   --  Constructors --
   ------------------

   --  newUser: allocates a user and its event queue / done signal.
   function New_User
     (Srv : Soja.Server.Server_Access; Rec : Soja.Database.User)
      return User_Access;

   --  newNetwork: builds a network around a user, seeding the channel map from
   --  Channels (database.ListChannels; empty for a freshly-created network).
   function New_Network
     (U : User_Access; Rec : Soja.Database.Network;
      Channels : Soja.Database.Channel_Lists.Vector) return Network_Access;

   --  newDownstreamConn: wraps a freshly-accepted transport in a downstream
   --  connection, advertising the always-available capabilities.
   function New_Downstream_Conn
     (Srv : Soja.Server.Server_Access;
      IC  : not null Soja.Conn.IRC_Conn_Access;
      ID  : Long_Long_Integer) return Downstream_Conn_Access;

   --  user.run(): load the user's networks from the DB, spawn each network's
   --  run task, then drain the event queue, dispatching each event to its
   --  handler.  The per-event handlers are stubs (they call the not-yet-ported
   --  connection methods).
   procedure Run (U : not null User_Access);

   --  The network-loading half of run(): list the user's networks (sorted by
   --  ID), build each network (with its channels), append it, and spawn its
   --  run task.  Factored out so it can be exercised without running the
   --  blocking event-dispatch loop.
   procedure Load_Networks (U : not null User_Access);

   --------------------------
   --  network/user helpers --
   --------------------------

   --  Callback for For_Each_Downstream.
   type Downstream_Process is access procedure (DC : Downstream_Conn_Access);

   --  forEachDownstream: apply Process to each downstream conn on Net's user.
   procedure For_Each_Downstream
     (Net : not null Network_Access; Process : not null Downstream_Process);

   function Is_Stopped (Net : not null Network_Access) return Boolean;

   procedure Stop_Network (Net : not null Network_Access);

   function Equal_Casemap (Net : not null Network_Access; A, B : String)
      return Boolean;

   function Get_Network (U : not null User_Access; Name : String)
      return Network_Access;

   function Get_Network_By_ID (U : not null User_Access; ID : Long_Long_Integer)
      return Network_Access;

   --  network.run(): the reconnect loop, spawned as a task by user.run().  It
   --  retries (via backoff) until the network is stopped.
   procedure Run_Network (Net : not null Network_Access);

end Soja.Core;
