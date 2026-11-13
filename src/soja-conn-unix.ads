--  Soja.Conn.Unix -- an IRC_Conn over a unix-domain stream socket (what
--  conn.go gets from net.Conn for the "unix" network), with the same CRLF line
--  framing as Soja.Conn.Net.  AWS.Net is TCP only, so this uses GNAT.Sockets.
pragma Ada_2022;

with Ada.Strings.Unbounded;
with GNAT.Sockets;

with Soja.Irc.Messages;

package Soja.Conn.Unix is

   use Soja.Irc.Messages;

   type Unix_IRC_Conn is new IRC_Conn with private;
   type Unix_IRC_Conn_Access is access all Unix_IRC_Conn;

   --  Takes ownership of a connected stream socket.
   function Create (Sock : GNAT.Sockets.Socket_Type) return Unix_IRC_Conn;

   --  Connect to the unix socket at Path; GNAT.Sockets.Socket_Error when it
   --  cannot be reached.
   function Connect (Path : String) return Unix_IRC_Conn;

   overriding function Read_Message (C : in out Unix_IRC_Conn) return Message;
   overriding procedure Write_Message
     (C : in out Unix_IRC_Conn; M : Message);
   overriding procedure Close (C : in out Unix_IRC_Conn);
   overriding function Remote_Addr (C : Unix_IRC_Conn) return String;

private

   --  Who may close the descriptor, and when.  It is closed once, after both
   --  Close was called and the reader saw the end of the stream: closing it
   --  earlier could hit a descriptor number the system has since given to a
   --  new connection.
   protected type Fd_State is
      procedure Init (S : GNAT.Sockets.Socket_Type);
      function Socket return GNAT.Sockets.Socket_Type;
      function Is_Closed return Boolean;
      procedure Shutdown;      --  Close was called
      procedure Reader_Done;   --  the reader got the end of the stream
   private
      Sock   : GNAT.Sockets.Socket_Type;
      Shut   : Boolean := False;
      Done   : Boolean := False;
      Closed : Boolean := False;
   end Fd_State;
   type Fd_State_Access is access Fd_State;

   type Unix_IRC_Conn is new IRC_Conn with record
      State  : Fd_State_Access;
      Buffer : Ada.Strings.Unbounded.Unbounded_String;   --  leftover bytes
   end record;

end Soja.Conn.Unix;
