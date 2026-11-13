--  Soja.Metrics -- the Prometheus metrics soju exposes (server.go
--  registerMetrics) and their text exposition format.
--
--  The core is pure: Render turns a snapshot of the gauges and counters into
--  the text a scrape returns.  The only state is Counter_Store, a protected
--  object the connections increment; reading it is a snapshot.
pragma Ada_2022;

package Soja.Metrics is

   subtype Count is Long_Long_Integer range 0 .. Long_Long_Integer'Last;

   type Counter_Kind is
     (Upstream_Out,              --  messages sent to upstream servers
      Upstream_In,               --  messages received from upstream servers
      Downstream_Out,            --  messages sent to downstream clients
      Downstream_In,             --  messages received from downstream clients
      Upstream_Connect_Errors,   --  failed upstream connections
      Worker_Panics);            --  panics in worker goroutines (none here)

   type Counts is array (Counter_Kind) of Count;

   protected type Counter_Store is
      procedure Increment (Kind : Counter_Kind);
      function Snapshot return Counts;
   private
      Data : Counts := [others => 0];
   end Counter_Store;

   type Counter_Store_Access is access all Counter_Store;

   --  The gauges: how many users, downstream and upstream connections there
   --  are right now.
   type Gauges is record
      Users       : Natural := 0;
      Downstreams : Natural := 0;
      Upstreams   : Natural := 0;
   end record;

   --  The metric's name, as the exposition format spells it.
   function Name (Kind : Counter_Kind) return String
     with Global => null;

   --  The text of a scrape: HELP, TYPE and the sample of each metric, sorted
   --  by name as the Prometheus client library gathers them.  Values are
   --  integers (the client library writes a float; 1e+06 for a million).
   function Render (G : Gauges; C : Counts) return String
     with Global => null;

   --  The Content-Type of a scrape.
   Content_Type : constant String :=
     "text/plain; version=0.0.4; charset=utf-8";

end Soja.Metrics;
