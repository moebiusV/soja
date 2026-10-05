pragma Ada_2022;

--  Exponential backoff with jitter, translated 1:1 from soju's rate.go
--  (type backoffer / newBackoffer / Reset / Next).  The jitter term is a
--  uniform random value in [0, Jitter), matching Go's rand.Int63n(jitter)
--  over a time.Duration.
--
--  Note the faithful quirk: when the computed delay exceeds Max, Next
--  returns Max but does not double the exponent, so a saturated backoffer
--  keeps returning Max (soju does the same).
package Soja.Backoff is

   type Backoffer is private;

   function New_Backoffer
     (Min, Max, Jitter : Duration) return Backoffer;

   procedure Reset (B : in out Backoffer);
   function Next (B : in out Backoffer) return Duration;

private

   type Backoffer is record
      Min, Max, Jitter : Duration;
      N                 : Long_Long_Integer := 0;
   end record;

end Soja.Backoff;
