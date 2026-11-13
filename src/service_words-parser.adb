
with Interfaces;
with Ada.Unchecked_Deallocation;

package body Service_Words.Parser is

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

   function Scan_Plain (S : String; Pos, Len : Natural) return Natural is
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
                  Match := N > 0 and then (Cp <= 8);
                  if Match then O := O + N; end if;
               end if;
               if Match and then O > Br then Br := O; end if;
               O := 0;
               Match := True;
               if Match then
                  N := Decode_Utf8 (S, Pos + Off + O, Len, Cp);
                  Match := N > 0 and then (Cp >= 14 and then Cp <= 31);
                  if Match then O := O + N; end if;
               end if;
               if Match and then O > Br then Br := O; end if;
               O := 0;
               Match := True;
               if Match then
                  N := Decode_Utf8 (S, Pos + Off + O, Len, Cp);
                  Match := N > 0 and then (Cp >= 33 and then Cp <= 33);
                  if Match then O := O + N; end if;
               end if;
               if Match and then O > Br then Br := O; end if;
               O := 0;
               Match := True;
               if Match then
                  N := Decode_Utf8 (S, Pos + Off + O, Len, Cp);
                  Match := N > 0 and then (Cp >= 35 and then Cp <= 38);
                  if Match then O := O + N; end if;
               end if;
               if Match and then O > Br then Br := O; end if;
               O := 0;
               Match := True;
               if Match then
                  N := Decode_Utf8 (S, Pos + Off + O, Len, Cp);
                  Match := N > 0 and then (Cp >= 40 and then Cp <= 91);
                  if Match then O := O + N; end if;
               end if;
               if Match and then O > Br then Br := O; end if;
               O := 0;
               Match := True;
               if Match then
                  N := Decode_Utf8 (S, Pos + Off + O, Len, Cp);
                  Match := N > 0 and then (Cp >= 93 and then Cp <= 132);
                  if Match then O := O + N; end if;
               end if;
               if Match and then O > Br then Br := O; end if;
               O := 0;
               Match := True;
               if Match then
                  N := Decode_Utf8 (S, Pos + Off + O, Len, Cp);
                  Match := N > 0 and then (Cp >= 134 and then Cp <= 159);
                  if Match then O := O + N; end if;
               end if;
               if Match and then O > Br then Br := O; end if;
               O := 0;
               Match := True;
               if Match then
                  N := Decode_Utf8 (S, Pos + Off + O, Len, Cp);
                  Match := N > 0 and then (Cp >= 161 and then Cp <= 5759);
                  if Match then O := O + N; end if;
               end if;
               if Match and then O > Br then Br := O; end if;
               O := 0;
               Match := True;
               if Match then
                  N := Decode_Utf8 (S, Pos + Off + O, Len, Cp);
                  Match := N > 0 and then (Cp >= 5761 and then Cp <= 8191);
                  if Match then O := O + N; end if;
               end if;
               if Match and then O > Br then Br := O; end if;
               O := 0;
               Match := True;
               if Match then
                  N := Decode_Utf8 (S, Pos + Off + O, Len, Cp);
                  Match := N > 0 and then (Cp >= 8203 and then Cp <= 8231);
                  if Match then O := O + N; end if;
               end if;
               if Match and then O > Br then Br := O; end if;
               O := 0;
               Match := True;
               if Match then
                  N := Decode_Utf8 (S, Pos + Off + O, Len, Cp);
                  Match := N > 0 and then (Cp >= 8234 and then Cp <= 8238);
                  if Match then O := O + N; end if;
               end if;
               if Match and then O > Br then Br := O; end if;
               O := 0;
               Match := True;
               if Match then
                  N := Decode_Utf8 (S, Pos + Off + O, Len, Cp);
                  Match := N > 0 and then (Cp >= 8240 and then Cp <= 8286);
                  if Match then O := O + N; end if;
               end if;
               if Match and then O > Br then Br := O; end if;
               O := 0;
               Match := True;
               if Match then
                  N := Decode_Utf8 (S, Pos + Off + O, Len, Cp);
                  Match := N > 0 and then (Cp >= 8288 and then Cp <= 12287);
                  if Match then O := O + N; end if;
               end if;
               if Match and then O > Br then Br := O; end if;
               O := 0;
               Match := True;
               if Match then
                  N := Decode_Utf8 (S, Pos + Off + O, Len, Cp);
                  Match := N > 0 and then (Cp >= 12289 and then Cp <= 1114111);
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
   end Scan_Plain;

   function Scan_Escaped (S : String; Pos, Len : Natural) return Natural is
      Cp  : Natural;
      N   : Natural;
      Off : Natural := 0;
   begin
      N := Decode_Utf8 (S, Pos + Off, Len, Cp);
      if N = 0 or else not (Cp >= 92 and then Cp <= 92) then return 0; end if;
      Off := Off + N;
      N := Decode_Utf8 (S, Pos + Off, Len, Cp);
      if N = 0 or else not (Cp <= 1114111) then return 0; end if;
      Off := Off + N;
      return Off;
   end Scan_Escaped;

   function Scan_Bad_quote (S : String; Pos, Len : Natural) return Natural is
      type Table is array (Natural range <>) of Natural;
      Lo    : constant Table := (34, 39, 0, 1, 1);
      Hi    : constant Table := (34, 39, 1114111, 0, 0);
      To    : constant Table := (1, 1, 1, 0, 0);
      First : constant Table := (0, 2, 3);
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
   end Scan_Bad_quote;

   function Scan_Bad_slash (S : String; Pos, Len : Natural) return Natural is
      Cp  : Natural;
      N   : Natural;
      Off : Natural := 0;
   begin
      N := Decode_Utf8 (S, Pos + Off, Len, Cp);
      if N = 0 or else not (Cp >= 92 and then Cp <= 92) then return 0; end if;
      Off := Off + N;
      return Off;
   end Scan_Bad_slash;

   function Scan_Dq_body (S : String; Pos, Len : Natural) return Natural is
      type Table is array (Natural range <>) of Natural;
      Lo    : constant Table := (0, 35, 92, 93, 0, 1, 1);
      Hi    : constant Table := (33, 91, 92, 1114111, 1114111, 0, 0);
      To    : constant Table := (0, 0, 1, 0, 0, 0, 0);
      First : constant Table := (0, 4, 5);
      Acc   : constant Table := (1, 0, 0);
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
   end Scan_Dq_body;

   function Scan_Sq_body (S : String; Pos, Len : Natural) return Natural is
      type Table is array (Natural range <>) of Natural;
      Lo    : constant Table := (0, 40, 92, 93, 0, 1, 1);
      Hi    : constant Table := (38, 91, 92, 1114111, 1114111, 0, 0);
      To    : constant Table := (0, 0, 1, 0, 0, 0, 0);
      First : constant Table := (0, 4, 5);
      Acc   : constant Table := (1, 0, 0);
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
   end Scan_Sq_body;

   function Scan_Gap (S : String; Pos, Len : Natural) return Natural is
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
                  Match := N > 0 and then (Cp >= 9 and then Cp <= 13);
                  if Match then O := O + N; end if;
               end if;
               if Match and then O > Br then Br := O; end if;
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
                  Match := N > 0 and then (Cp >= 133 and then Cp <= 133);
                  if Match then O := O + N; end if;
               end if;
               if Match and then O > Br then Br := O; end if;
               O := 0;
               Match := True;
               if Match then
                  N := Decode_Utf8 (S, Pos + Off + O, Len, Cp);
                  Match := N > 0 and then (Cp >= 160 and then Cp <= 160);
                  if Match then O := O + N; end if;
               end if;
               if Match and then O > Br then Br := O; end if;
               O := 0;
               Match := True;
               if Match then
                  N := Decode_Utf8 (S, Pos + Off + O, Len, Cp);
                  Match := N > 0 and then (Cp >= 5760 and then Cp <= 5760);
                  if Match then O := O + N; end if;
               end if;
               if Match and then O > Br then Br := O; end if;
               O := 0;
               Match := True;
               if Match then
                  N := Decode_Utf8 (S, Pos + Off + O, Len, Cp);
                  Match := N > 0 and then (Cp >= 8192 and then Cp <= 8202);
                  if Match then O := O + N; end if;
               end if;
               if Match and then O > Br then Br := O; end if;
               O := 0;
               Match := True;
               if Match then
                  N := Decode_Utf8 (S, Pos + Off + O, Len, Cp);
                  Match := N > 0 and then (Cp >= 8232 and then Cp <= 8232);
                  if Match then O := O + N; end if;
               end if;
               if Match and then O > Br then Br := O; end if;
               O := 0;
               Match := True;
               if Match then
                  N := Decode_Utf8 (S, Pos + Off + O, Len, Cp);
                  Match := N > 0 and then (Cp >= 8233 and then Cp <= 8233);
                  if Match then O := O + N; end if;
               end if;
               if Match and then O > Br then Br := O; end if;
               O := 0;
               Match := True;
               if Match then
                  N := Decode_Utf8 (S, Pos + Off + O, Len, Cp);
                  Match := N > 0 and then (Cp >= 8239 and then Cp <= 8239);
                  if Match then O := O + N; end if;
               end if;
               if Match and then O > Br then Br := O; end if;
               O := 0;
               Match := True;
               if Match then
                  N := Decode_Utf8 (S, Pos + Off + O, Len, Cp);
                  Match := N > 0 and then (Cp >= 8287 and then Cp <= 8287);
                  if Match then O := O + N; end if;
               end if;
               if Match and then O > Br then Br := O; end if;
               O := 0;
               Match := True;
               if Match then
                  N := Decode_Utf8 (S, Pos + Off + O, Len, Cp);
                  Match := N > 0 and then (Cp >= 12288 and then Cp <= 12288);
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
   end Scan_Gap;

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
   begin
      null;
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

   procedure Dealloc_Item is new Ada.Unchecked_Deallocation (Item_Type, Item_Access);
   procedure Dealloc_Piece is new Ada.Unchecked_Deallocation (Piece_Type, Piece_Access);
   procedure Dealloc_Dquoted is new Ada.Unchecked_Deallocation (Dquoted_Type, Dquoted_Access);
   procedure Dealloc_Squoted is new Ada.Unchecked_Deallocation (Squoted_Type, Squoted_Access);

   procedure Free_Line (V : in out Line_Type) is
   begin
   for K in V.First_Index .. V.Last_Index loop
      declare
         E : Item_Access := V (K);
      begin
         if E /= null then
            Free_Item (E.all);
            V.Replace_Element (K, null);
            Dealloc_Item (E);
         end if;
      end;
   end loop;
   end Free_Line;

   procedure Free_Item (V : in out Item_Type) is
   begin
   Free_Cmd_word (V.Cmd_word);
   end Free_Item;

   procedure Free_Cmd_word (V : in out Cmd_word_Type) is
   begin
   for K in V.First_Index .. V.Last_Index loop
      declare
         E : Piece_Access := V (K);
      begin
         if E /= null then
            Free_Piece (E.all);
            V.Replace_Element (K, null);
            Dealloc_Piece (E);
         end if;
      end;
   end loop;
   end Free_Cmd_word;

   procedure Free_Piece (V : in out Piece_Type) is
   begin
   if V.Dquoted /= null then
      Free_Dquoted (V.Dquoted.all);
      Dealloc_Dquoted (V.Dquoted);
   end if;
   if V.Squoted /= null then
      Free_Squoted (V.Squoted.all);
      Dealloc_Squoted (V.Squoted);
   end if;
   end Free_Piece;

   procedure Free_Dquoted (V : in out Dquoted_Type) is
      pragma Unreferenced (V);
   begin
      null;
   end Free_Dquoted;

   procedure Free_Squoted (V : in out Squoted_Type) is
      pragma Unreferenced (V);
   begin
      null;
   end Free_Squoted;

   function Parse_Line (P : in out Parser) return Line_Type;
   function Parse_Item (P : in out Parser) return Item_Type;
   function Parse_Cmd_word (P : in out Parser) return Cmd_word_Type;
   function Parse_Piece (P : in out Parser) return Piece_Type;
   function Parse_Plain (P : in out Parser) return Plain_Type;
   function Parse_Escaped (P : in out Parser) return Escaped_Type;
   function Parse_Dquoted (P : in out Parser) return Dquoted_Type;
   function Parse_Squoted (P : in out Parser) return Squoted_Type;
   function Parse_Bad_quote (P : in out Parser) return Bad_quote_Type;
   function Parse_Bad_slash (P : in out Parser) return Bad_slash_Type;
   function Parse_Quote_mark (P : in out Parser) return Quote_mark_Type;
   function Parse_Dq_body (P : in out Parser) return Dq_body_Type;
   function Parse_Sq_body (P : in out Parser) return Sq_body_Type;
   function Parse_Gap (P : in out Parser) return Gap_Type;
   function Parse_Word (P : in out Parser) return Word_Type;
   function Parse_Int (P : in out Parser) return Int_Type;
   function Parse_Str (P : in out Parser) return Str_Type;
   function Parse_Ws (P : in out Parser) return Ws_Type;

   function Body_Of_Line (P : in out Parser) return Line_Type is
   R : Line_Type;
   begin
      loop
         declare
            Start : constant Natural := P.Pos;
         begin
            if P.Pos > Limit (P) then P.Pos := Start; exit; end if;
            declare V : Item_Type := Parse_Item (P); begin if P.Failed then P.Failed := False; P.Pos := Start; exit; end if; R.Append (new Item_Type'(V)); end;
         end;
      end loop;
      return R;
   end Body_Of_Line;

   function Parse_Line (P : in out Parser) return Line_Type is
   begin
      Enter (P, 1);
      declare
         R : constant Line_Type := Body_Of_Line (P);
      begin
         P.Depth := P.Depth - 1;
         return R;
      end;
   end Parse_Line;

   function Body_Of_Item (P : in out Parser) return Item_Type is
   R : Item_Type;
   begin
      declare
         Save : constant Natural := P.Pos;
      begin
         declare
            R : Item_Type;
         begin
            declare
               N : constant Natural := Scan_Gap (P.Text.all, P.Pos, Limit (P));
            begin
               if N = 0 then Fail (P, "gap"); goto Alt_Fail_1; end if;
               R.Gap := To_Unbounded_String (P.Text (P.Pos .. P.Pos + N - 1)); P.Pos := P.Pos + N;
            end;
            return R;
            <<Alt_Fail_1>> null;
         end;
         P.Failed := False; P.Pos := Save;
         declare
            R : Item_Type;
         begin
            R.Cmd_word := Parse_Cmd_word (P); if P.Failed then goto Alt_Fail_2; end if;
            return R;
            <<Alt_Fail_2>> null;
         end;
         P.Failed := False; P.Pos := Save;
         P.Pos := Save;
         Fail (P, "a item");
         return R;
      end;
   end Body_Of_Item;

   function Parse_Item (P : in out Parser) return Item_Type is
   begin
      Enter (P, 2);
      declare
         R : constant Item_Type := Body_Of_Item (P);
      begin
         P.Depth := P.Depth - 1;
         return R;
      end;
   end Parse_Item;

   function Body_Of_Cmd_word (P : in out Parser) return Cmd_word_Type is
   R : Cmd_word_Type;
   begin
      declare
         Start : constant Natural := P.Pos;
      begin
      loop
         declare
            Start : constant Natural := P.Pos;
         begin
            if P.Pos > Limit (P) then P.Pos := Start; exit; end if;
            declare V : Piece_Type := Parse_Piece (P); begin if P.Failed then P.Failed := False; P.Pos := Start; exit; end if; R.Append (new Piece_Type'(V)); end;
         end;
      end loop;
         if Natural (R.Length) < 1 then P.Pos := Start; Fail (P, "a cmd-word"); return R; end if;
      end;
      return R;
   end Body_Of_Cmd_word;

   function Parse_Cmd_word (P : in out Parser) return Cmd_word_Type is
   begin
      Enter (P, 3);
      declare
         R : constant Cmd_word_Type := Body_Of_Cmd_word (P);
      begin
         P.Depth := P.Depth - 1;
         return R;
      end;
   end Parse_Cmd_word;

   function Body_Of_Piece (P : in out Parser) return Piece_Type is
   R : Piece_Type;
   begin
      declare
         Save : constant Natural := P.Pos;
      begin
         declare
            R : Piece_Type;
         begin
            declare
               N : constant Natural := Scan_Plain (P.Text.all, P.Pos, Limit (P));
            begin
               if N = 0 then Fail (P, "plain"); goto Alt_Fail_3; end if;
               R.Plain := To_Unbounded_String (P.Text (P.Pos .. P.Pos + N - 1)); P.Pos := P.Pos + N;
            end;
            return R;
            <<Alt_Fail_3>> null;
         end;
         P.Failed := False; P.Pos := Save;
         declare
            R : Piece_Type;
         begin
            declare
               N : constant Natural := Scan_Escaped (P.Text.all, P.Pos, Limit (P));
            begin
               if N = 0 then Fail (P, "escaped"); goto Alt_Fail_4; end if;
               R.Escaped := To_Unbounded_String (P.Text (P.Pos .. P.Pos + N - 1)); P.Pos := P.Pos + N;
            end;
            return R;
            <<Alt_Fail_4>> null;
         end;
         P.Failed := False; P.Pos := Save;
         declare
            R : Piece_Type;
         begin
            declare V : Dquoted_Type := Parse_Dquoted (P); begin if P.Failed then goto Alt_Fail_5; end if; R.Dquoted := new Dquoted_Type'(V); end;
            return R;
            <<Alt_Fail_5>> null;
         end;
         P.Failed := False; P.Pos := Save;
         declare
            R : Piece_Type;
         begin
            declare V : Squoted_Type := Parse_Squoted (P); begin if P.Failed then goto Alt_Fail_6; end if; R.Squoted := new Squoted_Type'(V); end;
            return R;
            <<Alt_Fail_6>> null;
         end;
         P.Failed := False; P.Pos := Save;
         declare
            R : Piece_Type;
         begin
            declare
               N : constant Natural := Scan_Bad_quote (P.Text.all, P.Pos, Limit (P));
            begin
               if N = 0 then Fail (P, "bad-quote"); goto Alt_Fail_7; end if;
               R.Bad_quote := To_Unbounded_String (P.Text (P.Pos .. P.Pos + N - 1)); P.Pos := P.Pos + N;
            end;
            return R;
            <<Alt_Fail_7>> null;
         end;
         P.Failed := False; P.Pos := Save;
         declare
            R : Piece_Type;
         begin
            declare
               N : constant Natural := Scan_Bad_slash (P.Text.all, P.Pos, Limit (P));
            begin
               if N = 0 then Fail (P, "bad-slash"); goto Alt_Fail_8; end if;
               R.Bad_slash := To_Unbounded_String (P.Text (P.Pos .. P.Pos + N - 1)); P.Pos := P.Pos + N;
            end;
            return R;
            <<Alt_Fail_8>> null;
         end;
         P.Failed := False; P.Pos := Save;
         P.Pos := Save;
         Fail (P, "a piece");
         return R;
      end;
   end Body_Of_Piece;

   function Parse_Piece (P : in out Parser) return Piece_Type is
   begin
      Enter (P, 4);
      declare
         R : constant Piece_Type := Body_Of_Piece (P);
      begin
         P.Depth := P.Depth - 1;
         return R;
      end;
   end Parse_Piece;

   function Body_Of_Plain (P : in out Parser) return Plain_Type is
   R : Plain_Type;
   begin
      declare
         N : constant Natural := Scan_Plain (P.Text.all, P.Pos, Limit (P));
      begin
         if N = 0 then Fail (P, "plain"); return R; end if;
         R := To_Unbounded_String (P.Text (P.Pos .. P.Pos + N - 1));
         P.Pos := P.Pos + N;
         return R;
      end;
   end Body_Of_Plain;

   function Parse_Plain (P : in out Parser) return Plain_Type is
   begin
      Enter (P, 5);
      declare
         R : constant Plain_Type := Body_Of_Plain (P);
      begin
         P.Depth := P.Depth - 1;
         return R;
      end;
   end Parse_Plain;

   function Body_Of_Escaped (P : in out Parser) return Escaped_Type is
   R : Escaped_Type;
   begin
      declare
         N : constant Natural := Scan_Escaped (P.Text.all, P.Pos, Limit (P));
      begin
         if N = 0 then Fail (P, "escaped"); return R; end if;
         R := To_Unbounded_String (P.Text (P.Pos .. P.Pos + N - 1));
         P.Pos := P.Pos + N;
         return R;
      end;
   end Body_Of_Escaped;

   function Parse_Escaped (P : in out Parser) return Escaped_Type is
   begin
      Enter (P, 6);
      declare
         R : constant Escaped_Type := Body_Of_Escaped (P);
      begin
         P.Depth := P.Depth - 1;
         return R;
      end;
   end Parse_Escaped;

   function Body_Of_Dquoted (P : in out Parser) return Dquoted_Type is
   R : Dquoted_Type;
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
            if Ok then Expect_Lit (P, """"); if P.Failed then P.Failed := False; Ok := False; end if; end if;
            if Ok then Hit := True; end if;
         end if;
         P := Sv;
         if not Hit then Fail (P, "`""`"); return R; end if;
      end;
      R.Quote_mark := Parse_Quote_mark (P); if P.Failed then return R; end if;
      declare
         N : constant Natural := Scan_Dq_body (P.Text.all, P.Pos, Limit (P));
      begin
         R.Dq_body := To_Unbounded_String (P.Text (P.Pos .. P.Pos + N - 1)); P.Pos := P.Pos + N;
      end;
      Expect_Lit (P, """"); if P.Failed then return R; end if;
      return R;
   end Body_Of_Dquoted;

   function Parse_Dquoted (P : in out Parser) return Dquoted_Type is
   begin
      Enter (P, 7);
      declare
         R : constant Dquoted_Type := Body_Of_Dquoted (P);
      begin
         P.Depth := P.Depth - 1;
         return R;
      end;
   end Parse_Dquoted;

   function Body_Of_Squoted (P : in out Parser) return Squoted_Type is
   R : Squoted_Type;
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
            if Ok then Expect_Lit (P, "'"); if P.Failed then P.Failed := False; Ok := False; end if; end if;
            if Ok then Hit := True; end if;
         end if;
         P := Sv;
         if not Hit then Fail (P, "`'`"); return R; end if;
      end;
      R.Quote_mark := Parse_Quote_mark (P); if P.Failed then return R; end if;
      declare
         N : constant Natural := Scan_Sq_body (P.Text.all, P.Pos, Limit (P));
      begin
         R.Sq_body := To_Unbounded_String (P.Text (P.Pos .. P.Pos + N - 1)); P.Pos := P.Pos + N;
      end;
      Expect_Lit (P, "'"); if P.Failed then return R; end if;
      return R;
   end Body_Of_Squoted;

   function Parse_Squoted (P : in out Parser) return Squoted_Type is
   begin
      Enter (P, 8);
      declare
         R : constant Squoted_Type := Body_Of_Squoted (P);
      begin
         P.Depth := P.Depth - 1;
         return R;
      end;
   end Parse_Squoted;

   function Body_Of_Bad_quote (P : in out Parser) return Bad_quote_Type is
   R : Bad_quote_Type;
   begin
      declare
         N : constant Natural := Scan_Bad_quote (P.Text.all, P.Pos, Limit (P));
      begin
         if N = 0 then Fail (P, "bad-quote"); return R; end if;
         R := To_Unbounded_String (P.Text (P.Pos .. P.Pos + N - 1));
         P.Pos := P.Pos + N;
         return R;
      end;
   end Body_Of_Bad_quote;

   function Parse_Bad_quote (P : in out Parser) return Bad_quote_Type is
   begin
      Enter (P, 9);
      declare
         R : constant Bad_quote_Type := Body_Of_Bad_quote (P);
      begin
         P.Depth := P.Depth - 1;
         return R;
      end;
   end Parse_Bad_quote;

   function Body_Of_Bad_slash (P : in out Parser) return Bad_slash_Type is
   R : Bad_slash_Type;
   begin
      declare
         N : constant Natural := Scan_Bad_slash (P.Text.all, P.Pos, Limit (P));
      begin
         if N = 0 then Fail (P, "bad-slash"); return R; end if;
         R := To_Unbounded_String (P.Text (P.Pos .. P.Pos + N - 1));
         P.Pos := P.Pos + N;
         return R;
      end;
   end Body_Of_Bad_slash;

   function Parse_Bad_slash (P : in out Parser) return Bad_slash_Type is
   begin
      Enter (P, 10);
      declare
         R : constant Bad_slash_Type := Body_Of_Bad_slash (P);
      begin
         P.Depth := P.Depth - 1;
         return R;
      end;
   end Parse_Bad_slash;

   function Body_Of_Quote_mark (P : in out Parser) return Quote_mark_Type is
   R : Quote_mark_Type;
   begin
      if P.Pos > Limit (P) then Fail (P, "a Quote_mark_Type"); return R; end if;
      if P.Pos + 1 - 1 <= Limit (P) and then P.Text (P.Pos .. P.Pos + 1 - 1) = """" then
         R := Quote_mark_Op_1; P.Pos := P.Pos + 1;
      elsif P.Pos + 1 - 1 <= Limit (P) and then P.Text (P.Pos .. P.Pos + 1 - 1) = "'" then
         R := Quote_mark_Op_2; P.Pos := P.Pos + 1;
      else Fail (P, "`""` or `'`"); end if;
      return R;
   end Body_Of_Quote_mark;

   function Parse_Quote_mark (P : in out Parser) return Quote_mark_Type is
   begin
      Enter (P, 11);
      declare
         R : constant Quote_mark_Type := Body_Of_Quote_mark (P);
      begin
         P.Depth := P.Depth - 1;
         return R;
      end;
   end Parse_Quote_mark;

   function Body_Of_Dq_body (P : in out Parser) return Dq_body_Type is
   R : Dq_body_Type;
   Save : Natural;
   begin
      declare
         N : constant Natural := Scan_Dq_body (P.Text.all, P.Pos, Limit (P));
      begin
         R := To_Unbounded_String (P.Text (P.Pos .. P.Pos + N - 1));
         P.Pos := P.Pos + N;
         return R;
      end;
   end Body_Of_Dq_body;

   function Parse_Dq_body (P : in out Parser) return Dq_body_Type is
   begin
      Enter (P, 12);
      declare
         R : constant Dq_body_Type := Body_Of_Dq_body (P);
      begin
         P.Depth := P.Depth - 1;
         return R;
      end;
   end Parse_Dq_body;

   function Body_Of_Sq_body (P : in out Parser) return Sq_body_Type is
   R : Sq_body_Type;
   Save : Natural;
   begin
      declare
         N : constant Natural := Scan_Sq_body (P.Text.all, P.Pos, Limit (P));
      begin
         R := To_Unbounded_String (P.Text (P.Pos .. P.Pos + N - 1));
         P.Pos := P.Pos + N;
         return R;
      end;
   end Body_Of_Sq_body;

   function Parse_Sq_body (P : in out Parser) return Sq_body_Type is
   begin
      Enter (P, 13);
      declare
         R : constant Sq_body_Type := Body_Of_Sq_body (P);
      begin
         P.Depth := P.Depth - 1;
         return R;
      end;
   end Parse_Sq_body;

   function Body_Of_Gap (P : in out Parser) return Gap_Type is
   R : Gap_Type;
   begin
      declare
         N : constant Natural := Scan_Gap (P.Text.all, P.Pos, Limit (P));
      begin
         if N = 0 then Fail (P, "gap"); return R; end if;
         R := To_Unbounded_String (P.Text (P.Pos .. P.Pos + N - 1));
         P.Pos := P.Pos + N;
         return R;
      end;
   end Body_Of_Gap;

   function Parse_Gap (P : in out Parser) return Gap_Type is
   begin
      Enter (P, 15);
      declare
         R : constant Gap_Type := Body_Of_Gap (P);
      begin
         P.Depth := P.Depth - 1;
         return R;
      end;
   end Parse_Gap;

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
      Enter (P, 24);
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
      Enter (P, 25);
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
      Enter (P, 26);
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
      Enter (P, 27);
      declare
         R : constant Ws_Type := Body_Of_Ws (P);
      begin
         P.Depth := P.Depth - 1;
         return R;
      end;
   end Parse_Ws;

   function Rule_Name (I : Natural) return String is
     (case I is
        when 1 => "line",
        when 2 => "item",
        when 3 => "cmd-word",
        when 4 => "piece",
        when 5 => "plain",
        when 6 => "escaped",
        when 7 => "dquoted",
        when 8 => "squoted",
        when 9 => "bad-quote",
        when 10 => "bad-slash",
        when 11 => "quote-mark",
        when 12 => "dq-body",
        when 13 => "sq-body",
        when 14 => "rest",
        when 15 => "gap",
        when 16 => "plain-char",
        when 17 => "dq-char",
        when 18 => "sq-char",
        when 19 => "rune",
        when 20 => "space-char",
        when 21 => "not-x0-8_E-1F_21_23-26_28-5B_5D-84_86-9F_A1-167F_1681-1FFF_200B-2027_202A-202E_2030-205E_2060-2FFF_3001-10FFFF",
        when 22 => "not-x0-21_23-5B_5D-10FFFF",
        when 23 => "not-x0-26_28-5B_5D-10FFFF",
        when 24 => "word",
        when 25 => "int",
        when 26 => "str",
        when 27 => "ws",
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
   
   function Parse_Text (Text : String) return Line_Type is
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
      R : Line_Type;
   begin
      begin
         R := Parse_Line (P);
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

end Service_Words.Parser;

