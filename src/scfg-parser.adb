
with Interfaces;
with Ada.Unchecked_Deallocation;

package body Scfg.Parser is

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

   function Scan_Directive_start (S : String; Pos, Len : Natural) return Natural is
      Cp   : Natural;
      N    : Natural;
      Best : Natural := 0;
      Off  : Natural;
      Ok   : Boolean;
   begin
      Off := 0;
      Ok := True;
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
                     Match := N > 0 and then (Cp >= 32 and then Cp <= 32);
                     if Match then O := O + N; end if;
                  end if;
                  if Match and then O > Br then Br := O; end if;
                  O := 0;
                  Match := True;
                  if Match then
                     N := Decode_Utf8 (S, Pos + Off + O, Len, Cp);
                     Match := N > 0 and then (Cp >= 9 and then Cp <= 9);
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
      if Ok then
         N := Decode_Utf8 (S, Pos + Off, Len, Cp);
         Ok := N > 0 and then (Cp <= 8);
         if Ok then Off := Off + N; end if;
      end if;
      if Ok and then Off > Best then Best := Off; end if;
      Off := 0;
      Ok := True;
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
                     Match := N > 0 and then (Cp >= 32 and then Cp <= 32);
                     if Match then O := O + N; end if;
                  end if;
                  if Match and then O > Br then Br := O; end if;
                  O := 0;
                  Match := True;
                  if Match then
                     N := Decode_Utf8 (S, Pos + Off + O, Len, Cp);
                     Match := N > 0 and then (Cp >= 9 and then Cp <= 9);
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
      if Ok then
         N := Decode_Utf8 (S, Pos + Off, Len, Cp);
         Ok := N > 0 and then (Cp >= 11 and then Cp <= 12);
         if Ok then Off := Off + N; end if;
      end if;
      if Ok and then Off > Best then Best := Off; end if;
      Off := 0;
      Ok := True;
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
                     Match := N > 0 and then (Cp >= 32 and then Cp <= 32);
                     if Match then O := O + N; end if;
                  end if;
                  if Match and then O > Br then Br := O; end if;
                  O := 0;
                  Match := True;
                  if Match then
                     N := Decode_Utf8 (S, Pos + Off + O, Len, Cp);
                     Match := N > 0 and then (Cp >= 9 and then Cp <= 9);
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
      if Ok then
         N := Decode_Utf8 (S, Pos + Off, Len, Cp);
         Ok := N > 0 and then (Cp >= 14 and then Cp <= 31);
         if Ok then Off := Off + N; end if;
      end if;
      if Ok and then Off > Best then Best := Off; end if;
      Off := 0;
      Ok := True;
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
                     Match := N > 0 and then (Cp >= 32 and then Cp <= 32);
                     if Match then O := O + N; end if;
                  end if;
                  if Match and then O > Br then Br := O; end if;
                  O := 0;
                  Match := True;
                  if Match then
                     N := Decode_Utf8 (S, Pos + Off + O, Len, Cp);
                     Match := N > 0 and then (Cp >= 9 and then Cp <= 9);
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
      if Ok then
         N := Decode_Utf8 (S, Pos + Off, Len, Cp);
         Ok := N > 0 and then (Cp >= 33 and then Cp <= 34);
         if Ok then Off := Off + N; end if;
      end if;
      if Ok and then Off > Best then Best := Off; end if;
      Off := 0;
      Ok := True;
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
                     Match := N > 0 and then (Cp >= 32 and then Cp <= 32);
                     if Match then O := O + N; end if;
                  end if;
                  if Match and then O > Br then Br := O; end if;
                  O := 0;
                  Match := True;
                  if Match then
                     N := Decode_Utf8 (S, Pos + Off + O, Len, Cp);
                     Match := N > 0 and then (Cp >= 9 and then Cp <= 9);
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
      if Ok then
         N := Decode_Utf8 (S, Pos + Off, Len, Cp);
         Ok := N > 0 and then (Cp >= 36 and then Cp <= 1114111);
         if Ok then Off := Off + N; end if;
      end if;
      if Ok and then Off > Best then Best := Off; end if;
      return Best;
   end Scan_Directive_start;

   function Scan_Name (S : String; Pos, Len : Natural) return Natural is
      type Table is array (Natural range <>) of Natural;
      Lo    : constant Table := (0, 11, 14, 33, 34, 36, 39, 40, 92, 93, 0, 11, 14, 33, 36, 40, 92, 93, 0, 11, 14, 34, 35, 92, 93, 0, 11, 14, 39, 40, 0, 11, 14, 0, 11, 14, 1, 1);
      Hi    : constant Table := (8, 12, 31, 33, 34, 38, 39, 91, 92, 1114111, 8, 12, 31, 33, 38, 91, 92, 1114111, 9, 12, 33, 34, 91, 92, 1114111, 9, 12, 38, 39, 1114111, 9, 12, 1114111, 9, 12, 1114111, 0, 0);
      To    : constant Table := (1, 1, 1, 1, 2, 1, 3, 1, 4, 1, 1, 1, 1, 1, 1, 1, 4, 1, 2, 2, 2, 5, 2, 6, 2, 3, 3, 3, 5, 3, 1, 1, 1, 2, 2, 2, 0, 0);
      First : constant Table := (0, 10, 18, 25, 30, 33, 33, 36);
      Acc   : constant Table := (0, 1, 0, 0, 0, 1, 0, 0);
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
   end Scan_Name;

   function Scan_Value (S : String; Pos, Len : Natural) return Natural is
      type Table is array (Natural range <>) of Natural;
      Lo    : constant Table := (0, 11, 14, 33, 34, 36, 39, 40, 92, 93, 0, 11, 14, 33, 36, 40, 92, 93, 0, 11, 14, 34, 35, 92, 93, 0, 11, 14, 39, 40, 0, 11, 14, 0, 11, 14, 1, 1);
      Hi    : constant Table := (8, 12, 31, 33, 34, 38, 39, 91, 92, 1114111, 8, 12, 31, 33, 38, 91, 92, 1114111, 9, 12, 33, 34, 91, 92, 1114111, 9, 12, 38, 39, 1114111, 9, 12, 1114111, 9, 12, 1114111, 0, 0);
      To    : constant Table := (1, 1, 1, 1, 2, 1, 3, 1, 4, 1, 1, 1, 1, 1, 1, 1, 4, 1, 2, 2, 2, 5, 2, 6, 2, 3, 3, 3, 5, 3, 1, 1, 1, 2, 2, 2, 0, 0);
      First : constant Table := (0, 10, 18, 25, 30, 33, 33, 36);
      Acc   : constant Table := (0, 1, 0, 0, 0, 1, 0, 0);
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
   end Scan_Value;

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
               O := 0;
               Match := True;
               if Match then
                  N := Decode_Utf8 (S, Pos + Off + O, Len, Cp);
                  Match := N > 0 and then (Cp >= 9 and then Cp <= 9);
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

   function Scan_Blanks (S : String; Pos, Len : Natural) return Natural is
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
               O := 0;
               Match := True;
               if Match then
                  N := Decode_Utf8 (S, Pos + Off + O, Len, Cp);
                  Match := N > 0 and then (Cp >= 9 and then Cp <= 9);
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
   end Scan_Blanks;

   function Scan_Blank_char (S : String; Pos, Len : Natural) return Natural is
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
         Ok := N > 0 and then (Cp >= 32 and then Cp <= 32);
         if Ok then Off := Off + N; end if;
      end if;
      if Ok and then Off > Best then Best := Off; end if;
      Off := 0;
      Ok := True;
      if Ok then
         N := Decode_Utf8 (S, Pos + Off, Len, Cp);
         Ok := N > 0 and then (Cp >= 9 and then Cp <= 9);
         if Ok then Off := Off + N; end if;
      end if;
      if Ok and then Off > Best then Best := Off; end if;
      return Best;
   end Scan_Blank_char;

   function Scan_Rune (S : String; Pos, Len : Natural) return Natural is
      Cp  : Natural;
      N   : Natural;
      Off : Natural := 0;
   begin
      N := Decode_Utf8 (S, Pos + Off, Len, Cp);
      if N = 0 or else not (Cp <= 1114111) then return 0; end if;
      Off := Off + N;
      return Off;
   end Scan_Rune;

   function Scan_CRLF (S : String; Pos, Len : Natural) return Natural is
      Cp  : Natural;
      N   : Natural;
      Off : Natural := 0;
   begin
      N := Decode_Utf8 (S, Pos + Off, Len, Cp);
      if N = 0 or else not (Cp >= 13 and then Cp <= 13) then return 0; end if;
      Off := Off + N;
      N := Decode_Utf8 (S, Pos + Off, Len, Cp);
      if N = 0 or else not (Cp >= 10 and then Cp <= 10) then return 0; end if;
      Off := Off + N;
      return Off;
   end Scan_CRLF;

   function Scan_LF (S : String; Pos, Len : Natural) return Natural is
      Cp  : Natural;
      N   : Natural;
      Off : Natural := 0;
   begin
      N := Decode_Utf8 (S, Pos + Off, Len, Cp);
      if N = 0 or else not (Cp >= 10 and then Cp <= 10) then return 0; end if;
      Off := Off + N;
      return Off;
   end Scan_LF;

   function Scan_CR (S : String; Pos, Len : Natural) return Natural is
      Cp  : Natural;
      N   : Natural;
      Off : Natural := 0;
   begin
      N := Decode_Utf8 (S, Pos + Off, Len, Cp);
      if N = 0 or else not (Cp >= 13 and then Cp <= 13) then return 0; end if;
      Off := Off + N;
      return Off;
   end Scan_CR;

   function Scan_Tail_1 (S : String; Pos, Len : Natural) return Natural is
      type Table is array (Natural range <>) of Natural;
      Lo    : constant Table := (35, 0, 11, 14, 1, 1);
      Hi    : constant Table := (35, 9, 12, 1114111, 0, 0);
      To    : constant Table := (1, 1, 1, 1, 0, 0);
      First : constant Table := (0, 1, 4);
      Acc   : constant Table := (1, 1, 0);
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
   end Scan_Tail_1;

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

   procedure Dealloc_Line is new Ada.Unchecked_Deallocation (Line_Type, Line_Access);
   procedure Dealloc_Directive_line is new Ada.Unchecked_Deallocation (Directive_line_Type, Directive_line_Access);
   procedure Dealloc_Directive is new Ada.Unchecked_Deallocation (Directive_Type, Directive_Access);
   procedure Dealloc_Param is new Ada.Unchecked_Deallocation (Param_Type, Param_Access);
   procedure Dealloc_Other_line is new Ada.Unchecked_Deallocation (Other_line_Type, Other_line_Access);
   procedure Dealloc_Tail is new Ada.Unchecked_Deallocation (Tail_Type, Tail_Access);
   procedure Dealloc_Line_end is new Ada.Unchecked_Deallocation (Line_end_Type, Line_end_Access);

   procedure Free_Config (V : in out Config_Type) is
   begin
   for K in V.First_Index .. V.Last_Index loop
      declare
         E : Line_Access := V (K);
      begin
         if E /= null then
            Free_Line (E.all);
            V.Replace_Element (K, null);
            Dealloc_Line (E);
         end if;
      end;
   end loop;
   end Free_Config;

   procedure Free_Line (V : in out Line_Type) is
   begin
   if V.Directive_line /= null then
      Free_Directive_line (V.Directive_line.all);
      Dealloc_Directive_line (V.Directive_line);
   end if;
   if V.Other_line /= null then
      Free_Other_line (V.Other_line.all);
      Dealloc_Other_line (V.Other_line);
   end if;
   end Free_Line;

   procedure Free_Directive_line (V : in out Directive_line_Type) is
   begin
   if V.Directive /= null then
      Free_Directive (V.Directive.all);
      Dealloc_Directive (V.Directive);
   end if;
   if V.Tail /= null then
      Free_Tail (V.Tail.all);
      Dealloc_Tail (V.Tail);
   end if;
   end Free_Directive_line;

   procedure Free_Directive (V : in out Directive_Type) is
   begin
   Free_Params (V.Params);
   end Free_Directive;

   procedure Free_Params (V : in out Params_Type) is
   begin
   for K in V.First_Index .. V.Last_Index loop
      declare
         E : Param_Access := V (K);
      begin
         if E /= null then
            Free_Param (E.all);
            V.Replace_Element (K, null);
            Dealloc_Param (E);
         end if;
      end;
   end loop;
   end Free_Params;

   procedure Free_Param (V : in out Param_Type) is
      pragma Unreferenced (V);
   begin
      null;
   end Free_Param;

   procedure Free_Other_line (V : in out Other_line_Type) is
   begin
   if V.Tail /= null then
      Free_Tail (V.Tail.all);
      Dealloc_Tail (V.Tail);
   end if;
   end Free_Other_line;

   procedure Free_Tail (V : in out Tail_Type) is
   begin
   if V.Line_end /= null then
      Free_Line_end (V.Line_end.all);
      Dealloc_Line_end (V.Line_end);
   end if;
   end Free_Tail;

   procedure Free_Line_end (V : in out Line_end_Type) is
      pragma Unreferenced (V);
   begin
      null;
   end Free_Line_end;

   function Parse_Config (P : in out Parser) return Config_Type;
   function Parse_Line (P : in out Parser) return Line_Type;
   function Parse_Directive_line (P : in out Parser) return Directive_line_Type;
   function Parse_Directive_start (P : in out Parser) return Directive_start_Type;
   function Parse_Directive (P : in out Parser) return Directive_Type;
   function Parse_Name (P : in out Parser) return Name_Type;
   function Parse_Params (P : in out Parser) return Params_Type;
   function Parse_Param (P : in out Parser) return Param_Type;
   function Parse_Value (P : in out Parser) return Value_Type;
   function Parse_Other_line (P : in out Parser) return Other_line_Type;
   function Parse_Tail (P : in out Parser) return Tail_Type;
   function Parse_Lead (P : in out Parser) return Lead_Type;
   function Parse_Blanks (P : in out Parser) return Blanks_Type;
   function Parse_Line_end (P : in out Parser) return Line_end_Type;
   function Parse_Blank_char (P : in out Parser) return Blank_char_Type;
   function Parse_Rune (P : in out Parser) return Rune_Type;
   function Parse_CRLF (P : in out Parser) return CRLF_Type;
   function Parse_LF (P : in out Parser) return LF_Type;
   function Parse_CR (P : in out Parser) return CR_Type;
   function Parse_Word (P : in out Parser) return Word_Type;
   function Parse_Int (P : in out Parser) return Int_Type;
   function Parse_Str (P : in out Parser) return Str_Type;
   function Parse_Ws (P : in out Parser) return Ws_Type;
   function Parse_Tail_1 (P : in out Parser) return Tail_1_Type;

   function Body_Of_Config (P : in out Parser) return Config_Type is
   R : Config_Type;
   begin
      loop
         declare
            Start : constant Natural := P.Pos;
         begin
            declare V : Line_Type := Parse_Line (P); begin if P.Failed then P.Failed := False; P.Pos := Start; exit; end if; R.Append (new Line_Type'(V)); end;
            exit when P.Pos = Start;
         end;
      end loop;
      return R;
   end Body_Of_Config;

   function Parse_Config (P : in out Parser) return Config_Type is
   begin
      Enter (P, 1);
      declare
         R : constant Config_Type := Body_Of_Config (P);
      begin
         P.Depth := P.Depth - 1;
         return R;
      end;
   end Parse_Config;

   function Body_Of_Line (P : in out Parser) return Line_Type is
   R : Line_Type;
   begin
      declare
         Save : constant Natural := P.Pos;
      begin
         declare
            R : Line_Type;
         begin
            declare V : Directive_line_Type := Parse_Directive_line (P); begin if P.Failed then goto Alt_Fail_1; end if; R.Directive_line := new Directive_line_Type'(V); end;
            return R;
            <<Alt_Fail_1>> null;
         end;
         P.Failed := False; P.Pos := Save;
         declare
            R : Line_Type;
         begin
            declare V : Other_line_Type := Parse_Other_line (P); begin if P.Failed then goto Alt_Fail_2; end if; R.Other_line := new Other_line_Type'(V); end;
            return R;
            <<Alt_Fail_2>> null;
         end;
         P.Failed := False; P.Pos := Save;
         P.Pos := Save;
         Fail (P, "a line");
         return R;
      end;
   end Body_Of_Line;

   function Parse_Line (P : in out Parser) return Line_Type is
   begin
      Enter (P, 2);
      declare
         R : constant Line_Type := Body_Of_Line (P);
      begin
         P.Depth := P.Depth - 1;
         return R;
      end;
   end Parse_Line;

   function Body_Of_Directive_line (P : in out Parser) return Directive_line_Type is
   R : Directive_line_Type;
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
            if Ok then declare N : constant Natural := Scan_Directive_start (P.Text.all, P.Pos, Limit (P)); begin if N > 0 then P.Pos := P.Pos + N; else Ok := False; end if; end; end if;
            if Ok then Hit := True; end if;
         end if;
         P := Sv;
         if not Hit then Fail (P, "directive-start"); return R; end if;
      end;
      declare
         N : constant Natural := Scan_Lead (P.Text.all, P.Pos, Limit (P));
      begin
         R.Lead := To_Unbounded_String (P.Text (P.Pos .. P.Pos + N - 1)); P.Pos := P.Pos + N;
      end;
      declare V : Directive_Type := Parse_Directive (P); begin if P.Failed then return R; end if; R.Directive := new Directive_Type'(V); end;
      declare V : Tail_Type := Parse_Tail (P); begin if P.Failed then return R; end if; R.Tail := new Tail_Type'(V); end;
      return R;
   end Body_Of_Directive_line;

   function Parse_Directive_line (P : in out Parser) return Directive_line_Type is
   begin
      Enter (P, 3);
      declare
         R : constant Directive_line_Type := Body_Of_Directive_line (P);
      begin
         P.Depth := P.Depth - 1;
         return R;
      end;
   end Parse_Directive_line;

   function Body_Of_Directive_start (P : in out Parser) return Directive_start_Type is
   R : Directive_start_Type;
   begin
      declare
         N : constant Natural := Scan_Directive_start (P.Text.all, P.Pos, Limit (P));
      begin
         if N = 0 then Fail (P, "directive-start"); return R; end if;
         R := To_Unbounded_String (P.Text (P.Pos .. P.Pos + N - 1));
         P.Pos := P.Pos + N;
         return R;
      end;
   end Body_Of_Directive_start;

   function Parse_Directive_start (P : in out Parser) return Directive_start_Type is
   begin
      Enter (P, 4);
      declare
         R : constant Directive_start_Type := Body_Of_Directive_start (P);
      begin
         P.Depth := P.Depth - 1;
         return R;
      end;
   end Parse_Directive_start;

   function Body_Of_Directive (P : in out Parser) return Directive_Type is
   R : Directive_Type;
   begin
      declare
         N : constant Natural := Scan_Name (P.Text.all, P.Pos, Limit (P));
      begin
         if N = 0 then Fail (P, "name"); return R; end if;
         R.Name := To_Unbounded_String (P.Text (P.Pos .. P.Pos + N - 1)); P.Pos := P.Pos + N;
      end;
      R.Params := Parse_Params (P); if P.Failed then return R; end if;
      return R;
   end Body_Of_Directive;

   function Parse_Directive (P : in out Parser) return Directive_Type is
   begin
      Enter (P, 5);
      declare
         R : constant Directive_Type := Body_Of_Directive (P);
      begin
         P.Depth := P.Depth - 1;
         return R;
      end;
   end Parse_Directive;

   function Body_Of_Name (P : in out Parser) return Name_Type is
   R : Name_Type;
   begin
      declare
         N : constant Natural := Scan_Name (P.Text.all, P.Pos, Limit (P));
      begin
         if N = 0 then Fail (P, "name"); return R; end if;
         R := To_Unbounded_String (P.Text (P.Pos .. P.Pos + N - 1));
         P.Pos := P.Pos + N;
         return R;
      end;
   end Body_Of_Name;

   function Parse_Name (P : in out Parser) return Name_Type is
   begin
      Enter (P, 6);
      declare
         R : constant Name_Type := Body_Of_Name (P);
      begin
         P.Depth := P.Depth - 1;
         return R;
      end;
   end Parse_Name;

   function Body_Of_Params (P : in out Parser) return Params_Type is
   R : Params_Type;
   begin
      loop
         declare
            Start : constant Natural := P.Pos;
         begin
            if P.Pos > Limit (P) then P.Pos := Start; exit; end if;
            declare V : Param_Type := Parse_Param (P); begin if P.Failed then P.Failed := False; P.Pos := Start; exit; end if; R.Append (new Param_Type'(V)); end;
         end;
      end loop;
      return R;
   end Body_Of_Params;

   function Parse_Params (P : in out Parser) return Params_Type is
   begin
      Enter (P, 7);
      declare
         R : constant Params_Type := Body_Of_Params (P);
      begin
         P.Depth := P.Depth - 1;
         return R;
      end;
   end Parse_Params;

   function Body_Of_Param (P : in out Parser) return Param_Type is
   R : Param_Type;
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
            if Ok then declare N : constant Natural := Scan_Blank_char (P.Text.all, P.Pos, Limit (P)); begin if N > 0 then P.Pos := P.Pos + N; else Ok := False; end if; end; end if;
            if Ok then Hit := True; end if;
         end if;
         P := Sv;
         if not Hit then Fail (P, "blank-char"); return R; end if;
      end;
      declare
         N : constant Natural := Scan_Blanks (P.Text.all, P.Pos, Limit (P));
      begin
         if N = 0 then Fail (P, "blanks"); return R; end if;
         R.Blanks := To_Unbounded_String (P.Text (P.Pos .. P.Pos + N - 1)); P.Pos := P.Pos + N;
      end;
      declare
         N : constant Natural := Scan_Value (P.Text.all, P.Pos, Limit (P));
      begin
         if N = 0 then Fail (P, "value"); return R; end if;
         R.Value := To_Unbounded_String (P.Text (P.Pos .. P.Pos + N - 1)); P.Pos := P.Pos + N;
      end;
      return R;
   end Body_Of_Param;

   function Parse_Param (P : in out Parser) return Param_Type is
   begin
      Enter (P, 8);
      declare
         R : constant Param_Type := Body_Of_Param (P);
      begin
         P.Depth := P.Depth - 1;
         return R;
      end;
   end Parse_Param;

   function Body_Of_Value (P : in out Parser) return Value_Type is
   R : Value_Type;
   begin
      declare
         N : constant Natural := Scan_Value (P.Text.all, P.Pos, Limit (P));
      begin
         if N = 0 then Fail (P, "value"); return R; end if;
         R := To_Unbounded_String (P.Text (P.Pos .. P.Pos + N - 1));
         P.Pos := P.Pos + N;
         return R;
      end;
   end Body_Of_Value;

   function Parse_Value (P : in out Parser) return Value_Type is
   begin
      Enter (P, 9);
      declare
         R : constant Value_Type := Body_Of_Value (P);
      begin
         P.Depth := P.Depth - 1;
         return R;
      end;
   end Parse_Value;

   function Body_Of_Other_line (P : in out Parser) return Other_line_Type is
   R : Other_line_Type;
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
            if Ok then declare N : constant Natural := Scan_Rune (P.Text.all, P.Pos, Limit (P)); begin if N > 0 then P.Pos := P.Pos + N; else Ok := False; end if; end; end if;
            if Ok then Hit := True; end if;
         end if;
         P := Sv;
         if not Hit then Fail (P, "rune"); return R; end if;
      end;
      declare
         N : constant Natural := Scan_Lead (P.Text.all, P.Pos, Limit (P));
      begin
         R.Lead := To_Unbounded_String (P.Text (P.Pos .. P.Pos + N - 1)); P.Pos := P.Pos + N;
      end;
      declare V : Tail_Type := Parse_Tail (P); begin if P.Failed then return R; end if; R.Tail := new Tail_Type'(V); end;
      return R;
   end Body_Of_Other_line;

   function Parse_Other_line (P : in out Parser) return Other_line_Type is
   begin
      Enter (P, 10);
      declare
         R : constant Other_line_Type := Body_Of_Other_line (P);
      begin
         P.Depth := P.Depth - 1;
         return R;
      end;
   end Parse_Other_line;

   function Body_Of_Tail (P : in out Parser) return Tail_Type is
   R : Tail_Type;
   begin
      declare
         N : constant Natural := Scan_Lead (P.Text.all, P.Pos, Limit (P));
      begin
         R.Lead := To_Unbounded_String (P.Text (P.Pos .. P.Pos + N - 1)); P.Pos := P.Pos + N;
      end;
      declare
         N : constant Natural := Scan_Tail_1 (P.Text.all, P.Pos, Limit (P));
      begin
         R.Tail_1 := To_Unbounded_String (P.Text (P.Pos .. P.Pos + N - 1)); P.Pos := P.Pos + N;
      end;
      declare V : Line_end_Type := Parse_Line_end (P); begin if P.Failed then return R; end if; R.Line_end := new Line_end_Type'(V); end;
      return R;
   end Body_Of_Tail;

   function Parse_Tail (P : in out Parser) return Tail_Type is
   begin
      Enter (P, 11);
      declare
         R : constant Tail_Type := Body_Of_Tail (P);
      begin
         P.Depth := P.Depth - 1;
         return R;
      end;
   end Parse_Tail;

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
      Enter (P, 12);
      declare
         R : constant Lead_Type := Body_Of_Lead (P);
      begin
         P.Depth := P.Depth - 1;
         return R;
      end;
   end Parse_Lead;

   function Body_Of_Blanks (P : in out Parser) return Blanks_Type is
   R : Blanks_Type;
   begin
      declare
         N : constant Natural := Scan_Blanks (P.Text.all, P.Pos, Limit (P));
      begin
         if N = 0 then Fail (P, "blanks"); return R; end if;
         R := To_Unbounded_String (P.Text (P.Pos .. P.Pos + N - 1));
         P.Pos := P.Pos + N;
         return R;
      end;
   end Body_Of_Blanks;

   function Parse_Blanks (P : in out Parser) return Blanks_Type is
   begin
      Enter (P, 13);
      declare
         R : constant Blanks_Type := Body_Of_Blanks (P);
      begin
         P.Depth := P.Depth - 1;
         return R;
      end;
   end Parse_Blanks;

   function Body_Of_Line_end (P : in out Parser) return Line_end_Type is
   R : Line_end_Type;
   begin
      declare
         Save : constant Natural := P.Pos;
      begin
         declare
            R : Line_end_Type;
         begin
            declare
               N : constant Natural := Scan_CRLF (P.Text.all, P.Pos, Limit (P));
            begin
               if N = 0 then Fail (P, "CRLF"); goto Alt_Fail_3; end if;
               R.CRLF := To_Unbounded_String (P.Text (P.Pos .. P.Pos + N - 1)); P.Pos := P.Pos + N;
            end;
            return R;
            <<Alt_Fail_3>> null;
         end;
         P.Failed := False; P.Pos := Save;
         declare
            R : Line_end_Type;
         begin
            declare
               N : constant Natural := Scan_LF (P.Text.all, P.Pos, Limit (P));
            begin
               if N = 0 then Fail (P, "LF"); goto Alt_Fail_4; end if;
               R.LF := To_Unbounded_String (P.Text (P.Pos .. P.Pos + N - 1)); P.Pos := P.Pos + N;
            end;
            return R;
            <<Alt_Fail_4>> null;
         end;
         P.Failed := False; P.Pos := Save;
         declare
            R : Line_end_Type;
         begin
            declare
               N : constant Natural := Scan_CR (P.Text.all, P.Pos, Limit (P));
            begin
               if N = 0 then Fail (P, "CR"); goto Alt_Fail_5; end if;
               R.CR := To_Unbounded_String (P.Text (P.Pos .. P.Pos + N - 1)); P.Pos := P.Pos + N;
            end;
            return R;
            <<Alt_Fail_5>> null;
         end;
         P.Failed := False; P.Pos := Save;
         declare
            R : Line_end_Type;
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
                  if Ok then declare N : constant Natural := Scan_Rune (P.Text.all, P.Pos, Limit (P)); begin if N > 0 then P.Pos := P.Pos + N; else Ok := False; end if; end; end if;
                  if Ok then Hit := True; end if;
               end if;
               P := Sv;
               if Hit then Fail (P, "something other than rune"); goto Alt_Fail_6; end if;
            end;
            return R;
            <<Alt_Fail_6>> null;
         end;
         P.Failed := False; P.Pos := Save;
         P.Pos := Save;
         Fail (P, "a line-end");
         return R;
      end;
   end Body_Of_Line_end;

   function Parse_Line_end (P : in out Parser) return Line_end_Type is
   begin
      Enter (P, 15);
      declare
         R : constant Line_end_Type := Body_Of_Line_end (P);
      begin
         P.Depth := P.Depth - 1;
         return R;
      end;
   end Parse_Line_end;

   function Body_Of_Blank_char (P : in out Parser) return Blank_char_Type is
   R : Blank_char_Type;
   begin
      declare
         N : constant Natural := Scan_Blank_char (P.Text.all, P.Pos, Limit (P));
      begin
         if N = 0 then Fail (P, "blank-char"); return R; end if;
         R := To_Unbounded_String (P.Text (P.Pos .. P.Pos + N - 1));
         P.Pos := P.Pos + N;
         return R;
      end;
   end Body_Of_Blank_char;

   function Parse_Blank_char (P : in out Parser) return Blank_char_Type is
   begin
      Enter (P, 25);
      declare
         R : constant Blank_char_Type := Body_Of_Blank_char (P);
      begin
         P.Depth := P.Depth - 1;
         return R;
      end;
   end Parse_Blank_char;

   function Body_Of_Rune (P : in out Parser) return Rune_Type is
   R : Rune_Type;
   begin
      declare
         N : constant Natural := Scan_Rune (P.Text.all, P.Pos, Limit (P));
      begin
         if N = 0 then Fail (P, "rune"); return R; end if;
         R := To_Unbounded_String (P.Text (P.Pos .. P.Pos + N - 1));
         P.Pos := P.Pos + N;
         return R;
      end;
   end Body_Of_Rune;

   function Parse_Rune (P : in out Parser) return Rune_Type is
   begin
      Enter (P, 26);
      declare
         R : constant Rune_Type := Body_Of_Rune (P);
      begin
         P.Depth := P.Depth - 1;
         return R;
      end;
   end Parse_Rune;

   function Body_Of_CRLF (P : in out Parser) return CRLF_Type is
   R : CRLF_Type;
   begin
      declare
         N : constant Natural := Scan_CRLF (P.Text.all, P.Pos, Limit (P));
      begin
         if N = 0 then Fail (P, "CRLF"); return R; end if;
         R := To_Unbounded_String (P.Text (P.Pos .. P.Pos + N - 1));
         P.Pos := P.Pos + N;
         return R;
      end;
   end Body_Of_CRLF;

   function Parse_CRLF (P : in out Parser) return CRLF_Type is
   begin
      Enter (P, 27);
      declare
         R : constant CRLF_Type := Body_Of_CRLF (P);
      begin
         P.Depth := P.Depth - 1;
         return R;
      end;
   end Parse_CRLF;

   function Body_Of_LF (P : in out Parser) return LF_Type is
   R : LF_Type;
   begin
      declare
         N : constant Natural := Scan_LF (P.Text.all, P.Pos, Limit (P));
      begin
         if N = 0 then Fail (P, "LF"); return R; end if;
         R := To_Unbounded_String (P.Text (P.Pos .. P.Pos + N - 1));
         P.Pos := P.Pos + N;
         return R;
      end;
   end Body_Of_LF;

   function Parse_LF (P : in out Parser) return LF_Type is
   begin
      Enter (P, 28);
      declare
         R : constant LF_Type := Body_Of_LF (P);
      begin
         P.Depth := P.Depth - 1;
         return R;
      end;
   end Parse_LF;

   function Body_Of_CR (P : in out Parser) return CR_Type is
   R : CR_Type;
   begin
      declare
         N : constant Natural := Scan_CR (P.Text.all, P.Pos, Limit (P));
      begin
         if N = 0 then Fail (P, "CR"); return R; end if;
         R := To_Unbounded_String (P.Text (P.Pos .. P.Pos + N - 1));
         P.Pos := P.Pos + N;
         return R;
      end;
   end Body_Of_CR;

   function Parse_CR (P : in out Parser) return CR_Type is
   begin
      Enter (P, 29);
      declare
         R : constant CR_Type := Body_Of_CR (P);
      begin
         P.Depth := P.Depth - 1;
         return R;
      end;
   end Parse_CR;

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
      Enter (P, 37);
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
      Enter (P, 38);
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
      Enter (P, 39);
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
      Enter (P, 40);
      declare
         R : constant Ws_Type := Body_Of_Ws (P);
      begin
         P.Depth := P.Depth - 1;
         return R;
      end;
   end Parse_Ws;

   function Body_Of_Tail_1 (P : in out Parser) return Tail_1_Type is
   R : Tail_1_Type;
   Save : Natural;
   begin
      declare
         N : constant Natural := Scan_Tail_1 (P.Text.all, P.Pos, Limit (P));
      begin
         R := To_Unbounded_String (P.Text (P.Pos .. P.Pos + N - 1));
         P.Pos := P.Pos + N;
         return R;
      end;
   end Body_Of_Tail_1;

   function Parse_Tail_1 (P : in out Parser) return Tail_1_Type is
   begin
      Enter (P, 41);
      declare
         R : constant Tail_1_Type := Body_Of_Tail_1 (P);
      begin
         P.Depth := P.Depth - 1;
         return R;
      end;
   end Parse_Tail_1;

   function Rule_Name (I : Natural) return String is
     (case I is
        when 1 => "config",
        when 2 => "line",
        when 3 => "directive-line",
        when 4 => "directive-start",
        when 5 => "directive",
        when 6 => "name",
        when 7 => "params",
        when 8 => "param",
        when 9 => "value",
        when 10 => "other-line",
        when 11 => "tail",
        when 12 => "lead",
        when 13 => "blanks",
        when 14 => "comment",
        when 15 => "line-end",
        when 16 => "cmd-word",
        when 17 => "word-start",
        when 18 => "bare",
        when 19 => "quoted",
        when 20 => "single-quoted",
        when 21 => "escaped",
        when 22 => "bare-char",
        when 23 => "dq-char",
        when 24 => "sq-char",
        when 25 => "blank-char",
        when 26 => "rune",
        when 27 => "CRLF",
        when 28 => "LF",
        when 29 => "CR",
        when 30 => "SP",
        when 31 => "HTAB",
        when 32 => "not-x0-9_B-C_E-10FFFF",
        when 33 => "not-x0-8_B-C_E-1F_21-22_24-10FFFF",
        when 34 => "not-x0-8_B-C_E-1F_21_24-26_28-5B_5D-10FFFF",
        when 35 => "not-x0-9_B-C_E-21_23-5B_5D-10FFFF",
        when 36 => "not-x0-9_B-C_E-26_28-10FFFF",
        when 37 => "word",
        when 38 => "int",
        when 39 => "str",
        when 40 => "ws",
        when 41 => "",
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
   
   function Parse_Text (Text : String) return Config_Type is
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
      R : Config_Type;
   begin
      begin
         R := Parse_Config (P);
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

end Scfg.Parser;

