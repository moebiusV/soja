pragma Ada_2022;

--  Go's time.AfterFunc / Timer.Reset / Timer.Stop, for soju's detach timer
--  and regain-nick timer.  A timer is a task; when it fires it runs an Action
--  once (in the timer's own task, so an Action must be short: soja's only
--  Actions post an event to a user's queue).  After firing, a timer stays
--  armed-for-Reset until Stop, as in Go.
--
--  Every timer must be Stopped (which frees it): a live timer task keeps the
--  program from exiting until it fires.
package Soja.Timers is

   --  Go's closure: derive and override Run.
   type Action is abstract tagged limited null record;
   procedure Run (A : in out Action) is abstract;
   type Action_Access is access all Action'Class;

   task type Timer_Task is
      entry Start (Dur : Duration; A : Action_Access);
      entry Reset (Dur : Duration);
      entry Cancel;
   end Timer_Task;

   type Timer_Access is access Timer_Task;

   --  time.AfterFunc: run A once after Dur.
   function After_Func (Dur : Duration; A : Action_Access)
      return Timer_Access;

   --  Timer.Reset: (re)arm the timer to fire Dur from now, whether or not it
   --  has already fired.  A no-op on a null timer.
   procedure Reset (T : Timer_Access; Dur : Duration);

   --  Timer.Stop, plus freeing: cancel any pending firing, release the timer
   --  and set T to null.  A no-op on a null timer.  Must not be called from
   --  the timer's own Action.
   procedure Stop (T : in out Timer_Access);

end Soja.Timers;
