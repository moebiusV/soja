pragma Ada_2022;

with Ada.Exceptions;
with Ada.Strings.Fixed;
with Ada.Text_IO;
with GNAT.OS_Lib;

with Soja.Metrics; use Soja.Metrics;

--  The Prometheus text and the counters.
procedure Metrics_Check is

   procedure Check (Cond : Boolean; What : String) is
   begin
      if not Cond then
         raise Program_Error with What;
      end if;
   end Check;

   LF : constant Character := ASCII.LF;

   Zero : constant Counts := [others => 0];

   Expected : constant String :=
     "# HELP soju_downstream_in_messages_total Total number of incoming "
     & "messages received from downstream clients" & LF
     & "# TYPE soju_downstream_in_messages_total counter" & LF
     & "soju_downstream_in_messages_total 3" & LF
     & "# HELP soju_downstream_out_messages_total Total number of outgoing "
     & "messages sent to downstream clients" & LF
     & "# TYPE soju_downstream_out_messages_total counter" & LF
     & "soju_downstream_out_messages_total 4" & LF
     & "# HELP soju_downstreams_active Current number of downstream "
     & "connections" & LF
     & "# TYPE soju_downstreams_active gauge" & LF
     & "soju_downstreams_active 2" & LF
     & "# HELP soju_upstream_connect_errors_total Total number of upstream "
     & "connection errors" & LF
     & "# TYPE soju_upstream_connect_errors_total counter" & LF
     & "soju_upstream_connect_errors_total 5" & LF
     & "# HELP soju_upstream_in_messages_total Total number of incoming "
     & "messages received from upstream servers" & LF
     & "# TYPE soju_upstream_in_messages_total counter" & LF
     & "soju_upstream_in_messages_total 1" & LF
     & "# HELP soju_upstream_out_messages_total Total number of outgoing "
     & "messages sent to upstream servers" & LF
     & "# TYPE soju_upstream_out_messages_total counter" & LF
     & "soju_upstream_out_messages_total 2" & LF
     & "# HELP soju_upstreams_active Current number of upstream "
     & "connections" & LF
     & "# TYPE soju_upstreams_active gauge" & LF
     & "soju_upstreams_active 7" & LF
     & "# HELP soju_users_active Current number of active users" & LF
     & "# TYPE soju_users_active gauge" & LF
     & "soju_users_active 6" & LF
     & "# HELP soju_worker_panics_total Total number of panics in worker "
     & "goroutines" & LF
     & "# TYPE soju_worker_panics_total counter" & LF
     & "soju_worker_panics_total 0" & LF;

   Store : Counter_Store;
begin
   Check (Render ((Users => 6, Downstreams => 2, Upstreams => 7),
                  [Upstream_In => 1, Upstream_Out => 2, Downstream_In => 3,
                   Downstream_Out => 4, Upstream_Connect_Errors => 5,
                   Worker_Panics => 0])
          = Expected, "the exposition text");

   Check (Name (Upstream_Out) = "soju_upstream_out_messages_total"
          and then Name (Worker_Panics) = "soju_worker_panics_total",
          "metric names");

   Check (Store.Snapshot = Zero, "a new store is zero");
   Store.Increment (Upstream_In);
   Store.Increment (Upstream_In);
   Store.Increment (Downstream_Out);
   Check (Store.Snapshot = Counts'[Upstream_In => 2, Downstream_Out => 1,
                                   others => 0], "counting");

   --  A big value is written in full, not as 1e+06.
   Check (Ada.Strings.Fixed.Index
            (Render ((others => <>), Counts'[Upstream_In => 1_000_000, others => 0]),
             "soju_upstream_in_messages_total 1000000" & LF) > 0,
          "no exponent");
   Ada.Text_IO.Put_Line ("ALL PASS");
exception
   when E : others =>
      Ada.Text_IO.Put_Line
        ("FAILED: " & Ada.Exceptions.Exception_Information (E));
      GNAT.OS_Lib.OS_Exit (1);
end Metrics_Check;
