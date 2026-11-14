--  Soja.Conn.Net — the socket transport (conn.go's newNetIRCConn): an
--  IRC_Conn over an AWS.Net socket (plain Net.Std or TLS Net.SSL), with CRLF
--  line framing.  The socket is held class-wide, so plain and TLS share one
--  code path, mirroring Go's net.Conn.
pragma Ada_2022;

with Ada.Strings.Unbounded;
with AWS.Net;

with Soja.Sock_Io;
with Soja.Irc.Messages;

package Soja.Conn.Net is

   use Soja.Irc.Messages;

   type Net_IRC_Conn is new IRC_Conn with private;
   type Net_IRC_Conn_Access is access all Net_IRC_Conn;

   --  Takes ownership of the socket (a plain Net.Std or TLS Net.SSL socket).
   function Create (Sock : not null AWS.Net.Socket_Access) return Net_IRC_Conn;

   overriding function Read_Message (C : in out Net_IRC_Conn) return Message;
   overriding procedure Write_Message (C : in out Net_IRC_Conn; M : Message);
   overriding procedure Close (C : in out Net_IRC_Conn);
   overriding function Remote_Addr (C : Net_IRC_Conn) return String;

   function Socket (C : Net_IRC_Conn) return AWS.Net.Socket_Access;

   --  The PROXY protocol (policy USE): if the connection starts with a PROXY
   --  header, consume it and report the address it names from now on as the
   --  remote address; if it starts with something else, leave it alone.
   --  Soja.Proxy_Protocol.Proxy_Error (after Timeout, or on a malformed
   --  header) means the connection must be dropped.
   procedure Read_Proxy_Header (C : in out Net_IRC_Conn; Timeout : Duration);

private

   type Net_IRC_Conn is new IRC_Conn with record
      Sock   : AWS.Net.Socket_Access;
      G      : Soja.Sock_Io.Gate_Access := new Soja.Sock_Io.Gate;
      Buffer : Ada.Strings.Unbounded.Unbounded_String;   -- leftover bytes
      --  Set by a PROXY header: "host:port" of the real client.
      Proxied : Ada.Strings.Unbounded.Unbounded_String;
   end record;

end Soja.Conn.Net;
