--  Soja.Conn.Ws -- an IRC_Conn over a WebSocket (conn.go's websocketIRCConn,
--  with what nhooyr.io/websocket does under it: RFC 6455 framing).  One IRC
--  message is one text frame, without a line end.
--
--  The connection is already upgraded when it is created (Soja.Web does the
--  HTTP handshake).  We are the server side: frames from the peer must be
--  masked, ours are not.  Pings are answered, pongs ignored, fragmented
--  messages are reassembled, a text message must be UTF-8, and a message over
--  Read_Limit is refused (1009), as nhooyr's default does.  A close frame with
--  a normal or "going away" status is the end of the stream (End_Error); a
--  protocol violation is answered with a close frame and raises Data_Error.
--
--  Who releases the socket: it is released once the connection is closed
--  (Close) *and* the handler is done with it (Handler_Done) *and* no task is
--  inside a read or a write, so a late write from the writer task finds the
--  connection closed instead of a freed socket.
pragma Ada_2022;

with Ada.Strings.Unbounded;

with Soja.Byte_Stream;

package Soja.Conn.Ws is

   --  nhooyr's default read limit: the largest message accepted, in bytes.
   Read_Limit : constant := 32_768;

   type Ws_IRC_Conn is limited new IRC_Conn with private;
   type Ws_IRC_Conn_Access is access all Ws_IRC_Conn;

   --  Initial: bytes already read from the peer after the HTTP head.  Remote
   --  is Go's RemoteAddr().String() (the address from Forwarded, behind a
   --  trusted proxy).  Takes ownership of the stream.
   function Create
     (Stream  : not null Soja.Byte_Stream.Stream_Access;
      Remote  : String;
      Initial : String := "") return Ws_IRC_Conn_Access;

   --  The handler that owns the connection has returned.
   procedure Handler_Done (C : not null Ws_IRC_Conn_Access);

   overriding function Read_Message (C : in out Ws_IRC_Conn) return Message;
   overriding procedure Write_Message (C : in out Ws_IRC_Conn; M : Message);
   overriding procedure Close (C : in out Ws_IRC_Conn);
   overriding function Remote_Addr (C : Ws_IRC_Conn) return String;

   --  The frame that carries Payload (unmasked, as a server sends it).
   --  Exposed for the tests.
   function Encode_Frame (Opcode : Natural; Payload : String) return String;

private

   protected type Life is
      procedure Enter (Ok : out Boolean);
      procedure Leave (Release_Now : out Boolean);
      procedure Mark_Closed (Release_Now : out Boolean);
      procedure Mark_Done (Release_Now : out Boolean);
   private
      Users    : Natural := 0;
      Closed   : Boolean := False;
      Done     : Boolean := False;
      Released : Boolean := False;
   end Life;

   protected type Write_Lock is
      entry Seize;
      procedure Try_Seize (Ok : out Boolean);
      procedure Release;
   private
      Busy : Boolean := False;
   end Write_Lock;

   type String_Access is access constant String;

   type State is limited record
      Stream  : Soja.Byte_Stream.Stream_Access;
      Remote  : String_Access;
      Buffer  : Ada.Strings.Unbounded.Unbounded_String;   -- bytes not yet used
      --  A fragmented message being reassembled.
      Msg     : Ada.Strings.Unbounded.Unbounded_String;
      Msg_Op  : Natural := 0;
      In_Msg  : Boolean := False;
      Lifetime : Life;
      Lock     : Write_Lock;
   end record;
   type State_Access is access State;

   type Ws_IRC_Conn is limited new IRC_Conn with record
      S : State_Access;
   end record;

end Soja.Conn.Ws;
