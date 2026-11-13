
with Interfaces;
with Ada.Unchecked_Deallocation;

package body Http_Range.Parser is

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

   function Scan_Ows (S : String; Pos, Len : Natural) return Natural is
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
   end Scan_Ows;

   function Scan_DIGIT (S : String; Pos, Len : Natural) return Natural is
      Cp  : Natural;
      N   : Natural;
      Off : Natural := 0;
   begin
      N := Decode_Utf8 (S, Pos + Off, Len, Cp);
      if N = 0 or else not (Cp >= 48 and then Cp <= 57) then return 0; end if;
      Off := Off + N;
      return Off;
   end Scan_DIGIT;

   function Scan_Ows_2 (S : String; Pos, Len : Natural) return Natural is
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
   end Scan_Ows_2;

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

   procedure Dealloc_Byte_ranges is new Ada.Unchecked_Deallocation (Byte_ranges_Type, Byte_ranges_Access);
   procedure Dealloc_Range_spec is new Ada.Unchecked_Deallocation (Range_spec_Type, Range_spec_Access);
   procedure Dealloc_From_to is new Ada.Unchecked_Deallocation (From_to_Type, From_to_Access);
   procedure Dealloc_Suffix is new Ada.Unchecked_Deallocation (Suffix_Type, Suffix_Access);
   procedure Dealloc_Range_spec_1 is new Ada.Unchecked_Deallocation (Range_spec_1_Type, Range_spec_1_Access);

   procedure Free_Byte_ranges (V : in out Byte_ranges_Type) is
   begin
   if V.Range_spec /= null then
      Free_Range_spec (V.Range_spec.all);
      Dealloc_Range_spec (V.Range_spec);
   end if;
   Free_Byte_ranges_1 (V.Byte_ranges_1);
   end Free_Byte_ranges;

   procedure Free_Range_spec (V : in out Range_spec_Type) is
   begin
   if V.Range_spec_1 /= null then
      Free_Range_spec_1 (V.Range_spec_1.all);
      Dealloc_Range_spec_1 (V.Range_spec_1);
   end if;
   end Free_Range_spec;

   procedure Free_From_to (V : in out From_to_Type) is
   begin
   Free_From_to_1 (V.From_to_1);
   end Free_From_to;

   procedure Free_Suffix (V : in out Suffix_Type) is
      pragma Unreferenced (V);
   begin
      null;
   end Free_Suffix;

   procedure Free_Byte_ranges_1 (V : in out Byte_ranges_1_Type) is
   begin
   for K in V.First_Index .. V.Last_Index loop
      declare
         E : Byte_ranges_1_Entry := V (K);
      begin
   if E.Range_spec /= null then
      Free_Range_spec (E.Range_spec.all);
      Dealloc_Range_spec (E.Range_spec);
   end if;
         V.Replace_Element (K, E);
      end;
   end loop;
   end Free_Byte_ranges_1;

   procedure Free_Range_spec_1 (V : in out Range_spec_1_Type) is
   begin
   if V.From_to /= null then
      Free_From_to (V.From_to.all);
      Dealloc_From_to (V.From_to);
   end if;
   if V.Suffix /= null then
      Free_Suffix (V.Suffix.all);
      Dealloc_Suffix (V.Suffix);
   end if;
   end Free_Range_spec_1;

   procedure Free_From_to_1 (V : in out From_to_1_Type) is
      pragma Unreferenced (V);
   begin
      null;
   end Free_From_to_1;

   function Parse_Byte_ranges (P : in out Parser) return Byte_ranges_Type;
   function Parse_Range_spec (P : in out Parser) return Range_spec_Type;
   function Parse_From_to (P : in out Parser) return From_to_Type;
   function Parse_Suffix (P : in out Parser) return Suffix_Type;
   function Parse_First (P : in out Parser) return First_Type;
   function Parse_Last (P : in out Parser) return Last_Type;
   function Parse_Amount (P : in out Parser) return Amount_Type;
   function Parse_Ows (P : in out Parser) return Ows_Type;
   function Parse_DIGIT (P : in out Parser) return DIGIT_Type;
   function Parse_Word (P : in out Parser) return Word_Type;
   function Parse_Int (P : in out Parser) return Int_Type;
   function Parse_Str (P : in out Parser) return Str_Type;
   function Parse_Ws (P : in out Parser) return Ws_Type;
   function Parse_Byte_ranges_1 (P : in out Parser) return Byte_ranges_1_Type;
   function Parse_Range_spec_1 (P : in out Parser) return Range_spec_1_Type;
   function Parse_From_to_1 (P : in out Parser) return From_to_1_Type;
   function Parse_Ows_2 (P : in out Parser) return Ows_2_Type;

   function Body_Of_Byte_ranges (P : in out Parser) return Byte_ranges_Type is
   R : Byte_ranges_Type;
   begin
      Expect_Lit (P, "bytes="); if P.Failed then return R; end if;
      declare V : Range_spec_Type := Parse_Range_spec (P); begin if P.Failed then return R; end if; R.Range_spec := new Range_spec_Type'(V); end;
      R.Byte_ranges_1 := Parse_Byte_ranges_1 (P); if P.Failed then return R; end if;
      return R;
   end Body_Of_Byte_ranges;

   function Parse_Byte_ranges (P : in out Parser) return Byte_ranges_Type is
   begin
      Enter (P, 1);
      declare
         R : constant Byte_ranges_Type := Body_Of_Byte_ranges (P);
      begin
         P.Depth := P.Depth - 1;
         return R;
      end;
   end Parse_Byte_ranges;

   function Body_Of_Range_spec (P : in out Parser) return Range_spec_Type is
   R : Range_spec_Type;
   begin
      declare
         N : constant Natural := Scan_Ows (P.Text.all, P.Pos, Limit (P));
      begin
         R.Ows := To_Unbounded_String (P.Text (P.Pos .. P.Pos + N - 1)); P.Pos := P.Pos + N;
      end;
      declare V : Range_spec_1_Type := Parse_Range_spec_1 (P); begin if P.Failed then return R; end if; R.Range_spec_1 := new Range_spec_1_Type'(V); end;
      declare
         N : constant Natural := Scan_Ows_2 (P.Text.all, P.Pos, Limit (P));
      begin
         R.Ows_2 := To_Unbounded_String (P.Text (P.Pos .. P.Pos + N - 1)); P.Pos := P.Pos + N;
      end;
      return R;
   end Body_Of_Range_spec;

   function Parse_Range_spec (P : in out Parser) return Range_spec_Type is
   begin
      Enter (P, 2);
      declare
         R : constant Range_spec_Type := Body_Of_Range_spec (P);
      begin
         P.Depth := P.Depth - 1;
         return R;
      end;
   end Parse_Range_spec;

   function Body_Of_From_to (P : in out Parser) return From_to_Type is
   R : From_to_Type;
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
            if Ok then declare N : constant Natural := Scan_DIGIT (P.Text.all, P.Pos, Limit (P)); begin if N > 0 then P.Pos := P.Pos + N; else Ok := False; end if; end; end if;
            if Ok then Hit := True; end if;
         end if;
         P := Sv;
         if not Hit then Fail (P, "DIGIT"); return R; end if;
      end;
      R.First := Parse_First (P); if P.Failed then return R; end if;
      Expect_Lit (P, "-"); if P.Failed then return R; end if;
      R.From_to_1 := Parse_From_to_1 (P); if P.Failed then return R; end if;
      return R;
   end Body_Of_From_to;

   function Parse_From_to (P : in out Parser) return From_to_Type is
   begin
      Enter (P, 3);
      declare
         R : constant From_to_Type := Body_Of_From_to (P);
      begin
         P.Depth := P.Depth - 1;
         return R;
      end;
   end Parse_From_to;

   function Body_Of_Suffix (P : in out Parser) return Suffix_Type is
   R : Suffix_Type;
   begin
      Expect_Lit (P, "-"); if P.Failed then return R; end if;
      R.Amount := Parse_Amount (P); if P.Failed then return R; end if;
      return R;
   end Body_Of_Suffix;

   function Parse_Suffix (P : in out Parser) return Suffix_Type is
   begin
      Enter (P, 4);
      declare
         R : constant Suffix_Type := Body_Of_Suffix (P);
      begin
         P.Depth := P.Depth - 1;
         return R;
      end;
   end Parse_Suffix;

   function Body_Of_First (P : in out Parser) return First_Type is
   R : First_Type;
   begin
      declare
         N : constant Natural := Scan_Int (P.Text.all, P.Pos, Limit (P));
      begin
         if N = 0 then Fail (P, "a number"); return R; end if;
         R := Long_Long_Integer'Value (P.Text (P.Pos .. P.Pos + N - 1)); P.Pos := P.Pos + N;
         return R;
      end;
   end Body_Of_First;

   function Parse_First (P : in out Parser) return First_Type is
   begin
      Enter (P, 5);
      declare
         R : constant First_Type := Body_Of_First (P);
      begin
         P.Depth := P.Depth - 1;
         return R;
      end;
   end Parse_First;

   function Body_Of_Last (P : in out Parser) return Last_Type is
   R : Last_Type;
   begin
      declare
         N : constant Natural := Scan_Int (P.Text.all, P.Pos, Limit (P));
      begin
         if N = 0 then Fail (P, "a number"); return R; end if;
         R := Long_Long_Integer'Value (P.Text (P.Pos .. P.Pos + N - 1)); P.Pos := P.Pos + N;
         return R;
      end;
   end Body_Of_Last;

   function Parse_Last (P : in out Parser) return Last_Type is
   begin
      Enter (P, 6);
      declare
         R : constant Last_Type := Body_Of_Last (P);
      begin
         P.Depth := P.Depth - 1;
         return R;
      end;
   end Parse_Last;

   function Body_Of_Amount (P : in out Parser) return Amount_Type is
   R : Amount_Type;
   begin
      declare
         N : constant Natural := Scan_Int (P.Text.all, P.Pos, Limit (P));
      begin
         if N = 0 then Fail (P, "a number"); return R; end if;
         R := Long_Long_Integer'Value (P.Text (P.Pos .. P.Pos + N - 1)); P.Pos := P.Pos + N;
         return R;
      end;
   end Body_Of_Amount;

   function Parse_Amount (P : in out Parser) return Amount_Type is
   begin
      Enter (P, 7);
      declare
         R : constant Amount_Type := Body_Of_Amount (P);
      begin
         P.Depth := P.Depth - 1;
         return R;
      end;
   end Parse_Amount;

   function Body_Of_Ows (P : in out Parser) return Ows_Type is
   R : Ows_Type;
   begin
      declare
         N : constant Natural := Scan_Ows (P.Text.all, P.Pos, Limit (P));
      begin
         R := To_Unbounded_String (P.Text (P.Pos .. P.Pos + N - 1));
         P.Pos := P.Pos + N;
         return R;
      end;
   end Body_Of_Ows;

   function Parse_Ows (P : in out Parser) return Ows_Type is
   begin
      Enter (P, 8);
      declare
         R : constant Ows_Type := Body_Of_Ows (P);
      begin
         P.Depth := P.Depth - 1;
         return R;
      end;
   end Parse_Ows;

   function Body_Of_DIGIT (P : in out Parser) return DIGIT_Type is
   R : DIGIT_Type;
   begin
      declare
         N : constant Natural := Scan_DIGIT (P.Text.all, P.Pos, Limit (P));
      begin
         if N = 0 then Fail (P, "DIGIT"); return R; end if;
         R := To_Unbounded_String (P.Text (P.Pos .. P.Pos + N - 1));
         P.Pos := P.Pos + N;
         return R;
      end;
   end Body_Of_DIGIT;

   function Parse_DIGIT (P : in out Parser) return DIGIT_Type is
   begin
      Enter (P, 9);
      declare
         R : constant DIGIT_Type := Body_Of_DIGIT (P);
      begin
         P.Depth := P.Depth - 1;
         return R;
      end;
   end Parse_DIGIT;

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
      Enter (P, 13);
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
      Enter (P, 14);
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
      Enter (P, 15);
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
      Enter (P, 16);
      declare
         R : constant Ws_Type := Body_Of_Ws (P);
      begin
         P.Depth := P.Depth - 1;
         return R;
      end;
   end Parse_Ws;

   function Body_Of_Byte_ranges_1 (P : in out Parser) return Byte_ranges_1_Type is
   R : Byte_ranges_1_Type;
   Save : Natural;
   begin
      loop
         Save := P.Pos;
         declare
            E : Byte_ranges_1_Entry;
            Matched : Boolean := False;
         begin
            if not Matched then
               declare
                  El : Byte_ranges_1_Entry;
               begin
                  Expect_Lit (P, ","); if P.Failed then goto Ent_Fail_1; end if;
                  declare V : Range_spec_Type := Parse_Range_spec (P); begin if P.Failed then goto Ent_Fail_1; end if; El.Range_spec := new Range_spec_Type'(V); end;
                  E := El; Matched := True;
                  <<Ent_Fail_1>> null;
               end;
               if P.Failed then P.Failed := False; P.Pos := Save; end if;
            end if;
            exit when not Matched;
            R.Append (E);
         end;
      end loop;
      return R;
   end Body_Of_Byte_ranges_1;

   function Parse_Byte_ranges_1 (P : in out Parser) return Byte_ranges_1_Type is
   begin
      Enter (P, 17);
      declare
         R : constant Byte_ranges_1_Type := Body_Of_Byte_ranges_1 (P);
      begin
         P.Depth := P.Depth - 1;
         return R;
      end;
   end Parse_Byte_ranges_1;

   function Body_Of_Range_spec_1 (P : in out Parser) return Range_spec_1_Type is
   R : Range_spec_1_Type;
   begin
      declare
         Save : constant Natural := P.Pos;
      begin
         declare
            R : Range_spec_1_Type;
         begin
            declare V : From_to_Type := Parse_From_to (P); begin if P.Failed then goto Alt_Fail_2; end if; R.From_to := new From_to_Type'(V); end;
            return R;
            <<Alt_Fail_2>> null;
         end;
         P.Failed := False; P.Pos := Save;
         declare
            R : Range_spec_1_Type;
         begin
            declare V : Suffix_Type := Parse_Suffix (P); begin if P.Failed then goto Alt_Fail_3; end if; R.Suffix := new Suffix_Type'(V); end;
            return R;
            <<Alt_Fail_3>> null;
         end;
         P.Failed := False; P.Pos := Save;
         P.Pos := Save;
         Fail (P, "a range-spec_1");
         return R;
      end;
   end Body_Of_Range_spec_1;

   function Parse_Range_spec_1 (P : in out Parser) return Range_spec_1_Type is
   begin
      Enter (P, 18);
      declare
         R : constant Range_spec_1_Type := Body_Of_Range_spec_1 (P);
      begin
         P.Depth := P.Depth - 1;
         return R;
      end;
   end Parse_Range_spec_1;

   function Body_Of_From_to_1 (P : in out Parser) return From_to_1_Type is
   R : From_to_1_Type;
   Save : Natural;
   begin
      loop
         exit when Natural (R.Length) >= 1;
         declare
            Start : constant Natural := P.Pos;
         begin
            if P.Pos > Limit (P) then P.Pos := Start; exit; end if;
            declare V : Last_Type := Parse_Last (P); begin if P.Failed then P.Failed := False; P.Pos := Start; exit; end if; R.Append (V); end;
         end;
      end loop;
      return R;
   end Body_Of_From_to_1;

   function Parse_From_to_1 (P : in out Parser) return From_to_1_Type is
   begin
      Enter (P, 19);
      declare
         R : constant From_to_1_Type := Body_Of_From_to_1 (P);
      begin
         P.Depth := P.Depth - 1;
         return R;
      end;
   end Parse_From_to_1;

   function Body_Of_Ows_2 (P : in out Parser) return Ows_2_Type is
   R : Ows_2_Type;
   begin
      declare
         N : constant Natural := Scan_Ows_2 (P.Text.all, P.Pos, Limit (P));
      begin
         R := To_Unbounded_String (P.Text (P.Pos .. P.Pos + N - 1));
         P.Pos := P.Pos + N;
         return R;
      end;
   end Body_Of_Ows_2;

   function Parse_Ows_2 (P : in out Parser) return Ows_2_Type is
   begin
      Enter (P, 20);
      declare
         R : constant Ows_2_Type := Body_Of_Ows_2 (P);
      begin
         P.Depth := P.Depth - 1;
         return R;
      end;
   end Parse_Ows_2;

   function Rule_Name (I : Natural) return String is
     (case I is
        when 1 => "byte-ranges",
        when 2 => "range-spec",
        when 3 => "from-to",
        when 4 => "suffix",
        when 5 => "first",
        when 6 => "last",
        when 7 => "amount",
        when 8 => "ows",
        when 9 => "DIGIT",
        when 10 => "WSP",
        when 11 => "SP",
        when 12 => "HTAB",
        when 13 => "word",
        when 14 => "int",
        when 15 => "str",
        when 16 => "ws",
        when 17 => "",
        when 18 => "",
        when 19 => "",
        when 20 => "",
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
   
   function Parse_Text (Text : String) return Byte_ranges_Type is
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
      R : Byte_ranges_Type;
   begin
      begin
         R := Parse_Byte_ranges (P);
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

end Http_Range.Parser;

