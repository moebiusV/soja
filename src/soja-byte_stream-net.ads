--  A Byte_Stream over an AWS.Net socket (plain or TLS).
pragma Ada_2022;

with AWS.Net;

with Soja.Sock_Io;

package Soja.Byte_Stream.Net is

   type Net_Stream is limited new Stream with private;

   --  Takes ownership of the socket.
   function Create
     (Sock : not null AWS.Net.Socket_Access) return Stream_Access;

   overriding procedure Receive
     (S    : in out Net_Stream;
      Buf  : out Stream_Element_Array;
      Last : out Stream_Element_Offset);
   overriding procedure Send
     (S : in out Net_Stream; Data : Stream_Element_Array);
   overriding procedure Shutdown (S : in out Net_Stream);
   overriding procedure Release (S : in out Net_Stream);
   overriding function Peer (S : Net_Stream) return String;

private

   type Net_Stream is limited new Stream with record
      Sock : AWS.Net.Socket_Access;
      Addr : access constant String;   --  "host:port", taken at accept
      G    : Soja.Sock_Io.Gate_Access := new Soja.Sock_Io.Gate;
   end record;

end Soja.Byte_Stream.Net;
