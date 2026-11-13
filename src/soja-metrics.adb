pragma Ada_2022;

package body Soja.Metrics is

   LF : constant Character := ASCII.LF;

   protected body Counter_Store is
      procedure Increment (Kind : Counter_Kind) is
      begin
         Data := (Data with delta Kind => Data (Kind) + 1);
      end Increment;

      function Snapshot return Counts is (Data);
   end Counter_Store;

   function Name (Kind : Counter_Kind) return String is
     (case Kind is
         when Upstream_Out            => "soju_upstream_out_messages_total",
         when Upstream_In             => "soju_upstream_in_messages_total",
         when Downstream_Out          => "soju_downstream_out_messages_total",
         when Downstream_In           => "soju_downstream_in_messages_total",
         when Upstream_Connect_Errors => "soju_upstream_connect_errors_total",
         when Worker_Panics           => "soju_worker_panics_total");

   function Help (Kind : Counter_Kind) return String is
     (case Kind is
         when Upstream_Out            =>
            "Total number of outgoing messages sent to upstream servers",
         when Upstream_In             =>
            "Total number of incoming messages received from upstream servers",
         when Downstream_Out          =>
            "Total number of outgoing messages sent to downstream clients",
         when Downstream_In           =>
            "Total number of incoming messages received from downstream "
            & "clients",
         when Upstream_Connect_Errors =>
            "Total number of upstream connection errors",
         when Worker_Panics           =>
            "Total number of panics in worker goroutines");

   --  A non-negative number without its leading blank.
   function Image (N : Long_Long_Integer) return String is
     (declare S : constant String := N'Image; begin S (S'First + 1 .. S'Last));

   function Metric
     (Name, Help, Kind : String; Value : Long_Long_Integer) return String
   is
     ("# HELP " & Name & " " & Help & LF
      & "# TYPE " & Name & " " & Kind & LF
      & Name & " " & Image (Value) & LF);

   function Counter (Kind : Counter_Kind; C : Counts) return String is
     (Metric (Name (Kind), Help (Kind), "counter", C (Kind)));

   function Render (G : Gauges; C : Counts) return String is
     (Counter (Downstream_In, C)
      & Counter (Downstream_Out, C)
      & Metric ("soju_downstreams_active",
                "Current number of downstream connections", "gauge",
                Long_Long_Integer (G.Downstreams))
      & Counter (Upstream_Connect_Errors, C)
      & Counter (Upstream_In, C)
      & Counter (Upstream_Out, C)
      & Metric ("soju_upstreams_active",
                "Current number of upstream connections", "gauge",
                Long_Long_Integer (G.Upstreams))
      & Metric ("soju_users_active", "Current number of active users",
                "gauge", Long_Long_Integer (G.Users))
      & Counter (Worker_Panics, C));

end Soja.Metrics;
