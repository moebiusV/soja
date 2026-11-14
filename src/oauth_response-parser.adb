
with Interfaces;
with Ada.Unchecked_Deallocation;

package body Oauth_Response.Parser is

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

   function Scan_Authzid (S : String; Pos, Len : Natural) return Natural is
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
                  Match := N > 0 and then (Cp <= 0);
                  if Match then O := O + N; end if;
               end if;
               if Match and then O > Br then Br := O; end if;
               O := 0;
               Match := True;
               if Match then
                  N := Decode_Utf8 (S, Pos + Off + O, Len, Cp);
                  Match := N > 0 and then (Cp >= 2 and then Cp <= 43);
                  if Match then O := O + N; end if;
               end if;
               if Match and then O > Br then Br := O; end if;
               O := 0;
               Match := True;
               if Match then
                  N := Decode_Utf8 (S, Pos + Off + O, Len, Cp);
                  Match := N > 0 and then (Cp >= 45 and then Cp <= 1114111);
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
   end Scan_Authzid;

   function Scan_Key (S : String; Pos, Len : Natural) return Natural is
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
                  Match := N > 0 and then (Cp <= 0);
                  if Match then O := O + N; end if;
               end if;
               if Match and then O > Br then Br := O; end if;
               O := 0;
               Match := True;
               if Match then
                  N := Decode_Utf8 (S, Pos + Off + O, Len, Cp);
                  Match := N > 0 and then (Cp >= 2 and then Cp <= 60);
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
   end Scan_Key;

   function Scan_Value (S : String; Pos, Len : Natural) return Natural is
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
                  Match := N > 0 and then (Cp <= 0);
                  if Match then O := O + N; end if;
               end if;
               if Match and then O > Br then Br := O; end if;
               O := 0;
               Match := True;
               if Match then
                  N := Decode_Utf8 (S, Pos + Off + O, Len, Cp);
                  Match := N > 0 and then (Cp >= 2 and then Cp <= 1114111);
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
   end Scan_Value;

   function Scan_Final (S : String; Pos, Len : Natural) return Natural is
      Cp  : Natural;
      N   : Natural;
      Off : Natural := 0;
   begin
      N := Decode_Utf8 (S, Pos + Off, Len, Cp);
      if N = 0 or else not (Cp >= 1 and then Cp <= 1) then return 0; end if;
      Off := Off + N;
      return Off;
   end Scan_Final;

   function Scan_Soh (S : String; Pos, Len : Natural) return Natural is
      Cp  : Natural;
      N   : Natural;
      Off : Natural := 0;
   begin
      N := Decode_Utf8 (S, Pos + Off, Len, Cp);
      if N = 0 or else not (Cp >= 1 and then Cp <= 1) then return 0; end if;
      Off := Off + N;
      return Off;
   end Scan_Soh;

   function Scan_Key_char (S : String; Pos, Len : Natural) return Natural is
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
         Ok := N > 0 and then (Cp <= 0);
         if Ok then Off := Off + N; end if;
      end if;
      if Ok and then Off > Best then Best := Off; end if;
      Off := 0;
      Ok := True;
      if Ok then
         N := Decode_Utf8 (S, Pos + Off, Len, Cp);
         Ok := N > 0 and then (Cp >= 2 and then Cp <= 60);
         if Ok then Off := Off + N; end if;
      end if;
      if Ok and then Off > Best then Best := Off; end if;
      Off := 0;
      Ok := True;
      if Ok then
         N := Decode_Utf8 (S, Pos + Off, Len, Cp);
         Ok := N > 0 and then (Cp >= 62 and then Cp <= 1114111);
         if Ok then Off := Off + N; end if;
      end if;
      if Ok and then Off > Best then Best := Off; end if;
      return Best;
   end Scan_Key_char;

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

   procedure Dealloc_Response is new Ada.Unchecked_Deallocation (Response_Type, Response_Access);
   procedure Dealloc_Gs2_header is new Ada.Unchecked_Deallocation (Gs2_header_Type, Gs2_header_Access);
   procedure Dealloc_With_authzid is new Ada.Unchecked_Deallocation (With_authzid_Type, With_authzid_Access);
   procedure Dealloc_Without_authzid is new Ada.Unchecked_Deallocation (Without_authzid_Type, Without_authzid_Access);
   procedure Dealloc_Pairs is new Ada.Unchecked_Deallocation (Pairs_Type, Pairs_Access);
   procedure Dealloc_Pair is new Ada.Unchecked_Deallocation (Pair_Type, Pair_Access);

   procedure Free_Response (V : in out Response_Type) is
   begin
   if V.Gs2_header /= null then
      Free_Gs2_header (V.Gs2_header.all);
      Dealloc_Gs2_header (V.Gs2_header);
   end if;
   if V.Pairs /= null then
      Free_Pairs (V.Pairs.all);
      Dealloc_Pairs (V.Pairs);
   end if;
   end Free_Response;

   procedure Free_Gs2_header (V : in out Gs2_header_Type) is
   begin
   if V.With_authzid /= null then
      Free_With_authzid (V.With_authzid.all);
      Dealloc_With_authzid (V.With_authzid);
   end if;
   if V.Without_authzid /= null then
      Free_Without_authzid (V.Without_authzid.all);
      Dealloc_Without_authzid (V.Without_authzid);
   end if;
   end Free_Gs2_header;

   procedure Free_With_authzid (V : in out With_authzid_Type) is
      pragma Unreferenced (V);
   begin
      null;
   end Free_With_authzid;

   procedure Free_Without_authzid (V : in out Without_authzid_Type) is
      pragma Unreferenced (V);
   begin
      null;
   end Free_Without_authzid;

   procedure Free_Pairs (V : in out Pairs_Type) is
   begin
   Free_Pairs_1 (V.Pairs_1);
   end Free_Pairs;

   procedure Free_Pair (V : in out Pair_Type) is
      pragma Unreferenced (V);
   begin
      null;
   end Free_Pair;

   procedure Free_Pairs_1 (V : in out Pairs_1_Type) is
   begin
   for K in V.First_Index .. V.Last_Index loop
      declare
         E : Pair_Access := V (K);
      begin
         if E /= null then
            Free_Pair (E.all);
            V.Replace_Element (K, null);
            Dealloc_Pair (E);
         end if;
      end;
   end loop;
   end Free_Pairs_1;

   function Parse_Response (P : in out Parser) return Response_Type;
   function Parse_Gs2_header (P : in out Parser) return Gs2_header_Type;
   function Parse_With_authzid (P : in out Parser) return With_authzid_Type;
   function Parse_Without_authzid (P : in out Parser) return Without_authzid_Type;
   function Parse_Authzid (P : in out Parser) return Authzid_Type;
   function Parse_Pairs (P : in out Parser) return Pairs_Type;
   function Parse_Pair (P : in out Parser) return Pair_Type;
   function Parse_Key (P : in out Parser) return Key_Type;
   function Parse_Value (P : in out Parser) return Value_Type;
   function Parse_Final (P : in out Parser) return Final_Type;
   function Parse_Soh (P : in out Parser) return Soh_Type;
   function Parse_Key_char (P : in out Parser) return Key_char_Type;
   function Parse_Word (P : in out Parser) return Word_Type;
   function Parse_Int (P : in out Parser) return Int_Type;
   function Parse_Str (P : in out Parser) return Str_Type;
   function Parse_Ws (P : in out Parser) return Ws_Type;
   function Parse_Pairs_1 (P : in out Parser) return Pairs_1_Type;

   function Body_Of_Response (P : in out Parser) return Response_Type is
   R : Response_Type;
   begin
      declare V : Gs2_header_Type := Parse_Gs2_header (P); begin if P.Failed then return R; end if; R.Gs2_header := new Gs2_header_Type'(V); end;
      declare V : Pairs_Type := Parse_Pairs (P); begin if P.Failed then return R; end if; R.Pairs := new Pairs_Type'(V); end;
      declare
         N : constant Natural := Scan_Final (P.Text.all, P.Pos, Limit (P));
      begin
         if N = 0 then Fail (P, "final"); return R; end if;
         R.Final := To_Unbounded_String (P.Text (P.Pos .. P.Pos + N - 1)); P.Pos := P.Pos + N;
      end;
      return R;
   end Body_Of_Response;

   function Parse_Response (P : in out Parser) return Response_Type is
   begin
      Enter (P, 1);
      declare
         R : constant Response_Type := Body_Of_Response (P);
      begin
         P.Depth := P.Depth - 1;
         return R;
      end;
   end Parse_Response;

   function Body_Of_Gs2_header (P : in out Parser) return Gs2_header_Type is
   R : Gs2_header_Type;
   begin
      declare
         Save : constant Natural := P.Pos;
      begin
         declare
            R : Gs2_header_Type;
         begin
            declare V : With_authzid_Type := Parse_With_authzid (P); begin if P.Failed then goto Alt_Fail_1; end if; R.With_authzid := new With_authzid_Type'(V); end;
            return R;
            <<Alt_Fail_1>> null;
         end;
         P.Failed := False; P.Pos := Save;
         declare
            R : Gs2_header_Type;
         begin
            declare V : Without_authzid_Type := Parse_Without_authzid (P); begin if P.Failed then goto Alt_Fail_2; end if; R.Without_authzid := new Without_authzid_Type'(V); end;
            return R;
            <<Alt_Fail_2>> null;
         end;
         P.Failed := False; P.Pos := Save;
         P.Pos := Save;
         Fail (P, "a gs2-header");
         return R;
      end;
   end Body_Of_Gs2_header;

   function Parse_Gs2_header (P : in out Parser) return Gs2_header_Type is
   begin
      Enter (P, 2);
      declare
         R : constant Gs2_header_Type := Body_Of_Gs2_header (P);
      begin
         P.Depth := P.Depth - 1;
         return R;
      end;
   end Parse_Gs2_header;

   function Body_Of_With_authzid (P : in out Parser) return With_authzid_Type is
   R : With_authzid_Type;
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
            if Ok then Expect_Lit (P, "n,a="); if P.Failed then P.Failed := False; Ok := False; end if; end if;
            if Ok then Hit := True; end if;
         end if;
         P := Sv;
         if not Hit then Fail (P, "`n,a=`"); return R; end if;
      end;
      Expect_Lit (P, "n,a="); if P.Failed then return R; end if;
      declare
         N : constant Natural := Scan_Authzid (P.Text.all, P.Pos, Limit (P));
      begin
         R.Authzid := To_Unbounded_String (P.Text (P.Pos .. P.Pos + N - 1)); P.Pos := P.Pos + N;
      end;
      Expect_Lit (P, ","); if P.Failed then return R; end if;
      return R;
   end Body_Of_With_authzid;

   function Parse_With_authzid (P : in out Parser) return With_authzid_Type is
   begin
      Enter (P, 3);
      declare
         R : constant With_authzid_Type := Body_Of_With_authzid (P);
      begin
         P.Depth := P.Depth - 1;
         return R;
      end;
   end Parse_With_authzid;

   function Body_Of_Without_authzid (P : in out Parser) return Without_authzid_Type is
   R : Without_authzid_Type;
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
            if Ok then Expect_Lit (P, "n,,"); if P.Failed then P.Failed := False; Ok := False; end if; end if;
            if Ok then Hit := True; end if;
         end if;
         P := Sv;
         if not Hit then Fail (P, "`n,,`"); return R; end if;
      end;
      Expect_Lit (P, "n,,"); if P.Failed then return R; end if;
      return R;
   end Body_Of_Without_authzid;

   function Parse_Without_authzid (P : in out Parser) return Without_authzid_Type is
   begin
      Enter (P, 4);
      declare
         R : constant Without_authzid_Type := Body_Of_Without_authzid (P);
      begin
         P.Depth := P.Depth - 1;
         return R;
      end;
   end Parse_Without_authzid;

   function Body_Of_Authzid (P : in out Parser) return Authzid_Type is
   R : Authzid_Type;
   begin
      declare
         N : constant Natural := Scan_Authzid (P.Text.all, P.Pos, Limit (P));
      begin
         R := To_Unbounded_String (P.Text (P.Pos .. P.Pos + N - 1));
         P.Pos := P.Pos + N;
         return R;
      end;
   end Body_Of_Authzid;

   function Parse_Authzid (P : in out Parser) return Authzid_Type is
   begin
      Enter (P, 5);
      declare
         R : constant Authzid_Type := Body_Of_Authzid (P);
      begin
         P.Depth := P.Depth - 1;
         return R;
      end;
   end Parse_Authzid;

   function Body_Of_Pairs (P : in out Parser) return Pairs_Type is
   R : Pairs_Type;
   begin
      declare
         N : constant Natural := Scan_Soh (P.Text.all, P.Pos, Limit (P));
      begin
         if N = 0 then Fail (P, "soh"); return R; end if;
         R.Soh := To_Unbounded_String (P.Text (P.Pos .. P.Pos + N - 1)); P.Pos := P.Pos + N;
      end;
      R.Pairs_1 := Parse_Pairs_1 (P); if P.Failed then return R; end if;
      return R;
   end Body_Of_Pairs;

   function Parse_Pairs (P : in out Parser) return Pairs_Type is
   begin
      Enter (P, 6);
      declare
         R : constant Pairs_Type := Body_Of_Pairs (P);
      begin
         P.Depth := P.Depth - 1;
         return R;
      end;
   end Parse_Pairs;

   function Body_Of_Pair (P : in out Parser) return Pair_Type is
   R : Pair_Type;
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
            if Ok then declare N : constant Natural := Scan_Key_char (P.Text.all, P.Pos, Limit (P)); begin if N > 0 then P.Pos := P.Pos + N; else Ok := False; end if; end; end if;
            if Ok then Hit := True; end if;
         end if;
         P := Sv;
         if not Hit then Fail (P, "key-char"); return R; end if;
      end;
      declare
         N : constant Natural := Scan_Key (P.Text.all, P.Pos, Limit (P));
      begin
         if N = 0 then Fail (P, "key"); return R; end if;
         R.Key := To_Unbounded_String (P.Text (P.Pos .. P.Pos + N - 1)); P.Pos := P.Pos + N;
      end;
      Expect_Lit (P, "="); if P.Failed then return R; end if;
      declare
         N : constant Natural := Scan_Value (P.Text.all, P.Pos, Limit (P));
      begin
         R.Value := To_Unbounded_String (P.Text (P.Pos .. P.Pos + N - 1)); P.Pos := P.Pos + N;
      end;
      declare
         N : constant Natural := Scan_Soh (P.Text.all, P.Pos, Limit (P));
      begin
         if N = 0 then Fail (P, "soh"); return R; end if;
         R.Soh := To_Unbounded_String (P.Text (P.Pos .. P.Pos + N - 1)); P.Pos := P.Pos + N;
      end;
      return R;
   end Body_Of_Pair;

   function Parse_Pair (P : in out Parser) return Pair_Type is
   begin
      Enter (P, 7);
      declare
         R : constant Pair_Type := Body_Of_Pair (P);
      begin
         P.Depth := P.Depth - 1;
         return R;
      end;
   end Parse_Pair;

   function Body_Of_Key (P : in out Parser) return Key_Type is
   R : Key_Type;
   begin
      declare
         N : constant Natural := Scan_Key (P.Text.all, P.Pos, Limit (P));
      begin
         if N = 0 then Fail (P, "key"); return R; end if;
         R := To_Unbounded_String (P.Text (P.Pos .. P.Pos + N - 1));
         P.Pos := P.Pos + N;
         return R;
      end;
   end Body_Of_Key;

   function Parse_Key (P : in out Parser) return Key_Type is
   begin
      Enter (P, 8);
      declare
         R : constant Key_Type := Body_Of_Key (P);
      begin
         P.Depth := P.Depth - 1;
         return R;
      end;
   end Parse_Key;

   function Body_Of_Value (P : in out Parser) return Value_Type is
   R : Value_Type;
   begin
      declare
         N : constant Natural := Scan_Value (P.Text.all, P.Pos, Limit (P));
      begin
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

   function Body_Of_Final (P : in out Parser) return Final_Type is
   R : Final_Type;
   begin
      declare
         N : constant Natural := Scan_Final (P.Text.all, P.Pos, Limit (P));
      begin
         if N = 0 then Fail (P, "final"); return R; end if;
         R := To_Unbounded_String (P.Text (P.Pos .. P.Pos + N - 1));
         P.Pos := P.Pos + N;
         return R;
      end;
   end Body_Of_Final;

   function Parse_Final (P : in out Parser) return Final_Type is
   begin
      Enter (P, 10);
      declare
         R : constant Final_Type := Body_Of_Final (P);
      begin
         P.Depth := P.Depth - 1;
         return R;
      end;
   end Parse_Final;

   function Body_Of_Soh (P : in out Parser) return Soh_Type is
   R : Soh_Type;
   begin
      declare
         N : constant Natural := Scan_Soh (P.Text.all, P.Pos, Limit (P));
      begin
         if N = 0 then Fail (P, "soh"); return R; end if;
         R := To_Unbounded_String (P.Text (P.Pos .. P.Pos + N - 1));
         P.Pos := P.Pos + N;
         return R;
      end;
   end Body_Of_Soh;

   function Parse_Soh (P : in out Parser) return Soh_Type is
   begin
      Enter (P, 11);
      declare
         R : constant Soh_Type := Body_Of_Soh (P);
      begin
         P.Depth := P.Depth - 1;
         return R;
      end;
   end Parse_Soh;

   function Body_Of_Key_char (P : in out Parser) return Key_char_Type is
   R : Key_char_Type;
   begin
      declare
         N : constant Natural := Scan_Key_char (P.Text.all, P.Pos, Limit (P));
      begin
         if N = 0 then Fail (P, "key-char"); return R; end if;
         R := To_Unbounded_String (P.Text (P.Pos .. P.Pos + N - 1));
         P.Pos := P.Pos + N;
         return R;
      end;
   end Body_Of_Key_char;

   function Parse_Key_char (P : in out Parser) return Key_char_Type is
   begin
      Enter (P, 13);
      declare
         R : constant Key_char_Type := Body_Of_Key_char (P);
      begin
         P.Depth := P.Depth - 1;
         return R;
      end;
   end Parse_Key_char;

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
      Enter (P, 15);
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
      Enter (P, 16);
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
      Enter (P, 17);
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
      Enter (P, 18);
      declare
         R : constant Ws_Type := Body_Of_Ws (P);
      begin
         P.Depth := P.Depth - 1;
         return R;
      end;
   end Parse_Ws;

   function Body_Of_Pairs_1 (P : in out Parser) return Pairs_1_Type is
   R : Pairs_1_Type;
   begin
      loop
         declare
            Start : constant Natural := P.Pos;
         begin
            if P.Pos > Limit (P) then P.Pos := Start; exit; end if;
            declare V : Pair_Type := Parse_Pair (P); begin if P.Failed then P.Failed := False; P.Pos := Start; exit; end if; R.Append (new Pair_Type'(V)); end;
         end;
      end loop;
      return R;
   end Body_Of_Pairs_1;

   function Parse_Pairs_1 (P : in out Parser) return Pairs_1_Type is
   begin
      Enter (P, 19);
      declare
         R : constant Pairs_1_Type := Body_Of_Pairs_1 (P);
      begin
         P.Depth := P.Depth - 1;
         return R;
      end;
   end Parse_Pairs_1;

   function Rule_Name (I : Natural) return String is
     (case I is
        when 1 => "response",
        when 2 => "gs2-header",
        when 3 => "with-authzid",
        when 4 => "without-authzid",
        when 5 => "authzid",
        when 6 => "pairs",
        when 7 => "pair",
        when 8 => "key",
        when 9 => "value",
        when 10 => "final",
        when 11 => "soh",
        when 12 => "authz-char",
        when 13 => "key-char",
        when 14 => "value-char",
        when 15 => "word",
        when 16 => "int",
        when 17 => "str",
        when 18 => "ws",
        when 19 => "",
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
   
   function Parse_Text (Text : String) return Response_Type is
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
      R : Response_Type;
   begin
      begin
         R := Parse_Response (P);
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

end Oauth_Response.Parser;

