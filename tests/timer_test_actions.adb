pragma Ada_2022;

package body Timer_Test_Actions is

   protected body Counter is
      procedure Bump is
      begin
         N := N + 1;
      end Bump;
      function Value return Natural is (N);
   end Counter;

   overriding procedure Run (A : in out Bump_Action) is
      pragma Unreferenced (A);
   begin
      Counter.Bump;
   end Run;

   overriding procedure Run (A : in out Failing_Action) is
      pragma Unreferenced (A);
   begin
      raise Program_Error;
   end Run;

end Timer_Test_Actions;
