pragma Ada_2022;

with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;

package body Soja.Utf8 is

   --  The byte K places after S (I).
   function Byte (S : String; I : Positive; K : Natural) return Natural is
     (Character'Pos (S (I + K)));

   --  Whether the byte K places after S (I) is there and is a continuation.
   function Is_Cont (S : String; I : Positive; K : Natural) return Boolean is
     (I + K <= S'Last and then Byte (S, I, K) in 16#80# .. 16#BF#);

   --  The length of the well-formed character at S (I), 0 when there is none:
   --  no overlong forms, no surrogates, nothing above U+10FFFF.
   function Valid_Len (S : String; I : Positive) return Natural is
     (case Byte (S, I, 0) is
         when 16#00# .. 16#7F# => 1,
         when 16#C2# .. 16#DF# => (if Is_Cont (S, I, 1) then 2 else 0),
         when 16#E0# .. 16#EF# =>
           (if Is_Cont (S, I, 1) and then Is_Cont (S, I, 2)
               and then not (Byte (S, I, 0) = 16#E0#
                             and then Byte (S, I, 1) < 16#A0#)
               and then not (Byte (S, I, 0) = 16#ED#
                             and then Byte (S, I, 1) >= 16#A0#)
            then 3 else 0),
         when 16#F0# .. 16#F4# =>
           (if Is_Cont (S, I, 1) and then Is_Cont (S, I, 2)
               and then Is_Cont (S, I, 3)
               and then not (Byte (S, I, 0) = 16#F0#
                             and then Byte (S, I, 1) < 16#90#)
               and then not (Byte (S, I, 0) = 16#F4#
                             and then Byte (S, I, 1) >= 16#90#)
            then 4 else 0),
         when others => 0);

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
