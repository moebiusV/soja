
with Interfaces;
with Ada.Unchecked_Deallocation;

package body Irc_Prefix.Parser is

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

   function Scan_Bare_any (S : String; Pos, Len : Natural) return Natural is
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
   end Scan_Bare_any;

   function Scan_Bare_name (S : String; Pos, Len : Natural) return Natural is
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
                  Match := N > 0 and then (Cp <= 32);
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
   end Scan_Bare_name;

   function Scan_Bare_user_name (S : String; Pos, Len : Natural) return Natural is
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
   end Scan_Bare_user_name;

   function Scan_Bare_host_name (S : String; Pos, Len : Natural) return Natural is
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
   end Scan_Bare_host_name;

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

   procedure Dealloc_Bare_prefix is new Ada.Unchecked_Deallocation (Bare_prefix_Type, Bare_prefix_Access);
   procedure Dealloc_Bare_full is new Ada.Unchecked_Deallocation (Bare_full_Type, Bare_full_Access);
   procedure Dealloc_Bare_user is new Ada.Unchecked_Deallocation (Bare_user_Type, Bare_user_Access);
   procedure Dealloc_Bare_host is new Ada.Unchecked_Deallocation (Bare_host_Type, Bare_host_Access);
   procedure Dealloc_Bare_nick is new Ada.Unchecked_Deallocation (Bare_nick_Type, Bare_nick_Access);

   procedure Free_Bare_prefix (V : in out Bare_prefix_Type) is
   begin
   if V.Bare_full /= null then
      Free_Bare_full (V.Bare_full.all);
      Dealloc_Bare_full (V.Bare_full);
   end if;
   if V.Bare_user /= null then
      Free_Bare_user (V.Bare_user.all);
      Dealloc_Bare_user (V.Bare_user);
   end if;
   if V.Bare_host /= null then
      Free_Bare_host (V.Bare_host.all);
      Dealloc_Bare_host (V.Bare_host);
   end if;
   if V.Bare_nick /= null then
      Free_Bare_nick (V.Bare_nick.all);
      Dealloc_Bare_nick (V.Bare_nick);
   end if;
   end Free_Bare_prefix;

   procedure Free_Bare_full (V : in out Bare_full_Type) is
      pragma Unreferenced (V);
   begin
      null;
   end Free_Bare_full;

   procedure Free_Bare_user (V : in out Bare_user_Type) is
      pragma Unreferenced (V);
   begin
      null;
   end Free_Bare_user;

   procedure Free_Bare_host (V : in out Bare_host_Type) is
      pragma Unreferenced (V);
   begin
      null;
   end Free_Bare_host;

   procedure Free_Bare_nick (V : in out Bare_nick_Type) is
      pragma Unreferenced (V);
   begin
      null;
   end Free_Bare_nick;

   function Parse_Bare_prefix (P : in out Parser) return Bare_prefix_Type;
   function Parse_Bare_full (P : in out Parser) return Bare_full_Type;
   function Parse_Bare_user (P : in out Parser) return Bare_user_Type;
   function Parse_Bare_host (P : in out Parser) return Bare_host_Type;
   function Parse_Bare_nick (P : in out Parser) return Bare_nick_Type;
   function Parse_Bare_any (P : in out Parser) return Bare_any_Type;
   function Parse_Bare_name (P : in out Parser) return Bare_name_Type;
   function Parse_Bare_user_name (P : in out Parser) return Bare_user_name_Type;
   function Parse_Bare_host_name (P : in out Parser) return Bare_host_name_Type;
   function Parse_Word (P : in out Parser) return Word_Type;
   function Parse_Int (P : in out Parser) return Int_Type;
   function Parse_Str (P : in out Parser) return Str_Type;
   function Parse_Ws (P : in out Parser) return Ws_Type;

   function Body_Of_Bare_prefix (P : in out Parser) return Bare_prefix_Type is
   R : Bare_prefix_Type;
   begin
      declare
         Save : constant Natural := P.Pos;
      begin
         declare
            R : Bare_prefix_Type;
         begin
            declare V : Bare_full_Type := Parse_Bare_full (P); begin if P.Failed then goto Alt_Fail_1; end if; R.Bare_full := new Bare_full_Type'(V); end;
            return R;
            <<Alt_Fail_1>> null;
         end;
         P.Failed := False; P.Pos := Save;
         declare
            R : Bare_prefix_Type;
         begin
            declare V : Bare_user_Type := Parse_Bare_user (P); begin if P.Failed then goto Alt_Fail_2; end if; R.Bare_user := new Bare_user_Type'(V); end;
            return R;
            <<Alt_Fail_2>> null;
         end;
         P.Failed := False; P.Pos := Save;
         declare
            R : Bare_prefix_Type;
         begin
            declare V : Bare_host_Type := Parse_Bare_host (P); begin if P.Failed then goto Alt_Fail_3; end if; R.Bare_host := new Bare_host_Type'(V); end;
            return R;
            <<Alt_Fail_3>> null;
         end;
         P.Failed := False; P.Pos := Save;
         declare
            R : Bare_prefix_Type;
         begin
            declare V : Bare_nick_Type := Parse_Bare_nick (P); begin if P.Failed then goto Alt_Fail_4; end if; R.Bare_nick := new Bare_nick_Type'(V); end;
            return R;
            <<Alt_Fail_4>> null;
         end;
         P.Failed := False; P.Pos := Save;
         P.Pos := Save;
         Fail (P, "a bare-prefix");
         return R;
      end;
   end Body_Of_Bare_prefix;

   function Parse_Bare_prefix (P : in out Parser) return Bare_prefix_Type is
   begin
      Enter (P, 1);
      declare
         R : constant Bare_prefix_Type := Body_Of_Bare_prefix (P);
      begin
         P.Depth := P.Depth - 1;
         return R;
      end;
   end Parse_Bare_prefix;

   function Body_Of_Bare_full (P : in out Parser) return Bare_full_Type is
   R : Bare_full_Type;
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
            if Ok then declare N : constant Natural := Scan_Bare_any (P.Text.all, P.Pos, Limit (P)); begin if N > 0 then P.Pos := P.Pos + N; else Ok := False; end if; end; end if;
            if Ok then Hit := True; end if;
         end if;
         P := Sv;
         if not Hit then Fail (P, "bare-any"); return R; end if;
      end;
      declare
         N : constant Natural := Scan_Bare_name (P.Text.all, P.Pos, Limit (P));
      begin
         R.Bare_name := To_Unbounded_String (P.Text (P.Pos .. P.Pos + N - 1)); P.Pos := P.Pos + N;
      end;
      Expect_Lit (P, "!"); if P.Failed then return R; end if;
      declare
         N : constant Natural := Scan_Bare_user_name (P.Text.all, P.Pos, Limit (P));
      begin
         R.Bare_user_name := To_Unbounded_String (P.Text (P.Pos .. P.Pos + N - 1)); P.Pos := P.Pos + N;
      end;
      Expect_Lit (P, "@"); if P.Failed then return R; end if;
      declare
         N : constant Natural := Scan_Bare_host_name (P.Text.all, P.Pos, Limit (P));
      begin
         R.Bare_host_name := To_Unbounded_String (P.Text (P.Pos .. P.Pos + N - 1)); P.Pos := P.Pos + N;
      end;
      return R;
   end Body_Of_Bare_full;

   function Parse_Bare_full (P : in out Parser) return Bare_full_Type is
   begin
      Enter (P, 3);
      declare
         R : constant Bare_full_Type := Body_Of_Bare_full (P);
      begin
         P.Depth := P.Depth - 1;
         return R;
      end;
   end Parse_Bare_full;

   function Body_Of_Bare_user (P : in out Parser) return Bare_user_Type is
   R : Bare_user_Type;
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
            if Ok then declare N : constant Natural := Scan_Bare_any (P.Text.all, P.Pos, Limit (P)); begin if N > 0 then P.Pos := P.Pos + N; else Ok := False; end if; end; end if;
            if Ok then Hit := True; end if;
         end if;
         P := Sv;
         if not Hit then Fail (P, "bare-any"); return R; end if;
      end;
      declare
         N : constant Natural := Scan_Bare_name (P.Text.all, P.Pos, Limit (P));
      begin
         R.Bare_name := To_Unbounded_String (P.Text (P.Pos .. P.Pos + N - 1)); P.Pos := P.Pos + N;
      end;
      Expect_Lit (P, "!"); if P.Failed then return R; end if;
      declare
         N : constant Natural := Scan_Bare_user_name (P.Text.all, P.Pos, Limit (P));
      begin
         R.Bare_user_name := To_Unbounded_String (P.Text (P.Pos .. P.Pos + N - 1)); P.Pos := P.Pos + N;
      end;
      return R;
   end Body_Of_Bare_user;

   function Parse_Bare_user (P : in out Parser) return Bare_user_Type is
   begin
      Enter (P, 4);
      declare
         R : constant Bare_user_Type := Body_Of_Bare_user (P);
      begin
         P.Depth := P.Depth - 1;
         return R;
      end;
   end Parse_Bare_user;

   function Body_Of_Bare_host (P : in out Parser) return Bare_host_Type is
   R : Bare_host_Type;
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
            if Ok then declare N : constant Natural := Scan_Bare_any (P.Text.all, P.Pos, Limit (P)); begin if N > 0 then P.Pos := P.Pos + N; else Ok := False; end if; end; end if;
            if Ok then Hit := True; end if;
         end if;
         P := Sv;
         if not Hit then Fail (P, "bare-any"); return R; end if;
      end;
      declare
         N : constant Natural := Scan_Bare_name (P.Text.all, P.Pos, Limit (P));
      begin
         R.Bare_name := To_Unbounded_String (P.Text (P.Pos .. P.Pos + N - 1)); P.Pos := P.Pos + N;
      end;
      Expect_Lit (P, "@"); if P.Failed then return R; end if;
      declare
         N : constant Natural := Scan_Bare_host_name (P.Text.all, P.Pos, Limit (P));
      begin
         R.Bare_host_name := To_Unbounded_String (P.Text (P.Pos .. P.Pos + N - 1)); P.Pos := P.Pos + N;
      end;
      return R;
   end Body_Of_Bare_host;

   function Parse_Bare_host (P : in out Parser) return Bare_host_Type is
   begin
      Enter (P, 5);
      declare
         R : constant Bare_host_Type := Body_Of_Bare_host (P);
      begin
         P.Depth := P.Depth - 1;
         return R;
      end;
   end Parse_Bare_host;

   function Body_Of_Bare_nick (P : in out Parser) return Bare_nick_Type is
   R : Bare_nick_Type;
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
            if Ok then declare N : constant Natural := Scan_Bare_any (P.Text.all, P.Pos, Limit (P)); begin if N > 0 then P.Pos := P.Pos + N; else Ok := False; end if; end; end if;
            if Ok then Hit := True; end if;
         end if;
         P := Sv;
         if not Hit then Fail (P, "bare-any"); return R; end if;
      end;
      declare
         N : constant Natural := Scan_Bare_name (P.Text.all, P.Pos, Limit (P));
      begin
         R.Bare_name := To_Unbounded_String (P.Text (P.Pos .. P.Pos + N - 1)); P.Pos := P.Pos + N;
      end;
      return R;
   end Body_Of_Bare_nick;

   function Parse_Bare_nick (P : in out Parser) return Bare_nick_Type is
   begin
      Enter (P, 6);
      declare
         R : constant Bare_nick_Type := Body_Of_Bare_nick (P);
      begin
         P.Depth := P.Depth - 1;
         return R;
      end;
   end Parse_Bare_nick;

   function Body_Of_Bare_any (P : in out Parser) return Bare_any_Type is
   R : Bare_any_Type;
   begin
      declare
         N : constant Natural := Scan_Bare_any (P.Text.all, P.Pos, Limit (P));
      begin
         R := To_Unbounded_String (P.Text (P.Pos .. P.Pos + N - 1));
         P.Pos := P.Pos + N;
         return R;
      end;
   end Body_Of_Bare_any;

   function Parse_Bare_any (P : in out Parser) return Bare_any_Type is
   begin
      Enter (P, 7);
      declare
         R : constant Bare_any_Type := Body_Of_Bare_any (P);
      begin
         P.Depth := P.Depth - 1;
         return R;
      end;
   end Parse_Bare_any;

   function Body_Of_Bare_name (P : in out Parser) return Bare_name_Type is
   R : Bare_name_Type;
   begin
      declare
         N : constant Natural := Scan_Bare_name (P.Text.all, P.Pos, Limit (P));
      begin
         R := To_Unbounded_String (P.Text (P.Pos .. P.Pos + N - 1));
         P.Pos := P.Pos + N;
         return R;
      end;
   end Body_Of_Bare_name;

   function Parse_Bare_name (P : in out Parser) return Bare_name_Type is
   begin
      Enter (P, 8);
      declare
         R : constant Bare_name_Type := Body_Of_Bare_name (P);
      begin
         P.Depth := P.Depth - 1;
         return R;
      end;
   end Parse_Bare_name;

   function Body_Of_Bare_user_name (P : in out Parser) return Bare_user_name_Type is
   R : Bare_user_name_Type;
   begin
      declare
         N : constant Natural := Scan_Bare_user_name (P.Text.all, P.Pos, Limit (P));
      begin
         R := To_Unbounded_String (P.Text (P.Pos .. P.Pos + N - 1));
         P.Pos := P.Pos + N;
         return R;
      end;
   end Body_Of_Bare_user_name;

   function Parse_Bare_user_name (P : in out Parser) return Bare_user_name_Type is
   begin
      Enter (P, 9);
      declare
         R : constant Bare_user_name_Type := Body_Of_Bare_user_name (P);
      begin
         P.Depth := P.Depth - 1;
         return R;
      end;
   end Parse_Bare_user_name;

   function Body_Of_Bare_host_name (P : in out Parser) return Bare_host_name_Type is
   R : Bare_host_name_Type;
   begin
      declare
         N : constant Natural := Scan_Bare_host_name (P.Text.all, P.Pos, Limit (P));
      begin
         R := To_Unbounded_String (P.Text (P.Pos .. P.Pos + N - 1));
         P.Pos := P.Pos + N;
         return R;
      end;
   end Body_Of_Bare_host_name;

   function Parse_Bare_host_name (P : in out Parser) return Bare_host_name_Type is
   begin
      Enter (P, 10);
      declare
         R : constant Bare_host_name_Type := Body_Of_Bare_host_name (P);
      begin
         P.Depth := P.Depth - 1;
         return R;
      end;
   end Parse_Bare_host_name;

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

   function Rule_Name (I : Natural) return String is
     (case I is
        when 1 => "bare-prefix",
        when 2 => "rune",
        when 3 => "bare-full",
        when 4 => "bare-user",
        when 5 => "bare-host",
        when 6 => "bare-nick",
        when 7 => "bare-any",
        when 8 => "bare-name",
        when 9 => "bare-user-name",
        when 10 => "bare-host-name",
        when 11 => "not-x0-20_22-3F_41-10FFFF",
        when 12 => "not-x0-3F_41-10FFFF",
        when 13 => "word",
        when 14 => "int",
        when 15 => "str",
        when 16 => "ws",
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
   
   function Parse_Text (Text : String) return Bare_prefix_Type is
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
      R : Bare_prefix_Type;
   begin
      begin
         R := Parse_Bare_prefix (P);
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

end Irc_Prefix.Parser;

