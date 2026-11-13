--  Soja.Conn — conn.go's generic connection: a transport (ircConn) plus the
--  single-writer outgoing queue, rate limiter, and close semantics.
--
--  Concurrency: one writer task drains a bounded outgoing queue and writes to
--  the transport, matching conn.go's writer goroutine over the `outgoing`
--  channel.  Send_Message queues (dropping if closed); Close releases blocked
--  senders and stops the writer; Shutdown flushes then stops.
pragma Ada_2022;

with Ada.Real_Time;
with Soja.Irc.Messages;
with Soja.Logging;
with Soja.Metrics;

package Soja.Conn is

   use Soja.Irc.Messages;

   --  A generic IRC transport (conn.go's ircConn interface): read/write IRC
   --  messages, close, and report the peer address.  Concrete transports
   --  (net.Conn, websocket) implement this; Read_Message raises an exception
   --  on EOF/closed rather than returning an error value.
   type IRC_Conn is limited interface;
   function Read_Message (C : in out IRC_Conn) return Message is abstract;
   procedure Write_Message (C : in out IRC_Conn; M : Message) is abstract;
   procedure Close (C : in out IRC_Conn) is abstract;
   function Remote_Addr (C : IRC_Conn) return String is abstract;

   type IRC_Conn_Access is access all IRC_Conn'Class;

   --  conn.go's connOptions.
   type Conn_Options is record
      Logger           : Logging.Logger_Access := null;
      Rate_Limit_Delay : Duration := 0.0;   -- x/time/rate's Every(): 0 = none
      Rate_Limit_Burst : Natural := 0;
      --  Counted when set: a message read, a message queued for writing.
      Counters         : Soja.Metrics.Counter_Store_Access := null;
      Read_Kind        : Soja.Metrics.Counter_Kind :=
        Soja.Metrics.Downstream_In;
      Write_Kind       : Soja.Metrics.Counter_Kind :=
        Soja.Metrics.Downstream_Out;
   end record;

   type Conn is limited private;
   type Conn_Access is access Conn;

   type Message_Access is access Message;

   --  newConn: allocates the connection and starts its writer task.
   function New_Conn
     (Underlying : not null IRC_Conn_Access;
      Options    : Conn_Options) return Conn_Access;

   --  Reads one message from the transport (delegates, with a debug log).
   function Read_Message (C : not null access Conn) return Message;

   --  Queues a message for the writer; drops it silently if closed.  Blocks
   --  when the 64-slot queue is full (Go blocks too, on ctx.Done).
   procedure Send_Message (C : not null access Conn; M : Message);

   --  Gracefully flushes pending messages, then closes.  Safe from any task.
   procedure Shutdown (C : not null access Conn);

   --  Closes the connection.  Safe from any task.
   procedure Close (C : not null access Conn);

   --  Whether Close (or the writer ending) has closed it (Go's isClosed).
   function Is_Closed (C : not null access Conn) return Boolean;

   function Remote_Addr (C : not null access Conn) return String;

private

   Outgoing_Capacity : constant := 64;

   type Message_Array is array (1 .. Outgoing_Capacity) of Message_Access;

   --  The outgoing queue (conn.go's `outgoing` channel) plus the shutdown and
   --  closed flags.  Take returns Stop when the queue is empty and a shutdown
   --  or close was requested.
   protected type Out_Queue is
      entry Send (M : Message_Access; Accepted : out Boolean);
      entry Take (M : out Message_Access; Stop : out Boolean);
      procedure Shutdown;
      procedure Close_Queue;
      function Is_Closed return Boolean;
   private
      Buf      : Message_Array;
      Head     : Positive := 1;
      Count    : Natural := 0;
      Stopping : Boolean := False;
      Closed   : Boolean := False;
   end Out_Queue;

   type Out_Queue_Access is access all Out_Queue;

   --  The writer: drains the queue, rate-limits, writes, closes the transport.
   --  Rate_Delay_Nanos is the x/time/rate Every() interval in nanoseconds
   --  (a discrete type, since task discriminants cannot be Duration).
   task type Writer
     (Underlying      : not null IRC_Conn_Access;
      Queue           : not null Out_Queue_Access;
      Logger          : Logging.Logger_Access;
      Rate_Delay_Nanos : Long_Long_Integer;
      Rate_Burst      : Natural);
   type Writer_Access is access Writer;

   type Conn is limited record
      Underlying : IRC_Conn_Access;
      Logger     : Logging.Logger_Access;
      Queue      : aliased Out_Queue;
      Writer     : Writer_Access;
      Counters   : Soja.Metrics.Counter_Store_Access;
      Read_Kind  : Soja.Metrics.Counter_Kind;
      Write_Kind : Soja.Metrics.Counter_Kind;
   end record;

end Soja.Conn;
