--  Soja.Server — server.go's Server skeleton: the accept loop, the per-
--  connection handler tasks, TLS, and shutdown.  The user/downstream/
--  database/auth spine and metrics are ported separately.
pragma Ada_2022;

with Ada.Strings.Unbounded;

with AWS.Net;
with Soja.Byte_Stream;
with Soja.Config;
with Soja.Conn;
with Soja.Database;
with Soja.Identd;
with Soja.Logging;
with Soja.Metrics;

package Soja.Server is

   --  server.go's tunables (seconds, except the *Limit counters).
   Retry_Connect_Min_Delay           : constant Duration := 60.0;
   Retry_Connect_Max_Delay           : constant Duration := 600.0;
   Retry_Connect_Jitter              : constant Duration := 60.0;
   Connect_Timeout                   : constant Duration := 15.0;
   Write_Timeout                     : constant Duration := 10.0;
   Upstream_Message_Delay            : constant Duration := 2.0;
   Upstream_Message_Burst            : constant Natural := 10;
   Backlog_Timeout                   : constant Duration := 10.0;
   Handle_Downstream_Message_Timeout : constant Duration := 10.0;
   --  (A variable, so that tests can shorten it.)
   Downstream_Register_Timeout       : Duration := 30.0;
   Webpush_Check_Subscription_Delay  : constant Duration := 86_400.0;
   Webpush_Prune_Subscription_Delay  : constant Duration := 2_592_000.0;
   Chat_History_Limit                : constant Natural := 1000;
   Backlog_Limit                     : constant Natural := 4000;

   --  A connection handler (server.go's Serve handler func).  The handler owns
   --  the connection for its lifetime and returns when the peer disconnects.
   type Handler is access procedure (IC : not null Soja.Conn.IRC_Conn_Access);

   --  server.go's Config: the runtime settings the core reads (cmd/soju's
   --  loadConfig builds it from config.Server).  Defaults are NewServer's.
   --  The authenticator and file uploader, which are objects in Go, are
   --  represented by what the core asks of them: the auth driver name
   --  ("internal", "pam" or "oauth2") and whether an uploader is set.
   type Server_Config is record
      Hostname          : Ada.Strings.Unbounded.Unbounded_String :=
        Ada.Strings.Unbounded.To_Unbounded_String ("localhost");
      Title             : Ada.Strings.Unbounded.Unbounded_String;
      Msg_Store_Driver  : Ada.Strings.Unbounded.Unbounded_String;
      Msg_Store_Path    : Ada.Strings.Unbounded.Unbounded_String;
      HTTP_Origins      : Soja.Config.String_Vectors.Vector;
      HTTP_Ingress      : Ada.Strings.Unbounded.Unbounded_String;
      Accept_Proxy_IPs  : Soja.Config.IPSet;
      Max_User_Networks : Integer := -1;
      MOTD              : Ada.Strings.Unbounded.Unbounded_String;
      Upstream_User_IPs : Soja.Config.IPNet_Vectors.Vector;
      Disable_Inactive_Users_Delay : Duration := 0.0;
      Enable_Users_On_Auth : Boolean := False;
      Auth_Driver       : Ada.Strings.Unbounded.Unbounded_String :=
        Ada.Strings.Unbounded.To_Unbounded_String ("internal");
      Has_File_Uploader : Boolean := False;
      --  The `file-upload fs <dir>` directory, "" when there is none.
      File_Upload_Dir   : Ada.Strings.Unbounded.Unbounded_String;
      --  The `tls` keypair (PEM paths), "" when there is none.  A new
      --  configuration with other paths takes effect at Reload_TLS.
      TLS_Cert          : Ada.Strings.Unbounded.Unbounded_String;
      TLS_Key           : Ada.Strings.Unbounded.Unbounded_String;
   end record;

   type Server_Config_Access is access all Server_Config;

   type Server is tagged limited private;
   type Server_Access is access all Server;

   --  What a web listener (ws, wss, http, https and their unix/insecure
   --  forms) runs for each connection instead of the IRC handler: serve one
   --  HTTP request on Stream, upgrading it to a WebSocket that H then handles
   --  (server.go's Server.ServeHTTP and the HTTP mux).  Owns the stream.
   type Web_Handler is access procedure
     (S      : in out Server;
      Stream : not null Soja.Byte_Stream.Stream_Access;
      H      : Handler);

   --  Server.Config / SetConfig.  SetConfig swaps the whole object (as Go's
   --  atomic.Value does); readers holding the old one keep a valid snapshot.
   function Config (S : Server) return Server_Config_Access;
   procedure Set_Config (S : in out Server; Cfg : Server_Config_Access);

   function Logger (S : Server) return Soja.Logging.Logger_Access;

   function DB (S : Server) return Soja.Database.Database_Access;

   procedure Set_DB (S : in out Server; DB : Soja.Database.Database_Access);

   procedure Initialize
     (S : in out Server; Logger : Soja.Logging.Logger_Access := null);

   procedure Set_Handler (S : in out Server; H : Handler);

   --  Server.Identd: the ident server upstream connections are registered
   --  with; null (the default) when no `ident://` listener is configured.
   procedure Set_Identd (S : in out Server; I : Soja.Identd.Identd_Access);
   function Identd (S : Server) return Soja.Identd.Identd_Access;

   --  The accept loop: blocks the caller, spawning one task per connection
   --  that runs the handler.  When TLS_Cert/TLS_Key are non-empty, each
   --  accepted socket is wrapped in TLS.  Returns when Shutdown is requested
   --  (which closes the listener).
   --  With Web, connections are served by it instead (no PROXY protocol).
   procedure Serve
     (S        : in out Server;
      Listener : not null AWS.Net.Socket_Access;
      TLS_Cert : String := "";
      TLS_Key  : String := "";
      Web      : Web_Handler := null);

   procedure Shutdown (S : in out Server);

   --  Check that a certificate and key can be used for serving TLS (they
   --  exist, parse, and match); "" when they can, else why not.  (Go's
   --  tls.LoadX509KeyPair.)
   function Check_TLS (Cert, Key : String) return String;

   --  The TLS certificate was replaced (SIGHUP): from now on, new TLS
   --  connections use the keypair named by Config (S).TLS_Cert / TLS_Key,
   --  read afresh.  Connections already open keep what they have.
   procedure Reload_TLS (S : in out Server);
   function TLS_Generation (S : Server) return Natural;

   --  The gauges of server.go's metrics that BouncerServ's "server status"
   --  reports: connected clients and running upstream connections.
   type Server_Stats is record
      Users       : Natural := 0;
      Downstreams : Natural := 0;
      Upstreams   : Natural := 0;
   end record;

   procedure Add_Users (S : in out Server; By : Integer);
   procedure Add_Downstreams (S : in out Server; By : Integer);
   procedure Add_Upstreams (S : in out Server; By : Integer);
   function Stats (S : Server) return Server_Stats;

   --  The message counters connections increment (set in their
   --  Conn_Options).
   function Counters (S : in out Server)
      return Soja.Metrics.Counter_Store_Access;

   --  What a scrape of the http+prometheus listener returns.
   function Metrics_Text (S : Server) return String;

private

   protected type Shutdown_Flag is
      procedure Request;
      function Is_Set return Boolean;
   private
      Set : Boolean := False;
   end Shutdown_Flag;

   protected type Config_Holder is
      procedure Set (C : Server_Config_Access);
      function Get return Server_Config_Access;
   private
      Value : Server_Config_Access := new Server_Config;
   end Config_Holder;

   protected type Gauges is
      procedure Add_Users (By : Integer);
      procedure Add_Downstreams (By : Integer);
      procedure Add_Upstreams (By : Integer);
      function Get return Server_Stats;
   private
      Value : Server_Stats;
   end Gauges;

   protected type Generation_Counter is
      procedure Bump;
      function Value return Natural;
   private
      Count : Natural := 0;
   end Generation_Counter;

   type Server is tagged limited record
      TLS_Gen  : Generation_Counter;
      Gauge    : Gauges;
      Counted  : aliased Soja.Metrics.Counter_Store;
      Cfg      : Config_Holder;
      Logger   : Soja.Logging.Logger_Access;
      DB       : Soja.Database.Database_Access;
      H        : Handler;
      Ident    : Soja.Identd.Identd_Access;
      Listener : AWS.Net.Socket_Access;
      Flag     : Shutdown_Flag;
   end record;

end Soja.Server;
