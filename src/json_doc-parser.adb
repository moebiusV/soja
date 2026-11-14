
with Interfaces;
with Ada.Unchecked_Deallocation;

package body Json_Doc.Parser is

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

   function Scan_Ws (S : String; Pos, Len : Natural) return Natural is
      type Table is array (Natural range <>) of Natural;
      Lo    : constant Table := (9, 13, 32, 1, 1);
      Hi    : constant Table := (10, 13, 32, 0, 0);
      To    : constant Table := (0, 0, 0, 0, 0);
      First : constant Table := (0, 3);
      Acc   : constant Table := (1, 0);
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
   end Scan_Ws;

   function Scan_String (S : String; Pos, Len : Natural) return Natural is
      type Table is array (Natural range <>) of Natural;
      Lo    : constant Table := (34, 32, 34, 35, 92, 93, 34, 47, 92, 98, 102, 110, 114, 116, 117, 48, 65, 97, 48, 65, 97, 48, 65, 97, 48, 65, 97, 1, 1);
      Hi    : constant Table := (34, 33, 34, 91, 92, 1114111, 34, 47, 92, 98, 102, 110, 114, 116, 117, 57, 70, 102, 57, 70, 102, 57, 70, 102, 57, 70, 102, 0, 0);
      To    : constant Table := (1, 1, 2, 1, 3, 1, 1, 1, 1, 1, 1, 1, 1, 1, 4, 5, 5, 5, 6, 6, 6, 7, 7, 7, 1, 1, 1, 0, 0);
      First : constant Table := (0, 1, 6, 6, 15, 18, 21, 24, 27);
      Acc   : constant Table := (0, 0, 1, 0, 0, 0, 0, 0, 0);
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
   end Scan_String;

   function Scan_Number (S : String; Pos, Len : Natural) return Natural is
      type Table is array (Natural range <>) of Natural;
      Lo    : constant Table := (45, 48, 49, 48, 49, 46, 69, 101, 46, 48, 69, 101, 48, 43, 45, 48, 48, 69, 101, 48, 48, 1, 1);
      Hi    : constant Table := (45, 48, 57, 48, 57, 46, 69, 101, 46, 57, 69, 101, 57, 43, 45, 57, 57, 69, 101, 57, 57, 0, 0);
      To    : constant Table := (1, 2, 3, 2, 3, 4, 5, 5, 4, 3, 5, 5, 6, 7, 7, 8, 6, 5, 5, 8, 8, 0, 0);
      First : constant Table := (0, 3, 5, 8, 12, 13, 16, 19, 20, 21);
      Acc   : constant Table := (0, 0, 1, 1, 0, 0, 1, 0, 1, 0);
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
   end Scan_Number;

   function Look_Literal_true_look_1 (S : String; Pos, Len : Natural) return Boolean is
      Cp   : Natural;
      N    : Natural;
      Off  : Natural;
      Ok   : Boolean;
   begin
      Off := 0;
      Ok := True;
      if Ok then
         N := Decode_Utf8 (S, Pos + Off, Len, Cp);
         Ok := N > 0 and then (Cp >= 116 and then Cp <= 116);
         if Ok then Off := Off + N; end if;
      end if;
      if Ok then
         N := Decode_Utf8 (S, Pos + Off, Len, Cp);
         Ok := N > 0 and then (Cp >= 114 and then Cp <= 114);
         if Ok then Off := Off + N; end if;
      end if;
      if Ok then
         N := Decode_Utf8 (S, Pos + Off, Len, Cp);
         Ok := N > 0 and then (Cp >= 117 and then Cp <= 117);
         if Ok then Off := Off + N; end if;
      end if;
      if Ok then
         N := Decode_Utf8 (S, Pos + Off, Len, Cp);
         Ok := N > 0 and then (Cp >= 101 and then Cp <= 101);
         if Ok then Off := Off + N; end if;
      end if;
      if Ok then return True; end if;
      return False;
   end Look_Literal_true_look_1;

   function Scan_Literal_true (S : String; Pos, Len : Natural) return Natural is
      Cp  : Natural;
      N   : Natural;
      Off : Natural := 0;
   begin
      if not Look_Literal_true_look_1 (S, Pos + Off, Len) then return 0; end if;
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
                  Match := N > 0 and then (Cp >= 65 and then Cp <= 90);
                  if Match then O := O + N; end if;
               end if;
               if Match and then O > Br then Br := O; end if;
               O := 0;
               Match := True;
               if Match then
                  N := Decode_Utf8 (S, Pos + Off + O, Len, Cp);
                  Match := N > 0 and then (Cp >= 97 and then Cp <= 122);
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
   end Scan_Literal_true;

   function Look_Literal_false_look_1 (S : String; Pos, Len : Natural) return Boolean is
      Cp   : Natural;
      N    : Natural;
      Off  : Natural;
      Ok   : Boolean;
   begin
      Off := 0;
      Ok := True;
      if Ok then
         N := Decode_Utf8 (S, Pos + Off, Len, Cp);
         Ok := N > 0 and then (Cp >= 102 and then Cp <= 102);
         if Ok then Off := Off + N; end if;
      end if;
      if Ok then
         N := Decode_Utf8 (S, Pos + Off, Len, Cp);
         Ok := N > 0 and then (Cp >= 97 and then Cp <= 97);
         if Ok then Off := Off + N; end if;
      end if;
      if Ok then
         N := Decode_Utf8 (S, Pos + Off, Len, Cp);
         Ok := N > 0 and then (Cp >= 108 and then Cp <= 108);
         if Ok then Off := Off + N; end if;
      end if;
      if Ok then
         N := Decode_Utf8 (S, Pos + Off, Len, Cp);
         Ok := N > 0 and then (Cp >= 115 and then Cp <= 115);
         if Ok then Off := Off + N; end if;
      end if;
      if Ok then
         N := Decode_Utf8 (S, Pos + Off, Len, Cp);
         Ok := N > 0 and then (Cp >= 101 and then Cp <= 101);
         if Ok then Off := Off + N; end if;
      end if;
      if Ok then return True; end if;
      return False;
   end Look_Literal_false_look_1;

   function Scan_Literal_false (S : String; Pos, Len : Natural) return Natural is
      Cp  : Natural;
      N   : Natural;
      Off : Natural := 0;
   begin
      if not Look_Literal_false_look_1 (S, Pos + Off, Len) then return 0; end if;
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
                  Match := N > 0 and then (Cp >= 65 and then Cp <= 90);
                  if Match then O := O + N; end if;
               end if;
               if Match and then O > Br then Br := O; end if;
               O := 0;
               Match := True;
               if Match then
                  N := Decode_Utf8 (S, Pos + Off + O, Len, Cp);
                  Match := N > 0 and then (Cp >= 97 and then Cp <= 122);
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
   end Scan_Literal_false;

   function Look_Literal_null_look_1 (S : String; Pos, Len : Natural) return Boolean is
      Cp   : Natural;
      N    : Natural;
      Off  : Natural;
      Ok   : Boolean;
   begin
      Off := 0;
      Ok := True;
      if Ok then
         N := Decode_Utf8 (S, Pos + Off, Len, Cp);
         Ok := N > 0 and then (Cp >= 110 and then Cp <= 110);
         if Ok then Off := Off + N; end if;
      end if;
      if Ok then
         N := Decode_Utf8 (S, Pos + Off, Len, Cp);
         Ok := N > 0 and then (Cp >= 117 and then Cp <= 117);
         if Ok then Off := Off + N; end if;
      end if;
      if Ok then
         N := Decode_Utf8 (S, Pos + Off, Len, Cp);
         Ok := N > 0 and then (Cp >= 108 and then Cp <= 108);
         if Ok then Off := Off + N; end if;
      end if;
      if Ok then
         N := Decode_Utf8 (S, Pos + Off, Len, Cp);
         Ok := N > 0 and then (Cp >= 108 and then Cp <= 108);
         if Ok then Off := Off + N; end if;
      end if;
      if Ok then return True; end if;
      return False;
   end Look_Literal_null_look_1;

   function Scan_Literal_null (S : String; Pos, Len : Natural) return Natural is
      Cp  : Natural;
      N   : Natural;
      Off : Natural := 0;
   begin
      if not Look_Literal_null_look_1 (S, Pos + Off, Len) then return 0; end if;
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
                  Match := N > 0 and then (Cp >= 65 and then Cp <= 90);
                  if Match then O := O + N; end if;
               end if;
               if Match and then O > Br then Br := O; end if;
               O := 0;
               Match := True;
               if Match then
                  N := Decode_Utf8 (S, Pos + Off + O, Len, Cp);
                  Match := N > 0 and then (Cp >= 97 and then Cp <= 122);
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
   end Scan_Literal_null;

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

   procedure Dealloc_Value is new Ada.Unchecked_Deallocation (Value_Type, Value_Access);
   procedure Dealloc_Object is new Ada.Unchecked_Deallocation (Object_Type, Object_Access);
   procedure Dealloc_Member is new Ada.Unchecked_Deallocation (Member_Type, Member_Access);
   procedure Dealloc_Array is new Ada.Unchecked_Deallocation (Array_Type, Array_Access);

   procedure Free_Value (V : in out Value_Type) is
   begin
   if V.Object /= null then
      Free_Object (V.Object.all);
      Dealloc_Object (V.Object);
   end if;
   if V.hyper_Array /= null then
      Free_Array (V.hyper_Array.all);
      Dealloc_Array (V.hyper_Array);
   end if;
   end Free_Value;

   procedure Free_Object (V : in out Object_Type) is
   begin
   Free_Object_1 (V.Object_1);
   end Free_Object;

   procedure Free_Member (V : in out Member_Type) is
   begin
   if V.Value /= null then
      Free_Value (V.Value.all);
      Dealloc_Value (V.Value);
   end if;
   end Free_Member;

   procedure Free_Array (V : in out Array_Type) is
   begin
   Free_Array_1 (V.Array_1);
   end Free_Array;

   procedure Free_Object_1 (V : in out Object_1_Type) is
   begin
   for K in V.First_Index .. V.Last_Index loop
      declare
         E : Object_1_Entry := V (K);
      begin
   if E.Member /= null then
      Free_Member (E.Member.all);
      Dealloc_Member (E.Member);
   end if;
   Free_Object_1_1 (E.Object_1_1);
         V.Replace_Element (K, E);
      end;
   end loop;
   end Free_Object_1;

   procedure Free_Object_1_1 (V : in out Object_1_1_Type) is
   begin
   for K in V.First_Index .. V.Last_Index loop
      declare
         E : Object_1_1_Entry := V (K);
      begin
   if E.Member /= null then
      Free_Member (E.Member.all);
      Dealloc_Member (E.Member);
   end if;
         V.Replace_Element (K, E);
      end;
   end loop;
   end Free_Object_1_1;

   procedure Free_Array_1 (V : in out Array_1_Type) is
   begin
   for K in V.First_Index .. V.Last_Index loop
      declare
         E : Array_1_Entry := V (K);
      begin
   if E.Value /= null then
      Free_Value (E.Value.all);
      Dealloc_Value (E.Value);
   end if;
   Free_Array_1_1 (E.Array_1_1);
         V.Replace_Element (K, E);
      end;
   end loop;
   end Free_Array_1;

   procedure Free_Array_1_1 (V : in out Array_1_1_Type) is
   begin
   for K in V.First_Index .. V.Last_Index loop
      declare
         E : Array_1_1_Entry := V (K);
      begin
   if E.Value /= null then
      Free_Value (E.Value.all);
      Dealloc_Value (E.Value);
   end if;
         V.Replace_Element (K, E);
      end;
   end loop;
   end Free_Array_1_1;

   function Parse_Json (P : in out Parser) return Json_Type;
   function Parse_Value (P : in out Parser) return Value_Type;
   function Parse_Object (P : in out Parser) return Object_Type;
   function Parse_Member (P : in out Parser) return Member_Type;
   function Parse_Array (P : in out Parser) return Array_Type;
   function Parse_String (P : in out Parser) return String_Type;
   function Parse_Number (P : in out Parser) return Number_Type;
   function Parse_Literal_true (P : in out Parser) return Literal_true_Type;
   function Parse_Literal_false (P : in out Parser) return Literal_false_Type;
   function Parse_Literal_null (P : in out Parser) return Literal_null_Type;
   function Parse_Word (P : in out Parser) return Word_Type;
   function Parse_Int (P : in out Parser) return Int_Type;
   function Parse_Str (P : in out Parser) return Str_Type;
   function Parse_Object_1 (P : in out Parser) return Object_1_Type;
   function Parse_Object_1_1 (P : in out Parser) return Object_1_1_Type;
   function Parse_Array_1 (P : in out Parser) return Array_1_Type;
   function Parse_Array_1_1 (P : in out Parser) return Array_1_1_Type;

   function Body_Of_Json (P : in out Parser) return Json_Type is
   begin
      return Parse_Value (P);
   end Body_Of_Json;

   function Parse_Json (P : in out Parser) return Json_Type is
   begin
      Enter (P, 1);
      declare
         R : constant Json_Type := Body_Of_Json (P);
      begin
         P.Depth := P.Depth - 1;
         return R;
      end;
   end Parse_Json;

   function Body_Of_Value (P : in out Parser) return Value_Type is
   R : Value_Type;
   begin
      declare
         Save : constant Natural := P.Pos;
      begin
         declare
            R : Value_Type;
         begin
            Skip_Ws (P);
            declare V : Object_Type := Parse_Object (P); begin if P.Failed then goto Alt_Fail_1; end if; R.Object := new Object_Type'(V); end;
            return R;
            <<Alt_Fail_1>> null;
         end;
         P.Failed := False; P.Pos := Save;
         declare
            R : Value_Type;
         begin
            Skip_Ws (P);
            declare V : Array_Type := Parse_Array (P); begin if P.Failed then goto Alt_Fail_2; end if; R.hyper_Array := new Array_Type'(V); end;
            return R;
            <<Alt_Fail_2>> null;
         end;
         P.Failed := False; P.Pos := Save;
         declare
            R : Value_Type;
         begin
            Skip_Ws (P);
            declare
               N : constant Natural := Scan_String (P.Text.all, P.Pos, Limit (P));
            begin
               if N = 0 then Fail (P, "string"); goto Alt_Fail_3; end if;
               R.String := To_Unbounded_String (P.Text (P.Pos .. P.Pos + N - 1)); P.Pos := P.Pos + N;
            end;
            return R;
            <<Alt_Fail_3>> null;
         end;
         P.Failed := False; P.Pos := Save;
         declare
            R : Value_Type;
         begin
            Skip_Ws (P);
            declare
               N : constant Natural := Scan_Number (P.Text.all, P.Pos, Limit (P));
            begin
               if N = 0 then Fail (P, "number"); goto Alt_Fail_4; end if;
               R.Number := To_Unbounded_String (P.Text (P.Pos .. P.Pos + N - 1)); P.Pos := P.Pos + N;
            end;
            return R;
            <<Alt_Fail_4>> null;
         end;
         P.Failed := False; P.Pos := Save;
         declare
            R : Value_Type;
         begin
            Skip_Ws (P);
            declare
               N : constant Natural := Scan_Literal_true (P.Text.all, P.Pos, Limit (P));
            begin
               if N = 0 then Fail (P, "literal-true"); goto Alt_Fail_5; end if;
               R.Literal_true := To_Unbounded_String (P.Text (P.Pos .. P.Pos + N - 1)); P.Pos := P.Pos + N;
            end;
            return R;
            <<Alt_Fail_5>> null;
         end;
         P.Failed := False; P.Pos := Save;
         declare
            R : Value_Type;
         begin
            Skip_Ws (P);
            declare
               N : constant Natural := Scan_Literal_false (P.Text.all, P.Pos, Limit (P));
            begin
               if N = 0 then Fail (P, "literal-false"); goto Alt_Fail_6; end if;
               R.Literal_false := To_Unbounded_String (P.Text (P.Pos .. P.Pos + N - 1)); P.Pos := P.Pos + N;
            end;
            return R;
            <<Alt_Fail_6>> null;
         end;
         P.Failed := False; P.Pos := Save;
         declare
            R : Value_Type;
         begin
            Skip_Ws (P);
            declare
               N : constant Natural := Scan_Literal_null (P.Text.all, P.Pos, Limit (P));
            begin
               if N = 0 then Fail (P, "literal-null"); goto Alt_Fail_7; end if;
               R.Literal_null := To_Unbounded_String (P.Text (P.Pos .. P.Pos + N - 1)); P.Pos := P.Pos + N;
            end;
            return R;
            <<Alt_Fail_7>> null;
         end;
         P.Failed := False; P.Pos := Save;
         P.Pos := Save;
         Fail (P, "a value");
         return R;
      end;
   end Body_Of_Value;

   function Parse_Value (P : in out Parser) return Value_Type is
   begin
      Enter (P, 2);
      declare
         R : constant Value_Type := Body_Of_Value (P);
      begin
         P.Depth := P.Depth - 1;
         return R;
      end;
   end Parse_Value;

   function Body_Of_Object (P : in out Parser) return Object_Type is
   R : Object_Type;
   begin
      Skip_Ws (P);
      Expect_Lit (P, "{"); if P.Failed then return R; end if;
      Skip_Ws (P);
      R.Object_1 := Parse_Object_1 (P); if P.Failed then return R; end if;
      Skip_Ws (P);
      Expect_Lit (P, "}"); if P.Failed then return R; end if;
      return R;
   end Body_Of_Object;

   function Parse_Object (P : in out Parser) return Object_Type is
   begin
      Enter (P, 3);
      declare
         R : constant Object_Type := Body_Of_Object (P);
      begin
         P.Depth := P.Depth - 1;
         return R;
      end;
   end Parse_Object;

   function Body_Of_Member (P : in out Parser) return Member_Type is
   R : Member_Type;
   begin
      Skip_Ws (P);
      declare
         N : constant Natural := Scan_String (P.Text.all, P.Pos, Limit (P));
      begin
         if N = 0 then Fail (P, "string"); return R; end if;
         R.String := To_Unbounded_String (P.Text (P.Pos .. P.Pos + N - 1)); P.Pos := P.Pos + N;
      end;
      Skip_Ws (P);
      Expect_Lit (P, ":"); if P.Failed then return R; end if;
      Skip_Ws (P);
      declare V : Value_Type := Parse_Value (P); begin if P.Failed then return R; end if; R.Value := new Value_Type'(V); end;
      return R;
   end Body_Of_Member;

   function Parse_Member (P : in out Parser) return Member_Type is
   begin
      Enter (P, 4);
      declare
         R : constant Member_Type := Body_Of_Member (P);
      begin
         P.Depth := P.Depth - 1;
         return R;
      end;
   end Parse_Member;

   function Body_Of_Array (P : in out Parser) return Array_Type is
   R : Array_Type;
   begin
      Skip_Ws (P);
      Expect_Lit (P, "["); if P.Failed then return R; end if;
      Skip_Ws (P);
      R.Array_1 := Parse_Array_1 (P); if P.Failed then return R; end if;
      Skip_Ws (P);
      Expect_Lit (P, "]"); if P.Failed then return R; end if;
      return R;
   end Body_Of_Array;

   function Parse_Array (P : in out Parser) return Array_Type is
   begin
      Enter (P, 5);
      declare
         R : constant Array_Type := Body_Of_Array (P);
      begin
         P.Depth := P.Depth - 1;
         return R;
      end;
   end Parse_Array;

   function Body_Of_String (P : in out Parser) return String_Type is
   R : String_Type;
   begin
      declare
         N : constant Natural := Scan_String (P.Text.all, P.Pos, Limit (P));
      begin
         if N = 0 then Fail (P, "string"); return R; end if;
         R := To_Unbounded_String (P.Text (P.Pos .. P.Pos + N - 1));
         P.Pos := P.Pos + N;
         return R;
      end;
   end Body_Of_String;

   function Parse_String (P : in out Parser) return String_Type is
   begin
      Enter (P, 7);
      declare
         R : constant String_Type := Body_Of_String (P);
      begin
         P.Depth := P.Depth - 1;
         return R;
      end;
   end Parse_String;

   function Body_Of_Number (P : in out Parser) return Number_Type is
   R : Number_Type;
   begin
      declare
         N : constant Natural := Scan_Number (P.Text.all, P.Pos, Limit (P));
      begin
         if N = 0 then Fail (P, "number"); return R; end if;
         R := To_Unbounded_String (P.Text (P.Pos .. P.Pos + N - 1));
         P.Pos := P.Pos + N;
         return R;
      end;
   end Body_Of_Number;

   function Parse_Number (P : in out Parser) return Number_Type is
   begin
      Enter (P, 11);
      declare
         R : constant Number_Type := Body_Of_Number (P);
      begin
         P.Depth := P.Depth - 1;
         return R;
      end;
   end Parse_Number;

   function Body_Of_Literal_true (P : in out Parser) return Literal_true_Type is
   R : Literal_true_Type;
   begin
      declare
         N : constant Natural := Scan_Literal_true (P.Text.all, P.Pos, Limit (P));
      begin
         if N = 0 then Fail (P, "literal-true"); return R; end if;
         R := To_Unbounded_String (P.Text (P.Pos .. P.Pos + N - 1));
         P.Pos := P.Pos + N;
         return R;
      end;
   end Body_Of_Literal_true;

   function Parse_Literal_true (P : in out Parser) return Literal_true_Type is
   begin
      Enter (P, 15);
      declare
         R : constant Literal_true_Type := Body_Of_Literal_true (P);
      begin
         P.Depth := P.Depth - 1;
         return R;
      end;
   end Parse_Literal_true;

   function Body_Of_Literal_false (P : in out Parser) return Literal_false_Type is
   R : Literal_false_Type;
   begin
      declare
         N : constant Natural := Scan_Literal_false (P.Text.all, P.Pos, Limit (P));
      begin
         if N = 0 then Fail (P, "literal-false"); return R; end if;
         R := To_Unbounded_String (P.Text (P.Pos .. P.Pos + N - 1));
         P.Pos := P.Pos + N;
         return R;
      end;
   end Body_Of_Literal_false;

   function Parse_Literal_false (P : in out Parser) return Literal_false_Type is
   begin
      Enter (P, 16);
      declare
         R : constant Literal_false_Type := Body_Of_Literal_false (P);
      begin
         P.Depth := P.Depth - 1;
         return R;
      end;
   end Parse_Literal_false;

   function Body_Of_Literal_null (P : in out Parser) return Literal_null_Type is
   R : Literal_null_Type;
   begin
      declare
         N : constant Natural := Scan_Literal_null (P.Text.all, P.Pos, Limit (P));
      begin
         if N = 0 then Fail (P, "literal-null"); return R; end if;
         R := To_Unbounded_String (P.Text (P.Pos .. P.Pos + N - 1));
         P.Pos := P.Pos + N;
         return R;
      end;
   end Body_Of_Literal_null;

   function Parse_Literal_null (P : in out Parser) return Literal_null_Type is
   begin
      Enter (P, 17);
      declare
         R : constant Literal_null_Type := Body_Of_Literal_null (P);
      begin
         P.Depth := P.Depth - 1;
         return R;
      end;
   end Parse_Literal_null;

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
      Enter (P, 26);
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
      Enter (P, 27);
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
      Enter (P, 28);
      declare
         R : constant Str_Type := Body_Of_Str (P);
      begin
         P.Depth := P.Depth - 1;
         return R;
      end;
   end Parse_Str;

   function Body_Of_Object_1 (P : in out Parser) return Object_1_Type is
   R : Object_1_Type;
   Save : Natural;
   begin
      loop
         exit when Natural (R.Length) >= 1;
         Save := P.Pos;
         declare
            E : Object_1_Entry;
            Matched : Boolean := False;
         begin
            if not Matched then
               declare
                  El : Object_1_Entry;
               begin
                  Skip_Ws (P);
                  declare V : Member_Type := Parse_Member (P); begin if P.Failed then goto Ent_Fail_8; end if; El.Member := new Member_Type'(V); end;
                  Skip_Ws (P);
                  El.Object_1_1 := Parse_Object_1_1 (P); if P.Failed then goto Ent_Fail_8; end if;
                  E := El; Matched := True;
                  <<Ent_Fail_8>> null;
               end;
               if P.Failed then P.Failed := False; P.Pos := Save; end if;
            end if;
            exit when not Matched;
            R.Append (E);
         end;
      end loop;
      return R;
   end Body_Of_Object_1;

   function Parse_Object_1 (P : in out Parser) return Object_1_Type is
   begin
      Enter (P, 29);
      declare
         R : constant Object_1_Type := Body_Of_Object_1 (P);
      begin
         P.Depth := P.Depth - 1;
         return R;
      end;
   end Parse_Object_1;

   function Body_Of_Object_1_1 (P : in out Parser) return Object_1_1_Type is
   R : Object_1_1_Type;
   Save : Natural;
   begin
      loop
         Save := P.Pos;
         declare
            E : Object_1_1_Entry;
            Matched : Boolean := False;
         begin
            if not Matched then
               declare
                  El : Object_1_1_Entry;
               begin
                  Skip_Ws (P);
                  Expect_Lit (P, ","); if P.Failed then goto Ent_Fail_9; end if;
                  Skip_Ws (P);
                  declare V : Member_Type := Parse_Member (P); begin if P.Failed then goto Ent_Fail_9; end if; El.Member := new Member_Type'(V); end;
                  E := El; Matched := True;
                  <<Ent_Fail_9>> null;
               end;
               if P.Failed then P.Failed := False; P.Pos := Save; end if;
            end if;
            exit when not Matched;
            R.Append (E);
         end;
      end loop;
      return R;
   end Body_Of_Object_1_1;

   function Parse_Object_1_1 (P : in out Parser) return Object_1_1_Type is
   begin
      Enter (P, 30);
      declare
         R : constant Object_1_1_Type := Body_Of_Object_1_1 (P);
      begin
         P.Depth := P.Depth - 1;
         return R;
      end;
   end Parse_Object_1_1;

   function Body_Of_Array_1 (P : in out Parser) return Array_1_Type is
   R : Array_1_Type;
   Save : Natural;
   begin
      loop
         exit when Natural (R.Length) >= 1;
         Save := P.Pos;
         declare
            E : Array_1_Entry;
            Matched : Boolean := False;
         begin
            if not Matched then
               declare
                  El : Array_1_Entry;
               begin
                  Skip_Ws (P);
                  declare V : Value_Type := Parse_Value (P); begin if P.Failed then goto Ent_Fail_10; end if; El.Value := new Value_Type'(V); end;
                  Skip_Ws (P);
                  El.Array_1_1 := Parse_Array_1_1 (P); if P.Failed then goto Ent_Fail_10; end if;
                  E := El; Matched := True;
                  <<Ent_Fail_10>> null;
               end;
               if P.Failed then P.Failed := False; P.Pos := Save; end if;
            end if;
            exit when not Matched;
            R.Append (E);
         end;
      end loop;
      return R;
   end Body_Of_Array_1;

   function Parse_Array_1 (P : in out Parser) return Array_1_Type is
   begin
      Enter (P, 31);
      declare
         R : constant Array_1_Type := Body_Of_Array_1 (P);
      begin
         P.Depth := P.Depth - 1;
         return R;
      end;
   end Parse_Array_1;

   function Body_Of_Array_1_1 (P : in out Parser) return Array_1_1_Type is
   R : Array_1_1_Type;
   Save : Natural;
   begin
      loop
         Save := P.Pos;
         declare
            E : Array_1_1_Entry;
            Matched : Boolean := False;
         begin
            if not Matched then
               declare
                  El : Array_1_1_Entry;
               begin
                  Skip_Ws (P);
                  Expect_Lit (P, ","); if P.Failed then goto Ent_Fail_11; end if;
                  Skip_Ws (P);
                  declare V : Value_Type := Parse_Value (P); begin if P.Failed then goto Ent_Fail_11; end if; El.Value := new Value_Type'(V); end;
                  E := El; Matched := True;
                  <<Ent_Fail_11>> null;
               end;
               if P.Failed then P.Failed := False; P.Pos := Save; end if;
            end if;
            exit when not Matched;
            R.Append (E);
         end;
      end loop;
      return R;
   end Body_Of_Array_1_1;

   function Parse_Array_1_1 (P : in out Parser) return Array_1_1_Type is
   begin
      Enter (P, 32);
      declare
         R : constant Array_1_1_Type := Body_Of_Array_1_1 (P);
      begin
         P.Depth := P.Depth - 1;
         return R;
      end;
   end Parse_Array_1_1;

   function Rule_Name (I : Natural) return String is
     (case I is
        when 1 => "json",
        when 2 => "value",
        when 3 => "object",
        when 4 => "member",
        when 5 => "array",
        when 6 => "ws",
        when 7 => "string",
        when 8 => "char",
        when 9 => "unescaped",
        when 10 => "escape",
        when 11 => "number",
        when 12 => "integer",
        when 13 => "frac",
        when 14 => "exp",
        when 15 => "literal-true",
        when 16 => "literal-false",
        when 17 => "literal-null",
        when 18 => "DIGIT",
        when 19 => "ALPHA",
        when 20 => "HEXDIG",
        when 21 => "LF",
        when 22 => "CR",
        when 23 => "SP",
        when 24 => "HTAB",
        when 25 => "DQUOTE",
        when 26 => "word",
        when 27 => "int",
        when 28 => "str",
        when 29 => "",
        when 30 => "",
        when 31 => "",
        when 32 => "",
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
   
   function Parse_Text (Text : String) return Json_Type is
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
      R : Json_Type;
   begin
      begin
      Skip_Ws (P);
         R := Parse_Json (P);
         if P.Failed then
            raise Parse_Error with Render (P);
         end if;
      Skip_Ws (P);
         if P.Pos <= T'Last then
            Fail (P, "end of config");
            raise Parse_Error with Render (P);
         end if;
      end;
      return R;
   end Parse_Text;

end Json_Doc.Parser;

