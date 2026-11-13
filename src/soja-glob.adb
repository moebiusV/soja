pragma Ada_2022;

package body Soja.Glob is

   --  The length in bytes of the UTF-8 character starting at S (I), cut off
   --  at the end of S.
   function Char_Len (S : String; I : Positive) return Positive is
     (Positive'Min
        (S'Last - I + 1,
         (case Character'Pos (S (I)) is
             when 16#00# .. 16#7F# => 1,
             when 16#C0# .. 16#DF# => 2,
             when 16#E0# .. 16#EF# => 3,
             when 16#F0# .. 16#FF# => 4,
             when others           => 1)));

   --  The code point of the character at S (I .. I + Len - 1).
   function Code_Point (S : String; I : Positive; Len : Positive)
      return Natural
   is
      B : constant Natural := Character'Pos (S (I));
      V : Natural;
   begin
      if Len = 1 then
         return B;
      end if;
      V := B mod (2 ** (7 - Len));
      for K in 1 .. Len - 1 loop
         V := V * 64 + (Character'Pos (S (I + K)) mod 64);
      end loop;
      return V;
   end Code_Point;

   --  Match one [...] class at Pattern (P) (P is on the '['), against the
   --  character of Name at N.  Next is the first index after the class; Bad
   --  when the class is malformed.
   procedure Match_Class
     (Pattern : String; P : Positive; Name : String; N : Positive;
      Matched : out Boolean; Next : out Positive; Bad : out Boolean)
   is
      Len    : constant Positive := Char_Len (Name, N);
      C      : constant Natural := Code_Point (Name, N, Len);
      I      : Positive := P + 1;
      Negate : Boolean := False;
      Found  : Boolean := False;
      Count  : Natural := 0;

      --  One (possibly escaped) character of the pattern: its code point.
      procedure Take (Cp : out Natural; Ok : out Boolean) is
      begin
         Ok := False;
         Cp := 0;
         if I > Pattern'Last or else Pattern (I) = '-'
           or else Pattern (I) = ']'
         then
            return;
         end if;
         if Pattern (I) = '\' then
            I := I + 1;
            if I > Pattern'Last then
               return;
            end if;
         end if;
         declare
            L : constant Positive := Char_Len (Pattern, I);
         begin
            Cp := Code_Point (Pattern, I, L);
            I := I + L;
         end;
         Ok := True;
      end Take;
   begin
      Matched := False;
      Next := P + 1;
      Bad := False;
      if I <= Pattern'Last and then Pattern (I) = '^' then
         Negate := True;
         I := I + 1;
      end if;
      loop
         if I <= Pattern'Last and then Pattern (I) = ']'
           and then Count > 0
         then
            I := I + 1;
            exit;
         end if;
         declare
            Lo, Hi : Natural;
            Ok     : Boolean;
         begin
            Take (Lo, Ok);
            if not Ok then
               Bad := True;
               return;
            end if;
            Hi := Lo;
            if I <= Pattern'Last and then Pattern (I) = '-' then
               I := I + 1;
               Take (Hi, Ok);
               if not Ok then
                  Bad := True;
                  return;
               end if;
            end if;
            if Lo <= C and then C <= Hi then
               Found := True;
            end if;
            Count := Count + 1;
         end;
      end loop;
      Matched := Found /= Negate;
      Next := I;
   end Match_Class;

   function Match_At
     (Pattern : String; P : Positive; Name : String; N : Positive)
      return Boolean
   is
      Pi : Natural := P;
      Ni : Natural := N;
   begin
      while Pi <= Pattern'Last loop
         case Pattern (Pi) is
            when '*' =>
               --  Collapse a run of stars, then try every split point (but
               --  never across a '/').
               while Pi <= Pattern'Last and then Pattern (Pi) = '*' loop
                  Pi := Pi + 1;
               end loop;
               if Pi > Pattern'Last then
                  for K in Ni .. Name'Last loop
                     if Name (K) = '/' then
                        return False;
                     end if;
                  end loop;
                  return True;
               end if;
               declare
                  K : Natural := Ni;
               begin
                  loop
                     if Match_At (Pattern, Pi, Name, K) then
                        return True;
                     end if;
                     exit when K > Name'Last or else Name (K) = '/';
                     K := K + Char_Len (Name, K);
                  end loop;
                  return False;
               end;

            when '?' =>
               if Ni > Name'Last or else Name (Ni) = '/' then
                  return False;
               end if;
               Ni := Ni + Char_Len (Name, Ni);
               Pi := Pi + 1;

            when '[' =>
               if Ni > Name'Last then
                  return False;
               end if;
               declare
                  Matched, Bad : Boolean;
                  Next         : Positive;
               begin
                  Match_Class (Pattern, Pi, Name, Ni, Matched, Next, Bad);
                  if Bad or else not Matched then
                     return False;
                  end if;
                  Ni := Ni + Char_Len (Name, Ni);
                  Pi := Next;
               end;

            when '\' =>
               Pi := Pi + 1;
               if Pi > Pattern'Last or else Ni > Name'Last
                 or else Pattern (Pi) /= Name (Ni)
               then
                  return False;
               end if;
               Pi := Pi + 1;
               Ni := Ni + 1;

            when others =>
               if Ni > Name'Last or else Pattern (Pi) /= Name (Ni) then
                  return False;
               end if;
               Pi := Pi + 1;
               Ni := Ni + 1;
         end case;
      end loop;
      return Ni > Name'Last;
   end Match_At;

   function Match (Pattern, Name : String) return Boolean is
   begin
      return Match_At (Pattern, Pattern'First, Name, Name'First);
   end Match;

end Soja.Glob;
