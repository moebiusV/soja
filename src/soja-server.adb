pragma Ada_2022;

with GNAT.Sockets;
with Soja.Conn.Net;

package body Soja.Server is

   use GNAT.Sockets;

   protected body Shutdown_Flag is
      procedure Request is
      begin
         Set := True;
      end Request;
      function Is_Set return Boolean is (Set);
   end Shutdown_Flag;

   --  One task per connection (server.go's `go handler(...)`).
   task type Conn_Task
     (IC : not null Soja.Conn.IRC_Conn_Access; H : Handler);
   task body Conn_Task is
   begin
      H (IC);
   end Conn_Task;

   procedure Initialize
     (S : in out Server; Logger : Soja.Logging.Logger_Access := null)
   is
   begin
      S.Logger := Logger;
   end Initialize;

   procedure Set_Handler (S : in out Server; H : Handler) is
   begin
      S.H := H;
   end Set_Handler;

   procedure Serve (S : in out Server; Listener : GNAT.Sockets.Socket_Type) is
      Client : Socket_Type;
      Addr   : Sock_Addr_Type;
      Status : Selector_Status;
   begin
      loop
         --  A short timeout lets us observe Shutdown between connections.
         Accept_Socket (Listener, Client, Addr, 0.5, null, Status);

         if Status = Completed then
            declare
               Net : Soja.Conn.Net.Net_IRC_Conn_Access :=
                 new Soja.Conn.Net.Net_IRC_Conn'
                   (Soja.Conn.Net.Create (Client));
               IC : Soja.Conn.IRC_Conn_Access :=
                 Soja.Conn.IRC_Conn_Access (Net);
               T  : constant access Conn_Task := new Conn_Task (IC, S.H);
            begin
               null;   -- the task runs in the background
            end;
         elsif Status = Aborted then
            exit;
         end if;

         exit when S.Flag.Is_Set;
      end loop;
   end Serve;

   procedure Shutdown (S : in out Server) is
   begin
      S.Flag.Request;
   end Shutdown;

end Soja.Server;
