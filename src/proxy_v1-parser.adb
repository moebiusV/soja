
with Interfaces;
with Ada.Unchecked_Deallocation;

package body Proxy_V1.Parser is

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

   function Scan_Unknown (S : String; Pos, Len : Natural) return Natural is
      type Table is array (Natural range <>) of Natural;
      Lo    : constant Table := (85, 78, 75, 78, 79, 87, 78, 32, 0, 1, 1);
      Hi    : constant Table := (85, 78, 75, 78, 79, 87, 78, 32, 255, 0, 0);
      To    : constant Table := (1, 2, 3, 4, 5, 6, 7, 8, 8, 0, 0);
      First : constant Table := (0, 1, 2, 3, 4, 5, 6, 7, 8, 9);
      Acc   : constant Table := (0, 0, 0, 0, 0, 0, 0, 1, 1, 0);
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
   end Scan_Unknown;

   function Scan_Source (S : String; Pos, Len : Natural) return Natural is
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
                  Match := N > 0 and then (Cp >= 33 and then Cp <= 126);
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
   end Scan_Source;

   function Scan_Target (S : String; Pos, Len : Natural) return Natural is
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
                  Match := N > 0 and then (Cp >= 33 and then Cp <= 126);
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
   end Scan_Target;

   function Scan_Sep (S : String; Pos, Len : Natural) return Natural is
      Cp  : Natural;
      N   : Natural;
      Off : Natural := 0;
   begin
      N := Decode_Utf8 (S, Pos + Off, Len, Cp);
      if N = 0 or else not (Cp >= 32 and then Cp <= 32) then return 0; end if;
      Off := Off + N;
      return Off;
   end Scan_Sep;

   function Scan_Sep_2 (S : String; Pos, Len : Natural) return Natural is
      Cp  : Natural;
      N   : Natural;
      Off : Natural := 0;
   begin
      N := Decode_Utf8 (S, Pos + Off, Len, Cp);
      if N = 0 or else not (Cp >= 32 and then Cp <= 32) then return 0; end if;
      Off := Off + N;
      return Off;
   end Scan_Sep_2;

   function Scan_Sep_3 (S : String; Pos, Len : Natural) return Natural is
      Cp  : Natural;
      N   : Natural;
      Off : Natural := 0;
   begin
      N := Decode_Utf8 (S, Pos + Off, Len, Cp);
      if N = 0 or else not (Cp >= 32 and then Cp <= 32) then return 0; end if;
      Off := Off + N;
      return Off;
   end Scan_Sep_3;

   function Scan_Sep_4 (S : String; Pos, Len : Natural) return Natural is
      Cp  : Natural;
      N   : Natural;
      Off : Natural := 0;
   begin
      N := Decode_Utf8 (S, Pos + Off, Len, Cp);
      if N = 0 or else not (Cp >= 32 and then Cp <= 32) then return 0; end if;
      Off := Off + N;
      return Off;
   end Scan_Sep_4;

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
   procedure Dealloc_Tcp is new Ada.Unchecked_Deallocation (Tcp_Type, Tcp_Access);
   procedure Dealloc_Line_1 is new Ada.Unchecked_Deallocation (Line_1_Type, Line_1_Access);

   procedure Free_Line (V : in out Line_Type) is
   begin
   if V.Line_1 /= null then
      Free_Line_1 (V.Line_1.all);
      Dealloc_Line_1 (V.Line_1);
   end if;
   end Free_Line;

   procedure Free_Tcp (V : in out Tcp_Type) is
      pragma Unreferenced (V);
   begin
      null;
   end Free_Tcp;

   procedure Free_Line_1 (V : in out Line_1_Type) is
   begin
   if V.Tcp /= null then
      Free_Tcp (V.Tcp.all);
      Dealloc_Tcp (V.Tcp);
   end if;
   end Free_Line_1;

   function Parse_Line (P : in out Parser) return Line_Type;
   function Parse_Unknown (P : in out Parser) return Unknown_Type;
   function Parse_Tcp (P : in out Parser) return Tcp_Type;
   function Parse_Family (P : in out Parser) return Family_Type;
   function Parse_Source (P : in out Parser) return Source_Type;
   function Parse_Target (P : in out Parser) return Target_Type;
   function Parse_Source_port (P : in out Parser) return Source_port_Type;
   function Parse_Target_port (P : in out Parser) return Target_port_Type;
   function Parse_Sep (P : in out Parser) return Sep_Type;
   function Parse_Word (P : in out Parser) return Word_Type;
   function Parse_Int (P : in out Parser) return Int_Type;
   function Parse_Str (P : in out Parser) return Str_Type;
   function Parse_Ws (P : in out Parser) return Ws_Type;
   function Parse_Line_1 (P : in out Parser) return Line_1_Type;
   function Parse_Sep_2 (P : in out Parser) return Sep_2_Type;
   function Parse_Sep_3 (P : in out Parser) return Sep_3_Type;
   function Parse_Sep_4 (P : in out Parser) return Sep_4_Type;

   function Body_Of_Line (P : in out Parser) return Line_Type is
   R : Line_Type;
   begin
      Expect_Lit (P, "PROXY"); if P.Failed then return R; end if;
      declare N : constant Natural := Scan_Sep (P.Text.all, P.Pos, Limit (P)); begin if N = 0 then Fail (P, "sep"); return R; end if; P.Pos := P.Pos + N; end;
      declare V : Line_1_Type := Parse_Line_1 (P); begin if P.Failed then return R; end if; R.Line_1 := new Line_1_Type'(V); end;
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

   function Body_Of_Unknown (P : in out Parser) return Unknown_Type is
   R : Unknown_Type;
   begin
      declare
         N : constant Natural := Scan_Unknown (P.Text.all, P.Pos, Limit (P));
      begin
         if N = 0 then Fail (P, "unknown"); return R; end if;
         R := To_Unbounded_String (P.Text (P.Pos .. P.Pos + N - 1));
         P.Pos := P.Pos + N;
         return R;
      end;
   end Body_Of_Unknown;

   function Parse_Unknown (P : in out Parser) return Unknown_Type is
   begin
      Enter (P, 2);
      declare
         R : constant Unknown_Type := Body_Of_Unknown (P);
      begin
         P.Depth := P.Depth - 1;
         return R;
      end;
   end Parse_Unknown;

   function Body_Of_Tcp (P : in out Parser) return Tcp_Type is
   R : Tcp_Type;
   begin
      R.Family := Parse_Family (P); if P.Failed then return R; end if;
      declare N : constant Natural := Scan_Sep (P.Text.all, P.Pos, Limit (P)); begin if N = 0 then Fail (P, "sep"); return R; end if; P.Pos := P.Pos + N; end;
      declare
         N : constant Natural := Scan_Source (P.Text.all, P.Pos, Limit (P));
      begin
         if N = 0 then Fail (P, "source"); return R; end if;
         R.Source := To_Unbounded_String (P.Text (P.Pos .. P.Pos + N - 1)); P.Pos := P.Pos + N;
      end;
      declare
         N : constant Natural := Scan_Sep_2 (P.Text.all, P.Pos, Limit (P));
      begin
         if N = 0 then Fail (P, "sep_2"); return R; end if;
         R.Sep_2 := To_Unbounded_String (P.Text (P.Pos .. P.Pos + N - 1)); P.Pos := P.Pos + N;
      end;
      declare
         N : constant Natural := Scan_Target (P.Text.all, P.Pos, Limit (P));
      begin
         if N = 0 then Fail (P, "target"); return R; end if;
         R.Target := To_Unbounded_String (P.Text (P.Pos .. P.Pos + N - 1)); P.Pos := P.Pos + N;
      end;
      declare
         N : constant Natural := Scan_Sep_3 (P.Text.all, P.Pos, Limit (P));
      begin
         if N = 0 then Fail (P, "sep_3"); return R; end if;
         R.Sep_3 := To_Unbounded_String (P.Text (P.Pos .. P.Pos + N - 1)); P.Pos := P.Pos + N;
      end;
      R.Source_port := Parse_Source_port (P); if P.Failed then return R; end if;
      declare
         N : constant Natural := Scan_Sep_4 (P.Text.all, P.Pos, Limit (P));
      begin
         if N = 0 then Fail (P, "sep_4"); return R; end if;
         R.Sep_4 := To_Unbounded_String (P.Text (P.Pos .. P.Pos + N - 1)); P.Pos := P.Pos + N;
      end;
      R.Target_port := Parse_Target_port (P); if P.Failed then return R; end if;
      return R;
   end Body_Of_Tcp;

   function Parse_Tcp (P : in out Parser) return Tcp_Type is
   begin
      Enter (P, 3);
      declare
         R : constant Tcp_Type := Body_Of_Tcp (P);
      begin
         P.Depth := P.Depth - 1;
         return R;
      end;
   end Parse_Tcp;

   function Body_Of_Family (P : in out Parser) return Family_Type is
   R : Family_Type;
   begin
      if P.Pos > Limit (P) then Fail (P, "a Family_Type"); return R; end if;
      if P.Pos + 4 - 1 <= Limit (P) and then P.Text (P.Pos .. P.Pos + 4 - 1) = "TCP4" then
         R := Family_TCP4; P.Pos := P.Pos + 4;
      elsif P.Pos + 4 - 1 <= Limit (P) and then P.Text (P.Pos .. P.Pos + 4 - 1) = "TCP6" then
         R := Family_TCP6; P.Pos := P.Pos + 4;
      else Fail (P, "`TCP4` or `TCP6`"); end if;
      return R;
   end Body_Of_Family;

   function Parse_Family (P : in out Parser) return Family_Type is
   begin
      Enter (P, 4);
      declare
         R : constant Family_Type := Body_Of_Family (P);
      begin
         P.Depth := P.Depth - 1;
         return R;
      end;
   end Parse_Family;

   function Body_Of_Source (P : in out Parser) return Source_Type is
   R : Source_Type;
   begin
      declare
         N : constant Natural := Scan_Source (P.Text.all, P.Pos, Limit (P));
      begin
         if N = 0 then Fail (P, "source"); return R; end if;
         R := To_Unbounded_String (P.Text (P.Pos .. P.Pos + N - 1));
         P.Pos := P.Pos + N;
         return R;
      end;
   end Body_Of_Source;

   function Parse_Source (P : in out Parser) return Source_Type is
   begin
      Enter (P, 5);
      declare
         R : constant Source_Type := Body_Of_Source (P);
      begin
         P.Depth := P.Depth - 1;
         return R;
      end;
   end Parse_Source;

   function Body_Of_Target (P : in out Parser) return Target_Type is
   R : Target_Type;
   begin
      declare
         N : constant Natural := Scan_Target (P.Text.all, P.Pos, Limit (P));
      begin
         if N = 0 then Fail (P, "target"); return R; end if;
         R := To_Unbounded_String (P.Text (P.Pos .. P.Pos + N - 1));
         P.Pos := P.Pos + N;
         return R;
      end;
   end Body_Of_Target;

   function Parse_Target (P : in out Parser) return Target_Type is
   begin
      Enter (P, 6);
      declare
         R : constant Target_Type := Body_Of_Target (P);
      begin
         P.Depth := P.Depth - 1;
         return R;
      end;
   end Parse_Target;

   function Body_Of_Source_port (P : in out Parser) return Source_port_Type is
   R : Source_port_Type;
   begin
      declare
         N : constant Natural := Scan_Int (P.Text.all, P.Pos, Limit (P));
      begin
         if N = 0 then Fail (P, "a number"); return R; end if;
         R := Long_Long_Integer'Value (P.Text (P.Pos .. P.Pos + N - 1)); P.Pos := P.Pos + N;
         return R;
      end;
   end Body_Of_Source_port;

   function Parse_Source_port (P : in out Parser) return Source_port_Type is
   begin
      Enter (P, 7);
      declare
         R : constant Source_port_Type := Body_Of_Source_port (P);
      begin
         P.Depth := P.Depth - 1;
         return R;
      end;
   end Parse_Source_port;

   function Body_Of_Target_port (P : in out Parser) return Target_port_Type is
   R : Target_port_Type;
   begin
      declare
         N : constant Natural := Scan_Int (P.Text.all, P.Pos, Limit (P));
      begin
         if N = 0 then Fail (P, "a number"); return R; end if;
         R := Long_Long_Integer'Value (P.Text (P.Pos .. P.Pos + N - 1)); P.Pos := P.Pos + N;
         return R;
      end;
   end Body_Of_Target_port;

   function Parse_Target_port (P : in out Parser) return Target_port_Type is
   begin
      Enter (P, 8);
      declare
         R : constant Target_port_Type := Body_Of_Target_port (P);
      begin
         P.Depth := P.Depth - 1;
         return R;
      end;
   end Parse_Target_port;

   function Body_Of_Sep (P : in out Parser) return Sep_Type is
   R : Sep_Type;
   begin
      declare
         N : constant Natural := Scan_Sep (P.Text.all, P.Pos, Limit (P));
      begin
         if N = 0 then Fail (P, "sep"); return R; end if;
         R := To_Unbounded_String (P.Text (P.Pos .. P.Pos + N - 1));
         P.Pos := P.Pos + N;
         return R;
      end;
   end Body_Of_Sep;

   function Parse_Sep (P : in out Parser) return Sep_Type is
   begin
      Enter (P, 9);
      declare
         R : constant Sep_Type := Body_Of_Sep (P);
      begin
         P.Depth := P.Depth - 1;
         return R;
      end;
   end Parse_Sep;

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

   function Body_Of_Line_1 (P : in out Parser) return Line_1_Type is
   R : Line_1_Type;
   begin
      declare
         Save : constant Natural := P.Pos;
      begin
         declare
            R : Line_1_Type;
         begin
            declare
               N : constant Natural := Scan_Unknown (P.Text.all, P.Pos, Limit (P));
            begin
               if N = 0 then Fail (P, "unknown"); goto Alt_Fail_1; end if;
               R.Unknown := To_Unbounded_String (P.Text (P.Pos .. P.Pos + N - 1)); P.Pos := P.Pos + N;
            end;
            return R;
            <<Alt_Fail_1>> null;
         end;
         P.Failed := False; P.Pos := Save;
         declare
            R : Line_1_Type;
         begin
            declare V : Tcp_Type := Parse_Tcp (P); begin if P.Failed then goto Alt_Fail_2; end if; R.Tcp := new Tcp_Type'(V); end;
            return R;
            <<Alt_Fail_2>> null;
         end;
         P.Failed := False; P.Pos := Save;
         P.Pos := Save;
         Fail (P, "a line_1");
         return R;
      end;
   end Body_Of_Line_1;

   function Parse_Line_1 (P : in out Parser) return Line_1_Type is
   begin
      Enter (P, 17);
      declare
         R : constant Line_1_Type := Body_Of_Line_1 (P);
      begin
         P.Depth := P.Depth - 1;
         return R;
      end;
   end Parse_Line_1;

   function Body_Of_Sep_2 (P : in out Parser) return Sep_2_Type is
   R : Sep_2_Type;
   begin
      declare
         N : constant Natural := Scan_Sep_2 (P.Text.all, P.Pos, Limit (P));
      begin
         if N = 0 then Fail (P, "sep_2"); return R; end if;
         R := To_Unbounded_String (P.Text (P.Pos .. P.Pos + N - 1));
         P.Pos := P.Pos + N;
         return R;
      end;
   end Body_Of_Sep_2;

   function Parse_Sep_2 (P : in out Parser) return Sep_2_Type is
   begin
      Enter (P, 18);
      declare
         R : constant Sep_2_Type := Body_Of_Sep_2 (P);
      begin
         P.Depth := P.Depth - 1;
         return R;
      end;
   end Parse_Sep_2;

   function Body_Of_Sep_3 (P : in out Parser) return Sep_3_Type is
   R : Sep_3_Type;
   begin
      declare
         N : constant Natural := Scan_Sep_3 (P.Text.all, P.Pos, Limit (P));
      begin
         if N = 0 then Fail (P, "sep_3"); return R; end if;
         R := To_Unbounded_String (P.Text (P.Pos .. P.Pos + N - 1));
         P.Pos := P.Pos + N;
         return R;
      end;
   end Body_Of_Sep_3;

   function Parse_Sep_3 (P : in out Parser) return Sep_3_Type is
   begin
      Enter (P, 19);
      declare
         R : constant Sep_3_Type := Body_Of_Sep_3 (P);
      begin
         P.Depth := P.Depth - 1;
         return R;
      end;
   end Parse_Sep_3;

   function Body_Of_Sep_4 (P : in out Parser) return Sep_4_Type is
   R : Sep_4_Type;
   begin
      declare
         N : constant Natural := Scan_Sep_4 (P.Text.all, P.Pos, Limit (P));
      begin
         if N = 0 then Fail (P, "sep_4"); return R; end if;
         R := To_Unbounded_String (P.Text (P.Pos .. P.Pos + N - 1));
         P.Pos := P.Pos + N;
         return R;
      end;
   end Body_Of_Sep_4;

   function Parse_Sep_4 (P : in out Parser) return Sep_4_Type is
   begin
      Enter (P, 20);
      declare
         R : constant Sep_4_Type := Body_Of_Sep_4 (P);
      begin
         P.Depth := P.Depth - 1;
         return R;
      end;
   end Parse_Sep_4;

   function Rule_Name (I : Natural) return String is
     (case I is
        when 1 => "line",
        when 2 => "unknown",
        when 3 => "tcp",
        when 4 => "family",
        when 5 => "source",
        when 6 => "target",
        when 7 => "source-port",
        when 8 => "target-port",
        when 9 => "sep",
        when 10 => "VCHAR",
        when 11 => "OCTET",
        when 12 => "SP",
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

end Proxy_V1.Parser;

