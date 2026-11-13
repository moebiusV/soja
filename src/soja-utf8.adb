pragma Ada_2022;

with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;

package body Soja.Utf8 is

   --  The length of the well-formed character at S (I), 0 when there is none.
   function Valid_Len (S : String; I : Positive) return Natural is
      function B (K : Natural) return Natural is
        (Character'Pos (S (I + K)));
      Left : constant Natural := S'Last - I + 1;
      B0   : constant Natural := B (0);
      function Cont (K : Natural) return Boolean is
        (K < Left and then B (K) in 16#80# .. 16#BF#);
   begin
      if B0 < 16#80# then
         return 1;
      elsif B0 in 16#C2# .. 16#DF# then
         return (if Cont (1) then 2 else 0);
      elsif B0 in 16#E0# .. 16#EF# then
         if Left < 3 or else not Cont (1) or else not Cont (2) then
            return 0;
         end if;
         if B0 = 16#E0# and then B (1) < 16#A0# then
            return 0;   --  overlong
         end if;
         if B0 = 16#ED# and then B (1) >= 16#A0# then
            return 0;   --  a surrogate
         end if;
         return 3;
      elsif B0 in 16#F0# .. 16#F4# then
         if Left < 4 or else not Cont (1) or else not Cont (2)
           or else not Cont (3)
         then
            return 0;
         end if;
         if B0 = 16#F0# and then B (1) < 16#90# then
            return 0;   --  overlong
         end if;
         if B0 = 16#F4# and then B (1) >= 16#90# then
            return 0;   --  above U+10FFFF
         end if;
         return 4;
      end if;
      return 0;
   end Valid_Len;

   function Is_Valid (S : String) return Boolean is
      I : Natural := S'First;
   begin
      while I <= S'Last loop
         declare
            L : constant Natural := Valid_Len (S, I);
         begin
            if L = 0 then
               return False;
            end if;
            I := I + L;
         end;
      end loop;
      return True;
   end Is_Valid;

   function To_Valid (S : String) return String is
      R : Unbounded_String;
      I : Natural := S'First;
      In_Bad_Run : Boolean := False;
   begin
      while I <= S'Last loop
         declare
            L : constant Natural := Valid_Len (S, I);
         begin
            if L = 0 then
               if not In_Bad_Run then
                  Append (R, Character'Val (16#EF#) & Character'Val (16#BF#)
                             & Character'Val (16#BD#));
                  In_Bad_Run := True;
               end if;
               I := I + 1;
            else
               Append (R, S (I .. I + L - 1));
               In_Bad_Run := False;
               I := I + L;
            end if;
         end;
      end loop;
      return To_String (R);
   end To_Valid;

end Soja.Utf8;
