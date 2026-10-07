pragma Ada_2022;

with AWS.Net;
with AWS.Net.SSL;
with AWS.Net.Std;
with GNAT.Sockets;
with Soja.Conn.Net;

package body Soja.Server is

   use AWS.Net;
   use type GNAT.Sockets.Selector_Status;

   protected body Shutdown_Flag is
      procedure Request is
      begin
         Set := True;
      end Request;
      function Is_Set return Boolean is (Set);
   end Shutdown_Flag;

   --  One task per connection (server.go's `go handler(...)`).  Start gates
   --  the body so activation completes at an Ada suspension point rather than
   --  inside the handler's first blocking read.
   task type Conn_Task
     (IC : not null Soja.Conn.IRC_Conn_Access; H : Handler) is
      entry Start;
   end Conn_Task;

   task body Conn_Task is
   begin
      accept Start;
      H (IC);
   end Conn_Task;

   --  A package-level access type, so a connection task's master is the
   --  package (not the accept loop's block) and it outlives the block.
   type Conn_Task_Access is access Conn_Task;

   function Logger (S : Server) return Soja.Logging.Logger_Access is
   begin
      return S.Logger;
   end Logger;

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

   procedure Serve
     (S        : in out Server;
      Listener : not null AWS.Net.Socket_Access;
      TLS_Cert : String := "";
      TLS_Key  : String := "")
   is
      use type AWS.Net.Socket_Access;

      Config   : AWS.Net.SSL.Config := AWS.Net.SSL.Null_Config;
      Use_TLS  : constant Boolean := TLS_Cert'Length > 0;
      New_Sock : AWS.Net.Socket_Access;

      --  AWS.Net's Accept_Socket blocks, so watch the listener's descriptor
      --  through GNAT.Sockets' selector to observe Shutdown between
      --  connections (a 0.1 s poll).
      FD   : constant Integer := AWS.Net.Std.Socket_Type (Listener.all).Get_FD;
      GS   : constant GNAT.Sockets.Socket_Type := GNAT.Sockets.To_Ada (FD);
      Sel  : aliased GNAT.Sockets.Selector_Type;
      Rset : GNAT.Sockets.Socket_Set_Type;
      Wset : GNAT.Sockets.Socket_Set_Type;
      St   : GNAT.Sockets.Selector_Status;
   begin
      S.Listener := Listener;

      if Use_TLS then
         AWS.Net.SSL.Initialize
           (Config,
            Security_Mode      => AWS.Net.SSL.TLS_Server,
            Server_Certificate => TLS_Cert,
            Server_Key         => TLS_Key);
      end if;

      GNAT.Sockets.Create_Selector (Sel);

      loop
         GNAT.Sockets.Empty (Rset);
         GNAT.Sockets.Empty (Wset);
         GNAT.Sockets.Set (Rset, GS);
         GNAT.Sockets.Check_Selector (Sel, Rset, Wset, St, 0.1);

         if St = GNAT.Sockets.Completed
           and then not GNAT.Sockets.Is_Empty (Rset)
         then
            begin
               New_Sock := AWS.Net.Socket (False);
               Accept_Socket (Listener.all, New_Sock.all);
            exception
               when AWS.Net.Socket_Error =>
                  exit;   -- listener closed by Shutdown
            end;

            declare
               IC : Soja.Conn.IRC_Conn_Access;
            begin
               if Use_TLS then
                  declare
                     SSL_Sock : AWS.Net.SSL.Socket_Type :=
                       AWS.Net.SSL.Secure_Server (New_Sock.all, Config);
                  begin
                     AWS.Net.Free (New_Sock);
                     IC := new Soja.Conn.Net.Net_IRC_Conn'
                       (Soja.Conn.Net.Create
                          (new AWS.Net.SSL.Socket_Type'(SSL_Sock)));
                  end;
               else
                  IC := new Soja.Conn.Net.Net_IRC_Conn'
                    (Soja.Conn.Net.Create (New_Sock));
               end if;

               declare
                  T : Conn_Task_Access := new Conn_Task (IC, S.H);
               begin
                  T.Start;   -- begin serving the connection
               end;
            end;
         end if;

         exit when S.Flag.Is_Set;
      end loop;

      GNAT.Sockets.Close_Selector (Sel);

      if Use_TLS then
         AWS.Net.SSL.Release (Config);
      end if;
   end Serve;

   procedure Shutdown (S : in out Server) is
   begin
      S.Flag.Request;
      if S.Listener /= null then
         S.Listener.Shutdown (AWS.Net.Shut_Read_Write);
      end if;
   end Shutdown;

end Soja.Server;
