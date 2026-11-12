pragma Ada_2022;

package body Soja.Base64 is

   Std_Alphabet : constant String :=
     "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
   URL_Alphabet : constant String :=
     "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";

   ------------
   -- Encode --
   ------------

   function Encode
     (Data     : String;
      URL_Safe : Boolean := False;
      Padded   : Boolean := True) return String
   is
      Alphabet : constant String :=
        (if URL_Safe then URL_Alphabet else Std_Alphabet);
      Groups : constant Natural := (Data'Length + 2) / 3;
      R      : String (1 .. Groups * 4);
      P      : Natural := Data'First;
      O      : Natural := 0;
      B0, B1, B2, N : Natural;
   begin
      while P <= Data'Last loop
         N := Natural'Min (3, Data'Last - P + 1);
         B0 := Character'Pos (Data (P));
         B1 := (if N > 1 then Character'Pos (Data (P + 1)) else 0);
         B2 := (if N > 2 then Character'Pos (Data (P + 2)) else 0);
         R (O + 1) := Alphabet (B0 / 4 + 1);
         R (O + 2) := Alphabet ((B0 mod 4) * 16 + B1 / 16 + 1);
         R (O + 3) :=
           (if N > 1 then Alphabet ((B1 mod 16) * 4 + B2 / 64 + 1) else '=');
         R (O + 4) := (if N > 2 then Alphabet (B2 mod 64 + 1) else '=');
         P := P + 3;
         O := O + 4;
      end loop;

      if Padded then
         return R;
      end if;
      --  Unpadded: drop the '=' characters.
      declare
         Last : Natural := R'Last;
      begin
         while Last >= R'First and then R (Last) = '=' loop
            Last := Last - 1;
         end loop;
         return R (R'First .. Last);
      end;
   end Encode;

   ------------
   -- Decode --
   ------------

   function Decode
     (Text     : String;
      Valid    : out Boolean;
      URL_Safe : Boolean := False;
      Padded   : Boolean := True) return String
   is
      Alphabet : constant String :=
        (if URL_Safe then URL_Alphabet else Std_Alphabet);

      Clean : String (1 .. Text'Length);
      Len   : Natural := 0;

      function Value (C : Character) return Integer is
      begin
         for I in Alphabet'Range loop
            if Alphabet (I) = C then
               return I - 1;
            end if;
         end loop;
         return -1;
      end Value;
   begin
      Valid := False;

      for C of Text loop
         if C /= ASCII.CR and then C /= ASCII.LF then
            Len := Len + 1;
            Clean (Len) := C;
         end if;
      end loop;

      --  Padding.
      declare
         Pad : Natural := 0;
      begin
         if Padded then
            if Len mod 4 /= 0 then
               return "";
            end if;
            while Len > 0 and then Pad < 2 and then Clean (Len) = '=' loop
               Len := Len - 1;
               Pad := Pad + 1;
            end loop;
         elsif Len mod 4 = 1 then
            return "";
         end if;
         --  Whatever is left must be alphabet characters ('=' is not one).
         for I in 1 .. Len loop
            if Value (Clean (I)) < 0 then
               return "";
            end if;
         end loop;
      end;

      declare
         Out_Len : constant Natural := Len * 6 / 8;
         R       : String (1 .. Out_Len);
         O       : Natural := 0;
         Acc     : Natural := 0;
         Bits    : Natural := 0;
      begin
         for I in 1 .. Len loop
            Acc := (Acc * 64 + Value (Clean (I))) mod 2**24;
            Bits := Bits + 6;
            if Bits >= 8 then
               Bits := Bits - 8;
               O := O + 1;
               R (O) := Character'Val ((Acc / 2**Bits) mod 256);
            end if;
         end loop;
         Valid := True;
         return R;
      end;
   end Decode;

end Soja.Base64;
