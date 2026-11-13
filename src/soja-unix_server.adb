pragma Ada_2022;

with Ada.Exceptions;
with Interfaces.C;

with GNAT.OS_Lib;

with Soja.Conn.Unix;

package body Soja.Unix_Server is

   use Ada.Strings.Unbounded;
   use type GNAT.Sockets.Selector_Status;

   protected body Stop_Flag is
      procedure Request is
      begin
         Set := True;
      end Request;
      function Is_Set return Boolean is (Set);
   end Stop_Flag;

   function C_Umask (Mask : Interfaces.C.unsigned) return Interfaces.C.unsigned
     with Import, Convention => C, External_Name => "umask";

   function Listen (Path : String; Mode : Natural) return Listener_Access is
      L : constant Listener_Access := new Listener;
      Old : Interfaces.C.unsigned;
      Dead : Interfaces.C.unsigned;
      pragma Unreferenced (Dead);
   begin
      L.Path := To_Unbounded_String (Path);
      GNAT.Sockets.Create_Socket
        (L.Sock, GNAT.Sockets.Family_Unix, GNAT.Sockets.Socket_Stream);

      --  The socket file is created by bind: have it created with exactly
      --  Mode, rather than changing the mode afterwards.
      Old := C_Umask
        (Interfaces.C.unsigned (8#777# - (Mode mod 8#1000#)));
      begin
         GNAT.Sockets.Bind_Socket
           (L.Sock, GNAT.Sockets.Unix_Socket_Address (Path));
      exception
         when others =>
            Dead := C_Umask (Old);
            raise;
      end;
      Dead := C_Umask (Old);

      GNAT.Sockets.Listen_Socket (L.Sock, 128);
      return L;
   exception
      when E : GNAT.Sockets.Socket_Error =>
         begin
            GNAT.Sockets.Close_Socket (L.Sock);
         exception
            when others => null;
         end;
         raise Listen_Error with Ada.Exceptions.Exception_Message (E);
   end Listen;

   --  One task per connection (server.go's `go handler(...)`).
   task type Conn_Task
     (IC : not null Soja.Conn.IRC_Conn_Access; H : Soja.Server.Handler)
   is
      entry Start;
   end Conn_Task;

   task body Conn_Task is
   begin
      accept Start;
      H (IC);
   end Conn_Task;

   type Conn_Task_Access is access Conn_Task;

   procedure Serve
     (L : not null Listener_Access; H : Soja.Server.Handler)
   is
      Sel  : aliased GNAT.Sockets.Selector_Type;
      Rset, Wset : GNAT.Sockets.Socket_Set_Type;
      St   : GNAT.Sockets.Selector_Status;
   begin
      GNAT.Sockets.Create_Selector (Sel);
      while not L.Flag.Is_Set loop
         GNAT.Sockets.Empty (Rset);
         GNAT.Sockets.Empty (Wset);
         GNAT.Sockets.Set (Rset, L.Sock);
         GNAT.Sockets.Check_Selector (Sel, Rset, Wset, St, 0.1);

         if St = GNAT.Sockets.Completed
           and then not GNAT.Sockets.Is_Empty (Rset)
         then
            declare
               Client : GNAT.Sockets.Socket_Type;
               Addr   : GNAT.Sockets.Sock_Addr_Type;
            begin
               GNAT.Sockets.Accept_Socket (L.Sock, Client, Addr);
               declare
                  IC : constant Soja.Conn.IRC_Conn_Access :=
                    new Soja.Conn.Unix.Unix_IRC_Conn'
                      (Soja.Conn.Unix.Create (Client));
                  T  : constant Conn_Task_Access := new Conn_Task (IC, H);
               begin
                  T.Start;
               end;
            exception
               when GNAT.Sockets.Socket_Error =>
                  delay 0.05;   --  a failed accept is retried
            end;
         end if;
      end loop;

      GNAT.Sockets.Close_Selector (Sel);
      begin
         GNAT.Sockets.Close_Socket (L.Sock);
      exception
         when others => null;
      end;
      declare
         Ok : Boolean;
      begin
         GNAT.OS_Lib.Delete_File (To_String (L.Path), Ok);
      end;
   end Serve;

   procedure Stop (L : not null Listener_Access) is
   begin
      L.Flag.Request;
   end Stop;

end Soja.Unix_Server;
