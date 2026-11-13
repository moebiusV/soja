--  Soja.Byte_Stream -- a connected byte stream, for the protocols that sit
--  on top of one (HTTP and WebSocket): the same code serves a TCP or TLS
--  socket (AWS.Net) and a unix-domain one (GNAT.Sockets).
pragma Ada_2022;

with Ada.Streams;

package Soja.Byte_Stream is

   use Ada.Streams;

   type Stream is limited interface;
   type Stream_Access is access all Stream'Class;

   --  Reads what is there (at least one byte, waiting for it); Last is
   --  Buf'First - 1 when the peer has closed.  A task blocked here wakes up
   --  with that end of stream when another task calls Shutdown.
   procedure Receive
     (S    : in out Stream;
      Buf  : out Stream_Element_Array;
      Last : out Stream_Element_Offset) is abstract;

   --  Sends all of Data (Socket_Error when it cannot).
   procedure Send
     (S : in out Stream; Data : Stream_Element_Array) is abstract;

   --  Closes both directions (the descriptor stays until Release).
   procedure Shutdown (S : in out Stream) is abstract;

   --  Gives the descriptor back; nothing may use S afterwards.
   procedure Release (S : in out Stream) is abstract;

   --  The peer's address as Go's RemoteAddr().String(): "host:port" (an IPv6
   --  host in brackets), or "@" for an unnamed unix peer.
   function Peer (S : Stream) return String is abstract;

end Soja.Byte_Stream;
