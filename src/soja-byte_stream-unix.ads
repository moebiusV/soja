--  A Byte_Stream over a unix-domain socket.
pragma Ada_2022;

with GNAT.Sockets;

package Soja.Byte_Stream.Unix is

   type Unix_Stream is limited new Stream with private;

   --  Takes ownership of a connected socket.
   function Create (Sock : GNAT.Sockets.Socket_Type) return Stream_Access;

   overriding procedure Receive
     (S    : in out Unix_Stream;
      Buf  : out Stream_Element_Array;
      Last : out Stream_Element_Offset);
   overriding procedure Send
     (S : in out Unix_Stream; Data : Stream_Element_Array);
   overriding procedure Shutdown (S : in out Unix_Stream);
   overriding procedure Release (S : in out Unix_Stream);
   overriding function Peer (S : Unix_Stream) return String;

private

   type Unix_Stream is limited new Stream with record
      Sock : GNAT.Sockets.Socket_Type;
   end record;

end Soja.Byte_Stream.Unix;
