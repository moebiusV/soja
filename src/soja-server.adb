pragma Ada_2022;

with AWS.Net;
with AWS.Net.SSL;
with AWS.Net.Std;
with GNAT.Sockets;
with Ada.Exceptions;
with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;

with Soja.Config;
with Soja.Conn.Net;
with Soja.Proxy_Protocol;

package body Soja.Server is

   use AWS.Net;
   use type GNAT.Sockets.Selector_Status;
   use type Soja.Logging.Logger_Access;

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
   --  Proxy: the peer is in `accept-proxy-ip`, so the connection may start
   --  with a PROXY protocol header (go-proxyproto's USE policy, 5 s to read
   --  it).  It is read here, on the connection's own task, not in the accept
   --  loop; for TLS it comes inside the TLS stream, as in soju (the proxy
   --  listener wraps the TLS one).
   task type Conn_Task
     (S : not null access Server;
      IC : not null Soja.Conn.IRC_Conn_Access; H : Handler;
      Proxy : Boolean; Peer : not null access constant String)
   is
      entry Start;
   end Conn_Task;

   task body Conn_Task is
      Header_Timeout : constant Duration := 5.0;
      Serve_It       : Boolean := True;
   begin
      accept Start;
      if Proxy then
         begin
            Soja.Conn.Net.Read_Proxy_Header
              (Soja.Conn.Net.Net_IRC_Conn (IC.all), Header_Timeout);
         exception
            when E : others =>
               if S.Logger /= null then
                  S.Logger.Print
                    ("connection from " & Peer.all & ": "
                     & Ada.Exceptions.Exception_Message (E));
               end if;
               Soja.Conn.Close (IC.all);
               Serve_It := False;
         end;
      end if;
      if Serve_It then
         H (IC);
      end if;
   end Conn_Task;

   --  A package-level access type, so a connection task's master is the
   --  package (not the accept loop's block) and it outlives the block.
   type Conn_Task_Access is access Conn_Task;

   protected body Config_Holder is
      procedure Set (C : Server_Config_Access) is
      begin
         Value := C;
      end Set;
      function Get return Server_Config_Access is (Value);
   end Config_Holder;

   function Config (S : Server) return Server_Config_Access is
   begin
      return S.Cfg.Get;
   end Config;

   procedure Set_Config (S : in out Server; Cfg : Server_Config_Access) is
   begin
      S.Cfg.Set (Cfg);
   end Set_Config;

   function Logger (S : Server) return Soja.Logging.Logger_Access is
   begin
      return S.Logger;
   end Logger;

   function DB (S : Server) return Soja.Database.Database_Access is
   begin
      return S.DB;
   end DB;

   procedure Set_DB (S : in out Server; DB : Soja.Database.Database_Access) is
   begin
      S.DB := DB;
   end Set_DB;

   procedure Initialize
     (S : in out Server; Logger : Soja.Logging.Logger_Access := null)
   is
   begin
      S.Logger := Logger;
   end Initialize;

   procedure Set_Identd (S : in out Server; I : Soja.Identd.Identd_Access) is
   begin
      S.Ident := I;
   end Set_Identd;

   function Identd (S : Server) return Soja.Identd.Identd_Access is
   begin
      return S.Ident;
   end Identd;

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
      Cur_Gen  : Natural := TLS_Generation (S);

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

            --  A certificate reload (SIGHUP) since the last connection: take
            --  the new keypair.  The old config is not released: open
            --  connections still point at it (AWS does not count
            --  references), so it stays until the process ends.
            if Use_TLS and then TLS_Generation (S) /= Cur_Gen then
               Cur_Gen := TLS_Generation (S);
               declare
                  Cert : constant String :=
                    To_String (Soja.Server.Config (S).TLS_Cert);
                  Key  : constant String :=
                    To_String (Soja.Server.Config (S).TLS_Key);
                  Fresh : AWS.Net.SSL.Config := AWS.Net.SSL.Null_Config;
               begin
                  if Cert /= "" then
                     AWS.Net.SSL.Initialize
                       (Fresh,
                        Security_Mode      => AWS.Net.SSL.TLS_Server,
                        Server_Certificate => Cert,
                        Server_Key         => Key);
                     Config := Fresh;
                     if S.Logger /= null then
                        S.Logger.Print ("reloaded the TLS certificate");
                     end if;
                  end if;
               exception
                  when E : others =>
                     if S.Logger /= null then
                        S.Logger.Print
                          ("failed to reload the TLS certificate: "
                           & Ada.Exceptions.Exception_Message (E)
                           & " (keeping the old one)");
                     end if;
               end;
            end if;

            declare
               IC    : Soja.Conn.IRC_Conn_Access;
               Peer  : constant access constant String :=
                 new String'(New_Sock.Peer_Addr);
               Addr  : Soja.Config.IP_Addr;
               Proxy : constant Boolean :=
                 Soja.Proxy_Protocol.Parse_IP (Peer.all, Addr)
                 and then Soja.Proxy_Protocol.Contains
                            (Soja.Server.Config (S).Accept_Proxy_IPs, Addr);
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
                  T : Conn_Task_Access :=
                    new Conn_Task (S'Unchecked_Access, IC, S.H, Proxy, Peer);
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

   protected body Generation_Counter is
      procedure Bump is
      begin
         Count := Count + 1;
      end Bump;
      function Value return Natural is (Count);
   end Generation_Counter;

   procedure Reload_TLS (S : in out Server) is
   begin
      S.TLS_Gen.Bump;
   end Reload_TLS;

   function TLS_Generation (S : Server) return Natural is
   begin
      return S.TLS_Gen.Value;
   end TLS_Generation;

   function Check_TLS (Cert, Key : String) return String is
      Probe : AWS.Net.SSL.Config := AWS.Net.SSL.Null_Config;
   begin
      AWS.Net.SSL.Initialize
        (Probe,
         Security_Mode      => AWS.Net.SSL.TLS_Server,
         Server_Certificate => Cert,
         Server_Key         => Key);
      --  The probe is ours alone (no socket uses it): free it.
      AWS.Net.SSL.Release (Probe);
      return "";
   exception
      when E : others =>
         return Ada.Exceptions.Exception_Message (E);
   end Check_TLS;

   procedure Shutdown (S : in out Server) is
   begin
      S.Flag.Request;
      if S.Listener /= null then
         S.Listener.Shutdown (AWS.Net.Shut_Read_Write);
      end if;
   end Shutdown;

   protected body Gauges is
      procedure Add_Downstreams (By : Integer) is
      begin
         Value.Downstreams := Natural'Max (0, Value.Downstreams + By);
      end Add_Downstreams;

      procedure Add_Upstreams (By : Integer) is
      begin
         Value.Upstreams := Natural'Max (0, Value.Upstreams + By);
      end Add_Upstreams;

      function Get return Server_Stats is (Value);
   end Gauges;

   procedure Add_Downstreams (S : in out Server; By : Integer) is
   begin
      S.Gauge.Add_Downstreams (By);
   end Add_Downstreams;

   procedure Add_Upstreams (S : in out Server; By : Integer) is
   begin
      S.Gauge.Add_Upstreams (By);
   end Add_Upstreams;

   function Stats (S : Server) return Server_Stats is (S.Gauge.Get);

end Soja.Server;
