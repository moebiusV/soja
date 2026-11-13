
with Interfaces;
with Ada.Unchecked_Deallocation;

package body Irc_Wire.Parser is

   use Ada.Strings.Unbounded;
   use Interfaces;   function Scan_Word (S : String; Pos, Len : Natural) return Natural is
      I : Natural := Pos;
   begin
      if I > Len
        or else S (I) not in 'a' .. 'z' | 'A' .. 'Z' | '_' | '-'
      then
         return 0;
      end if;
      I := I + 1;
      while I <= Len
        and then S (I) in 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '_' | '-' | '.'
      loop
         I := I + 1;
      end loop;
      return I - Pos;
   end Scan_Word;

   function Scan_Int (S : String; Pos, Len : Natural) return Natural is
      I     : Natural := Pos;
      Start : Natural;
   begin
      if I < Len and then S (I) = '-' and then S (I + 1) in '0' .. '9' then
         I := I + 1;
      end if;
      Start := I;
      while I <= Len and then S (I) in '0' .. '9' loop
         I := I + 1;
      end loop;
      return (if I > Start then I - Pos else 0);
   end Scan_Int;

   function Scan_Str (S : String; Pos, Len : Natural) return Natural is
      I : Natural;
   begin
      if Pos > Len or else S (Pos) /= '"' then
         return 0;
      end if;
      I := Pos + 1;
      while I <= Len and then S (I) /= '"' loop
         if S (I) = '\' and then I < Len then
            I := I + 1;
         end if;
         I := I + 1;
      end loop;
      if I > Len then
         return 0;
      end if;
      return I + 1 - Pos;
   end Scan_Str;

   function Scan_Ws (S : String; Pos, Len : Natural) return Natural is
   begin
      if Pos <= Len
        and then S (Pos) in ' ' | ASCII.HT | ASCII.CR | ASCII.LF
      then
         return 1;
      end if;
      return 0;
   end Scan_Ws;

   function Decode_Utf8 (S : String; Pos, Len : Natural; Cp : out Natural) return Natural is
      B0 : Unsigned_32;
      N  : Natural := 0;
      C  : Unsigned_32 := 0;
      B  : Unsigned_32;
   begin
      Cp := 0;
      if Pos > Len then return 0; end if;
      B0 := Unsigned_32 (Character'Pos (S (Pos)));
      if B0 < 16#80# then
         Cp := Natural (B0); return 1;
      elsif (B0 and 16#E0#) = 16#C0# then N := 2; C := B0 and 16#1F#;
      elsif (B0 and 16#F0#) = 16#E0# then N := 3; C := B0 and 16#0F#;
      elsif (B0 and 16#F8#) = 16#F0# then N := 4; C := B0 and 16#07#;
      else return 0;
      end if;
      if Pos + N - 1 > Len then return 0; end if;
      for J in 1 .. N - 1 loop
         B := Unsigned_32 (Character'Pos (S (Pos + J)));
         if (B and 16#C0#) /= 16#80# then return 0; end if;
         C := C * 16#40# or (B and 16#3F#);
      end loop;
      Cp := Natural (C); return N;
   end Decode_Utf8;

   function Scan_Tag_end (S : String; Pos, Len : Natural) return Natural is
      Cp  : Natural;
      N   : Natural;
      Off : Natural := 0;
   begin
      declare
         Cnt : Natural := 0;
      begin
         loop
            declare
               Br    : Natural := 0;
               O     : Natural;
               Match : Boolean;
            begin
               O := 0;
               Match := True;
               if Match then
                  N := Decode_Utf8 (S, Pos + Off + O, Len, Cp);
                  Match := N > 0 and then (Cp <= 31);
                  if Match then O := O + N; end if;
               end if;
               if Match and then O > Br then Br := O; end if;
               O := 0;
               Match := True;
               if Match then
                  N := Decode_Utf8 (S, Pos + Off + O, Len, Cp);
                  Match := N > 0 and then (Cp >= 33 and then Cp <= 58);
                  if Match then O := O + N; end if;
               end if;
               if Match and then O > Br then Br := O; end if;
               O := 0;
               Match := True;
               if Match then
                  N := Decode_Utf8 (S, Pos + Off + O, Len, Cp);
                  Match := N > 0 and then (Cp >= 60 and then Cp <= 1114111);
                  if Match then O := O + N; end if;
               end if;
               if Match and then O > Br then Br := O; end if;
               exit when Br = 0;
               Off := Off + Br;
               Cnt := Cnt + 1;
            end;
         end loop;
      end;
      return Off;
   end Scan_Tag_end;

   function Scan_Tag_key (S : String; Pos, Len : Natural) return Natural is
      Cp  : Natural;
      N   : Natural;
      Off : Natural := 0;
   begin
      declare
         Cnt : Natural := 0;
      begin
         loop
            declare
               Br    : Natural := 0;
               O     : Natural;
               Match : Boolean;
            begin
               O := 0;
               Match := True;
               if Match then
                  N := Decode_Utf8 (S, Pos + Off + O, Len, Cp);
                  Match := N > 0 and then (Cp <= 31);
                  if Match then O := O + N; end if;
               end if;
               if Match and then O > Br then Br := O; end if;
               O := 0;
               Match := True;
               if Match then
                  N := Decode_Utf8 (S, Pos + Off + O, Len, Cp);
                  Match := N > 0 and then (Cp >= 33 and then Cp <= 58);
                  if Match then O := O + N; end if;
               end if;
               if Match and then O > Br then Br := O; end if;
               O := 0;
               Match := True;
               if Match then
                  N := Decode_Utf8 (S, Pos + Off + O, Len, Cp);
                  Match := N > 0 and then (Cp >= 60 and then Cp <= 60);
                  if Match then O := O + N; end if;
               end if;
               if Match and then O > Br then Br := O; end if;
               O := 0;
               Match := True;
               if Match then
                  N := Decode_Utf8 (S, Pos + Off + O, Len, Cp);
                  Match := N > 0 and then (Cp >= 62 and then Cp <= 1114111);
                  if Match then O := O + N; end if;
               end if;
               if Match and then O > Br then Br := O; end if;
               exit when Br = 0;
               Off := Off + Br;
               Cnt := Cnt + 1;
            end;
         end loop;
      end;
      return Off;
   end Scan_Tag_key;

   function Scan_Tag_key_1 (S : String; Pos, Len : Natural) return Natural is
      Cp  : Natural;
      N   : Natural;
      Off : Natural := 0;
   begin
      declare
         Cnt : Natural := 0;
      begin
         loop
            declare
               Br    : Natural := 0;
               O     : Natural;
               Match : Boolean;
            begin
               O := 0;
               Match := True;
               if Match then
                  N := Decode_Utf8 (S, Pos + Off + O, Len, Cp);
                  Match := N > 0 and then (Cp <= 31);
                  if Match then O := O + N; end if;
               end if;
               if Match and then O > Br then Br := O; end if;
               O := 0;
               Match := True;
               if Match then
                  N := Decode_Utf8 (S, Pos + Off + O, Len, Cp);
                  Match := N > 0 and then (Cp >= 33 and then Cp <= 58);
                  if Match then O := O + N; end if;
               end if;
               if Match and then O > Br then Br := O; end if;
               O := 0;
               Match := True;
               if Match then
                  N := Decode_Utf8 (S, Pos + Off + O, Len, Cp);
                  Match := N > 0 and then (Cp >= 60 and then Cp <= 60);
                  if Match then O := O + N; end if;
               end if;
               if Match and then O > Br then Br := O; end if;
               O := 0;
               Match := True;
               if Match then
                  N := Decode_Utf8 (S, Pos + Off + O, Len, Cp);
                  Match := N > 0 and then (Cp >= 62 and then Cp <= 1114111);
                  if Match then O := O + N; end if;
               end if;
               if Match and then O > Br then Br := O; end if;
               exit when Br = 0;
               Off := Off + Br;
               Cnt := Cnt + 1;
            end;
         end loop;
         if Cnt < 1 then return 0; end if;
      end;
      return Off;
   end Scan_Tag_key_1;

   function Scan_Tag_value (S : String; Pos, Len : Natural) return Natural is
      Cp  : Natural;
      N   : Natural;
      Off : Natural := 0;
   begin
      declare
         Cnt : Natural := 0;
      begin
         loop
            declare
               Br    : Natural := 0;
               O     : Natural;
               Match : Boolean;
            begin
               O := 0;
               Match := True;
               if Match then
                  N := Decode_Utf8 (S, Pos + Off + O, Len, Cp);
                  Match := N > 0 and then (Cp <= 31);
                  if Match then O := O + N; end if;
               end if;
               if Match and then O > Br then Br := O; end if;
               O := 0;
               Match := True;
               if Match then
                  N := Decode_Utf8 (S, Pos + Off + O, Len, Cp);
                  Match := N > 0 and then (Cp >= 33 and then Cp <= 58);
                  if Match then O := O + N; end if;
               end if;
               if Match and then O > Br then Br := O; end if;
               O := 0;
               Match := True;
               if Match then
                  N := Decode_Utf8 (S, Pos + Off + O, Len, Cp);
                  Match := N > 0 and then (Cp >= 60 and then Cp <= 1114111);
                  if Match then O := O + N; end if;
               end if;
               if Match and then O > Br then Br := O; end if;
               exit when Br = 0;
               Off := Off + Br;
               Cnt := Cnt + 1;
            end;
         end loop;
      end;
      return Off;
   end Scan_Tag_value;

   function Scan_Pfx_end (S : String; Pos, Len : Natural) return Natural is
      Cp  : Natural;
      N   : Natural;
      Off : Natural := 0;
   begin
      declare
         Cnt : Natural := 0;
      begin
         loop
            declare
               Br    : Natural := 0;
               O     : Natural;
               Match : Boolean;
            begin
               O := 0;
               Match := True;
               if Match then
                  N := Decode_Utf8 (S, Pos + Off + O, Len, Cp);
                  Match := N > 0 and then (Cp <= 31);
                  if Match then O := O + N; end if;
               end if;
               if Match and then O > Br then Br := O; end if;
               O := 0;
               Match := True;
               if Match then
                  N := Decode_Utf8 (S, Pos + Off + O, Len, Cp);
                  Match := N > 0 and then (Cp >= 33 and then Cp <= 1114111);
                  if Match then O := O + N; end if;
               end if;
               if Match and then O > Br then Br := O; end if;
               exit when Br = 0;
               Off := Off + Br;
               Cnt := Cnt + 1;
            end;
         end loop;
      end;
      return Off;
   end Scan_Pfx_end;

   function Scan_Pfx_name (S : String; Pos, Len : Natural) return Natural is
      Cp  : Natural;
      N   : Natural;
      Off : Natural := 0;
   begin
      declare
         Cnt : Natural := 0;
      begin
         loop
            declare
               Br    : Natural := 0;
               O     : Natural;
               Match : Boolean;
            begin
               O := 0;
               Match := True;
               if Match then
                  N := Decode_Utf8 (S, Pos + Off + O, Len, Cp);
                  Match := N > 0 and then (Cp <= 31);
                  if Match then O := O + N; end if;
               end if;
               if Match and then O > Br then Br := O; end if;
               O := 0;
               Match := True;
               if Match then
                  N := Decode_Utf8 (S, Pos + Off + O, Len, Cp);
                  Match := N > 0 and then (Cp >= 34 and then Cp <= 63);
                  if Match then O := O + N; end if;
               end if;
               if Match and then O > Br then Br := O; end if;
               O := 0;
               Match := True;
               if Match then
                  N := Decode_Utf8 (S, Pos + Off + O, Len, Cp);
                  Match := N > 0 and then (Cp >= 65 and then Cp <= 1114111);
                  if Match then O := O + N; end if;
               end if;
               if Match and then O > Br then Br := O; end if;
               exit when Br = 0;
               Off := Off + Br;
               Cnt := Cnt + 1;
            end;
         end loop;
      end;
      return Off;
   end Scan_Pfx_name;

   function Scan_Pfx_name_1 (S : String; Pos, Len : Natural) return Natural is
      Cp  : Natural;
      N   : Natural;
      Off : Natural := 0;
   begin
      declare
         Cnt : Natural := 0;
      begin
         loop
            declare
               Br    : Natural := 0;
               O     : Natural;
               Match : Boolean;
            begin
               O := 0;
               Match := True;
               if Match then
                  N := Decode_Utf8 (S, Pos + Off + O, Len, Cp);
                  Match := N > 0 and then (Cp <= 31);
                  if Match then O := O + N; end if;
               end if;
               if Match and then O > Br then Br := O; end if;
               O := 0;
               Match := True;
               if Match then
                  N := Decode_Utf8 (S, Pos + Off + O, Len, Cp);
                  Match := N > 0 and then (Cp >= 34 and then Cp <= 63);
                  if Match then O := O + N; end if;
               end if;
               if Match and then O > Br then Br := O; end if;
               O := 0;
               Match := True;
               if Match then
                  N := Decode_Utf8 (S, Pos + Off + O, Len, Cp);
                  Match := N > 0 and then (Cp >= 65 and then Cp <= 1114111);
                  if Match then O := O + N; end if;
               end if;
               if Match and then O > Br then Br := O; end if;
               exit when Br = 0;
               Off := Off + Br;
               Cnt := Cnt + 1;
            end;
         end loop;
         if Cnt < 1 then return 0; end if;
      end;
      return Off;
   end Scan_Pfx_name_1;

   function Scan_Pfx_user_name (S : String; Pos, Len : Natural) return Natural is
      Cp  : Natural;
      N   : Natural;
      Off : Natural := 0;
   begin
      declare
         Cnt : Natural := 0;
      begin
         loop
            declare
               Br    : Natural := 0;
               O     : Natural;
               Match : Boolean;
            begin
               O := 0;
               Match := True;
               if Match then
                  N := Decode_Utf8 (S, Pos + Off + O, Len, Cp);
                  Match := N > 0 and then (Cp <= 31);
                  if Match then O := O + N; end if;
               end if;
               if Match and then O > Br then Br := O; end if;
               O := 0;
               Match := True;
               if Match then
                  N := Decode_Utf8 (S, Pos + Off + O, Len, Cp);
                  Match := N > 0 and then (Cp >= 33 and then Cp <= 63);
                  if Match then O := O + N; end if;
               end if;
               if Match and then O > Br then Br := O; end if;
               O := 0;
               Match := True;
               if Match then
                  N := Decode_Utf8 (S, Pos + Off + O, Len, Cp);
                  Match := N > 0 and then (Cp >= 65 and then Cp <= 1114111);
                  if Match then O := O + N; end if;
               end if;
               if Match and then O > Br then Br := O; end if;
               exit when Br = 0;
               Off := Off + Br;
               Cnt := Cnt + 1;
            end;
         end loop;
      end;
      return Off;
   end Scan_Pfx_user_name;

   function Scan_Pfx_host_name (S : String; Pos, Len : Natural) return Natural is
      Cp  : Natural;
      N   : Natural;
      Off : Natural := 0;
   begin
      declare
         Cnt : Natural := 0;
      begin
         loop
            declare
               Br    : Natural := 0;
               O     : Natural;
               Match : Boolean;
            begin
               O := 0;
               Match := True;
               if Match then
                  N := Decode_Utf8 (S, Pos + Off + O, Len, Cp);
                  Match := N > 0 and then (Cp <= 31);
                  if Match then O := O + N; end if;
               end if;
               if Match and then O > Br then Br := O; end if;
               O := 0;
               Match := True;
               if Match then
                  N := Decode_Utf8 (S, Pos + Off + O, Len, Cp);
                  Match := N > 0 and then (Cp >= 33 and then Cp <= 1114111);
                  if Match then O := O + N; end if;
               end if;
               if Match and then O > Br then Br := O; end if;
               exit when Br = 0;
               Off := Off + Br;
               Cnt := Cnt + 1;
            end;
         end loop;
      end;
      return Off;
   end Scan_Pfx_host_name;

   function Scan_Lead (S : String; Pos, Len : Natural) return Natural is
      Cp  : Natural;
      N   : Natural;
      Off : Natural := 0;
   begin
      declare
         Cnt : Natural := 0;
      begin
         loop
            declare
               Br    : Natural := 0;
               O     : Natural;
               Match : Boolean;
            begin
               O := 0;
               Match := True;
               if Match then
                  N := Decode_Utf8 (S, Pos + Off + O, Len, Cp);
                  Match := N > 0 and then (Cp >= 32 and then Cp <= 32);
                  if Match then O := O + N; end if;
               end if;
               if Match and then O > Br then Br := O; end if;
               exit when Br = 0;
               Off := Off + Br;
               Cnt := Cnt + 1;
            end;
         end loop;
      end;
      return Off;
   end Scan_Lead;

   function Scan_Spaces (S : String; Pos, Len : Natural) return Natural is
      Cp  : Natural;
      N   : Natural;
      Off : Natural := 0;
   begin
      declare
         Cnt : Natural := 0;
      begin
         loop
            declare
               Br    : Natural := 0;
               O     : Natural;
               Match : Boolean;
            begin
               O := 0;
               Match := True;
               if Match then
                  N := Decode_Utf8 (S, Pos + Off + O, Len, Cp);
                  Match := N > 0 and then (Cp >= 32 and then Cp <= 32);
                  if Match then O := O + N; end if;
               end if;
               if Match and then O > Br then Br := O; end if;
               exit when Br = 0;
               Off := Off + Br;
               Cnt := Cnt + 1;
            end;
         end loop;
         if Cnt < 1 then return 0; end if;
      end;
      return Off;
   end Scan_Spaces;

   function Scan_Command (S : String; Pos, Len : Natural) return Natural is
      Cp  : Natural;
      N   : Natural;
      Off : Natural := 0;
   begin
      declare
         Cnt : Natural := 0;
      begin
         loop
            declare
               Br    : Natural := 0;
               O     : Natural;
               Match : Boolean;
            begin
               O := 0;
               Match := True;
               if Match then
                  N := Decode_Utf8 (S, Pos + Off + O, Len, Cp);
                  Match := N > 0 and then (Cp <= 31);
                  if Match then O := O + N; end if;
               end if;
               if Match and then O > Br then Br := O; end if;
               O := 0;
               Match := True;
               if Match then
                  N := Decode_Utf8 (S, Pos + Off + O, Len, Cp);
                  Match := N > 0 and then (Cp >= 33 and then Cp <= 1114111);
                  if Match then O := O + N; end if;
               end if;
               if Match and then O > Br then Br := O; end if;
               exit when Br = 0;
               Off := Off + Br;
               Cnt := Cnt + 1;
            end;
         end loop;
         if Cnt < 1 then return 0; end if;
      end;
      return Off;
   end Scan_Command;

   function Scan_Middle (S : String; Pos, Len : Natural) return Natural is
      Cp   : Natural;
      N    : Natural;
      Best : Natural := 0;
      Off  : Natural;
      Ok   : Boolean;
   begin
      Off := 0;
      Ok := True;
      if Ok then
         N := Decode_Utf8 (S, Pos + Off, Len, Cp);
         Ok := N > 0 and then (Cp <= 31);
         if Ok then Off := Off + N; end if;
      end if;
      if Ok then
         declare
            Cnt : Natural := 0;
         begin
            loop
               declare
                  Br    : Natural := 0;
                  O     : Natural;
                  Match : Boolean;
               begin
                  O := 0;
                  Match := True;
                  if Match then
                     N := Decode_Utf8 (S, Pos + Off + O, Len, Cp);
                     Match := N > 0 and then (Cp <= 31);
                     if Match then O := O + N; end if;
                  end if;
                  if Match and then O > Br then Br := O; end if;
                  O := 0;
                  Match := True;
                  if Match then
                     N := Decode_Utf8 (S, Pos + Off + O, Len, Cp);
                     Match := N > 0 and then (Cp >= 33 and then Cp <= 1114111);
                     if Match then O := O + N; end if;
                  end if;
                  if Match and then O > Br then Br := O; end if;
                  exit when Br = 0;
                  Off := Off + Br;
                  Cnt := Cnt + 1;
               end;
            end loop;
         end;
      end if;
      if Ok and then Off > Best then Best := Off; end if;
      Off := 0;
      Ok := True;
      if Ok then
         N := Decode_Utf8 (S, Pos + Off, Len, Cp);
         Ok := N > 0 and then (Cp >= 33 and then Cp <= 57);
         if Ok then Off := Off + N; end if;
      end if;
      if Ok then
         declare
            Cnt : Natural := 0;
         begin
            loop
               declare
                  Br    : Natural := 0;
                  O     : Natural;
                  Match : Boolean;
               begin
                  O := 0;
                  Match := True;
                  if Match then
                     N := Decode_Utf8 (S, Pos + Off + O, Len, Cp);
                     Match := N > 0 and then (Cp <= 31);
                     if Match then O := O + N; end if;
                  end if;
                  if Match and then O > Br then Br := O; end if;
                  O := 0;
                  Match := True;
                  if Match then
                     N := Decode_Utf8 (S, Pos + Off + O, Len, Cp);
                     Match := N > 0 and then (Cp >= 33 and then Cp <= 1114111);
                     if Match then O := O + N; end if;
                  end if;
                  if Match and then O > Br then Br := O; end if;
                  exit when Br = 0;
                  Off := Off + Br;
                  Cnt := Cnt + 1;
               end;
            end loop;
         end;
      end if;
      if Ok and then Off > Best then Best := Off; end if;
      Off := 0;
      Ok := True;
      if Ok then
         N := Decode_Utf8 (S, Pos + Off, Len, Cp);
         Ok := N > 0 and then (Cp >= 59 and then Cp <= 1114111);
         if Ok then Off := Off + N; end if;
      end if;
      if Ok then
         declare
            Cnt : Natural := 0;
         begin
            loop
               declare
                  Br    : Natural := 0;
                  O     : Natural;
                  Match : Boolean;
               begin
                  O := 0;
                  Match := True;
                  if Match then
                     N := Decode_Utf8 (S, Pos + Off + O, Len, Cp);
                     Match := N > 0 and then (Cp <= 31);
                     if Match then O := O + N; end if;
                  end if;
                  if Match and then O > Br then Br := O; end if;
                  O := 0;
                  Match := True;
                  if Match then
                     N := Decode_Utf8 (S, Pos + Off + O, Len, Cp);
                     Match := N > 0 and then (Cp >= 33 and then Cp <= 1114111);
                     if Match then O := O + N; end if;
                  end if;
                  if Match and then O > Br then Br := O; end if;
                  exit when Br = 0;
                  Off := Off + Br;
                  Cnt := Cnt + 1;
               end;
            end loop;
         end;
      end if;
      if Ok and then Off > Best then Best := Off; end if;
      return Best;
   end Scan_Middle;

   function Scan_Trailing (S : String; Pos, Len : Natural) return Natural is
      Cp  : Natural;
      N   : Natural;
      Off : Natural := 0;
   begin
      declare
         Cnt : Natural := 0;
      begin
         loop
            declare
               Br    : Natural := 0;
               O     : Natural;
               Match : Boolean;
            begin
               O := 0;
               Match := True;
               if Match then
                  N := Decode_Utf8 (S, Pos + Off + O, Len, Cp);
                  Match := N > 0 and then (Cp <= 1114111);
                  if Match then O := O + N; end if;
               end if;
               if Match and then O > Br then Br := O; end if;
               exit when Br = 0;
               Off := Off + Br;
               Cnt := Cnt + 1;
            end;
         end loop;
      end;
      return Off;
   end Scan_Trailing;

   function Scan_SP (S : String; Pos, Len : Natural) return Natural is
      Cp  : Natural;
      N   : Natural;
      Off : Natural := 0;
   begin
      N := Decode_Utf8 (S, Pos + Off, Len, Cp);
      if N = 0 or else not (Cp >= 32 and then Cp <= 32) then return 0; end if;
      Off := Off + N;
      return Off;
   end Scan_SP;

   function Scan_Lead_2 (S : String; Pos, Len : Natural) return Natural is
      Cp  : Natural;
      N   : Natural;
      Off : Natural := 0;
   begin
      declare
         Cnt : Natural := 0;
      begin
         loop
            declare
               Br    : Natural := 0;
               O     : Natural;
               Match : Boolean;
            begin
               O := 0;
               Match := True;
               if Match then
                  N := Decode_Utf8 (S, Pos + Off + O, Len, Cp);
                  Match := N > 0 and then (Cp >= 32 and then Cp <= 32);
                  if Match then O := O + N; end if;
               end if;
               if Match and then O > Br then Br := O; end if;
               exit when Br = 0;
               Off := Off + Br;
               Cnt := Cnt + 1;
            end;
         end loop;
      end;
      return Off;
   end Scan_Lead_2;

   type Text_Access is access constant String;

   type Alt_List is array (1 .. 16) of Unbounded_String;
   type Rule_Stack is array (1 .. 24) of Natural;

   --  The parser reads the text itself: a position in it, no token array.
   type Parser is record
      Text : Text_Access;
      Pos  : Natural := 1;
      Last : Natural := Natural'Last;   --  the input is cut here for a trial parse (`a - b`)
      Failed : Boolean := False;        --  a parse that failed returns at once, up to whoever tries the next way
      --  The farthest failure (Err_Pos, 0 while there is none): what could have stood
      --  there, each told once, and the rules being read then and where each began.
      Err_Pos    : Natural := 0;
      Alt_N      : Natural := 0;
      Alts       : Alt_List;
      More       : Boolean := False;
      Depth      : Natural := 0;
      Stk        : Rule_Stack := (others => 0);
      Stkpos     : Rule_Stack := (others => 0);
      Err_Depth  : Natural := 0;
      Err_Stk    : Rule_Stack := (others => 0);
      Err_Stkpos : Rule_Stack := (others => 0);
   end record;

   --  A rule is being read from here (and not any more, when it returns).
   procedure Enter (P : in out Parser; Rule : Positive) is
   begin
      if P.Depth < 24 then
         P.Stk (P.Depth + 1) := Rule;
         P.Stkpos (P.Depth + 1) := P.Pos;
      end if;
      P.Depth := P.Depth + 1;
   end Enter;

   function Limit (P : Parser) return Natural is
     (Natural'Min (P.Last, P.Text'Last));

   Spaces : constant String :=
     "                                                                ";

   --  What stands at the position, for an error message: the bareword that
   --  starts there, else the one character, else the end of the text.
   function Found (P : Parser; At_Pos : Natural) return String is
      Last : constant Natural := P.Text'Last;
      I    : Natural := At_Pos;

      function Word_Char (C : Character) return Boolean is
        (C in 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '_' | '-' | '.');
   begin
      if At_Pos > Last then
         return "end of input";
      end if;
      if Word_Char (P.Text (I)) then
         while I <= Last and then Word_Char (P.Text (I)) loop
            I := I + 1;
         end loop;
         return P.Text (At_Pos .. I - 1);
      end if;
      return P.Text (At_Pos .. At_Pos);
   end Found;

   --  Keep the farthest failure, and at the same place what else could have stood
   --  there; the message is made of them when the whole parse has failed (Render).
   procedure Fail (P : in out Parser; Expected : String) is
   begin
      if P.Err_Pos = 0 or else P.Pos > P.Err_Pos then
         P.Err_Pos := P.Pos;
         P.Alt_N := 1;
         P.Alts (1) := To_Unbounded_String (Expected);
         P.More := False;
         P.Err_Depth := Natural'Min (P.Depth, 24);
         P.Err_Stk := P.Stk;
         P.Err_Stkpos := P.Stkpos;
      elsif P.Pos = P.Err_Pos then
         declare
            Seen : Boolean := P.Alt_N >= 16 and then P.More;   --  a full list that has said "and more" cannot change
         begin
            for I in 1 .. P.Alt_N loop
               exit when Seen;
               if P.Alts (I) = Expected then   --  no string is made to compare
                  Seen := True;
               end if;
            end loop;
            if not Seen then
               if P.Alt_N < 16 then
                  P.Alt_N := P.Alt_N + 1;
                  P.Alts (P.Alt_N) := To_Unbounded_String (Expected);
               else
                  P.More := True;
               end if;
            end if;
         end;
      end if;
      P.Failed := True;   --  not raised: GNAT unwinds in microseconds, and a parse fails more often than it succeeds
   end Fail;

   --  A punctuation- or digit-led literal: compare bytes at the position (a
   --  prefix is correct there, e.g. "-" in "-5", "0x" in "0x1F").
   procedure Expect_Lit (P : in out Parser; Lit : String) is
   begin
      if P.Pos + Lit'Length - 1 <= Limit (P)
        and then P.Text (P.Pos .. P.Pos + Lit'Length - 1) = Lit
      then
         P.Pos := P.Pos + Lit'Length;
      else
         Fail (P, "`" & Lit & "`");
      end if;
   end Expect_Lit;

   --  A keyword: the whole bareword at the position must be the literal, so
   --  `in` does not match the front of `input`.
   procedure Expect_Word (P : in out Parser; Lit : String) is
      N : constant Natural := Scan_Word (P.Text.all, P.Pos, Limit (P));
   begin
      if N = Lit'Length and then P.Text (P.Pos .. P.Pos + N - 1) = Lit then
         P.Pos := P.Pos + N;
      else
         Fail (P, "`" & Lit & "`");
      end if;
   end Expect_Word;

   --  Skip what the grammar calls whitespace, one match at a time.
   procedure Skip_Ws (P : in out Parser) is
      N : Natural;
   begin
      loop
         N := Scan_Ws (P.Text.all, P.Pos, Limit (P));
         exit when N = 0;
         P.Pos := P.Pos + N;
      end loop;
   end Skip_Ws;

   --  The content of a quoted string: strip the quotes, and drop a backslash
   --  (keeping the character after it) or a backslash-newline.
   function Str_Value (S : String) return Unbounded_String is
      R : Unbounded_String;
      I : Natural := S'First + 1;
   begin
      while I < S'Last loop
         if S (I) = '\' and then I + 1 < S'Last then
            I := I + 1;
            if S (I) /= ASCII.LF then
               Append (R, S (I));
            end if;
         else
            Append (R, S (I));
         end if;
         I := I + 1;
      end loop;
      return R;
   end Str_Value;

   function Is_Keyword (S : String) return Boolean is
   begin
      pragma Unreferenced (S);
      return False;
   end Is_Keyword;

   procedure Dealloc_Message is new Ada.Unchecked_Deallocation (Message_Type, Message_Access);
   procedure Dealloc_After_tags is new Ada.Unchecked_Deallocation (After_tags_Type, After_tags_Access);
   procedure Dealloc_Tags_part is new Ada.Unchecked_Deallocation (Tags_part_Type, Tags_part_Access);
   procedure Dealloc_Prefix_part is new Ada.Unchecked_Deallocation (Prefix_part_Type, Prefix_part_Access);
   procedure Dealloc_Tag_unit is new Ada.Unchecked_Deallocation (Tag_unit_Type, Tag_unit_Access);
   procedure Dealloc_Empty_item is new Ada.Unchecked_Deallocation (Empty_item_Type, Empty_item_Access);
   procedure Dealloc_Item_semi is new Ada.Unchecked_Deallocation (Item_semi_Type, Item_semi_Access);
   procedure Dealloc_Tag is new Ada.Unchecked_Deallocation (Tag_Type, Tag_Access);
   procedure Dealloc_Tag_pair is new Ada.Unchecked_Deallocation (Tag_pair_Type, Tag_pair_Access);
   procedure Dealloc_Tag_key_only is new Ada.Unchecked_Deallocation (Tag_key_only_Type, Tag_key_only_Access);
   procedure Dealloc_Prefix is new Ada.Unchecked_Deallocation (Prefix_Type, Prefix_Access);
   procedure Dealloc_Pfx_full is new Ada.Unchecked_Deallocation (Pfx_full_Type, Pfx_full_Access);
   procedure Dealloc_Pfx_user is new Ada.Unchecked_Deallocation (Pfx_user_Type, Pfx_user_Access);
   procedure Dealloc_Pfx_host is new Ada.Unchecked_Deallocation (Pfx_host_Type, Pfx_host_Access);
   procedure Dealloc_Pfx_nick is new Ada.Unchecked_Deallocation (Pfx_nick_Type, Pfx_nick_Access);
   procedure Dealloc_Rest is new Ada.Unchecked_Deallocation (Rest_Type, Rest_Access);
   procedure Dealloc_Only_trailing is new Ada.Unchecked_Deallocation (Only_trailing_Type, Only_trailing_Access);
   procedure Dealloc_With_command is new Ada.Unchecked_Deallocation (With_command_Type, With_command_Access);
   procedure Dealloc_Middle_item is new Ada.Unchecked_Deallocation (Middle_item_Type, Middle_item_Access);
   procedure Dealloc_More_trailing is new Ada.Unchecked_Deallocation (More_trailing_Type, More_trailing_Access);

   procedure Free_Message (V : in out Message_Type) is
   begin
   if V.Tags_part /= null then
      Free_Tags_part (V.Tags_part.all);
      Dealloc_Tags_part (V.Tags_part);
   end if;
   if V.After_tags /= null then
      Free_After_tags (V.After_tags.all);
      Dealloc_After_tags (V.After_tags);
   end if;
   end Free_Message;

   procedure Free_After_tags (V : in out After_tags_Type) is
   begin
   if V.Prefix_part /= null then
      Free_Prefix_part (V.Prefix_part.all);
      Dealloc_Prefix_part (V.Prefix_part);
   end if;
   if V.Rest /= null then
      Free_Rest (V.Rest.all);
      Dealloc_Rest (V.Rest);
   end if;
   end Free_After_tags;

   procedure Free_Tags_part (V : in out Tags_part_Type) is
   begin
   Free_Tag_list (V.Tag_list);
   end Free_Tags_part;

   procedure Free_Prefix_part (V : in out Prefix_part_Type) is
   begin
   Free_Prefix_part_1 (V.Prefix_part_1);
   end Free_Prefix_part;

   procedure Free_Tag_list (V : in out Tag_list_Type) is
   begin
   for K in V.First_Index .. V.Last_Index loop
      declare
         E : Tag_unit_Access := V (K);
      begin
         if E /= null then
            Free_Tag_unit (E.all);
            V.Replace_Element (K, null);
            Dealloc_Tag_unit (E);
         end if;
      end;
   end loop;
   end Free_Tag_list;

   procedure Free_Tag_unit (V : in out Tag_unit_Type) is
   begin
   if V.Empty_item /= null then
      Free_Empty_item (V.Empty_item.all);
      Dealloc_Empty_item (V.Empty_item);
   end if;
   if V.Item_semi /= null then
      Free_Item_semi (V.Item_semi.all);
      Dealloc_Item_semi (V.Item_semi);
   end if;
   Free_Tag (V.Item_final);
   end Free_Tag_unit;

   procedure Free_Empty_item (V : in out Empty_item_Type) is
      pragma Unreferenced (V);
   begin
      null;
   end Free_Empty_item;

   procedure Free_Item_semi (V : in out Item_semi_Type) is
   begin
   if V.Tag /= null then
      Free_Tag (V.Tag.all);
      Dealloc_Tag (V.Tag);
   end if;
   end Free_Item_semi;

   procedure Free_Tag (V : in out Tag_Type) is
   begin
   if V.Tag_pair /= null then
      Free_Tag_pair (V.Tag_pair.all);
      Dealloc_Tag_pair (V.Tag_pair);
   end if;
   if V.Tag_key_only /= null then
      Free_Tag_key_only (V.Tag_key_only.all);
      Dealloc_Tag_key_only (V.Tag_key_only);
   end if;
   end Free_Tag;

   procedure Free_Tag_pair (V : in out Tag_pair_Type) is
      pragma Unreferenced (V);
   begin
      null;
   end Free_Tag_pair;

   procedure Free_Tag_key_only (V : in out Tag_key_only_Type) is
      pragma Unreferenced (V);
   begin
      null;
   end Free_Tag_key_only;

   procedure Free_Prefix (V : in out Prefix_Type) is
   begin
   if V.Pfx_full /= null then
      Free_Pfx_full (V.Pfx_full.all);
      Dealloc_Pfx_full (V.Pfx_full);
   end if;
   if V.Pfx_user /= null then
      Free_Pfx_user (V.Pfx_user.all);
      Dealloc_Pfx_user (V.Pfx_user);
   end if;
   if V.Pfx_host /= null then
      Free_Pfx_host (V.Pfx_host.all);
      Dealloc_Pfx_host (V.Pfx_host);
   end if;
   if V.Pfx_nick /= null then
      Free_Pfx_nick (V.Pfx_nick.all);
      Dealloc_Pfx_nick (V.Pfx_nick);
   end if;
   end Free_Prefix;

   procedure Free_Pfx_full (V : in out Pfx_full_Type) is
      pragma Unreferenced (V);
   begin
      null;
   end Free_Pfx_full;

   procedure Free_Pfx_user (V : in out Pfx_user_Type) is
      pragma Unreferenced (V);
   begin
      null;
   end Free_Pfx_user;

   procedure Free_Pfx_host (V : in out Pfx_host_Type) is
      pragma Unreferenced (V);
   begin
      null;
   end Free_Pfx_host;

   procedure Free_Pfx_nick (V : in out Pfx_nick_Type) is
      pragma Unreferenced (V);
   begin
      null;
   end Free_Pfx_nick;

   procedure Free_Rest (V : in out Rest_Type) is
   begin
   if V.Only_trailing /= null then
      Free_Only_trailing (V.Only_trailing.all);
      Dealloc_Only_trailing (V.Only_trailing);
   end if;
   if V.With_command /= null then
      Free_With_command (V.With_command.all);
      Dealloc_With_command (V.With_command);
   end if;
   end Free_Rest;

   procedure Free_Only_trailing (V : in out Only_trailing_Type) is
      pragma Unreferenced (V);
   begin
      null;
   end Free_Only_trailing;

   procedure Free_With_command (V : in out With_command_Type) is
   begin
   Free_Middles (V.Middles);
   Free_With_command_1 (V.With_command_1);
   end Free_With_command;

   procedure Free_Middles (V : in out Middles_Type) is
   begin
   for K in V.First_Index .. V.Last_Index loop
      declare
         E : Middle_item_Access := V (K);
      begin
         if E /= null then
            Free_Middle_item (E.all);
            V.Replace_Element (K, null);
            Dealloc_Middle_item (E);
         end if;
      end;
   end loop;
   end Free_Middles;

   procedure Free_Middle_item (V : in out Middle_item_Type) is
      pragma Unreferenced (V);
   begin
      null;
   end Free_Middle_item;

   procedure Free_More_trailing (V : in out More_trailing_Type) is
      pragma Unreferenced (V);
   begin
      null;
   end Free_More_trailing;

   procedure Free_Prefix_part_1 (V : in out Prefix_part_1_Type) is
   begin
   for K in V.First_Index .. V.Last_Index loop
      declare
         E : Prefix_Access := V (K);
      begin
         if E /= null then
            Free_Prefix (E.all);
            V.Replace_Element (K, null);
            Dealloc_Prefix (E);
         end if;
      end;
   end loop;
   end Free_Prefix_part_1;

   procedure Free_With_command_1 (V : in out With_command_1_Type) is
   begin
   for K in V.First_Index .. V.Last_Index loop
      declare
         E : More_trailing_Access := V (K);
      begin
         if E /= null then
            Free_More_trailing (E.all);
            V.Replace_Element (K, null);
            Dealloc_More_trailing (E);
         end if;
      end;
   end loop;
   end Free_With_command_1;

   function Parse_Message (P : in out Parser) return Message_Type;
   function Parse_After_tags (P : in out Parser) return After_tags_Type;
   function Parse_Tags_part (P : in out Parser) return Tags_part_Type;
   function Parse_Prefix_part (P : in out Parser) return Prefix_part_Type;
   function Parse_Tag_list (P : in out Parser) return Tag_list_Type;
   function Parse_Tag_unit (P : in out Parser) return Tag_unit_Type;
   function Parse_Empty_item (P : in out Parser) return Empty_item_Type;
   function Parse_Item_semi (P : in out Parser) return Item_semi_Type;
   function Parse_Item_final (P : in out Parser) return Item_final_Type;
   function Parse_Tag (P : in out Parser) return Tag_Type;
   function Parse_Tag_pair (P : in out Parser) return Tag_pair_Type;
   function Parse_Tag_key_only (P : in out Parser) return Tag_key_only_Type;
   function Parse_Tag_end (P : in out Parser) return Tag_end_Type;
   function Parse_Tag_key (P : in out Parser) return Tag_key_Type;
   function Parse_Tag_key_1 (P : in out Parser) return Tag_key_1_Type;
   function Parse_Tag_value (P : in out Parser) return Tag_value_Type;
   function Parse_Prefix (P : in out Parser) return Prefix_Type;
   function Parse_Pfx_full (P : in out Parser) return Pfx_full_Type;
   function Parse_Pfx_user (P : in out Parser) return Pfx_user_Type;
   function Parse_Pfx_host (P : in out Parser) return Pfx_host_Type;
   function Parse_Pfx_nick (P : in out Parser) return Pfx_nick_Type;
   function Parse_Pfx_end (P : in out Parser) return Pfx_end_Type;
   function Parse_Pfx_name (P : in out Parser) return Pfx_name_Type;
   function Parse_Pfx_name_1 (P : in out Parser) return Pfx_name_1_Type;
   function Parse_Pfx_user_name (P : in out Parser) return Pfx_user_name_Type;
   function Parse_Pfx_host_name (P : in out Parser) return Pfx_host_name_Type;
   function Parse_Rest (P : in out Parser) return Rest_Type;
   function Parse_Only_trailing (P : in out Parser) return Only_trailing_Type;
   function Parse_With_command (P : in out Parser) return With_command_Type;
   function Parse_Middles (P : in out Parser) return Middles_Type;
   function Parse_Middle_item (P : in out Parser) return Middle_item_Type;
   function Parse_More_trailing (P : in out Parser) return More_trailing_Type;
   function Parse_Lead (P : in out Parser) return Lead_Type;
   function Parse_Spaces (P : in out Parser) return Spaces_Type;
   function Parse_Command (P : in out Parser) return Command_Type;
   function Parse_Middle (P : in out Parser) return Middle_Type;
   function Parse_Trailing (P : in out Parser) return Trailing_Type;
   function Parse_SP (P : in out Parser) return SP_Type;
   function Parse_Word (P : in out Parser) return Word_Type;
   function Parse_Int (P : in out Parser) return Int_Type;
   function Parse_Str (P : in out Parser) return Str_Type;
   function Parse_Ws (P : in out Parser) return Ws_Type;
   function Parse_Prefix_part_1 (P : in out Parser) return Prefix_part_1_Type;
   function Parse_With_command_1 (P : in out Parser) return With_command_1_Type;
   function Parse_Lead_2 (P : in out Parser) return Lead_2_Type;

   function Body_Of_Message (P : in out Parser) return Message_Type is
   R : Message_Type;
   begin
      declare
         Save : constant Natural := P.Pos;
      begin
         declare
            R : Message_Type;
         begin
            declare V : Tags_part_Type := Parse_Tags_part (P); begin if P.Failed then goto Alt_Fail_1; end if; R.Tags_part := new Tags_part_Type'(V); end;
            declare V : After_tags_Type := Parse_After_tags (P); begin if P.Failed then goto Alt_Fail_1; end if; R.After_tags := new After_tags_Type'(V); end;
            return R;
            <<Alt_Fail_1>> null;
         end;
         P.Failed := False; P.Pos := Save;
         declare
            R : Message_Type;
         begin
            declare
               Sv  : constant Parser := P;
               Hit : Boolean := False;
               Ok  : Boolean;
               Hp  : Natural := 0;
            begin
               Hp := P.Pos;
               if not Hit then
                  Ok := True;  P.Pos := Hp;
                  if Ok then Expect_Lit (P, "@"); if P.Failed then P.Failed := False; Ok := False; end if; end if;
                  if Ok then Hit := True; end if;
               end if;
               P := Sv;
               if Hit then Fail (P, "something other than `@`"); goto Alt_Fail_2; end if;
            end;
            declare V : After_tags_Type := Parse_After_tags (P); begin if P.Failed then goto Alt_Fail_2; end if; R.After_tags := new After_tags_Type'(V); end;
            return R;
            <<Alt_Fail_2>> null;
         end;
         P.Failed := False; P.Pos := Save;
         P.Pos := Save;
         Fail (P, "a message");
         return R;
      end;
   end Body_Of_Message;

   function Parse_Message (P : in out Parser) return Message_Type is
   begin
      Enter (P, 1);
      declare
         R : constant Message_Type := Body_Of_Message (P);
      begin
         P.Depth := P.Depth - 1;
         return R;
      end;
   end Parse_Message;

   function Body_Of_After_tags (P : in out Parser) return After_tags_Type is
   R : After_tags_Type;
   begin
      declare
         Save : constant Natural := P.Pos;
      begin
         declare
            R : After_tags_Type;
         begin
            declare V : Prefix_part_Type := Parse_Prefix_part (P); begin if P.Failed then goto Alt_Fail_3; end if; R.Prefix_part := new Prefix_part_Type'(V); end;
            declare V : Rest_Type := Parse_Rest (P); begin if P.Failed then goto Alt_Fail_3; end if; R.Rest := new Rest_Type'(V); end;
            return R;
            <<Alt_Fail_3>> null;
         end;
         P.Failed := False; P.Pos := Save;
         declare
            R : After_tags_Type;
         begin
            declare
               Sv  : constant Parser := P;
               Hit : Boolean := False;
               Ok  : Boolean;
               Hp  : Natural := 0;
            begin
               Hp := P.Pos;
               if not Hit then
                  Ok := True;  P.Pos := Hp;
                  if Ok then Expect_Lit (P, ":"); if P.Failed then P.Failed := False; Ok := False; end if; end if;
                  if Ok then Hit := True; end if;
               end if;
               P := Sv;
               if Hit then Fail (P, "something other than `:`"); goto Alt_Fail_4; end if;
            end;
            declare V : Rest_Type := Parse_Rest (P); begin if P.Failed then goto Alt_Fail_4; end if; R.Rest := new Rest_Type'(V); end;
            return R;
            <<Alt_Fail_4>> null;
         end;
         P.Failed := False; P.Pos := Save;
         P.Pos := Save;
         Fail (P, "a after-tags");
         return R;
      end;
   end Body_Of_After_tags;

   function Parse_After_tags (P : in out Parser) return After_tags_Type is
   begin
      Enter (P, 2);
      declare
         R : constant After_tags_Type := Body_Of_After_tags (P);
      begin
         P.Depth := P.Depth - 1;
         return R;
      end;
   end Parse_After_tags;

   function Body_Of_Tags_part (P : in out Parser) return Tags_part_Type is
   R : Tags_part_Type;
   begin
      declare
         Sv  : constant Parser := P;
         Hit : Boolean := False;
         Ok  : Boolean;
         Hp  : Natural := 0;
      begin
         Hp := P.Pos;
         if not Hit then
            Ok := True;  P.Pos := Hp;
            if Ok then Expect_Lit (P, "@"); if P.Failed then P.Failed := False; Ok := False; end if; end if;
            if Ok then Hit := True; end if;
         end if;
         P := Sv;
         if not Hit then Fail (P, "`@`"); return R; end if;
      end;
      Expect_Lit (P, "@"); if P.Failed then return R; end if;
      R.Tag_list := Parse_Tag_list (P); if P.Failed then return R; end if;
      declare
         N : constant Natural := Scan_SP (P.Text.all, P.Pos, Limit (P));
      begin
         if N = 0 then Fail (P, "SP"); return R; end if;
         R.SP := To_Unbounded_String (P.Text (P.Pos .. P.Pos + N - 1)); P.Pos := P.Pos + N;
      end;
      return R;
   end Body_Of_Tags_part;

   function Parse_Tags_part (P : in out Parser) return Tags_part_Type is
   begin
      Enter (P, 3);
      declare
         R : constant Tags_part_Type := Body_Of_Tags_part (P);
      begin
         P.Depth := P.Depth - 1;
         return R;
      end;
   end Parse_Tags_part;

   function Body_Of_Prefix_part (P : in out Parser) return Prefix_part_Type is
   R : Prefix_part_Type;
   begin
      declare
         Sv  : constant Parser := P;
         Hit : Boolean := False;
         Ok  : Boolean;
         Hp  : Natural := 0;
      begin
         Hp := P.Pos;
         if not Hit then
            Ok := True;  P.Pos := Hp;
            if Ok then Expect_Lit (P, ":"); if P.Failed then P.Failed := False; Ok := False; end if; end if;
            if Ok then Hit := True; end if;
         end if;
         P := Sv;
         if not Hit then Fail (P, "`:`"); return R; end if;
      end;
      Expect_Lit (P, ":"); if P.Failed then return R; end if;
      R.Prefix_part_1 := Parse_Prefix_part_1 (P); if P.Failed then return R; end if;
      declare
         N : constant Natural := Scan_SP (P.Text.all, P.Pos, Limit (P));
      begin
         if N = 0 then Fail (P, "SP"); return R; end if;
         R.SP := To_Unbounded_String (P.Text (P.Pos .. P.Pos + N - 1)); P.Pos := P.Pos + N;
      end;
      return R;
   end Body_Of_Prefix_part;

   function Parse_Prefix_part (P : in out Parser) return Prefix_part_Type is
   begin
      Enter (P, 4);
      declare
         R : constant Prefix_part_Type := Body_Of_Prefix_part (P);
      begin
         P.Depth := P.Depth - 1;
         return R;
      end;
   end Parse_Prefix_part;

   function Body_Of_Tag_list (P : in out Parser) return Tag_list_Type is
   R : Tag_list_Type;
   begin
      loop
         declare
            Start : constant Natural := P.Pos;
         begin
            if P.Pos > Limit (P) then P.Pos := Start; exit; end if;
            declare V : Tag_unit_Type := Parse_Tag_unit (P); begin if P.Failed then P.Failed := False; P.Pos := Start; exit; end if; R.Append (new Tag_unit_Type'(V)); end;
         end;
      end loop;
      return R;
   end Body_Of_Tag_list;

   function Parse_Tag_list (P : in out Parser) return Tag_list_Type is
   begin
      Enter (P, 5);
      declare
         R : constant Tag_list_Type := Body_Of_Tag_list (P);
      begin
         P.Depth := P.Depth - 1;
         return R;
      end;
   end Parse_Tag_list;

   function Body_Of_Tag_unit (P : in out Parser) return Tag_unit_Type is
   R : Tag_unit_Type;
   begin
      declare
         Save : constant Natural := P.Pos;
      begin
         declare
            R : Tag_unit_Type;
         begin
            declare V : Empty_item_Type := Parse_Empty_item (P); begin if P.Failed then goto Alt_Fail_5; end if; R.Empty_item := new Empty_item_Type'(V); end;
            return R;
            <<Alt_Fail_5>> null;
         end;
         P.Failed := False; P.Pos := Save;
         declare
            R : Tag_unit_Type;
         begin
            declare V : Item_semi_Type := Parse_Item_semi (P); begin if P.Failed then goto Alt_Fail_6; end if; R.Item_semi := new Item_semi_Type'(V); end;
            return R;
            <<Alt_Fail_6>> null;
         end;
         P.Failed := False; P.Pos := Save;
         declare
            R : Tag_unit_Type;
         begin
            R.Item_final := Parse_Item_final (P); if P.Failed then goto Alt_Fail_7; end if;
            return R;
            <<Alt_Fail_7>> null;
         end;
         P.Failed := False; P.Pos := Save;
         P.Pos := Save;
         Fail (P, "a tag-unit");
         return R;
      end;
   end Body_Of_Tag_unit;

   function Parse_Tag_unit (P : in out Parser) return Tag_unit_Type is
   begin
      Enter (P, 6);
      declare
         R : constant Tag_unit_Type := Body_Of_Tag_unit (P);
      begin
         P.Depth := P.Depth - 1;
         return R;
      end;
   end Parse_Tag_unit;

   function Body_Of_Empty_item (P : in out Parser) return Empty_item_Type is
   R : Empty_item_Type;
   begin
      declare
         Sv  : constant Parser := P;
         Hit : Boolean := False;
         Ok  : Boolean;
         Hp  : Natural := 0;
      begin
         Hp := P.Pos;
         if not Hit then
            Ok := True;  P.Pos := Hp;
            if Ok then Expect_Lit (P, ";"); if P.Failed then P.Failed := False; Ok := False; end if; end if;
            if Ok then Hit := True; end if;
         end if;
         P := Sv;
         if not Hit then Fail (P, "`;`"); return R; end if;
      end;
      Expect_Lit (P, ";"); if P.Failed then return R; end if;
      return R;
   end Body_Of_Empty_item;

   function Parse_Empty_item (P : in out Parser) return Empty_item_Type is
   begin
      Enter (P, 7);
      declare
         R : constant Empty_item_Type := Body_Of_Empty_item (P);
      begin
         P.Depth := P.Depth - 1;
         return R;
      end;
   end Parse_Empty_item;

   function Body_Of_Item_semi (P : in out Parser) return Item_semi_Type is
   R : Item_semi_Type;
   begin
      declare V : Tag_Type := Parse_Tag (P); begin if P.Failed then return R; end if; R.Tag := new Tag_Type'(V); end;
      Expect_Lit (P, ";"); if P.Failed then return R; end if;
      return R;
   end Body_Of_Item_semi;

   function Parse_Item_semi (P : in out Parser) return Item_semi_Type is
   begin
      Enter (P, 8);
      declare
         R : constant Item_semi_Type := Body_Of_Item_semi (P);
      begin
         P.Depth := P.Depth - 1;
         return R;
      end;
   end Parse_Item_semi;

   function Body_Of_Item_final (P : in out Parser) return Item_final_Type is
   begin
      return Parse_Tag (P);
   end Body_Of_Item_final;

   function Parse_Item_final (P : in out Parser) return Item_final_Type is
   begin
      Enter (P, 9);
      declare
         R : constant Item_final_Type := Body_Of_Item_final (P);
      begin
         P.Depth := P.Depth - 1;
         return R;
      end;
   end Parse_Item_final;

   function Body_Of_Tag (P : in out Parser) return Tag_Type is
   R : Tag_Type;
   begin
      declare
         Save : constant Natural := P.Pos;
      begin
         declare
            R : Tag_Type;
         begin
            declare V : Tag_pair_Type := Parse_Tag_pair (P); begin if P.Failed then goto Alt_Fail_8; end if; R.Tag_pair := new Tag_pair_Type'(V); end;
            return R;
            <<Alt_Fail_8>> null;
         end;
         P.Failed := False; P.Pos := Save;
         declare
            R : Tag_Type;
         begin
            declare V : Tag_key_only_Type := Parse_Tag_key_only (P); begin if P.Failed then goto Alt_Fail_9; end if; R.Tag_key_only := new Tag_key_only_Type'(V); end;
            return R;
            <<Alt_Fail_9>> null;
         end;
         P.Failed := False; P.Pos := Save;
         P.Pos := Save;
         Fail (P, "a tag");
         return R;
      end;
   end Body_Of_Tag;

   function Parse_Tag (P : in out Parser) return Tag_Type is
   begin
      Enter (P, 10);
      declare
         R : constant Tag_Type := Body_Of_Tag (P);
      begin
         P.Depth := P.Depth - 1;
         return R;
      end;
   end Parse_Tag;

   function Body_Of_Tag_pair (P : in out Parser) return Tag_pair_Type is
   R : Tag_pair_Type;
   begin
      declare
         Sv  : constant Parser := P;
         Hit : Boolean := False;
         Ok  : Boolean;
         Hp  : Natural := 0;
      begin
         Hp := P.Pos;
         if not Hit then
            Ok := True;  P.Pos := Hp;
            if Ok then declare N : constant Natural := Scan_Tag_end (P.Text.all, P.Pos, Limit (P)); begin if N > 0 then P.Pos := P.Pos + N; else Ok := False; end if; end; end if;
            if Ok then Hit := True; end if;
         end if;
         P := Sv;
         if not Hit then Fail (P, "tag-end"); return R; end if;
      end;
      declare
         N : constant Natural := Scan_Tag_key (P.Text.all, P.Pos, Limit (P));
      begin
         R.Tag_key := To_Unbounded_String (P.Text (P.Pos .. P.Pos + N - 1)); P.Pos := P.Pos + N;
      end;
      Expect_Lit (P, "="); if P.Failed then return R; end if;
      declare
         N : constant Natural := Scan_Tag_value (P.Text.all, P.Pos, Limit (P));
      begin
         R.Tag_value := To_Unbounded_String (P.Text (P.Pos .. P.Pos + N - 1)); P.Pos := P.Pos + N;
      end;
      return R;
   end Body_Of_Tag_pair;

   function Parse_Tag_pair (P : in out Parser) return Tag_pair_Type is
   begin
      Enter (P, 11);
      declare
         R : constant Tag_pair_Type := Body_Of_Tag_pair (P);
      begin
         P.Depth := P.Depth - 1;
         return R;
      end;
   end Parse_Tag_pair;

   function Body_Of_Tag_key_only (P : in out Parser) return Tag_key_only_Type is
   R : Tag_key_only_Type;
   begin
      declare
         Sv  : constant Parser := P;
         Hit : Boolean := False;
         Ok  : Boolean;
         Hp  : Natural := 0;
      begin
         Hp := P.Pos;
         if not Hit then
            Ok := True;  P.Pos := Hp;
            if Ok then declare N : constant Natural := Scan_Tag_end (P.Text.all, P.Pos, Limit (P)); begin if N > 0 then P.Pos := P.Pos + N; else Ok := False; end if; end; end if;
            if Ok then Hit := True; end if;
         end if;
         P := Sv;
         if not Hit then Fail (P, "tag-end"); return R; end if;
      end;
      declare
         N : constant Natural := Scan_Tag_key_1 (P.Text.all, P.Pos, Limit (P));
      begin
         if N = 0 then Fail (P, "tag-key-1"); return R; end if;
         R.Tag_key_1 := To_Unbounded_String (P.Text (P.Pos .. P.Pos + N - 1)); P.Pos := P.Pos + N;
      end;
      return R;
   end Body_Of_Tag_key_only;

   function Parse_Tag_key_only (P : in out Parser) return Tag_key_only_Type is
   begin
      Enter (P, 12);
      declare
         R : constant Tag_key_only_Type := Body_Of_Tag_key_only (P);
      begin
         P.Depth := P.Depth - 1;
         return R;
      end;
   end Parse_Tag_key_only;

   function Body_Of_Tag_end (P : in out Parser) return Tag_end_Type is
   R : Tag_end_Type;
   begin
      declare
         N : constant Natural := Scan_Tag_end (P.Text.all, P.Pos, Limit (P));
      begin
         R := To_Unbounded_String (P.Text (P.Pos .. P.Pos + N - 1));
         P.Pos := P.Pos + N;
         return R;
      end;
   end Body_Of_Tag_end;

   function Parse_Tag_end (P : in out Parser) return Tag_end_Type is
   begin
      Enter (P, 13);
      declare
         R : constant Tag_end_Type := Body_Of_Tag_end (P);
      begin
         P.Depth := P.Depth - 1;
         return R;
      end;
   end Parse_Tag_end;

   function Body_Of_Tag_key (P : in out Parser) return Tag_key_Type is
   R : Tag_key_Type;
   begin
      declare
         N : constant Natural := Scan_Tag_key (P.Text.all, P.Pos, Limit (P));
      begin
         R := To_Unbounded_String (P.Text (P.Pos .. P.Pos + N - 1));
         P.Pos := P.Pos + N;
         return R;
      end;
   end Body_Of_Tag_key;

   function Parse_Tag_key (P : in out Parser) return Tag_key_Type is
   begin
      Enter (P, 14);
      declare
         R : constant Tag_key_Type := Body_Of_Tag_key (P);
      begin
         P.Depth := P.Depth - 1;
         return R;
      end;
   end Parse_Tag_key;

   function Body_Of_Tag_key_1 (P : in out Parser) return Tag_key_1_Type is
   R : Tag_key_1_Type;
   begin
      declare
         N : constant Natural := Scan_Tag_key_1 (P.Text.all, P.Pos, Limit (P));
      begin
         if N = 0 then Fail (P, "tag-key-1"); return R; end if;
         R := To_Unbounded_String (P.Text (P.Pos .. P.Pos + N - 1));
         P.Pos := P.Pos + N;
         return R;
      end;
   end Body_Of_Tag_key_1;

   function Parse_Tag_key_1 (P : in out Parser) return Tag_key_1_Type is
   begin
      Enter (P, 15);
      declare
         R : constant Tag_key_1_Type := Body_Of_Tag_key_1 (P);
      begin
         P.Depth := P.Depth - 1;
         return R;
      end;
   end Parse_Tag_key_1;

   function Body_Of_Tag_value (P : in out Parser) return Tag_value_Type is
   R : Tag_value_Type;
   begin
      declare
         N : constant Natural := Scan_Tag_value (P.Text.all, P.Pos, Limit (P));
      begin
         R := To_Unbounded_String (P.Text (P.Pos .. P.Pos + N - 1));
         P.Pos := P.Pos + N;
         return R;
      end;
   end Body_Of_Tag_value;

   function Parse_Tag_value (P : in out Parser) return Tag_value_Type is
   begin
      Enter (P, 16);
      declare
         R : constant Tag_value_Type := Body_Of_Tag_value (P);
      begin
         P.Depth := P.Depth - 1;
         return R;
      end;
   end Parse_Tag_value;

   function Body_Of_Prefix (P : in out Parser) return Prefix_Type is
   R : Prefix_Type;
   begin
      declare
         Save : constant Natural := P.Pos;
      begin
         declare
            R : Prefix_Type;
         begin
            declare V : Pfx_full_Type := Parse_Pfx_full (P); begin if P.Failed then goto Alt_Fail_10; end if; R.Pfx_full := new Pfx_full_Type'(V); end;
            return R;
            <<Alt_Fail_10>> null;
         end;
         P.Failed := False; P.Pos := Save;
         declare
            R : Prefix_Type;
         begin
            declare V : Pfx_user_Type := Parse_Pfx_user (P); begin if P.Failed then goto Alt_Fail_11; end if; R.Pfx_user := new Pfx_user_Type'(V); end;
            return R;
            <<Alt_Fail_11>> null;
         end;
         P.Failed := False; P.Pos := Save;
         declare
            R : Prefix_Type;
         begin
            declare V : Pfx_host_Type := Parse_Pfx_host (P); begin if P.Failed then goto Alt_Fail_12; end if; R.Pfx_host := new Pfx_host_Type'(V); end;
            return R;
            <<Alt_Fail_12>> null;
         end;
         P.Failed := False; P.Pos := Save;
         declare
            R : Prefix_Type;
         begin
            declare V : Pfx_nick_Type := Parse_Pfx_nick (P); begin if P.Failed then goto Alt_Fail_13; end if; R.Pfx_nick := new Pfx_nick_Type'(V); end;
            return R;
            <<Alt_Fail_13>> null;
         end;
         P.Failed := False; P.Pos := Save;
         P.Pos := Save;
         Fail (P, "a prefix");
         return R;
      end;
   end Body_Of_Prefix;

   function Parse_Prefix (P : in out Parser) return Prefix_Type is
   begin
      Enter (P, 17);
      declare
         R : constant Prefix_Type := Body_Of_Prefix (P);
      begin
         P.Depth := P.Depth - 1;
         return R;
      end;
   end Parse_Prefix;

   function Body_Of_Pfx_full (P : in out Parser) return Pfx_full_Type is
   R : Pfx_full_Type;
   begin
      declare
         Sv  : constant Parser := P;
         Hit : Boolean := False;
         Ok  : Boolean;
         Hp  : Natural := 0;
      begin
         Hp := P.Pos;
         if not Hit then
            Ok := True;  P.Pos := Hp;
            if Ok then declare N : constant Natural := Scan_Pfx_end (P.Text.all, P.Pos, Limit (P)); begin if N > 0 then P.Pos := P.Pos + N; else Ok := False; end if; end; end if;
            if Ok then Hit := True; end if;
         end if;
         P := Sv;
         if not Hit then Fail (P, "pfx-end"); return R; end if;
      end;
      declare
         N : constant Natural := Scan_Pfx_name (P.Text.all, P.Pos, Limit (P));
      begin
         R.Pfx_name := To_Unbounded_String (P.Text (P.Pos .. P.Pos + N - 1)); P.Pos := P.Pos + N;
      end;
      Expect_Lit (P, "!"); if P.Failed then return R; end if;
      declare
         N : constant Natural := Scan_Pfx_user_name (P.Text.all, P.Pos, Limit (P));
      begin
         R.Pfx_user_name := To_Unbounded_String (P.Text (P.Pos .. P.Pos + N - 1)); P.Pos := P.Pos + N;
      end;
      Expect_Lit (P, "@"); if P.Failed then return R; end if;
      declare
         N : constant Natural := Scan_Pfx_host_name (P.Text.all, P.Pos, Limit (P));
      begin
         R.Pfx_host_name := To_Unbounded_String (P.Text (P.Pos .. P.Pos + N - 1)); P.Pos := P.Pos + N;
      end;
      return R;
   end Body_Of_Pfx_full;

   function Parse_Pfx_full (P : in out Parser) return Pfx_full_Type is
   begin
      Enter (P, 18);
      declare
         R : constant Pfx_full_Type := Body_Of_Pfx_full (P);
      begin
         P.Depth := P.Depth - 1;
         return R;
      end;
   end Parse_Pfx_full;

   function Body_Of_Pfx_user (P : in out Parser) return Pfx_user_Type is
   R : Pfx_user_Type;
   begin
      declare
         Sv  : constant Parser := P;
         Hit : Boolean := False;
         Ok  : Boolean;
         Hp  : Natural := 0;
      begin
         Hp := P.Pos;
         if not Hit then
            Ok := True;  P.Pos := Hp;
            if Ok then declare N : constant Natural := Scan_Pfx_end (P.Text.all, P.Pos, Limit (P)); begin if N > 0 then P.Pos := P.Pos + N; else Ok := False; end if; end; end if;
            if Ok then Hit := True; end if;
         end if;
         P := Sv;
         if not Hit then Fail (P, "pfx-end"); return R; end if;
      end;
      declare
         N : constant Natural := Scan_Pfx_name (P.Text.all, P.Pos, Limit (P));
      begin
         R.Pfx_name := To_Unbounded_String (P.Text (P.Pos .. P.Pos + N - 1)); P.Pos := P.Pos + N;
      end;
      Expect_Lit (P, "!"); if P.Failed then return R; end if;
      declare
         N : constant Natural := Scan_Pfx_user_name (P.Text.all, P.Pos, Limit (P));
      begin
         R.Pfx_user_name := To_Unbounded_String (P.Text (P.Pos .. P.Pos + N - 1)); P.Pos := P.Pos + N;
      end;
      return R;
   end Body_Of_Pfx_user;

   function Parse_Pfx_user (P : in out Parser) return Pfx_user_Type is
   begin
      Enter (P, 19);
      declare
         R : constant Pfx_user_Type := Body_Of_Pfx_user (P);
      begin
         P.Depth := P.Depth - 1;
         return R;
      end;
   end Parse_Pfx_user;

   function Body_Of_Pfx_host (P : in out Parser) return Pfx_host_Type is
   R : Pfx_host_Type;
   begin
      declare
         Sv  : constant Parser := P;
         Hit : Boolean := False;
         Ok  : Boolean;
         Hp  : Natural := 0;
      begin
         Hp := P.Pos;
         if not Hit then
            Ok := True;  P.Pos := Hp;
            if Ok then declare N : constant Natural := Scan_Pfx_end (P.Text.all, P.Pos, Limit (P)); begin if N > 0 then P.Pos := P.Pos + N; else Ok := False; end if; end; end if;
            if Ok then Hit := True; end if;
         end if;
         P := Sv;
         if not Hit then Fail (P, "pfx-end"); return R; end if;
      end;
      declare
         N : constant Natural := Scan_Pfx_name (P.Text.all, P.Pos, Limit (P));
      begin
         R.Pfx_name := To_Unbounded_String (P.Text (P.Pos .. P.Pos + N - 1)); P.Pos := P.Pos + N;
      end;
      Expect_Lit (P, "@"); if P.Failed then return R; end if;
      declare
         N : constant Natural := Scan_Pfx_host_name (P.Text.all, P.Pos, Limit (P));
      begin
         R.Pfx_host_name := To_Unbounded_String (P.Text (P.Pos .. P.Pos + N - 1)); P.Pos := P.Pos + N;
      end;
      return R;
   end Body_Of_Pfx_host;

   function Parse_Pfx_host (P : in out Parser) return Pfx_host_Type is
   begin
      Enter (P, 20);
      declare
         R : constant Pfx_host_Type := Body_Of_Pfx_host (P);
      begin
         P.Depth := P.Depth - 1;
         return R;
      end;
   end Parse_Pfx_host;

   function Body_Of_Pfx_nick (P : in out Parser) return Pfx_nick_Type is
   R : Pfx_nick_Type;
   begin
      declare
         Sv  : constant Parser := P;
         Hit : Boolean := False;
         Ok  : Boolean;
         Hp  : Natural := 0;
      begin
         Hp := P.Pos;
         if not Hit then
            Ok := True;  P.Pos := Hp;
            if Ok then declare N : constant Natural := Scan_Pfx_end (P.Text.all, P.Pos, Limit (P)); begin if N > 0 then P.Pos := P.Pos + N; else Ok := False; end if; end; end if;
            if Ok then Hit := True; end if;
         end if;
         P := Sv;
         if not Hit then Fail (P, "pfx-end"); return R; end if;
      end;
      declare
         N : constant Natural := Scan_Pfx_name_1 (P.Text.all, P.Pos, Limit (P));
      begin
         if N = 0 then Fail (P, "pfx-name-1"); return R; end if;
         R.Pfx_name_1 := To_Unbounded_String (P.Text (P.Pos .. P.Pos + N - 1)); P.Pos := P.Pos + N;
      end;
      return R;
   end Body_Of_Pfx_nick;

   function Parse_Pfx_nick (P : in out Parser) return Pfx_nick_Type is
   begin
      Enter (P, 21);
      declare
         R : constant Pfx_nick_Type := Body_Of_Pfx_nick (P);
      begin
         P.Depth := P.Depth - 1;
         return R;
      end;
   end Parse_Pfx_nick;

   function Body_Of_Pfx_end (P : in out Parser) return Pfx_end_Type is
   R : Pfx_end_Type;
   begin
      declare
         N : constant Natural := Scan_Pfx_end (P.Text.all, P.Pos, Limit (P));
      begin
         R := To_Unbounded_String (P.Text (P.Pos .. P.Pos + N - 1));
         P.Pos := P.Pos + N;
         return R;
      end;
   end Body_Of_Pfx_end;

   function Parse_Pfx_end (P : in out Parser) return Pfx_end_Type is
   begin
      Enter (P, 22);
      declare
         R : constant Pfx_end_Type := Body_Of_Pfx_end (P);
      begin
         P.Depth := P.Depth - 1;
         return R;
      end;
   end Parse_Pfx_end;

   function Body_Of_Pfx_name (P : in out Parser) return Pfx_name_Type is
   R : Pfx_name_Type;
   begin
      declare
         N : constant Natural := Scan_Pfx_name (P.Text.all, P.Pos, Limit (P));
      begin
         R := To_Unbounded_String (P.Text (P.Pos .. P.Pos + N - 1));
         P.Pos := P.Pos + N;
         return R;
      end;
   end Body_Of_Pfx_name;

   function Parse_Pfx_name (P : in out Parser) return Pfx_name_Type is
   begin
      Enter (P, 23);
      declare
         R : constant Pfx_name_Type := Body_Of_Pfx_name (P);
      begin
         P.Depth := P.Depth - 1;
         return R;
      end;
   end Parse_Pfx_name;

   function Body_Of_Pfx_name_1 (P : in out Parser) return Pfx_name_1_Type is
   R : Pfx_name_1_Type;
   begin
      declare
         N : constant Natural := Scan_Pfx_name_1 (P.Text.all, P.Pos, Limit (P));
      begin
         if N = 0 then Fail (P, "pfx-name-1"); return R; end if;
         R := To_Unbounded_String (P.Text (P.Pos .. P.Pos + N - 1));
         P.Pos := P.Pos + N;
         return R;
      end;
   end Body_Of_Pfx_name_1;

   function Parse_Pfx_name_1 (P : in out Parser) return Pfx_name_1_Type is
   begin
      Enter (P, 24);
      declare
         R : constant Pfx_name_1_Type := Body_Of_Pfx_name_1 (P);
      begin
         P.Depth := P.Depth - 1;
         return R;
      end;
   end Parse_Pfx_name_1;

   function Body_Of_Pfx_user_name (P : in out Parser) return Pfx_user_name_Type is
   R : Pfx_user_name_Type;
   begin
      declare
         N : constant Natural := Scan_Pfx_user_name (P.Text.all, P.Pos, Limit (P));
      begin
         R := To_Unbounded_String (P.Text (P.Pos .. P.Pos + N - 1));
         P.Pos := P.Pos + N;
         return R;
      end;
   end Body_Of_Pfx_user_name;

   function Parse_Pfx_user_name (P : in out Parser) return Pfx_user_name_Type is
   begin
      Enter (P, 25);
      declare
         R : constant Pfx_user_name_Type := Body_Of_Pfx_user_name (P);
      begin
         P.Depth := P.Depth - 1;
         return R;
      end;
   end Parse_Pfx_user_name;

   function Body_Of_Pfx_host_name (P : in out Parser) return Pfx_host_name_Type is
   R : Pfx_host_name_Type;
   begin
      declare
         N : constant Natural := Scan_Pfx_host_name (P.Text.all, P.Pos, Limit (P));
      begin
         R := To_Unbounded_String (P.Text (P.Pos .. P.Pos + N - 1));
         P.Pos := P.Pos + N;
         return R;
      end;
   end Body_Of_Pfx_host_name;

   function Parse_Pfx_host_name (P : in out Parser) return Pfx_host_name_Type is
   begin
      Enter (P, 26);
      declare
         R : constant Pfx_host_name_Type := Body_Of_Pfx_host_name (P);
      begin
         P.Depth := P.Depth - 1;
         return R;
      end;
   end Parse_Pfx_host_name;

   function Body_Of_Rest (P : in out Parser) return Rest_Type is
   R : Rest_Type;
   begin
      declare
         Save : constant Natural := P.Pos;
      begin
         declare
            R : Rest_Type;
         begin
            declare V : Only_trailing_Type := Parse_Only_trailing (P); begin if P.Failed then goto Alt_Fail_14; end if; R.Only_trailing := new Only_trailing_Type'(V); end;
            return R;
            <<Alt_Fail_14>> null;
         end;
         P.Failed := False; P.Pos := Save;
         declare
            R : Rest_Type;
         begin
            declare V : With_command_Type := Parse_With_command (P); begin if P.Failed then goto Alt_Fail_15; end if; R.With_command := new With_command_Type'(V); end;
            return R;
            <<Alt_Fail_15>> null;
         end;
         P.Failed := False; P.Pos := Save;
         P.Pos := Save;
         Fail (P, "a rest");
         return R;
      end;
   end Body_Of_Rest;

   function Parse_Rest (P : in out Parser) return Rest_Type is
   begin
      Enter (P, 27);
      declare
         R : constant Rest_Type := Body_Of_Rest (P);
      begin
         P.Depth := P.Depth - 1;
         return R;
      end;
   end Parse_Rest;

   function Body_Of_Only_trailing (P : in out Parser) return Only_trailing_Type is
   R : Only_trailing_Type;
   begin
      declare
         Sv  : constant Parser := P;
         Hit : Boolean := False;
         Ok  : Boolean;
         Hp  : Natural := 0;
      begin
         Hp := P.Pos;
         if not Hit then
            Ok := True;  P.Pos := Hp;
            if Ok then declare N : constant Natural := Scan_SP (P.Text.all, P.Pos, Limit (P)); begin if N > 0 then P.Pos := P.Pos + N; else Ok := False; end if; end; end if;
            if Ok then Hit := True; end if;
         end if;
         P := Sv;
         if not Hit then Fail (P, "SP"); return R; end if;
      end;
      declare
         N : constant Natural := Scan_Spaces (P.Text.all, P.Pos, Limit (P));
      begin
         if N = 0 then Fail (P, "spaces"); return R; end if;
         R.Spaces := To_Unbounded_String (P.Text (P.Pos .. P.Pos + N - 1)); P.Pos := P.Pos + N;
      end;
      Expect_Lit (P, ":"); if P.Failed then return R; end if;
      declare
         N : constant Natural := Scan_Trailing (P.Text.all, P.Pos, Limit (P));
      begin
         R.Trailing := To_Unbounded_String (P.Text (P.Pos .. P.Pos + N - 1)); P.Pos := P.Pos + N;
      end;
      return R;
   end Body_Of_Only_trailing;

   function Parse_Only_trailing (P : in out Parser) return Only_trailing_Type is
   begin
      Enter (P, 28);
      declare
         R : constant Only_trailing_Type := Body_Of_Only_trailing (P);
      begin
         P.Depth := P.Depth - 1;
         return R;
      end;
   end Parse_Only_trailing;

   function Body_Of_With_command (P : in out Parser) return With_command_Type is
   R : With_command_Type;
   begin
      declare
         N : constant Natural := Scan_Lead (P.Text.all, P.Pos, Limit (P));
      begin
         R.Lead := To_Unbounded_String (P.Text (P.Pos .. P.Pos + N - 1)); P.Pos := P.Pos + N;
      end;
      declare
         N : constant Natural := Scan_Command (P.Text.all, P.Pos, Limit (P));
      begin
         if N = 0 then Fail (P, "command"); return R; end if;
         R.Command := To_Unbounded_String (P.Text (P.Pos .. P.Pos + N - 1)); P.Pos := P.Pos + N;
      end;
      R.Middles := Parse_Middles (P); if P.Failed then return R; end if;
      R.With_command_1 := Parse_With_command_1 (P); if P.Failed then return R; end if;
      declare
         N : constant Natural := Scan_Lead_2 (P.Text.all, P.Pos, Limit (P));
      begin
         R.Lead_2 := To_Unbounded_String (P.Text (P.Pos .. P.Pos + N - 1)); P.Pos := P.Pos + N;
      end;
      return R;
   end Body_Of_With_command;

   function Parse_With_command (P : in out Parser) return With_command_Type is
   begin
      Enter (P, 29);
      declare
         R : constant With_command_Type := Body_Of_With_command (P);
      begin
         P.Depth := P.Depth - 1;
         return R;
      end;
   end Parse_With_command;

   function Body_Of_Middles (P : in out Parser) return Middles_Type is
   R : Middles_Type;
   begin
      loop
         declare
            Start : constant Natural := P.Pos;
         begin
            if P.Pos > Limit (P) then P.Pos := Start; exit; end if;
            declare V : Middle_item_Type := Parse_Middle_item (P); begin if P.Failed then P.Failed := False; P.Pos := Start; exit; end if; R.Append (new Middle_item_Type'(V)); end;
         end;
      end loop;
      return R;
   end Body_Of_Middles;

   function Parse_Middles (P : in out Parser) return Middles_Type is
   begin
      Enter (P, 30);
      declare
         R : constant Middles_Type := Body_Of_Middles (P);
      begin
         P.Depth := P.Depth - 1;
         return R;
      end;
   end Parse_Middles;

   function Body_Of_Middle_item (P : in out Parser) return Middle_item_Type is
   R : Middle_item_Type;
   begin
      declare
         Sv  : constant Parser := P;
         Hit : Boolean := False;
         Ok  : Boolean;
         Hp  : Natural := 0;
      begin
         Hp := P.Pos;
         if not Hit then
            Ok := True;  P.Pos := Hp;
            if Ok then declare N : constant Natural := Scan_SP (P.Text.all, P.Pos, Limit (P)); begin if N > 0 then P.Pos := P.Pos + N; else Ok := False; end if; end; end if;
            if Ok then Hit := True; end if;
         end if;
         P := Sv;
         if not Hit then Fail (P, "SP"); return R; end if;
      end;
      declare
         N : constant Natural := Scan_Spaces (P.Text.all, P.Pos, Limit (P));
      begin
         if N = 0 then Fail (P, "spaces"); return R; end if;
         R.Spaces := To_Unbounded_String (P.Text (P.Pos .. P.Pos + N - 1)); P.Pos := P.Pos + N;
      end;
      declare
         N : constant Natural := Scan_Middle (P.Text.all, P.Pos, Limit (P));
      begin
         if N = 0 then Fail (P, "middle"); return R; end if;
         R.Middle := To_Unbounded_String (P.Text (P.Pos .. P.Pos + N - 1)); P.Pos := P.Pos + N;
      end;
      return R;
   end Body_Of_Middle_item;

   function Parse_Middle_item (P : in out Parser) return Middle_item_Type is
   begin
      Enter (P, 31);
      declare
         R : constant Middle_item_Type := Body_Of_Middle_item (P);
      begin
         P.Depth := P.Depth - 1;
         return R;
      end;
   end Parse_Middle_item;

   function Body_Of_More_trailing (P : in out Parser) return More_trailing_Type is
   R : More_trailing_Type;
   begin
      declare
         Sv  : constant Parser := P;
         Hit : Boolean := False;
         Ok  : Boolean;
         Hp  : Natural := 0;
      begin
         Hp := P.Pos;
         if not Hit then
            Ok := True;  P.Pos := Hp;
            if Ok then declare N : constant Natural := Scan_SP (P.Text.all, P.Pos, Limit (P)); begin if N > 0 then P.Pos := P.Pos + N; else Ok := False; end if; end; end if;
            if Ok then Hit := True; end if;
         end if;
         P := Sv;
         if not Hit then Fail (P, "SP"); return R; end if;
      end;
      declare
         N : constant Natural := Scan_Spaces (P.Text.all, P.Pos, Limit (P));
      begin
         if N = 0 then Fail (P, "spaces"); return R; end if;
         R.Spaces := To_Unbounded_String (P.Text (P.Pos .. P.Pos + N - 1)); P.Pos := P.Pos + N;
      end;
      Expect_Lit (P, ":"); if P.Failed then return R; end if;
      declare
         N : constant Natural := Scan_Trailing (P.Text.all, P.Pos, Limit (P));
      begin
         R.Trailing := To_Unbounded_String (P.Text (P.Pos .. P.Pos + N - 1)); P.Pos := P.Pos + N;
      end;
      return R;
   end Body_Of_More_trailing;

   function Parse_More_trailing (P : in out Parser) return More_trailing_Type is
   begin
      Enter (P, 32);
      declare
         R : constant More_trailing_Type := Body_Of_More_trailing (P);
      begin
         P.Depth := P.Depth - 1;
         return R;
      end;
   end Parse_More_trailing;

   function Body_Of_Lead (P : in out Parser) return Lead_Type is
   R : Lead_Type;
   begin
      declare
         N : constant Natural := Scan_Lead (P.Text.all, P.Pos, Limit (P));
      begin
         R := To_Unbounded_String (P.Text (P.Pos .. P.Pos + N - 1));
         P.Pos := P.Pos + N;
         return R;
      end;
   end Body_Of_Lead;

   function Parse_Lead (P : in out Parser) return Lead_Type is
   begin
      Enter (P, 33);
      declare
         R : constant Lead_Type := Body_Of_Lead (P);
      begin
         P.Depth := P.Depth - 1;
         return R;
      end;
   end Parse_Lead;

   function Body_Of_Spaces (P : in out Parser) return Spaces_Type is
   R : Spaces_Type;
   begin
      declare
         N : constant Natural := Scan_Spaces (P.Text.all, P.Pos, Limit (P));
      begin
         if N = 0 then Fail (P, "spaces"); return R; end if;
         R := To_Unbounded_String (P.Text (P.Pos .. P.Pos + N - 1));
         P.Pos := P.Pos + N;
         return R;
      end;
   end Body_Of_Spaces;

   function Parse_Spaces (P : in out Parser) return Spaces_Type is
   begin
      Enter (P, 34);
      declare
         R : constant Spaces_Type := Body_Of_Spaces (P);
      begin
         P.Depth := P.Depth - 1;
         return R;
      end;
   end Parse_Spaces;

   function Body_Of_Command (P : in out Parser) return Command_Type is
   R : Command_Type;
   begin
      declare
         N : constant Natural := Scan_Command (P.Text.all, P.Pos, Limit (P));
      begin
         if N = 0 then Fail (P, "command"); return R; end if;
         R := To_Unbounded_String (P.Text (P.Pos .. P.Pos + N - 1));
         P.Pos := P.Pos + N;
         return R;
      end;
   end Body_Of_Command;

   function Parse_Command (P : in out Parser) return Command_Type is
   begin
      Enter (P, 35);
      declare
         R : constant Command_Type := Body_Of_Command (P);
      begin
         P.Depth := P.Depth - 1;
         return R;
      end;
   end Parse_Command;

   function Body_Of_Middle (P : in out Parser) return Middle_Type is
   R : Middle_Type;
   begin
      declare
         N : constant Natural := Scan_Middle (P.Text.all, P.Pos, Limit (P));
      begin
         if N = 0 then Fail (P, "middle"); return R; end if;
         R := To_Unbounded_String (P.Text (P.Pos .. P.Pos + N - 1));
         P.Pos := P.Pos + N;
         return R;
      end;
   end Body_Of_Middle;

   function Parse_Middle (P : in out Parser) return Middle_Type is
   begin
      Enter (P, 36);
      declare
         R : constant Middle_Type := Body_Of_Middle (P);
      begin
         P.Depth := P.Depth - 1;
         return R;
      end;
   end Parse_Middle;

   function Body_Of_Trailing (P : in out Parser) return Trailing_Type is
   R : Trailing_Type;
   begin
      declare
         N : constant Natural := Scan_Trailing (P.Text.all, P.Pos, Limit (P));
      begin
         R := To_Unbounded_String (P.Text (P.Pos .. P.Pos + N - 1));
         P.Pos := P.Pos + N;
         return R;
      end;
   end Body_Of_Trailing;

   function Parse_Trailing (P : in out Parser) return Trailing_Type is
   begin
      Enter (P, 37);
      declare
         R : constant Trailing_Type := Body_Of_Trailing (P);
      begin
         P.Depth := P.Depth - 1;
         return R;
      end;
   end Parse_Trailing;

   function Body_Of_SP (P : in out Parser) return SP_Type is
   R : SP_Type;
   begin
      declare
         N : constant Natural := Scan_SP (P.Text.all, P.Pos, Limit (P));
      begin
         if N = 0 then Fail (P, "SP"); return R; end if;
         R := To_Unbounded_String (P.Text (P.Pos .. P.Pos + N - 1));
         P.Pos := P.Pos + N;
         return R;
      end;
   end Body_Of_SP;

   function Parse_SP (P : in out Parser) return SP_Type is
   begin
      Enter (P, 39);
      declare
         R : constant SP_Type := Body_Of_SP (P);
      begin
         P.Depth := P.Depth - 1;
         return R;
      end;
   end Parse_SP;

   function Body_Of_Word (P : in out Parser) return Word_Type is
   R : Word_Type;
   begin
      declare
         N : constant Natural := Scan_Word (P.Text.all, P.Pos, Limit (P));
      begin
         if N = 0 then Fail (P, "a word"); return R; end if;
         R := To_Unbounded_String (P.Text (P.Pos .. P.Pos + N - 1));
         P.Pos := P.Pos + N;
         return R;
      end;
   end Body_Of_Word;

   function Parse_Word (P : in out Parser) return Word_Type is
   begin
      Enter (P, 46);
      declare
         R : constant Word_Type := Body_Of_Word (P);
      begin
         P.Depth := P.Depth - 1;
         return R;
      end;
   end Parse_Word;

   function Body_Of_Int (P : in out Parser) return Int_Type is
   R : Int_Type;
   begin
      declare
         N : constant Natural := Scan_Int (P.Text.all, P.Pos, Limit (P));
      begin
         if N = 0 then Fail (P, "a int"); return R; end if;
         R := To_Unbounded_String (P.Text (P.Pos .. P.Pos + N - 1));
         P.Pos := P.Pos + N;
         return R;
      end;
   end Body_Of_Int;

   function Parse_Int (P : in out Parser) return Int_Type is
   begin
      Enter (P, 47);
      declare
         R : constant Int_Type := Body_Of_Int (P);
      begin
         P.Depth := P.Depth - 1;
         return R;
      end;
   end Parse_Int;

   function Body_Of_Str (P : in out Parser) return Str_Type is
   R : Str_Type;
   begin
      declare
         N : constant Natural := Scan_Str (P.Text.all, P.Pos, Limit (P));
      begin
         if N = 0 then Fail (P, "a str"); return R; end if;
         R := To_Unbounded_String (P.Text (P.Pos .. P.Pos + N - 1));
         P.Pos := P.Pos + N;
         return R;
      end;
   end Body_Of_Str;

   function Parse_Str (P : in out Parser) return Str_Type is
   begin
      Enter (P, 48);
      declare
         R : constant Str_Type := Body_Of_Str (P);
      begin
         P.Depth := P.Depth - 1;
         return R;
      end;
   end Parse_Str;

   function Body_Of_Ws (P : in out Parser) return Ws_Type is
   R : Ws_Type;
   begin
      declare
         N : constant Natural := Scan_Ws (P.Text.all, P.Pos, Limit (P));
      begin
         if N = 0 then Fail (P, "a ws"); return R; end if;
         R := To_Unbounded_String (P.Text (P.Pos .. P.Pos + N - 1));
         P.Pos := P.Pos + N;
         return R;
      end;
   end Body_Of_Ws;

   function Parse_Ws (P : in out Parser) return Ws_Type is
   begin
      Enter (P, 49);
      declare
         R : constant Ws_Type := Body_Of_Ws (P);
      begin
         P.Depth := P.Depth - 1;
         return R;
      end;
   end Parse_Ws;

   function Body_Of_Prefix_part_1 (P : in out Parser) return Prefix_part_1_Type is
   R : Prefix_part_1_Type;
   Save : Natural;
   begin
      loop
         exit when Natural (R.Length) >= 1;
         declare
            Start : constant Natural := P.Pos;
         begin
            if P.Pos > Limit (P) then P.Pos := Start; exit; end if;
            declare V : Prefix_Type := Parse_Prefix (P); begin if P.Failed then P.Failed := False; P.Pos := Start; exit; end if; R.Append (new Prefix_Type'(V)); end;
         end;
      end loop;
      return R;
   end Body_Of_Prefix_part_1;

   function Parse_Prefix_part_1 (P : in out Parser) return Prefix_part_1_Type is
   begin
      Enter (P, 50);
      declare
         R : constant Prefix_part_1_Type := Body_Of_Prefix_part_1 (P);
      begin
         P.Depth := P.Depth - 1;
         return R;
      end;
   end Parse_Prefix_part_1;

   function Body_Of_With_command_1 (P : in out Parser) return With_command_1_Type is
   R : With_command_1_Type;
   Save : Natural;
   begin
      loop
         exit when Natural (R.Length) >= 1;
         declare
            Start : constant Natural := P.Pos;
         begin
            if P.Pos > Limit (P) then P.Pos := Start; exit; end if;
            declare V : More_trailing_Type := Parse_More_trailing (P); begin if P.Failed then P.Failed := False; P.Pos := Start; exit; end if; R.Append (new More_trailing_Type'(V)); end;
         end;
      end loop;
      return R;
   end Body_Of_With_command_1;

   function Parse_With_command_1 (P : in out Parser) return With_command_1_Type is
   begin
      Enter (P, 51);
      declare
         R : constant With_command_1_Type := Body_Of_With_command_1 (P);
      begin
         P.Depth := P.Depth - 1;
         return R;
      end;
   end Parse_With_command_1;

   function Body_Of_Lead_2 (P : in out Parser) return Lead_2_Type is
   R : Lead_2_Type;
   begin
      declare
         N : constant Natural := Scan_Lead_2 (P.Text.all, P.Pos, Limit (P));
      begin
         R := To_Unbounded_String (P.Text (P.Pos .. P.Pos + N - 1));
         P.Pos := P.Pos + N;
         return R;
      end;
   end Body_Of_Lead_2;

   function Parse_Lead_2 (P : in out Parser) return Lead_2_Type is
   begin
      Enter (P, 52);
      declare
         R : constant Lead_2_Type := Body_Of_Lead_2 (P);
      begin
         P.Depth := P.Depth - 1;
         return R;
      end;
   end Parse_Lead_2;

   function Rule_Name (I : Natural) return String is
     (case I is
        when 1 => "message",
        when 2 => "after-tags",
        when 3 => "tags-part",
        when 4 => "prefix-part",
        when 5 => "tag-list",
        when 6 => "tag-unit",
        when 7 => "empty-item",
        when 8 => "item-semi",
        when 9 => "item-final",
        when 10 => "tag",
        when 11 => "tag-pair",
        when 12 => "tag-key-only",
        when 13 => "tag-end",
        when 14 => "tag-key",
        when 15 => "tag-key-1",
        when 16 => "tag-value",
        when 17 => "prefix",
        when 18 => "pfx-full",
        when 19 => "pfx-user",
        when 20 => "pfx-host",
        when 21 => "pfx-nick",
        when 22 => "pfx-end",
        when 23 => "pfx-name",
        when 24 => "pfx-name-1",
        when 25 => "pfx-user-name",
        when 26 => "pfx-host-name",
        when 27 => "rest",
        when 28 => "only-trailing",
        when 29 => "with-command",
        when 30 => "middles",
        when 31 => "middle-item",
        when 32 => "more-trailing",
        when 33 => "lead",
        when 34 => "spaces",
        when 35 => "command",
        when 36 => "middle",
        when 37 => "trailing",
        when 38 => "rune",
        when 39 => "SP",
        when 40 => "not-x0-1F_21-3A_3C-10FFFF",
        when 41 => "not-x0-1F_21-3A_3C_3E-10FFFF",
        when 42 => "not-x0-1F_21-10FFFF",
        when 43 => "not-x0-1F_22-3F_41-10FFFF",
        when 44 => "not-x0-1F_21-3F_41-10FFFF",
        when 45 => "not-x0-1F_21-39_3B-10FFFF",
        when 46 => "word",
        when 47 => "int",
        when 48 => "str",
        when 49 => "ws",
        when 50 => "",
        when 51 => "",
        when 52 => "",
        when others => "");
   
   function Render (P : Parser) return String is
      At_Pos : constant Natural := P.Err_Pos;
      Last   : constant Natural := P.Text'Last;
      At_End : constant Boolean := At_Pos > Last;
      Line   : Natural := 1;
      Col    : Natural := 1;
      Start  : Natural := 1;
      Msg    : Unbounded_String;
   
      function Img (N : Natural) return String is
         S : constant String := Natural'Image (N);
      begin
         return S (S'First + 1 .. S'Last);
      end Img;
   begin
      for I in 1 .. Natural'Min (At_Pos, Last + 1) - 1 loop
         if P.Text (I) = ASCII.LF then
            Line := Line + 1;
            Col := 1;
            Start := I + 1;
         else
            Col := Col + 1;
         end if;
      end loop;
      Append (Msg, Img (Line) & ":" & Img (Col) & ":" & Img (At_Pos - 1) & ": expected ");
      if P.Alt_N > 1 then
         Append (Msg, "one of ");
      end if;
      for I in 1 .. P.Alt_N loop
         if I > 1 then
            Append (Msg, ", ");
         end if;
         Append (Msg, P.Alts (I));
      end loop;
      if P.More then
         Append (Msg, ", ...");
      end if;
      Append (Msg, ", found " & Found (P, At_Pos));
      declare
         Stop : Natural := Start;
      begin
         while Stop <= Last and then P.Text (Stop) /= ASCII.LF loop
            Stop := Stop + 1;
         end loop;
         declare
            W   : constant Natural := Col - 1;
            Pad : constant String :=
              (if W <= Spaces'Length then Spaces (1 .. W) else Spaces);
         begin
            Append (Msg, ASCII.LF & "  " & P.Text (Start .. Stop - 1)
              & ASCII.LF & "  " & Pad & "^");
         end;
      end;
      for K in reverse 1 .. P.Err_Depth loop
         declare
            Nm : constant String := Rule_Name (P.Err_Stk (K));
            Sp : Natural := P.Err_Stkpos (K);
            L  : Natural := 1;
            Ls : Natural := 1;
            Le : Natural;
         begin
            if Nm'Length > 0 then
               while Sp <= Last and then P.Text (Sp) in ' ' | ASCII.HT | ASCII.LF | ASCII.CR loop
                  Sp := Sp + 1;
               end loop;
               for I in 1 .. Natural'Min (Sp, Last + 1) - 1 loop
                  if P.Text (I) = ASCII.LF then
                     L := L + 1;
                     Ls := I + 1;
                  end if;
               end loop;
               if L + (if At_End then 1 else 3) <= Line then
                  Le := Ls;
                  while Le <= Last and then P.Text (Le) /= ASCII.LF loop
                     Le := Le + 1;
                  end loop;
                  Append (Msg, ASCII.LF & "  " & Img (L) & ":" & Img (Sp - Ls + 1)
                    & ":" & Img (Sp - 1) & ": "
                    & (if At_End then "the " else "inside the ") & Nm
                    & " that begins here" & (if At_End then " is not finished:" else ":")
                    & ASCII.LF & "  " & P.Text (Ls .. Le - 1) & ASCII.LF & "  "
                    & (if Sp - Ls <= Spaces'Length then Spaces (1 .. Sp - Ls) else Spaces)
                    & "^");
                  exit;
               end if;
            end if;
         end;
      end loop;
      return To_String (Msg);
   end Render;
   
   function Parse_Text (Text : String) return Message_Type is
      --  A 1-based copy: positions are indexes into it, wherever the
      --  caller's string starts.
      function Rebase (S : String) return String is
         R : String (1 .. S'Length);
      begin
         R := S;
         return R;
      end Rebase;

      T : aliased constant String := Rebase (Text);
      P : Parser := (Text => T'Unchecked_Access, Pos => 1, Last => Natural'Last, others => <>);
      R : Message_Type;
   begin
      begin
         R := Parse_Message (P);
         if P.Failed then
            raise Parse_Error with Render (P);
         end if;
         if P.Pos <= T'Last then
            Fail (P, "end of config");
            raise Parse_Error with Render (P);
         end if;
      end;
      return R;
   end Parse_Text;

end Irc_Wire.Parser;

