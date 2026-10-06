pragma Ada_2022;

package body Soja.Irc.User_Modes is

   use Ada.Strings.Unbounded;

   ---------
   -- Has --
   ---------

   function Has (M : User_Modes; C : Character) return Boolean is
      S : constant String := To_String (M.Value);
   begin
      for I in S'Range loop
         if S (I) = C then
            return True;
         end if;
      end loop;
      return False;
   end Has;

   ---------
   -- Add --
   ---------

   procedure Add (M : in out User_Modes; C : Character) is
   begin
      if not Has (M, C) then
         Append (M.Value, C);
      end if;
   end Add;

   ---------
   -- Del --
   ---------

   procedure Del (M : in out User_Modes; C : Character) is
      S : constant String := To_String (M.Value);
   begin
      for I in S'Range loop
         if S (I) = C then
            declare
               R : Unbounded_String;
            begin
               if I > S'First then
                  Append (R, S (S'First .. I - 1));
               end if;
               if I < S'Last then
                  Append (R, S (I + 1 .. S'Last));
               end if;
               M.Value := R;
            end;
            return;
         end if;
      end loop;
   end Del;

   -----------
   -- Apply --
   -----------

   procedure Apply (M : in out User_Modes; S : String; Success : out Boolean)
   is
      Plus_Minus : Character := ASCII.NUL;
   begin
      for I in S'Range loop
         case S (I) is
            when '+' | '-' =>
               Plus_Minus := S (I);
            when others =>
               case Plus_Minus is
                  when '+' =>
                     Add (M, S (I));
                  when '-' =>
                     Del (M, S (I));
                  when others =>
                     Success := False;
                     return;
               end case;
         end case;
      end loop;
      Success := True;
   end Apply;

   -----------
   -- Image --
   -----------

   function Image (M : User_Modes) return String is
     (To_String (M.Value));

end Soja.Irc.User_Modes;
