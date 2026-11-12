pragma Ada_2022;

with Ada.Text_IO;

with Soja.Timers;
with Timer_Test_Actions; use Timer_Test_Actions;

procedure Timers_Check is
   use Soja.Timers;

   procedure Check (Cond : Boolean; What : String) is
   begin
      if not Cond then
         raise Program_Error with What;
      end if;
   end Check;

   T : Timer_Access;
begin
   --  Fires once.
   T := After_Func (0.05, new Bump_Action);
   delay 0.3;
   Check (Counter.Value = 1, "timer fires once");
   delay 0.2;
   Check (Counter.Value = 1, "timer does not fire again");

   --  Reset after firing re-arms it (Go's Timer.Reset).
   Reset (T, 0.05);
   delay 0.3;
   Check (Counter.Value = 2, "reset re-arms a fired timer");
   Stop (T);
   Check (T = null, "Stop nulls the timer");

   --  Stop before firing cancels.
   T := After_Func (0.3, new Bump_Action);
   Stop (T);
   delay 0.5;
   Check (Counter.Value = 2, "stopped timer must not fire");

   --  Reset before firing postpones.
   T := After_Func (0.2, new Bump_Action);
   delay 0.1;
   Reset (T, 0.4);
   delay 0.25;
   Check (Counter.Value = 2, "reset postpones the firing");
   delay 0.4;
   Check (Counter.Value = 3, "postponed timer fires");
   Stop (T);

   --  A raising Action does not kill the timer.
   T := After_Func (0.05, new Failing_Action);
   delay 0.2;
   Reset (T, 0.05);   --  would raise Tasking_Error if the task had died
   Stop (T);

   --  Null timers are fine.
   Reset (null, 1.0);
   Stop (T);

   Ada.Text_IO.Put_Line ("ALL PASS");
end Timers_Check;
