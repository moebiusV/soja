--  Serving IRC connections on a unix-domain socket (net.Listen("unix", path)
--  and Server.Serve): used for the admin socket and the unix:// listeners.
pragma Ada_2022;

with Ada.Strings.Unbounded;
with GNAT.Sockets;

with Soja.Server;

package Soja.Unix_Server is

   Listen_Error : exception;   --  Exception_Message says why

   type Listener is limited private;
   type Listener_Access is access all Listener;

   --  A listening socket at Path with the given permission bits (e.g. 8#600#).
   --  The mode is applied to the socket file as it is created (the umask is
   --  narrowed meanwhile), so the file is never reachable with other
   --  permissions, not even briefly.  Fails (Listen_Error) when something
   --  already is at Path, as net.Listen does.
   function Listen (Path : String; Mode : Natural) return Listener_Access;

   --  Serve: accept connections and run H on a task for each, until Stop.
   --  The socket file is removed on the way out (as closing a Go
   --  UnixListener does).
   procedure Serve
     (L : not null Listener_Access; H : Soja.Server.Handler);

   procedure Stop (L : not null Listener_Access);

private

   protected type Stop_Flag is
      procedure Request;
      function Is_Set return Boolean;
   private
      Set : Boolean := False;
   end Stop_Flag;

   type Listener is limited record
      Path : Ada.Strings.Unbounded.Unbounded_String;
      Sock : GNAT.Sockets.Socket_Type;
      Flag : Stop_Flag;
   end record;

end Soja.Unix_Server;
