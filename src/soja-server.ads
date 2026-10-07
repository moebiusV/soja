--  Soja.Server — server.go's Server skeleton: the accept loop, the per-
--  connection handler tasks, TLS, and shutdown.  The user/downstream/
--  database/auth spine and metrics are ported separately.
pragma Ada_2022;

with AWS.Net;
with Soja.Conn;
with Soja.Logging;

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
   Downstream_Register_Timeout       : constant Duration := 30.0;
   Webpush_Check_Subscription_Delay  : constant Duration := 86_400.0;
   Webpush_Prune_Subscription_Delay  : constant Duration := 2_592_000.0;
   Chat_History_Limit                : constant Natural := 1000;
   Backlog_Limit                     : constant Natural := 4000;

   --  A connection handler (server.go's Serve handler func).  The handler owns
   --  the connection for its lifetime and returns when the peer disconnects.
   type Handler is access procedure (IC : not null Soja.Conn.IRC_Conn_Access);

   type Server is tagged limited private;
   type Server_Access is access all Server;

   function Logger (S : Server) return Soja.Logging.Logger_Access;

   procedure Initialize
     (S : in out Server; Logger : Soja.Logging.Logger_Access := null);

   procedure Set_Handler (S : in out Server; H : Handler);

   --  The accept loop: blocks the caller, spawning one task per connection
   --  that runs the handler.  When TLS_Cert/TLS_Key are non-empty, each
   --  accepted socket is wrapped in TLS.  Returns when Shutdown is requested
   --  (which closes the listener).
   procedure Serve
     (S        : in out Server;
      Listener : not null AWS.Net.Socket_Access;
      TLS_Cert : String := "";
      TLS_Key  : String := "");

   procedure Shutdown (S : in out Server);

private

   protected type Shutdown_Flag is
      procedure Request;
      function Is_Set return Boolean;
   private
      Set : Boolean := False;
   end Shutdown_Flag;

   type Server is tagged limited record
      Logger   : Soja.Logging.Logger_Access;
      H        : Handler;
      Listener : AWS.Net.Socket_Access;
      Flag     : Shutdown_Flag;
   end record;

end Soja.Server;
