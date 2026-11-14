pragma Ada_2022;

with Ada.Calendar;
with Ada.Containers.Indefinite_Ordered_Maps;
with Ada.Containers.Vectors;
with Ada.Strings.Unbounded;

with Soja.Backoff;

with Soja.Conn;
with Soja.Database;
with Soja.Downstream;
with Soja.Irc.Cap_Registry;
with Soja.Irc.Genmsg;
with Soja.Irc.Case_Mapping;
with Soja.Irc.Case_Mapping_Maps;
with Soja.Irc.Members;
with Soja.Irc.Messages;
with Soja.Irc.Modes;
with Soja.Irc.User_Modes;
with Soja.Logging;
with Soja.Msgstore;
with Soja.Server;
with Soja.Timers;
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
   package Upstream_Conn_Access_Vectors is new Ada.Containers.Vectors
     (Positive, Upstream_Conn_Access);

   package Channel_Maps is new Soja.Irc.Case_Mapping_Maps
     (Element => Channel_Access, Null_Element => null);
   package Upstream_Channel_Maps is new Soja.Irc.Case_Mapping_Maps
     (Element => Upstream_Channel_Access, Null_Element => null);
   package Upstream_User_Maps is new Soja.Irc.Case_Mapping_Maps
     (Element => Upstream_User_Access, Null_Element => null);

   --  xirc.CaseMappingMap[bool] / [struct{}]: a set of names (a name is in the
   --  set when Get returns True).
   package Flag_Maps is new Soja.Irc.Case_Mapping_Maps
     (Element => Boolean, Null_Element => False);

   --  Go's zero time.Time, as the "absent" value of time-valued maps/fields.
   Zero_Time : constant Ada.Calendar.Time := Ada.Calendar.Time_Of (1901, 1, 1);

   --  xirc.CaseMappingMap[time.Time] (network.pushTargets).
   package Time_Maps is new Soja.Irc.Case_Mapping_Maps
     (Element => Ada.Calendar.Time, Null_Element => Zero_Time);

   type Backoff_Access is access all Soja.Backoff.Backoffer;

   --  A channel we were kicked from and have not rejoined: who did it, why
   --  and when.  Kept per network so that soja does not rejoin on its own
   --  (not even when the upstream connection is re-established), and so that
   --  clients that connect later can be told and rejoin by hand.
   type Kick_Info is record
      Kicked_By : Unbounded_String;
      Reason    : Unbounded_String;
      At_Time   : Ada.Calendar.Time := Zero_Time;
      ID        : Long_Long_Integer := 0;   --  its Kick_Record, 0 if unsaved
   end record;
   type Kick_Info_Access is access all Kick_Info;

   package Kick_Maps is new Soja.Irc.Case_Mapping_Maps
     (Element => Kick_Info_Access, Null_Element => null);

   --  A pending retry to join a channel that was full (ERR_CHANNELISFULL):
   --  the backoff that spaces the attempts and the timer for the next one.
   type Join_Retry is record
      Backoff : Backoff_Access;
      Timer   : Soja.Timers.Timer_Access;
      Armed   : Boolean := False;   --  a timer is pending
   end record;
   type Join_Retry_Access is access all Join_Retry;

   package Join_Retry_Maps is new Soja.Irc.Case_Mapping_Maps
     (Element => Join_Retry_Access, Null_Element => null);

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

   -------------------------------------------------
   --  Per-connection state (upstream.go/downstream.go) --
   -------------------------------------------------

   --  upstreamBatch: an open BATCH on an upstream.  Outer is the enclosing
   --  batch (null when top-level).
   type Upstream_Batch;
   type Upstream_Batch_Access is access all Upstream_Batch;
   type Upstream_Batch is record
      Batch_Type : Unbounded_String;   --  Go's Type
      Params     : Soja.Irc.Messages.Param_Vectors.Vector;
      Outer      : Upstream_Batch_Access;
      Label      : Unbounded_String;
   end record;

   package Batch_Maps is new Ada.Containers.Indefinite_Ordered_Maps
     (Key_Type => String, Element_Type => Upstream_Batch);

   --  pendingUpstreamCommand: a downstream command forwarded upstream and
   --  awaiting its reply.
   type Pending_Upstream_Command is record
      Downstream_ID : Long_Long_Integer := 0;
      Msg           : Soja.Irc.Messages.Message;
      Sent_At       : Ada.Calendar.Time := Zero_Time;
   end record;

   package Pending_Command_Vectors is new Ada.Containers.Vectors
     (Positive, Pending_Upstream_Command);

   --  uc.pendingCmds: command name -> queue.  The first entry has been sent
   --  and awaits a reply; the rest have not been sent yet.
   package Pending_Command_Maps is new Ada.Containers.Indefinite_Ordered_Maps
     (Key_Type => String, Element_Type => Pending_Command_Vectors.Vector,
      "=" => Pending_Command_Vectors."=");

   --  uc.isupport: token -> optional value (Go's map[string]*string, where a
   --  nil value is a token without "=").
   type Isupport_Value is record
      Has_Value : Boolean := False;
      Value     : Unbounded_String;
   end record;

   package Isupport_Maps is new Ada.Containers.Indefinite_Ordered_Maps
     (Key_Type => String, Element_Type => Isupport_Value);

   --  uc.saslClient: go-sasl's PLAIN and EXTERNAL clients (soju's only two).
   type Sasl_Mechanism is (Sasl_None, Sasl_Plain, Sasl_External);

   --  downstreamSASL: a client's SASL exchange in progress (nil unless SASL
   --  is underway).  OAUTHBEARER's options are deferred with oauth2 auth.
   type Downstream_SASL is record
      Mechanism      : Unbounded_String;
      --  the server's first challenge is out
      Challenged     : Boolean := False;
      Plain_Set      : Boolean := False;   --  Go's plain != nil
      Plain_Username : Unbounded_String;
      Plain_Password : Unbounded_String;
      Bearer_Set     : Boolean := False;   --  Go's oauthBearer != nil
      Bearer_Username : Unbounded_String;
      Bearer_Token   : Unbounded_String;
      Pending_Resp   : Unbounded_String;   --  Go's pendingResp buffer
   end record;

   type Downstream_SASL_Access is access Downstream_SASL;

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

   --  eventUserUpdate: change the user's password/admin/enabled flags from
   --  another task (BouncerServ, sojudb).  The sender waits on Result.
   protected type Update_Result is
      procedure Finish (Error : String);   --  "" when it worked
      entry Wait (Error : out Unbounded_String);
   private
      Is_Done  : Boolean := False;
      Last     : Unbounded_String;
   end Update_Result;
   type Update_Result_Access is access all Update_Result;

   type User_Update_Event is new Event with record
      Has_Password : Boolean := False;
      Password     : Unbounded_String;
      Has_Admin    : Boolean := False;
      Admin        : Boolean := False;
      Has_Enabled  : Boolean := False;
      Enabled      : Boolean := False;
      Has_Max_Networks : Boolean := False;
      Max_Networks     : Integer := -1;
      Result       : Update_Result_Access;
   end record;

   --  eventUserRun: run a BouncerServ command as this user.  The sender
   --  reads the lines the command prints, then its result, from Output.
   protected type Run_Output is
      procedure Put (Text : String);
      --  Error is the text of Go's `error` ("" when the command worked).
      procedure Finish (Failed : Boolean; Error : String);
      --  The next printed line (Is_Line), or, once the command is over and
      --  every line was taken, its result.
      entry Next
        (Is_Line : out Boolean; Text : out Unbounded_String;
         Failed : out Boolean);
   private
      Lines      : Soja.Irc.Genmsg.String_Vectors.Vector;
      Taken      : Natural := 0;
      Is_Done    : Boolean := False;
      Has_Failed : Boolean := False;
      Reason     : Unbounded_String;
   end Run_Output;
   type Run_Output_Access is access all Run_Output;

   type User_Run_Event is new Event with record
      Params : Soja.Irc.Genmsg.String_Vectors.Vector;
      Output : Run_Output_Access;
   end record;

   --  A join retry timer fired (soja-specific: channel-full retries).
   type Retry_Join_Event is new Event with record
      UC   : Upstream_Conn_Access;
      Name : Unbounded_String;
   end record;

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
      --  Non-blocking send (Go's select-with-default): Ok is False, and E is
      --  not queued, when the queue is full.
      procedure Try_Enqueue (E : Event_Access; Ok : out Boolean);
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
      --  Written by the user's task, read by the server's inactive-user
      --  loop (Go: an atomic).
      Num_Downstream_Conns : Long_Long_Integer := 0 with Atomic;

      Events : Event_Queue_Access;
      Done   : Signal_Access;
      --  `user delete` on one's own account (soja-specific, SB-10): the
      --  record is deleted by Run once the user has stopped.
      Delete_On_Stop : Boolean := False;

      --  user.msgStore: null when no store is configured.  Only the
      --  "memory" driver is ported; "fs" and "db" leave it null.
      Msg_Store : Soja.Msgstore.Store_Access;
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

      Active_Conn    : Upstream_Conn_Access;   --  being set up, or running
      Push_Targets   : Time_Maps.Map;
      Kicked         : Kick_Maps.Map;   --  channels we were kicked from
      Has_Last_Error : Boolean := False;   --  Go's lastError != nil
      Last_Error     : Unbounded_String;
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

      --  dc.isupport: the tokens the client was last sent.
      Isupport : Isupport_Maps.Map;

      Cap_Version : Integer := 0;
      Caps        : Soja.Irc.Cap_Registry.Registry;
      Registration : Downstream_Registration_Access;
      Last_Batch_Ref : Long_Long_Integer := 0;
      Casemap     : Kind;

      Sasl      : Downstream_SASL_Access;   --  null unless SASL is underway
      Monitored : Flag_Maps.Map;
   end record;

   --  What an upstream connection registered with identd (host and ports as
   --  Identd.Store wants them); Local_Port 0 when nothing was registered.
   type Ident_Entry is record
      Host        : Unbounded_String;
      Remote_Port : Natural := 0;
      Local_Port  : Natural := 0;
   end record;

   type Upstream_Conn is tagged record
      Ident : Ident_Entry;
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
      Available_Channel_Modes : Soja.Irc.Modes.Mode_Type_Maps.Map;
      Isupport                : Isupport_Maps.Map;

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

      Batches   : Batch_Maps.Map;
      Monitored : Flag_Maps.Map;

      Sasl_Mech     : Sasl_Mechanism := Sasl_None;   --  saslClient
      Sasl_Username : Unbounded_String;               --  PLAIN credentials
      Sasl_Password : Unbounded_String;
      Sasl_Started  : Boolean := False;

      Pending_Cmds : Pending_Command_Maps.Map;

      Pending_Regain_Nick : Unbounded_String;
      Regain_Nick_Timer   : Soja.Timers.Timer_Access;
      Regain_Nick_Backoff : Backoff_Access;

      --  Saved channels that were full when we tried to join them, by name.
      Join_Retries : Join_Retry_Maps.Map;
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

      Modes         : Soja.Irc.Modes.Channel_Modes;
      Members       : Soja.Irc.Members.Member_Maps.Map;
      Detach_Timer  : Soja.Timers.Timer_Access;
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

   --  serverSASLMechanisms: the downstream SASL mechanisms the configured
   --  authenticator supports, comma-joined ("" when none): internal and pam
   --  authenticate PLAIN; oauth2 authenticates PLAIN and OAUTHBEARER.
   function Server_SASL_Mechanisms (Srv : Soja.Server.Server_Access)
      return String;

   --  service.go's BouncerServ identity.
   Service_Nick    : constant String := "BouncerServ";
   Service_Nick_CM : constant String := "bouncerserv";
   Service_Realname : constant String := "soju bouncer service";

   --  srv.prefix(): the server's prefix (its hostname).
   function Server_Prefix (Srv : Soja.Server.Server_Access)
      return Soja.Irc.Messages.Prefix_Access;

   --  net.forEachDownstream, as a snapshot of the downstream connections
   --  attached to Net.
   function Downstreams (Net : not null Network_Access)
      return Downstream_Conn_Vectors.Vector;

   --  network.updateCasemapping: switch the network's case-mapping and
   --  re-key everything that is keyed by it.
   procedure Update_Casemapping
     (Net : not null Network_Access; CM : Soja.Irc.Case_Mapping.Kind);

   --  downstreamConn.updateCasemapping.
   procedure Update_Casemapping (DC : not null Downstream_Conn_Access);

   --  network.autoSaveSASLPlain: remember PLAIN credentials that just worked,
   --  unless another mechanism (e.g. EXTERNAL) is configured.
   procedure Auto_Save_SASL_Plain
     (Net : not null Network_Access; Username, Password : String);

   --  Kicks of our own nick are persisted (Soja.Database.Kick_Record) and
   --  kept as history: Record_Kick stores a new one (and closes an earlier
   --  one that is still active), Clear_Kick marks the active one rejoined --
   --  it is then ignored until the next kick -- and Load_Kicks reads the
   --  active ones back when a network is loaded.  All three work without a
   --  database (null) and log database errors instead of failing.
   procedure Record_Kick
     (Net : not null Network_Access;
      Channel, Kicked_By, Reason : String);
   procedure Clear_Kick
     (Net : not null Network_Access; Channel : String);
   procedure Load_Kicks (Net : not null Network_Access);

   --  uc.appendLog: store a message sent to or received from Entity and
   --  return its ID ("" when it is not stored: no store, a TAGMSG without a
   --  storable tag, a server-mask target, or NickServ).  The first message
   --  from a target also records the last message ID in every known client's
   --  delivery receipt, for the backlog of a reconnecting client.
   function Append_Log
     (UC     : not null Upstream_Conn_Access;
      Entity : String;
      Msg    : Soja.Irc.Messages.Message) return String;

   --  The `&upstreamChannel{Name, conn, Members}` literal of the JOIN handler:
   --  a fresh channel whose member map uses the network's case-mapping.
   function New_Upstream_Channel
     (UC : not null Upstream_Conn_Access; Name : String)
      return Upstream_Channel_Access;

   --  upstreamChannel.updateAutoDetach: (re)arm the timer that posts a
   --  Channel_Detach_Event after Dur; a zero Dur only cancels it.
   procedure Update_Auto_Detach
     (Ch : not null Upstream_Channel_Access; Dur : Duration);

   --  uc.isOurNick.
   function Is_Our_Nick (UC : not null Upstream_Conn_Access; Nick : String)
      return Boolean;

   --  The regain-nick machinery: while the desired nick is unavailable, a
   --  backed-off timer posts Try_Regain_Nick_Events; Try_Regain_Nick (run by
   --  the event handler) re-arms it and sends NICK.
   procedure Start_Regain_Nick_Timer (UC : not null Upstream_Conn_Access);
   procedure Stop_Regain_Nick_Timer (UC : not null Upstream_Conn_Access);
   procedure Try_Regain_Nick
     (UC : not null Upstream_Conn_Access; Nick : String);

   --  user.stop(): ask the user's loop to stop and wait until it has (False
   --  when Timeout expires first).
   function Stop_User
     (U : not null User_Access; Timeout : Duration := 30.0) return Boolean;

   --  user.hasPersistentMsgStore.
   function Has_Persistent_Msg_Store (U : not null User_Access) return Boolean;

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

   --  How long to leave the network's authentication to settle before the
   --  saved channels are joined (a variable, so that tests need not wait).
   Join_Delay : Duration := 3.0;

   --  What connectToUpstream does once the connection has registered: the
   --  connect commands, the pause for the authentication they may start (a
   --  connect command, or a client certificate that the server does not take
   --  by SASL EXTERNAL), and the JOINs of the saved channels.
   procedure Start_Session (UC : not null Upstream_Conn_Access);

   function Is_Stopped (Net : not null Network_Access) return Boolean;

   --  network.stop(): flag the network as stopped (its run loop ends) and
   --  close its upstream connection, whatever phase it is in.
   procedure Stop_Network (Net : not null Network_Access);

   --  Start the task running Run_Network (Go's `go network.run()`).
   procedure Spawn_Network (Net : not null Network_Access);

   function Equal_Casemap (Net : not null Network_Access; A, B : String)
      return Boolean;

   function Get_Network (U : not null User_Access; Name : String)
      return Network_Access;

   function Get_Network_By_ID (U : not null User_Access; ID :
     Long_Long_Integer)
      return Network_Access;

   --  network.run(): the reconnect loop, spawned as a task by user.run().  It
   --  retries (via backoff) until the network is stopped.
   procedure Run_Network (Net : not null Network_Access);

   --  connectToUpstream (upstream.go): dial the upstream, wrap it in an
   --  ircConn + conn, and build the upstreamConn.  Returns null on failure.
   --  SASL EXTERNAL certificate handling, certfp verification, and the
   --  unix-socket schemes are deferred.
   function Connect_To_Upstream (Net : not null Network_Access)
      return Upstream_Conn_Access;

   ------------------------
   --  Upstream connection --
   ------------------------

   --  The outcome of handling one upstream message (Go's `error` return of
   --  uc.handleMessage).  A registration error (Go's registrationError) says
   --  whether retrying can help; any other error is temporary.
   type Handle_Result is record
      Failed                : Boolean := False;
      Is_Registration_Error : Boolean := False;
      Reason                : Unbounded_String;
      Temporary             : Boolean := True;
   end record;

   --  registrationError's carry: whether registration failed, why, and whether
   --  the failure is temporary (reconnect will retry) or a configuration
   --  error.
   type Registration_Result is record
      Success   : Boolean;
      Reason    : Unbounded_String;
      Temporary : Boolean;
   end record;

   --  network.runConn's outcome: Text is empty on a clean (closed) run;
   --  otherwise it holds the failure text and whether to retry.
   type Run_Conn_Error is record
      Text      : Unbounded_String;
      Temporary : Boolean;
   end record;

   --  uc.register: set nick/username/realname and send the CAP/NICK/USER
   --  (+PASS) burst.
   procedure Register (UC : not null Upstream_Conn_Access);

   --  uc.SendMessage: drop message tags when the message-tags cap is disabled,
   --  then send.
   procedure Send_Message (UC : not null Upstream_Conn_Access;
      M : Soja.Irc.Messages.Message);

   --  uc.runUntilRegistered: read and handle messages until the connection
   --  registers (001) or registration fails.
   function Run_Until_Registered (UC : not null Upstream_Conn_Access)
      return Registration_Result;

   --  network.runConn: connect, register, then forward upstream messages to
   --  the user's event queue until the connection closes.
   function Run_Conn (Net : not null Network_Access) return Run_Conn_Error;

   -------------------------
   --  Downstream connection --
   -------------------------

   --  A client-facing reply (an ircError to send) or success.
   --  Is_IRC is False for an error that is not an IRC reply (Go's plain
   --  `error`): Text says what went wrong and the connection is dropped.
   type Irc_Error_Result (Failed : Boolean := False) is record
      case Failed is
         when True  =>
            Is_IRC : Boolean := True;
            Err    : Soja.Downstream.Irc_Error;
            Text   : Unbounded_String;
         when False => null;
      end case;
   end record;

   --  dc.SendMessage: adapt the message to the client's enabled capabilities
   --  (tags, extended-join, ...) or drop it, add the server prefix to
   --  numerics, then send.
   procedure Send_Message (DC : not null Downstream_Conn_Access;
      M : Soja.Irc.Messages.Message);

   --  dc.handleMessageUnregistered: NICK/USER/PASS/AWAY.  CAP, AUTHENTICATE
   --  and BOUNCER are deferred (treated as unknown commands).
   function Handle_Message_Unregistered
     (DC : not null Downstream_Conn_Access; M : Soja.Irc.Messages.Message)
      return Irc_Error_Result;

   --  dc.register: authenticate via PASS against the DB (soju's internal
   --  auth) and mark the connection registered.
   function Register_Downstream (DC : not null Downstream_Conn_Access)
      return Irc_Error_Result;

   --  dc.runUntilRegistered: read NICK/USER/PASS, replying to client errors,
   --  until the connection registers.  Returns False when the peer closed.
   function Run_Until_Registered_Downstream
     (DC : not null Downstream_Conn_Access) return Boolean;

   --  dc.handleMessage: QUIT, then the registered or unregistered dispatch.
   function Handle_Downstream_Message
     (DC : not null Downstream_Conn_Access; M : Soja.Irc.Messages.Message)
      return Irc_Error_Result;

end Soja.Core;
