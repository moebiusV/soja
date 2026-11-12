pragma Ada_2022;

with Soja.Timers;

--  Library-level Actions for timers_check (Action_Access is library-level, so
--  test Actions cannot be declared inside the main procedure).
package Timer_Test_Actions is

   protected Counter is
      procedure Bump;
      function Value return Natural;
   private
      N : Natural := 0;
   end Counter;

   type Bump_Action is new Soja.Timers.Action with null record;
   overriding procedure Run (A : in out Bump_Action);

   type Failing_Action is new Soja.Timers.Action with null record;
   overriding procedure Run (A : in out Failing_Action);

end Timer_Test_Actions;
