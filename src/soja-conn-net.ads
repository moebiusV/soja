--  Soja.Conn.Net — the net.Conn transport (conn.go's newNetIRCConn): an
--  IRC_Conn over a GNAT.Sockets stream socket, with line framing.  TLS is a
--  later layer (AWS.Net.SSL); this is the plain-text transport.
pragma Ada_2022;

with Ada.Strings.Unbounded;
with GNAT.Sockets;
with Soja.Irc.Messages;

package Soja.Conn.Net is

   use Soja.Irc.Messages;

   type Net_IRC_Conn is new IRC_Conn with private;
   type Net_IRC_Conn_Access is access all Net_IRC_Conn;

   --  Takes ownership of the socket.
   function Create (Socket : GNAT.Sockets.Socket_Type) return Net_IRC_Conn;

   overriding function Read_Message (C : in out Net_IRC_Conn) return Message;
   overriding procedure Write_Message (C : in out Net_IRC_Conn; M : Message);
   overriding procedure Close (C : in out Net_IRC_Conn);
   overriding function Remote_Addr (C : Net_IRC_Conn) return String;

   --  The socket, exposed so a listener can hand a connected socket to a
   --  Net_IRC_Conn (and for tests).
   function Socket (C : Net_IRC_Conn) return GNAT.Sockets.Socket_Type;

private

   type Net_IRC_Conn is new IRC_Conn with record
      Sock   : GNAT.Sockets.Socket_Type;
      Buffer : Ada.Strings.Unbounded.Unbounded_String;   -- leftover bytes
   end record;

end Soja.Conn.Net;
