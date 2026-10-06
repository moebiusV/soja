pragma Ada_2022;

with Ada.Real_Time;
with Soja.Irc.Messages;

package body Soja.Conn is

   use type Ada.Real_Time.Time;
   use type Logging.Logger_Access;

   ---------
   -- Out_Queue --
   ---------

   protected body Out_Queue is

      entry Send (M : Message_Access; Accepted : out Boolean)
        when Count < Outgoing_Capacity or else Stopping or else Closed
      is
      begin
         if Stopping or else Closed then
            Accepted := False;
         else
            Buf ((Head + Count - 1) mod Outgoing_Capacity + 1) := M;
            Count := Count + 1;
            Accepted := True;
         end if;
      end Send;

      entry Take (M : out Message_Access; Stop : out Boolean)
        when Count > 0 or else Stopping or else Closed
      is
      begin
         if Count > 0 then
            M := Buf (Head);
            Buf (Head) := null;
            Head := Head mod Outgoing_Capacity + 1;
            Count := Count - 1;
            Stop := False;
         else
            M := null;
            Stop := True;
         end if;
      end Take;

      procedure Shutdown is
      begin
         Stopping := True;
      end Shutdown;

      procedure Close_Queue is
      begin
         Closed := True;
      end Close_Queue;

   end Out_Queue;

   ---------
   -- Writer --
   ---------

   task body Writer is
      M    : Message_Access;
      Stop : Boolean := False;

      Interval : constant Ada.Real_Time.Time_Span :=
        Ada.Real_Time.To_Time_Span
          (Duration (Rate_Delay_Nanos) / 1.0E9);
      Tokens : Float := Float (Rate_Burst);
      Last   : Ada.Real_Time.Time := Ada.Real_Time.Clock;

      --  x/time/rate's Wait: block until one token is available (refilling at
      --  one per Interval, capped at the burst), then consume it.
      procedure Wait_For_Token is
         Now     : Ada.Real_Time.Time;
         Elapsed : Ada.Real_Time.Time_Span;
      begin
         loop
            Now := Ada.Real_Time.Clock;
            Elapsed := Now - Last;
            Tokens := Float'Min
              (Float (Rate_Burst),
               Tokens
               + Float (Ada.Real_Time.To_Duration (Elapsed))
                 / Float (Ada.Real_Time.To_Duration (Interval)));
            Last := Now;
            exit when Tokens >= 1.0;
            delay Ada.Real_Time.To_Duration (Interval);
         end loop;
         Tokens := Tokens - 1.0;
      end Wait_For_Token;

   begin
      loop
         Queue.Take (M, Stop);
         exit when Stop;

         if Rate_Delay_Nanos > 0 then
            Wait_For_Token;
         end if;

         begin
            Underlying.Write_Message (M.all);
         exception
            when others =>
               exit;   -- write error: stop
         end;
      end loop;

      Underlying.Close;

      --  Drain anything queued behind a write error (conn.go drains the
      --  channel after the writer loop).
      loop
         select
            Queue.Take (M, Stop);
            exit when Stop;
         else
            exit;
         end select;
      end loop;
   end Writer;

   ---------
   -- New_Conn --
   ---------

   function New_Conn
     (Underlying : not null IRC_Conn_Access;
      Options    : Conn_Options) return Conn_Access
   is
      C : Conn_Access := new Conn;
   begin
      C.Underlying := Underlying;
      C.Logger := Options.Logger;
      C.Writer := new Writer
        (Underlying, C.Queue'Access, Options.Logger,
         Long_Long_Integer (Options.Rate_Limit_Delay * 1.0E9),
         Options.Rate_Limit_Burst);
      return C;
   end New_Conn;

   ---------
   -- Read_Message --
   ---------

   function Read_Message (C : not null access Conn) return Message is
      M : Message;
   begin
      M := C.Underlying.Read_Message;
      if C.Logger /= null then
         C.Logger.Debug ("received: " & Image (M));
      end if;
      return M;
   end Read_Message;

   ---------
   -- Send_Message --
   ---------

   procedure Send_Message (C : not null access Conn; M : Message) is
      Accepted : Boolean;
   begin
      C.Queue.Send (new Message'(M), Accepted);
   end Send_Message;

   ---------
   -- Shutdown --
   ---------

   procedure Shutdown (C : not null access Conn) is
   begin
      C.Queue.Shutdown;
   end Shutdown;

   ---------
   -- Close --
   ---------

   procedure Close (C : not null access Conn) is
   begin
      C.Queue.Close_Queue;
      C.Underlying.Close;
   end Close;

   ---------
   -- Remote_Addr --
   ---------

   function Remote_Addr (C : not null access Conn) return String is
   begin
      return C.Underlying.Remote_Addr;
   end Remote_Addr;

end Soja.Conn;
