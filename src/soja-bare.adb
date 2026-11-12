pragma Ada_2022;

package body Soja.Bare is

   use Ada.Strings.Unbounded;

   ----------------
   -- Write_Uint --
   ----------------

   procedure Write_Uint
     (Buf : in out Unbounded_String; V : Unsigned_64)
   is
      X : Unsigned_64 := V;
   begin
      while X >= 16#80# loop
         Append (Buf, Character'Val (Natural (X and 16#7F#) + 16#80#));
         X := Shift_Right (X, 7);
      end loop;
      Append (Buf, Character'Val (Natural (X)));
   end Write_Uint;

   ---------------
   -- Write_Int --
   ---------------

   procedure Write_Int (Buf : in out Unbounded_String; V : Integer_64) is
      UX : Unsigned_64 := Shift_Left (Unsigned_64'Mod (V), 1);
   begin
      if V < 0 then
         UX := not UX;
      end if;
      Write_Uint (Buf, UX);
   end Write_Int;

   ------------------
   -- Write_String --
   ------------------

   procedure Write_String (Buf : in out Unbounded_String; S : String) is
   begin
      Write_Uint (Buf, Unsigned_64 (S'Length));
      Append (Buf, S);
   end Write_String;

   ----------------
   -- New_Reader --
   ----------------

   function New_Reader (Data : String) return Reader is
   begin
      return (Data => To_Unbounded_String (Data), Pos => 1);
   end New_Reader;

   ---------------
   -- Read_Uint --
   ---------------

   function Read_Uint (R : in out Reader) return Unsigned_64 is
      X : Unsigned_64 := 0;
      S : Natural := 0;
      B : Natural;
   begin
      for I in 0 .. 9 loop
         if R.Pos > Length (R.Data) then
            raise Bare_Error with "unexpected EOF";
         end if;
         B := Character'Pos (Element (R.Data, R.Pos));
         R.Pos := R.Pos + 1;
         if B < 16#80# then
            if I = 9 and then B > 1 then
               raise Bare_Error with "varint overflows a 64-bit integer";
            end if;
            return X or Shift_Left (Unsigned_64 (B), S);
         end if;
         X := X or Shift_Left (Unsigned_64 (B mod 16#80#), S);
         S := S + 7;
      end loop;
      raise Bare_Error with "varint overflows a 64-bit integer";
   end Read_Uint;

   --------------
   -- Read_Int --
   --------------

   function Read_Int (R : in out Reader) return Integer_64 is
      UX : constant Unsigned_64 := Read_Uint (R);
      X  : Unsigned_64 := Shift_Right (UX, 1);
   begin
      if (UX and 1) /= 0 then
         X := not X;
      end if;
      --  Two's-complement reinterpretation of the unsigned bits.
      if X >= 2**63 then
         return -Integer_64 (not X) - 1;
      end if;
      return Integer_64 (X);
   end Read_Int;

   -----------------
   -- Read_String --
   -----------------

   function Read_String (R : in out Reader) return String is
      N : constant Unsigned_64 := Read_Uint (R);
   begin
      if N > Unsigned_64 (Length (R.Data) - R.Pos + 1) then
         raise Bare_Error with "unexpected EOF";
      end if;
      declare
         L : constant Natural := Natural (N);
         S : constant String := Slice (R.Data, R.Pos, R.Pos + L - 1);
      begin
         R.Pos := R.Pos + L;
         return S;
      end;
   end Read_String;

   ----------
   -- Rest --
   ----------

   function Rest (R : Reader) return String is
   begin
      if R.Pos > Length (R.Data) then
         return "";
      end if;
      return Slice (R.Data, R.Pos, Length (R.Data));
   end Rest;

end Soja.Bare;
