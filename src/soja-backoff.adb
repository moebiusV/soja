pragma Ada_2022;

with Ada.Numerics.Float_Random;

package body Soja.Backoff is

   use Ada.Numerics.Float_Random;

   --  Shared generator for the jitter term, reset to a time-dependent state
   --  on elaboration.  Jitter is not security-sensitive, so a single
   --  package-level generator matches soju's use of the global math/rand.
   Gen : Generator;

   function New_Backoffer
     (Min, Max, Jitter : Duration) return Backoffer
   is
   begin
      return (Min => Min, Max => Max, Jitter => Jitter, N => 0);
   end New_Backoffer;

   procedure Reset (B : in out Backoffer) is
   begin
      B.N := 0;
   end Reset;

   function Next (B : in out Backoffer) return Duration is
      D : Duration;
   begin
      if B.N = 0 then
         B.N := 1;
         return 0.0;
      end if;

      D := Duration (B.N) * B.Min;

      --  Faithful to soju: once the delay saturates at Max the exponent is
      --  no longer doubled, so a saturated backoffer keeps returning Max.
      if D > B.Max then
         D := B.Max;
      else
         B.N := B.N * 2;
      end if;

      if B.Jitter /= 0.0 then
         D := D + B.Jitter * Duration (Random (Gen));
      end if;

      return D;
   end Next;

begin
   Reset (Gen);
end Soja.Backoff;
