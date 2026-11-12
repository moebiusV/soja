pragma Ada_2022;

with Ada.Unchecked_Deallocation;

package body Soja.Timers is

   task body Timer_Task is
      D     : Duration := 0.0;
      Act   : Action_Access;
      Armed : Boolean := True;
   begin
      select
         accept Start (Dur : Duration; A : Action_Access) do
            D := Dur;
            Act := A;
         end Start;
      or
         terminate;   --  allocated but never started
      end select;

      loop
         if Armed then
            select
               accept Reset (Dur : Duration) do
                  D := Dur;
               end Reset;
            or
               accept Cancel;
               exit;
            or
               delay D;
               begin
                  Act.Run;
               exception
                  when others => null;   --  a failing Action must not kill
               end;                      --  the timer (Go: recovered)
               Armed := False;
            end select;
         else
            select
               accept Reset (Dur : Duration) do
                  D := Dur;
               end Reset;
               Armed := True;
            or
               accept Cancel;
               exit;
            or
               terminate;
            end select;
         end if;
      end loop;
   end Timer_Task;

   ----------------
   -- After_Func --
   ----------------

   function After_Func (Dur : Duration; A : Action_Access)
      return Timer_Access
   is
      T : constant Timer_Access := new Timer_Task;
   begin
      T.Start (Dur, A);
      return T;
   end After_Func;

   -----------
   -- Reset --
   -----------

   procedure Reset (T : Timer_Access; Dur : Duration) is
   begin
      if T /= null then
         T.Reset (Dur);
      end if;
   end Reset;

   ----------
   -- Stop --
   ----------

   procedure Free is new Ada.Unchecked_Deallocation (Timer_Task, Timer_Access);

   procedure Stop (T : in out Timer_Access) is
   begin
      if T = null then
         return;
      end if;
      begin
         T.Cancel;
      exception
         when Tasking_Error => null;   --  already terminated
      end;
      while not T'Terminated loop
         delay 0.001;
      end loop;
      Free (T);
   end Stop;

end Soja.Timers;
