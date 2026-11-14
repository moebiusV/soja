
with Interfaces;
with Ada.Unchecked_Deallocation;

package body Url_Parts.Parser is

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

   function Scan_Scheme (S : String; Pos, Len : Natural) return Natural is
      type Table is array (Natural range <>) of Natural;
      Lo    : constant Table := (65, 97, 43, 45, 48, 65, 97, 1, 1);
      Hi    : constant Table := (90, 122, 43, 46, 57, 90, 122, 0, 0);
      To    : constant Table := (1, 1, 1, 1, 1, 1, 1, 0, 0);
      First : constant Table := (0, 2, 7);
      Acc   : constant Table := (0, 1, 0);
      I     : Natural := Pos;
      Best  : Natural := 0;
      St    : Natural := 0;
      Cp, N, K : Natural;
   begin
      loop
         if Acc (St) /= 0 then Best := I - Pos; end if;
         exit when I > Len;
         N := Decode_Utf8 (S, I, Len, Cp);
         exit when N = 0;
         K := First (St);
         while K < First (St + 1)
           and then not (Cp >= Lo (K) and then Cp <= Hi (K))
         loop
            K := K + 1;
         end loop;
         exit when K = First (St + 1);
         St := To (K);
         I := I + N;
      end loop;
      return Best;
   end Scan_Scheme;

   function Scan_Userinfo_end (S : String; Pos, Len : Natural) return Natural is
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
                  Match := N > 0 and then (Cp <= 34);
                  if Match then O := O + N; end if;
               end if;
               if Match and then O > Br then Br := O; end if;
               O := 0;
               Match := True;
               if Match then
                  N := Decode_Utf8 (S, Pos + Off + O, Len, Cp);
                  Match := N > 0 and then (Cp >= 36 and then Cp <= 46);
                  if Match then O := O + N; end if;
               end if;
               if Match and then O > Br then Br := O; end if;
               O := 0;
               Match := True;
               if Match then
                  N := Decode_Utf8 (S, Pos + Off + O, Len, Cp);
                  Match := N > 0 and then (Cp >= 48 and then Cp <= 62);
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
      N := Decode_Utf8 (S, Pos + Off, Len, Cp);
      if N = 0 or else not (Cp >= 64 and then Cp <= 64) then return 0; end if;
      Off := Off + N;
      return Off;
   end Scan_Userinfo_end;

   function Scan_Host_start (S : String; Pos, Len : Natural) return Natural is
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
         Ok := N > 0 and then (Cp <= 34);
         if Ok then Off := Off + N; end if;
      end if;
      if Ok and then Off > Best then Best := Off; end if;
      Off := 0;
      Ok := True;
      if Ok then
         N := Decode_Utf8 (S, Pos + Off, Len, Cp);
         Ok := N > 0 and then (Cp >= 36 and then Cp <= 46);
         if Ok then Off := Off + N; end if;
      end if;
      if Ok and then Off > Best then Best := Off; end if;
      Off := 0;
      Ok := True;
      if Ok then
         N := Decode_Utf8 (S, Pos + Off, Len, Cp);
         Ok := N > 0 and then (Cp >= 48 and then Cp <= 62);
         if Ok then Off := Off + N; end if;
      end if;
      if Ok and then Off > Best then Best := Off; end if;
      Off := 0;
      Ok := True;
      if Ok then
         N := Decode_Utf8 (S, Pos + Off, Len, Cp);
         Ok := N > 0 and then (Cp >= 64 and then Cp <= 1114111);
         if Ok then Off := Off + N; end if;
      end if;
      if Ok and then Off > Best then Best := Off; end if;
      return Best;
   end Scan_Host_start;

   function Scan_User_colon (S : String; Pos, Len : Natural) return Natural is
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
                  Match := N > 0 and then (Cp <= 57);
                  if Match then O := O + N; end if;
               end if;
               if Match and then O > Br then Br := O; end if;
               O := 0;
               Match := True;
               if Match then
                  N := Decode_Utf8 (S, Pos + Off + O, Len, Cp);
                  Match := N > 0 and then (Cp >= 59 and then Cp <= 63);
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
      N := Decode_Utf8 (S, Pos + Off, Len, Cp);
      if N = 0 or else not (Cp >= 58 and then Cp <= 58) then return 0; end if;
      Off := Off + N;
      return Off;
   end Scan_User_colon;

   function Scan_User_name (S : String; Pos, Len : Natural) return Natural is
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
                  Match := N > 0 and then (Cp <= 57);
                  if Match then O := O + N; end if;
               end if;
               if Match and then O > Br then Br := O; end if;
               O := 0;
               Match := True;
               if Match then
                  N := Decode_Utf8 (S, Pos + Off + O, Len, Cp);
                  Match := N > 0 and then (Cp >= 59 and then Cp <= 63);
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
   end Scan_User_name;

   function Scan_User_name_1 (S : String; Pos, Len : Natural) return Natural is
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
                  Match := N > 0 and then (Cp <= 57);
                  if Match then O := O + N; end if;
               end if;
               if Match and then O > Br then Br := O; end if;
               O := 0;
               Match := True;
               if Match then
                  N := Decode_Utf8 (S, Pos + Off + O, Len, Cp);
                  Match := N > 0 and then (Cp >= 59 and then Cp <= 63);
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
   end Scan_User_name_1;

   function Scan_Password (S : String; Pos, Len : Natural) return Natural is
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
                  Match := N > 0 and then (Cp <= 63);
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
   end Scan_Password;

   function Scan_Ipv6 (S : String; Pos, Len : Natural) return Natural is
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
                  Match := N > 0 and then (Cp <= 92);
                  if Match then O := O + N; end if;
               end if;
               if Match and then O > Br then Br := O; end if;
               O := 0;
               Match := True;
               if Match then
                  N := Decode_Utf8 (S, Pos + Off + O, Len, Cp);
                  Match := N > 0 and then (Cp >= 94 and then Cp <= 1114111);
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
   end Scan_Ipv6;

   function Scan_Host_colon (S : String; Pos, Len : Natural) return Natural is
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
                  Match := N > 0 and then (Cp <= 34);
                  if Match then O := O + N; end if;
               end if;
               if Match and then O > Br then Br := O; end if;
               O := 0;
               Match := True;
               if Match then
                  N := Decode_Utf8 (S, Pos + Off + O, Len, Cp);
                  Match := N > 0 and then (Cp >= 36 and then Cp <= 46);
                  if Match then O := O + N; end if;
               end if;
               if Match and then O > Br then Br := O; end if;
               O := 0;
               Match := True;
               if Match then
                  N := Decode_Utf8 (S, Pos + Off + O, Len, Cp);
                  Match := N > 0 and then (Cp >= 48 and then Cp <= 57);
                  if Match then O := O + N; end if;
               end if;
               if Match and then O > Br then Br := O; end if;
               O := 0;
               Match := True;
               if Match then
                  N := Decode_Utf8 (S, Pos + Off + O, Len, Cp);
                  Match := N > 0 and then (Cp >= 59 and then Cp <= 62);
                  if Match then O := O + N; end if;
               end if;
               if Match and then O > Br then Br := O; end if;
               O := 0;
               Match := True;
               if Match then
                  N := Decode_Utf8 (S, Pos + Off + O, Len, Cp);
                  Match := N > 0 and then (Cp >= 64 and then Cp <= 1114111);
                  if Match then O := O + N; end if;
               end if;
               if Match and then O > Br then Br := O; end if;
               exit when Br = 0;
               Off := Off + Br;
               Cnt := Cnt + 1;
            end;
         end loop;
      end;
      N := Decode_Utf8 (S, Pos + Off, Len, Cp);
      if N = 0 or else not (Cp >= 58 and then Cp <= 58) then return 0; end if;
      Off := Off + N;
      return Off;
   end Scan_Host_colon;

   function Scan_Host (S : String; Pos, Len : Natural) return Natural is
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
                  Match := N > 0 and then (Cp <= 34);
                  if Match then O := O + N; end if;
               end if;
               if Match and then O > Br then Br := O; end if;
               O := 0;
               Match := True;
               if Match then
                  N := Decode_Utf8 (S, Pos + Off + O, Len, Cp);
                  Match := N > 0 and then (Cp >= 36 and then Cp <= 46);
                  if Match then O := O + N; end if;
               end if;
               if Match and then O > Br then Br := O; end if;
               O := 0;
               Match := True;
               if Match then
                  N := Decode_Utf8 (S, Pos + Off + O, Len, Cp);
                  Match := N > 0 and then (Cp >= 48 and then Cp <= 57);
                  if Match then O := O + N; end if;
               end if;
               if Match and then O > Br then Br := O; end if;
               O := 0;
               Match := True;
               if Match then
                  N := Decode_Utf8 (S, Pos + Off + O, Len, Cp);
                  Match := N > 0 and then (Cp >= 59 and then Cp <= 62);
                  if Match then O := O + N; end if;
               end if;
               if Match and then O > Br then Br := O; end if;
               O := 0;
               Match := True;
               if Match then
                  N := Decode_Utf8 (S, Pos + Off + O, Len, Cp);
                  Match := N > 0 and then (Cp >= 64 and then Cp <= 1114111);
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
   end Scan_Host;

   function Scan_Host_name_1 (S : String; Pos, Len : Natural) return Natural is
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
                  Match := N > 0 and then (Cp <= 34);
                  if Match then O := O + N; end if;
               end if;
               if Match and then O > Br then Br := O; end if;
               O := 0;
               Match := True;
               if Match then
                  N := Decode_Utf8 (S, Pos + Off + O, Len, Cp);
                  Match := N > 0 and then (Cp >= 36 and then Cp <= 46);
                  if Match then O := O + N; end if;
               end if;
               if Match and then O > Br then Br := O; end if;
               O := 0;
               Match := True;
               if Match then
                  N := Decode_Utf8 (S, Pos + Off + O, Len, Cp);
                  Match := N > 0 and then (Cp >= 48 and then Cp <= 62);
                  if Match then O := O + N; end if;
               end if;
               if Match and then O > Br then Br := O; end if;
               O := 0;
               Match := True;
               if Match then
                  N := Decode_Utf8 (S, Pos + Off + O, Len, Cp);
                  Match := N > 0 and then (Cp >= 64 and then Cp <= 1114111);
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
   end Scan_Host_name_1;

   function Scan_Port (S : String; Pos, Len : Natural) return Natural is
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
                  Match := N > 0 and then (Cp >= 48 and then Cp <= 57);
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
   end Scan_Port;

   function Look_Path_chars_look_1 (S : String; Pos, Len : Natural) return Boolean is
      Cp   : Natural;
      N    : Natural;
      Off  : Natural;
      Ok   : Boolean;
   begin
      Off := 0;
      Ok := True;
      if Ok then
         N := Decode_Utf8 (S, Pos + Off, Len, Cp);
         Ok := N > 0 and then (Cp >= 47 and then Cp <= 47);
         if Ok then Off := Off + N; end if;
      end if;
      if Ok then return True; end if;
      return False;
   end Look_Path_chars_look_1;

   function Scan_Path_chars (S : String; Pos, Len : Natural) return Natural is
      Cp  : Natural;
      N   : Natural;
      Off : Natural := 0;
   begin
      if not Look_Path_chars_look_1 (S, Pos + Off, Len) then return 0; end if;
      N := Decode_Utf8 (S, Pos + Off, Len, Cp);
      if N = 0 or else not (Cp >= 47 and then Cp <= 47) then return 0; end if;
      Off := Off + N;
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
                  Match := N > 0 and then (Cp <= 34);
                  if Match then O := O + N; end if;
               end if;
               if Match and then O > Br then Br := O; end if;
               O := 0;
               Match := True;
               if Match then
                  N := Decode_Utf8 (S, Pos + Off + O, Len, Cp);
                  Match := N > 0 and then (Cp >= 36 and then Cp <= 62);
                  if Match then O := O + N; end if;
               end if;
               if Match and then O > Br then Br := O; end if;
               O := 0;
               Match := True;
               if Match then
                  N := Decode_Utf8 (S, Pos + Off + O, Len, Cp);
                  Match := N > 0 and then (Cp >= 64 and then Cp <= 1114111);
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
   end Scan_Path_chars;

   function Look_Trailer_chars_look_1 (S : String; Pos, Len : Natural) return Boolean is
      Cp   : Natural;
      N    : Natural;
      Off  : Natural;
      Ok   : Boolean;
   begin
      Off := 0;
      Ok := True;
      if Ok then
         N := Decode_Utf8 (S, Pos + Off, Len, Cp);
         Ok := N > 0 and then (Cp >= 63 and then Cp <= 63);
         if Ok then Off := Off + N; end if;
      end if;
      if Ok then return True; end if;
      Off := 0;
      Ok := True;
      if Ok then
         N := Decode_Utf8 (S, Pos + Off, Len, Cp);
         Ok := N > 0 and then (Cp >= 35 and then Cp <= 35);
         if Ok then Off := Off + N; end if;
      end if;
      if Ok then return True; end if;
      return False;
   end Look_Trailer_chars_look_1;

   function Scan_Trailer_chars (S : String; Pos, Len : Natural) return Natural is
      Cp  : Natural;
      N   : Natural;
      Off : Natural := 0;
   begin
      if not Look_Trailer_chars_look_1 (S, Pos + Off, Len) then return 0; end if;
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
   end Scan_Trailer_chars;

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

   procedure Dealloc_Url is new Ada.Unchecked_Deallocation (Url_Type, Url_Access);
   procedure Dealloc_Authority is new Ada.Unchecked_Deallocation (Authority_Type, Authority_Access);
   procedure Dealloc_With_user is new Ada.Unchecked_Deallocation (With_user_Type, With_user_Access);
   procedure Dealloc_Without_user is new Ada.Unchecked_Deallocation (Without_user_Type, Without_user_Access);
   procedure Dealloc_Userinfo is new Ada.Unchecked_Deallocation (Userinfo_Type, Userinfo_Access);
   procedure Dealloc_User_pass is new Ada.Unchecked_Deallocation (User_pass_Type, User_pass_Access);
   procedure Dealloc_User_only is new Ada.Unchecked_Deallocation (User_only_Type, User_only_Access);
   procedure Dealloc_Host_port is new Ada.Unchecked_Deallocation (Host_port_Type, Host_port_Access);
   procedure Dealloc_Bracketed_port is new Ada.Unchecked_Deallocation (Bracketed_port_Type, Bracketed_port_Access);
   procedure Dealloc_Bracketed_only is new Ada.Unchecked_Deallocation (Bracketed_only_Type, Bracketed_only_Access);
   procedure Dealloc_Plain_host_port is new Ada.Unchecked_Deallocation (Plain_host_port_Type, Plain_host_port_Access);
   procedure Dealloc_Host_with_port is new Ada.Unchecked_Deallocation (Host_with_port_Type, Host_with_port_Access);
   procedure Dealloc_Host_only is new Ada.Unchecked_Deallocation (Host_only_Type, Host_only_Access);

   procedure Free_Url (V : in out Url_Type) is
   begin
   if V.Authority /= null then
      Free_Authority (V.Authority.all);
      Dealloc_Authority (V.Authority);
   end if;
   Free_Path (V.Path);
   Free_Trailer (V.Trailer);
   end Free_Url;

   procedure Free_Authority (V : in out Authority_Type) is
   begin
   if V.With_user /= null then
      Free_With_user (V.With_user.all);
      Dealloc_With_user (V.With_user);
   end if;
   if V.Without_user /= null then
      Free_Without_user (V.Without_user.all);
      Dealloc_Without_user (V.Without_user);
   end if;
   end Free_Authority;

   procedure Free_With_user (V : in out With_user_Type) is
   begin
   if V.Userinfo /= null then
      Free_Userinfo (V.Userinfo.all);
      Dealloc_Userinfo (V.Userinfo);
   end if;
   if V.Host_port /= null then
      Free_Host_port (V.Host_port.all);
      Dealloc_Host_port (V.Host_port);
   end if;
   end Free_With_user;

   procedure Free_Without_user (V : in out Without_user_Type) is
   begin
   if V.Host_port /= null then
      Free_Host_port (V.Host_port.all);
      Dealloc_Host_port (V.Host_port);
   end if;
   end Free_Without_user;

   procedure Free_Userinfo (V : in out Userinfo_Type) is
   begin
   if V.User_pass /= null then
      Free_User_pass (V.User_pass.all);
      Dealloc_User_pass (V.User_pass);
   end if;
   if V.User_only /= null then
      Free_User_only (V.User_only.all);
      Dealloc_User_only (V.User_only);
   end if;
   end Free_Userinfo;

   procedure Free_User_pass (V : in out User_pass_Type) is
      pragma Unreferenced (V);
   begin
      null;
   end Free_User_pass;

   procedure Free_User_only (V : in out User_only_Type) is
      pragma Unreferenced (V);
   begin
      null;
   end Free_User_only;

   procedure Free_Host_port (V : in out Host_port_Type) is
   begin
   if V.Bracketed_port /= null then
      Free_Bracketed_port (V.Bracketed_port.all);
      Dealloc_Bracketed_port (V.Bracketed_port);
   end if;
   if V.Bracketed_only /= null then
      Free_Bracketed_only (V.Bracketed_only.all);
      Dealloc_Bracketed_only (V.Bracketed_only);
   end if;
   if V.Plain_host_port /= null then
      Free_Plain_host_port (V.Plain_host_port.all);
      Dealloc_Plain_host_port (V.Plain_host_port);
   end if;
   end Free_Host_port;

   procedure Free_Bracketed_port (V : in out Bracketed_port_Type) is
      pragma Unreferenced (V);
   begin
      null;
   end Free_Bracketed_port;

   procedure Free_Bracketed_only (V : in out Bracketed_only_Type) is
      pragma Unreferenced (V);
   begin
      null;
   end Free_Bracketed_only;

   procedure Free_Plain_host_port (V : in out Plain_host_port_Type) is
   begin
   if V.Host_with_port /= null then
      Free_Host_with_port (V.Host_with_port.all);
      Dealloc_Host_with_port (V.Host_with_port);
   end if;
   if V.Host_only /= null then
      Free_Host_only (V.Host_only.all);
      Dealloc_Host_only (V.Host_only);
   end if;
   end Free_Plain_host_port;

   procedure Free_Host_with_port (V : in out Host_with_port_Type) is
      pragma Unreferenced (V);
   begin
      null;
   end Free_Host_with_port;

   procedure Free_Host_only (V : in out Host_only_Type) is
      pragma Unreferenced (V);
   begin
      null;
   end Free_Host_only;

   procedure Free_Path (V : in out Path_Type) is
      pragma Unreferenced (V);
   begin
      null;
   end Free_Path;

   procedure Free_Trailer (V : in out Trailer_Type) is
      pragma Unreferenced (V);
   begin
      null;
   end Free_Trailer;

   function Parse_Url (P : in out Parser) return Url_Type;
   function Parse_Scheme (P : in out Parser) return Scheme_Type;
   function Parse_Authority (P : in out Parser) return Authority_Type;
   function Parse_With_user (P : in out Parser) return With_user_Type;
   function Parse_Without_user (P : in out Parser) return Without_user_Type;
   function Parse_Userinfo_end (P : in out Parser) return Userinfo_end_Type;
   function Parse_Host_start (P : in out Parser) return Host_start_Type;
   function Parse_Userinfo (P : in out Parser) return Userinfo_Type;
   function Parse_User_pass (P : in out Parser) return User_pass_Type;
   function Parse_User_only (P : in out Parser) return User_only_Type;
   function Parse_User_colon (P : in out Parser) return User_colon_Type;
   function Parse_User_name (P : in out Parser) return User_name_Type;
   function Parse_User_name_1 (P : in out Parser) return User_name_1_Type;
   function Parse_Password (P : in out Parser) return Password_Type;
   function Parse_Host_port (P : in out Parser) return Host_port_Type;
   function Parse_Bracketed_port (P : in out Parser) return Bracketed_port_Type;
   function Parse_Bracketed_only (P : in out Parser) return Bracketed_only_Type;
   function Parse_Ipv6 (P : in out Parser) return Ipv6_Type;
   function Parse_Plain_host_port (P : in out Parser) return Plain_host_port_Type;
   function Parse_Host_with_port (P : in out Parser) return Host_with_port_Type;
   function Parse_Host_only (P : in out Parser) return Host_only_Type;
   function Parse_Host_colon (P : in out Parser) return Host_colon_Type;
   function Parse_Host (P : in out Parser) return Host_Type;
   function Parse_Host_name_1 (P : in out Parser) return Host_name_1_Type;
   function Parse_Port (P : in out Parser) return Port_Type;
   function Parse_Path (P : in out Parser) return Path_Type;
   function Parse_Path_chars (P : in out Parser) return Path_chars_Type;
   function Parse_Trailer (P : in out Parser) return Trailer_Type;
   function Parse_Trailer_chars (P : in out Parser) return Trailer_chars_Type;
   function Parse_Word (P : in out Parser) return Word_Type;
   function Parse_Int (P : in out Parser) return Int_Type;
   function Parse_Str (P : in out Parser) return Str_Type;
   function Parse_Ws (P : in out Parser) return Ws_Type;

   function Body_Of_Url (P : in out Parser) return Url_Type is
   R : Url_Type;
   begin
      declare
         N : constant Natural := Scan_Scheme (P.Text.all, P.Pos, Limit (P));
      begin
         if N = 0 then Fail (P, "scheme"); return R; end if;
         R.Scheme := To_Unbounded_String (P.Text (P.Pos .. P.Pos + N - 1)); P.Pos := P.Pos + N;
      end;
      Expect_Lit (P, "://"); if P.Failed then return R; end if;
      declare V : Authority_Type := Parse_Authority (P); begin if P.Failed then return R; end if; R.Authority := new Authority_Type'(V); end;
      R.Path := Parse_Path (P); if P.Failed then return R; end if;
      R.Trailer := Parse_Trailer (P); if P.Failed then return R; end if;
      return R;
   end Body_Of_Url;

   function Parse_Url (P : in out Parser) return Url_Type is
   begin
      Enter (P, 1);
      declare
         R : constant Url_Type := Body_Of_Url (P);
      begin
         P.Depth := P.Depth - 1;
         return R;
      end;
   end Parse_Url;

   function Body_Of_Scheme (P : in out Parser) return Scheme_Type is
   R : Scheme_Type;
   begin
      declare
         N : constant Natural := Scan_Scheme (P.Text.all, P.Pos, Limit (P));
      begin
         if N = 0 then Fail (P, "scheme"); return R; end if;
         R := To_Unbounded_String (P.Text (P.Pos .. P.Pos + N - 1));
         P.Pos := P.Pos + N;
         return R;
      end;
   end Body_Of_Scheme;

   function Parse_Scheme (P : in out Parser) return Scheme_Type is
   begin
      Enter (P, 2);
      declare
         R : constant Scheme_Type := Body_Of_Scheme (P);
      begin
         P.Depth := P.Depth - 1;
         return R;
      end;
   end Parse_Scheme;

   function Body_Of_Authority (P : in out Parser) return Authority_Type is
   R : Authority_Type;
   begin
      declare
         Save : constant Natural := P.Pos;
      begin
         declare
            R : Authority_Type;
         begin
            declare V : With_user_Type := Parse_With_user (P); begin if P.Failed then goto Alt_Fail_1; end if; R.With_user := new With_user_Type'(V); end;
            return R;
            <<Alt_Fail_1>> null;
         end;
         P.Failed := False; P.Pos := Save;
         declare
            R : Authority_Type;
         begin
            declare V : Without_user_Type := Parse_Without_user (P); begin if P.Failed then goto Alt_Fail_2; end if; R.Without_user := new Without_user_Type'(V); end;
            return R;
            <<Alt_Fail_2>> null;
         end;
         P.Failed := False; P.Pos := Save;
         P.Pos := Save;
         Fail (P, "a authority");
         return R;
      end;
   end Body_Of_Authority;

   function Parse_Authority (P : in out Parser) return Authority_Type is
   begin
      Enter (P, 3);
      declare
         R : constant Authority_Type := Body_Of_Authority (P);
      begin
         P.Depth := P.Depth - 1;
         return R;
      end;
   end Parse_Authority;

   function Body_Of_With_user (P : in out Parser) return With_user_Type is
   R : With_user_Type;
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
            if Ok then declare N : constant Natural := Scan_Userinfo_end (P.Text.all, P.Pos, Limit (P)); begin if N > 0 then P.Pos := P.Pos + N; else Ok := False; end if; end; end if;
            if Ok then Hit := True; end if;
         end if;
         P := Sv;
         if not Hit then Fail (P, "userinfo-end"); return R; end if;
      end;
      declare V : Userinfo_Type := Parse_Userinfo (P); begin if P.Failed then return R; end if; R.Userinfo := new Userinfo_Type'(V); end;
      Expect_Lit (P, "@"); if P.Failed then return R; end if;
      declare V : Host_port_Type := Parse_Host_port (P); begin if P.Failed then return R; end if; R.Host_port := new Host_port_Type'(V); end;
      return R;
   end Body_Of_With_user;

   function Parse_With_user (P : in out Parser) return With_user_Type is
   begin
      Enter (P, 4);
      declare
         R : constant With_user_Type := Body_Of_With_user (P);
      begin
         P.Depth := P.Depth - 1;
         return R;
      end;
   end Parse_With_user;

   function Body_Of_Without_user (P : in out Parser) return Without_user_Type is
   R : Without_user_Type;
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
            if Ok then declare N : constant Natural := Scan_Host_start (P.Text.all, P.Pos, Limit (P)); begin if N > 0 then P.Pos := P.Pos + N; else Ok := False; end if; end; end if;
            if Ok then Hit := True; end if;
         end if;
         P := Sv;
         if not Hit then Fail (P, "host-start"); return R; end if;
      end;
      declare V : Host_port_Type := Parse_Host_port (P); begin if P.Failed then return R; end if; R.Host_port := new Host_port_Type'(V); end;
      return R;
   end Body_Of_Without_user;

   function Parse_Without_user (P : in out Parser) return Without_user_Type is
   begin
      Enter (P, 5);
      declare
         R : constant Without_user_Type := Body_Of_Without_user (P);
      begin
         P.Depth := P.Depth - 1;
         return R;
      end;
   end Parse_Without_user;

   function Body_Of_Userinfo_end (P : in out Parser) return Userinfo_end_Type is
   R : Userinfo_end_Type;
   begin
      declare
         N : constant Natural := Scan_Userinfo_end (P.Text.all, P.Pos, Limit (P));
      begin
         if N = 0 then Fail (P, "userinfo-end"); return R; end if;
         R := To_Unbounded_String (P.Text (P.Pos .. P.Pos + N - 1));
         P.Pos := P.Pos + N;
         return R;
      end;
   end Body_Of_Userinfo_end;

   function Parse_Userinfo_end (P : in out Parser) return Userinfo_end_Type is
   begin
      Enter (P, 6);
      declare
         R : constant Userinfo_end_Type := Body_Of_Userinfo_end (P);
      begin
         P.Depth := P.Depth - 1;
         return R;
      end;
   end Parse_Userinfo_end;

   function Body_Of_Host_start (P : in out Parser) return Host_start_Type is
   R : Host_start_Type;
   begin
      declare
         N : constant Natural := Scan_Host_start (P.Text.all, P.Pos, Limit (P));
      begin
         if N = 0 then Fail (P, "host-start"); return R; end if;
         R := To_Unbounded_String (P.Text (P.Pos .. P.Pos + N - 1));
         P.Pos := P.Pos + N;
         return R;
      end;
   end Body_Of_Host_start;

   function Parse_Host_start (P : in out Parser) return Host_start_Type is
   begin
      Enter (P, 7);
      declare
         R : constant Host_start_Type := Body_Of_Host_start (P);
      begin
         P.Depth := P.Depth - 1;
         return R;
      end;
   end Parse_Host_start;

   function Body_Of_Userinfo (P : in out Parser) return Userinfo_Type is
   R : Userinfo_Type;
   begin
      declare
         Save : constant Natural := P.Pos;
      begin
         declare
            R : Userinfo_Type;
         begin
            declare V : User_pass_Type := Parse_User_pass (P); begin if P.Failed then goto Alt_Fail_3; end if; R.User_pass := new User_pass_Type'(V); end;
            return R;
            <<Alt_Fail_3>> null;
         end;
         P.Failed := False; P.Pos := Save;
         declare
            R : Userinfo_Type;
         begin
            declare V : User_only_Type := Parse_User_only (P); begin if P.Failed then goto Alt_Fail_4; end if; R.User_only := new User_only_Type'(V); end;
            return R;
            <<Alt_Fail_4>> null;
         end;
         P.Failed := False; P.Pos := Save;
         P.Pos := Save;
         Fail (P, "a userinfo");
         return R;
      end;
   end Body_Of_Userinfo;

   function Parse_Userinfo (P : in out Parser) return Userinfo_Type is
   begin
      Enter (P, 8);
      declare
         R : constant Userinfo_Type := Body_Of_Userinfo (P);
      begin
         P.Depth := P.Depth - 1;
         return R;
      end;
   end Parse_Userinfo;

   function Body_Of_User_pass (P : in out Parser) return User_pass_Type is
   R : User_pass_Type;
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
            if Ok then declare N : constant Natural := Scan_User_colon (P.Text.all, P.Pos, Limit (P)); begin if N > 0 then P.Pos := P.Pos + N; else Ok := False; end if; end; end if;
            if Ok then Hit := True; end if;
         end if;
         P := Sv;
         if not Hit then Fail (P, "user-colon"); return R; end if;
      end;
      declare
         N : constant Natural := Scan_User_name (P.Text.all, P.Pos, Limit (P));
      begin
         R.User_name := To_Unbounded_String (P.Text (P.Pos .. P.Pos + N - 1)); P.Pos := P.Pos + N;
      end;
      Expect_Lit (P, ":"); if P.Failed then return R; end if;
      declare
         N : constant Natural := Scan_Password (P.Text.all, P.Pos, Limit (P));
      begin
         R.Password := To_Unbounded_String (P.Text (P.Pos .. P.Pos + N - 1)); P.Pos := P.Pos + N;
      end;
      return R;
   end Body_Of_User_pass;

   function Parse_User_pass (P : in out Parser) return User_pass_Type is
   begin
      Enter (P, 9);
      declare
         R : constant User_pass_Type := Body_Of_User_pass (P);
      begin
         P.Depth := P.Depth - 1;
         return R;
      end;
   end Parse_User_pass;

   function Body_Of_User_only (P : in out Parser) return User_only_Type is
   R : User_only_Type;
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
            if Ok then declare N : constant Natural := Scan_User_name_1 (P.Text.all, P.Pos, Limit (P)); begin if N > 0 then P.Pos := P.Pos + N; else Ok := False; end if; end; end if;
            if Ok then Hit := True; end if;
         end if;
         P := Sv;
         if not Hit then Fail (P, "user-name-1"); return R; end if;
      end;
      declare
         N : constant Natural := Scan_User_name_1 (P.Text.all, P.Pos, Limit (P));
      begin
         if N = 0 then Fail (P, "user-name-1"); return R; end if;
         R.User_name_1 := To_Unbounded_String (P.Text (P.Pos .. P.Pos + N - 1)); P.Pos := P.Pos + N;
      end;
      return R;
   end Body_Of_User_only;

   function Parse_User_only (P : in out Parser) return User_only_Type is
   begin
      Enter (P, 10);
      declare
         R : constant User_only_Type := Body_Of_User_only (P);
      begin
         P.Depth := P.Depth - 1;
         return R;
      end;
   end Parse_User_only;

   function Body_Of_User_colon (P : in out Parser) return User_colon_Type is
   R : User_colon_Type;
   begin
      declare
         N : constant Natural := Scan_User_colon (P.Text.all, P.Pos, Limit (P));
      begin
         if N = 0 then Fail (P, "user-colon"); return R; end if;
         R := To_Unbounded_String (P.Text (P.Pos .. P.Pos + N - 1));
         P.Pos := P.Pos + N;
         return R;
      end;
   end Body_Of_User_colon;

   function Parse_User_colon (P : in out Parser) return User_colon_Type is
   begin
      Enter (P, 11);
      declare
         R : constant User_colon_Type := Body_Of_User_colon (P);
      begin
         P.Depth := P.Depth - 1;
         return R;
      end;
   end Parse_User_colon;

   function Body_Of_User_name (P : in out Parser) return User_name_Type is
   R : User_name_Type;
   begin
      declare
         N : constant Natural := Scan_User_name (P.Text.all, P.Pos, Limit (P));
      begin
         R := To_Unbounded_String (P.Text (P.Pos .. P.Pos + N - 1));
         P.Pos := P.Pos + N;
         return R;
      end;
   end Body_Of_User_name;

   function Parse_User_name (P : in out Parser) return User_name_Type is
   begin
      Enter (P, 12);
      declare
         R : constant User_name_Type := Body_Of_User_name (P);
      begin
         P.Depth := P.Depth - 1;
         return R;
      end;
   end Parse_User_name;

   function Body_Of_User_name_1 (P : in out Parser) return User_name_1_Type is
   R : User_name_1_Type;
   begin
      declare
         N : constant Natural := Scan_User_name_1 (P.Text.all, P.Pos, Limit (P));
      begin
         if N = 0 then Fail (P, "user-name-1"); return R; end if;
         R := To_Unbounded_String (P.Text (P.Pos .. P.Pos + N - 1));
         P.Pos := P.Pos + N;
         return R;
      end;
   end Body_Of_User_name_1;

   function Parse_User_name_1 (P : in out Parser) return User_name_1_Type is
   begin
      Enter (P, 13);
      declare
         R : constant User_name_1_Type := Body_Of_User_name_1 (P);
      begin
         P.Depth := P.Depth - 1;
         return R;
      end;
   end Parse_User_name_1;

   function Body_Of_Password (P : in out Parser) return Password_Type is
   R : Password_Type;
   begin
      declare
         N : constant Natural := Scan_Password (P.Text.all, P.Pos, Limit (P));
      begin
         R := To_Unbounded_String (P.Text (P.Pos .. P.Pos + N - 1));
         P.Pos := P.Pos + N;
         return R;
      end;
   end Body_Of_Password;

   function Parse_Password (P : in out Parser) return Password_Type is
   begin
      Enter (P, 14);
      declare
         R : constant Password_Type := Body_Of_Password (P);
      begin
         P.Depth := P.Depth - 1;
         return R;
      end;
   end Parse_Password;

   function Body_Of_Host_port (P : in out Parser) return Host_port_Type is
   R : Host_port_Type;
   begin
      declare
         Save : constant Natural := P.Pos;
      begin
         declare
            R : Host_port_Type;
         begin
            declare V : Bracketed_port_Type := Parse_Bracketed_port (P); begin if P.Failed then goto Alt_Fail_5; end if; R.Bracketed_port := new Bracketed_port_Type'(V); end;
            return R;
            <<Alt_Fail_5>> null;
         end;
         P.Failed := False; P.Pos := Save;
         declare
            R : Host_port_Type;
         begin
            declare V : Bracketed_only_Type := Parse_Bracketed_only (P); begin if P.Failed then goto Alt_Fail_6; end if; R.Bracketed_only := new Bracketed_only_Type'(V); end;
            return R;
            <<Alt_Fail_6>> null;
         end;
         P.Failed := False; P.Pos := Save;
         declare
            R : Host_port_Type;
         begin
            declare V : Plain_host_port_Type := Parse_Plain_host_port (P); begin if P.Failed then goto Alt_Fail_7; end if; R.Plain_host_port := new Plain_host_port_Type'(V); end;
            return R;
            <<Alt_Fail_7>> null;
         end;
         P.Failed := False; P.Pos := Save;
         P.Pos := Save;
         Fail (P, "a host-port");
         return R;
      end;
   end Body_Of_Host_port;

   function Parse_Host_port (P : in out Parser) return Host_port_Type is
   begin
      Enter (P, 15);
      declare
         R : constant Host_port_Type := Body_Of_Host_port (P);
      begin
         P.Depth := P.Depth - 1;
         return R;
      end;
   end Parse_Host_port;

   function Body_Of_Bracketed_port (P : in out Parser) return Bracketed_port_Type is
   R : Bracketed_port_Type;
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
            if Ok then Expect_Lit (P, "["); if P.Failed then P.Failed := False; Ok := False; end if; end if;
            if Ok then Hit := True; end if;
         end if;
         P := Sv;
         if not Hit then Fail (P, "`[`"); return R; end if;
      end;
      Expect_Lit (P, "["); if P.Failed then return R; end if;
      declare
         N : constant Natural := Scan_Ipv6 (P.Text.all, P.Pos, Limit (P));
      begin
         R.Ipv6 := To_Unbounded_String (P.Text (P.Pos .. P.Pos + N - 1)); P.Pos := P.Pos + N;
      end;
      Expect_Lit (P, "]"); if P.Failed then return R; end if;
      Expect_Lit (P, ":"); if P.Failed then return R; end if;
      declare
         N : constant Natural := Scan_Port (P.Text.all, P.Pos, Limit (P));
      begin
         R.Port := To_Unbounded_String (P.Text (P.Pos .. P.Pos + N - 1)); P.Pos := P.Pos + N;
      end;
      return R;
   end Body_Of_Bracketed_port;

   function Parse_Bracketed_port (P : in out Parser) return Bracketed_port_Type is
   begin
      Enter (P, 16);
      declare
         R : constant Bracketed_port_Type := Body_Of_Bracketed_port (P);
      begin
         P.Depth := P.Depth - 1;
         return R;
      end;
   end Parse_Bracketed_port;

   function Body_Of_Bracketed_only (P : in out Parser) return Bracketed_only_Type is
   R : Bracketed_only_Type;
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
            if Ok then Expect_Lit (P, "["); if P.Failed then P.Failed := False; Ok := False; end if; end if;
            if Ok then Hit := True; end if;
         end if;
         P := Sv;
         if not Hit then Fail (P, "`[`"); return R; end if;
      end;
      Expect_Lit (P, "["); if P.Failed then return R; end if;
      declare
         N : constant Natural := Scan_Ipv6 (P.Text.all, P.Pos, Limit (P));
      begin
         R.Ipv6 := To_Unbounded_String (P.Text (P.Pos .. P.Pos + N - 1)); P.Pos := P.Pos + N;
      end;
      Expect_Lit (P, "]"); if P.Failed then return R; end if;
      return R;
   end Body_Of_Bracketed_only;

   function Parse_Bracketed_only (P : in out Parser) return Bracketed_only_Type is
   begin
      Enter (P, 17);
      declare
         R : constant Bracketed_only_Type := Body_Of_Bracketed_only (P);
      begin
         P.Depth := P.Depth - 1;
         return R;
      end;
   end Parse_Bracketed_only;

   function Body_Of_Ipv6 (P : in out Parser) return Ipv6_Type is
   R : Ipv6_Type;
   begin
      declare
         N : constant Natural := Scan_Ipv6 (P.Text.all, P.Pos, Limit (P));
      begin
         R := To_Unbounded_String (P.Text (P.Pos .. P.Pos + N - 1));
         P.Pos := P.Pos + N;
         return R;
      end;
   end Body_Of_Ipv6;

   function Parse_Ipv6 (P : in out Parser) return Ipv6_Type is
   begin
      Enter (P, 18);
      declare
         R : constant Ipv6_Type := Body_Of_Ipv6 (P);
      begin
         P.Depth := P.Depth - 1;
         return R;
      end;
   end Parse_Ipv6;

   function Body_Of_Plain_host_port (P : in out Parser) return Plain_host_port_Type is
   R : Plain_host_port_Type;
   begin
      declare
         Save : constant Natural := P.Pos;
      begin
         declare
            R : Plain_host_port_Type;
         begin
            declare V : Host_with_port_Type := Parse_Host_with_port (P); begin if P.Failed then goto Alt_Fail_8; end if; R.Host_with_port := new Host_with_port_Type'(V); end;
            return R;
            <<Alt_Fail_8>> null;
         end;
         P.Failed := False; P.Pos := Save;
         declare
            R : Plain_host_port_Type;
         begin
            declare V : Host_only_Type := Parse_Host_only (P); begin if P.Failed then goto Alt_Fail_9; end if; R.Host_only := new Host_only_Type'(V); end;
            return R;
            <<Alt_Fail_9>> null;
         end;
         P.Failed := False; P.Pos := Save;
         P.Pos := Save;
         Fail (P, "a plain-host-port");
         return R;
      end;
   end Body_Of_Plain_host_port;

   function Parse_Plain_host_port (P : in out Parser) return Plain_host_port_Type is
   begin
      Enter (P, 19);
      declare
         R : constant Plain_host_port_Type := Body_Of_Plain_host_port (P);
      begin
         P.Depth := P.Depth - 1;
         return R;
      end;
   end Parse_Plain_host_port;

   function Body_Of_Host_with_port (P : in out Parser) return Host_with_port_Type is
   R : Host_with_port_Type;
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
            if Ok then declare N : constant Natural := Scan_Host_colon (P.Text.all, P.Pos, Limit (P)); begin if N > 0 then P.Pos := P.Pos + N; else Ok := False; end if; end; end if;
            if Ok then Hit := True; end if;
         end if;
         P := Sv;
         if not Hit then Fail (P, "host-colon"); return R; end if;
      end;
      declare
         N : constant Natural := Scan_Host (P.Text.all, P.Pos, Limit (P));
      begin
         R.Host := To_Unbounded_String (P.Text (P.Pos .. P.Pos + N - 1)); P.Pos := P.Pos + N;
      end;
      Expect_Lit (P, ":"); if P.Failed then return R; end if;
      declare
         N : constant Natural := Scan_Port (P.Text.all, P.Pos, Limit (P));
      begin
         R.Port := To_Unbounded_String (P.Text (P.Pos .. P.Pos + N - 1)); P.Pos := P.Pos + N;
      end;
      return R;
   end Body_Of_Host_with_port;

   function Parse_Host_with_port (P : in out Parser) return Host_with_port_Type is
   begin
      Enter (P, 20);
      declare
         R : constant Host_with_port_Type := Body_Of_Host_with_port (P);
      begin
         P.Depth := P.Depth - 1;
         return R;
      end;
   end Parse_Host_with_port;

   function Body_Of_Host_only (P : in out Parser) return Host_only_Type is
   R : Host_only_Type;
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
            if Ok then declare N : constant Natural := Scan_Host_name_1 (P.Text.all, P.Pos, Limit (P)); begin if N > 0 then P.Pos := P.Pos + N; else Ok := False; end if; end; end if;
            if Ok then Hit := True; end if;
         end if;
         P := Sv;
         if not Hit then Fail (P, "host-name-1"); return R; end if;
      end;
      declare
         N : constant Natural := Scan_Host_name_1 (P.Text.all, P.Pos, Limit (P));
      begin
         if N = 0 then Fail (P, "host-name-1"); return R; end if;
         R.Host_name_1 := To_Unbounded_String (P.Text (P.Pos .. P.Pos + N - 1)); P.Pos := P.Pos + N;
      end;
      return R;
   end Body_Of_Host_only;

   function Parse_Host_only (P : in out Parser) return Host_only_Type is
   begin
      Enter (P, 21);
      declare
         R : constant Host_only_Type := Body_Of_Host_only (P);
      begin
         P.Depth := P.Depth - 1;
         return R;
      end;
   end Parse_Host_only;

   function Body_Of_Host_colon (P : in out Parser) return Host_colon_Type is
   R : Host_colon_Type;
   begin
      declare
         N : constant Natural := Scan_Host_colon (P.Text.all, P.Pos, Limit (P));
      begin
         if N = 0 then Fail (P, "host-colon"); return R; end if;
         R := To_Unbounded_String (P.Text (P.Pos .. P.Pos + N - 1));
         P.Pos := P.Pos + N;
         return R;
      end;
   end Body_Of_Host_colon;

   function Parse_Host_colon (P : in out Parser) return Host_colon_Type is
   begin
      Enter (P, 22);
      declare
         R : constant Host_colon_Type := Body_Of_Host_colon (P);
      begin
         P.Depth := P.Depth - 1;
         return R;
      end;
   end Parse_Host_colon;

   function Body_Of_Host (P : in out Parser) return Host_Type is
   R : Host_Type;
   begin
      declare
         N : constant Natural := Scan_Host (P.Text.all, P.Pos, Limit (P));
      begin
         R := To_Unbounded_String (P.Text (P.Pos .. P.Pos + N - 1));
         P.Pos := P.Pos + N;
         return R;
      end;
   end Body_Of_Host;

   function Parse_Host (P : in out Parser) return Host_Type is
   begin
      Enter (P, 23);
      declare
         R : constant Host_Type := Body_Of_Host (P);
      begin
         P.Depth := P.Depth - 1;
         return R;
      end;
   end Parse_Host;

   function Body_Of_Host_name_1 (P : in out Parser) return Host_name_1_Type is
   R : Host_name_1_Type;
   begin
      declare
         N : constant Natural := Scan_Host_name_1 (P.Text.all, P.Pos, Limit (P));
      begin
         if N = 0 then Fail (P, "host-name-1"); return R; end if;
         R := To_Unbounded_String (P.Text (P.Pos .. P.Pos + N - 1));
         P.Pos := P.Pos + N;
         return R;
      end;
   end Body_Of_Host_name_1;

   function Parse_Host_name_1 (P : in out Parser) return Host_name_1_Type is
   begin
      Enter (P, 24);
      declare
         R : constant Host_name_1_Type := Body_Of_Host_name_1 (P);
      begin
         P.Depth := P.Depth - 1;
         return R;
      end;
   end Parse_Host_name_1;

   function Body_Of_Port (P : in out Parser) return Port_Type is
   R : Port_Type;
   begin
      declare
         N : constant Natural := Scan_Port (P.Text.all, P.Pos, Limit (P));
      begin
         R := To_Unbounded_String (P.Text (P.Pos .. P.Pos + N - 1));
         P.Pos := P.Pos + N;
         return R;
      end;
   end Body_Of_Port;

   function Parse_Port (P : in out Parser) return Port_Type is
   begin
      Enter (P, 25);
      declare
         R : constant Port_Type := Body_Of_Port (P);
      begin
         P.Depth := P.Depth - 1;
         return R;
      end;
   end Parse_Port;

   function Body_Of_Path (P : in out Parser) return Path_Type is
   R : Path_Type;
   Save : Natural;
   begin
      loop
         exit when Natural (R.Length) >= 1;
         declare
            Start : constant Natural := P.Pos;
         begin
            if P.Pos > Limit (P) then P.Pos := Start; exit; end if;
            declare V : Path_chars_Type := Parse_Path_chars (P); begin if P.Failed then P.Failed := False; P.Pos := Start; exit; end if; R.Append (V); end;
         end;
      end loop;
      return R;
   end Body_Of_Path;

   function Parse_Path (P : in out Parser) return Path_Type is
   begin
      Enter (P, 26);
      declare
         R : constant Path_Type := Body_Of_Path (P);
      begin
         P.Depth := P.Depth - 1;
         return R;
      end;
   end Parse_Path;

   function Body_Of_Path_chars (P : in out Parser) return Path_chars_Type is
   R : Path_chars_Type;
   begin
      declare
         N : constant Natural := Scan_Path_chars (P.Text.all, P.Pos, Limit (P));
      begin
         if N = 0 then Fail (P, "path-chars"); return R; end if;
         R := To_Unbounded_String (P.Text (P.Pos .. P.Pos + N - 1));
         P.Pos := P.Pos + N;
         return R;
      end;
   end Body_Of_Path_chars;

   function Parse_Path_chars (P : in out Parser) return Path_chars_Type is
   begin
      Enter (P, 27);
      declare
         R : constant Path_chars_Type := Body_Of_Path_chars (P);
      begin
         P.Depth := P.Depth - 1;
         return R;
      end;
   end Parse_Path_chars;

   function Body_Of_Trailer (P : in out Parser) return Trailer_Type is
   R : Trailer_Type;
   Save : Natural;
   begin
      loop
         exit when Natural (R.Length) >= 1;
         declare
            Start : constant Natural := P.Pos;
         begin
            declare V : Trailer_chars_Type := Parse_Trailer_chars (P); begin if P.Failed then P.Failed := False; P.Pos := Start; exit; end if; R.Append (V); end;
            exit when P.Pos = Start;
         end;
      end loop;
      return R;
   end Body_Of_Trailer;

   function Parse_Trailer (P : in out Parser) return Trailer_Type is
   begin
      Enter (P, 28);
      declare
         R : constant Trailer_Type := Body_Of_Trailer (P);
      begin
         P.Depth := P.Depth - 1;
         return R;
      end;
   end Parse_Trailer;

   function Body_Of_Trailer_chars (P : in out Parser) return Trailer_chars_Type is
   R : Trailer_chars_Type;
   begin
      declare
         N : constant Natural := Scan_Trailer_chars (P.Text.all, P.Pos, Limit (P));
      begin
         R := To_Unbounded_String (P.Text (P.Pos .. P.Pos + N - 1));
         P.Pos := P.Pos + N;
         return R;
      end;
   end Body_Of_Trailer_chars;

   function Parse_Trailer_chars (P : in out Parser) return Trailer_chars_Type is
   begin
      Enter (P, 29);
      declare
         R : constant Trailer_chars_Type := Body_Of_Trailer_chars (P);
      begin
         P.Depth := P.Depth - 1;
         return R;
      end;
   end Parse_Trailer_chars;

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
      Enter (P, 40);
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
      Enter (P, 41);
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
      Enter (P, 42);
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
      Enter (P, 43);
      declare
         R : constant Ws_Type := Body_Of_Ws (P);
      begin
         P.Depth := P.Depth - 1;
         return R;
      end;
   end Parse_Ws;

   function Rule_Name (I : Natural) return String is
     (case I is
        when 1 => "url",
        when 2 => "scheme",
        when 3 => "authority",
        when 4 => "with-user",
        when 5 => "without-user",
        when 6 => "userinfo-end",
        when 7 => "host-start",
        when 8 => "userinfo",
        when 9 => "user-pass",
        when 10 => "user-only",
        when 11 => "user-colon",
        when 12 => "user-name",
        when 13 => "user-name-1",
        when 14 => "password",
        when 15 => "host-port",
        when 16 => "bracketed-port",
        when 17 => "bracketed-only",
        when 18 => "ipv6",
        when 19 => "plain-host-port",
        when 20 => "host-with-port",
        when 21 => "host-only",
        when 22 => "host-colon",
        when 23 => "host",
        when 24 => "host-name-1",
        when 25 => "port",
        when 26 => "path",
        when 27 => "path-chars",
        when 28 => "trailer",
        when 29 => "trailer-chars",
        when 30 => "rune",
        when 31 => "DIGIT",
        when 32 => "ALPHA",
        when 33 => "not-x0-22_24-2E_30-3E_41-10FFFF",
        when 34 => "not-x0-22_24-2E_30-3E_40-10FFFF",
        when 35 => "not-x0-39_3B-3F_41-10FFFF",
        when 36 => "not-x0-3F_41-10FFFF",
        when 37 => "not-x0-5C_5E-10FFFF",
        when 38 => "not-x0-22_24-2E_30-39_3B-3E_40-10FFFF",
        when 39 => "not-x0-22_24-3E_40-10FFFF",
        when 40 => "word",
        when 41 => "int",
        when 42 => "str",
        when 43 => "ws",
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
   
   function Parse_Text (Text : String) return Url_Type is
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
      R : Url_Type;
   begin
      begin
         R := Parse_Url (P);
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

end Url_Parts.Parser;

