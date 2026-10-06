
with Interfaces;

package body Schema.Parser is

   use Ada.Strings.Unbounded;
   use Interfaces;

   type Parser is record
      Toks  : Token_Vectors.Vector;
      Lines : Line_Vectors.Vector;
      Pos   : Natural := 1;
   end record;

   Spaces : constant String :=
     "                                                                ";

   function Found (P : Parser) return String is
   begin
      if P.Pos <= Natural (P.Toks.Length) then
         return To_String (P.Toks (P.Pos).Text);
      end if;
      return "end of input";
   end Found;

   procedure Fail (P : Parser; Expected : String) is
      L : Natural := 0;
      C : Natural := 0;
      Msg : Unbounded_String;
   begin
      if P.Pos <= Natural (P.Toks.Length) then
         L := P.Toks (P.Pos).Line;
         C := P.Toks (P.Pos).Col;
      end if;
      if L >= 1 then
         Append (Msg, "line" & Natural'Image (L) & ": ");
      end if;
      Append (Msg, "expected " & Expected & ", found " & Found (P));
      if L >= 1 and then L <= Natural (P.Lines.Length) then
         declare
            W   : constant Natural := (if C > 1 then C - 1 else 0);
            Pad : constant String :=
              (if W <= Spaces'Length then Spaces (1 .. W) else Spaces);
         begin
            Append (Msg, ASCII.LF & "  " & To_String (P.Lines (L))
              & ASCII.LF & "  " & Pad & "^");
         end;
      end if;
      raise Parse_Error with To_String (Msg);
   end Fail;

   procedure Expect_Lit (P : in out Parser; Lit : String) is
   begin
      if P.Pos <= Natural (P.Toks.Length)
        and then (P.Toks (P.Pos).Kind = Atom or else P.Toks (P.Pos).Kind = Punct)
        and then To_String (P.Toks (P.Pos).Text) = Lit
      then
         P.Pos := P.Pos + 1;
      else
         Fail (P, "`" & Lit & "`");
      end if;
   end Expect_Lit;

   procedure Expect_Kind (P : in out Parser; K : Token_Kind; Desc : String) is
   begin
      if P.Pos <= Natural (P.Toks.Length) and then P.Toks (P.Pos).Kind = K then
         null;
      else
         Fail (P, Desc);
      end if;
   end Expect_Kind;

   function Parse_Message (P : in out Parser) return Message_Type;
   function Parse_Trailing (P : in out Parser) return Trailing_Type;
   function Parse_Atword (P : in out Parser) return Atword_Type;
   function Parse_Colonword (P : in out Parser) return Colonword_Type;
   function Parse_Plainword (P : in out Parser) return Plainword_Type;
   function Parse_Gap (P : in out Parser) return Gap_Type;
   function Parse_Word (P : in out Parser) return Word_Type;
   function Parse_Int (P : in out Parser) return Int_Type;
   function Parse_Str (P : in out Parser) return Str_Type;
   function Parse_Ws (P : in out Parser) return Ws_Type;
   function Parse_Message_1 (P : in out Parser) return Message_1_Type;
   function Parse_Message_2 (P : in out Parser) return Message_2_Type;
   function Parse_Message_3 (P : in out Parser) return Message_3_Type;
   function Parse_Message_4 (P : in out Parser) return Message_4_Type;
   function Parse_Trailing_1 (P : in out Parser) return Trailing_1_Type;

   function Parse_Message (P : in out Parser) return Message_Type is
   R : Message_Type;
   begin
      R.Message_1 := Parse_Message_1 (P);
      R.Message_2 := Parse_Message_2 (P);
      Expect_Kind (P, Plainword, "plainword");
      R.Plainword := P.Toks (P.Pos).Text; P.Pos := P.Pos + 1;
      R.Message_3 := Parse_Message_3 (P);
      R.Message_4 := Parse_Message_4 (P);
      return R;
   end Parse_Message;

   function Parse_Trailing (P : in out Parser) return Trailing_Type is
   R : Trailing_Type;
   begin
      Expect_Kind (P, Gap, "gap");
      R.Gap := P.Toks (P.Pos).Text; P.Pos := P.Pos + 1;
      Expect_Kind (P, Colonword, "colonword");
      R.Colonword := P.Toks (P.Pos).Text; P.Pos := P.Pos + 1;
      R.Trailing_1 := Parse_Trailing_1 (P);
      return R;
   end Parse_Trailing;

   function Parse_Atword (P : in out Parser) return Atword_Type is
   R : Atword_Type;
   begin
      Expect_Kind (P, Atword, "atword");
      R := P.Toks (P.Pos).Text; P.Pos := P.Pos + 1;
      return R;
   end Parse_Atword;

   function Parse_Colonword (P : in out Parser) return Colonword_Type is
   R : Colonword_Type;
   begin
      Expect_Kind (P, Colonword, "colonword");
      R := P.Toks (P.Pos).Text; P.Pos := P.Pos + 1;
      return R;
   end Parse_Colonword;

   function Parse_Plainword (P : in out Parser) return Plainword_Type is
   R : Plainword_Type;
   begin
      Expect_Kind (P, Plainword, "plainword");
      R := P.Toks (P.Pos).Text; P.Pos := P.Pos + 1;
      return R;
   end Parse_Plainword;

   function Parse_Gap (P : in out Parser) return Gap_Type is
   R : Gap_Type;
   begin
      Expect_Kind (P, Gap, "gap");
      R := P.Toks (P.Pos).Text; P.Pos := P.Pos + 1;
      return R;
   end Parse_Gap;

   function Parse_Word (P : in out Parser) return Word_Type is
   R : Word_Type;
   begin
      Expect_Kind (P, Atom, "a word");
      R := P.Toks (P.Pos).Text; P.Pos := P.Pos + 1;
      return R;
   end Parse_Word;

   function Parse_Int (P : in out Parser) return Int_Type is
   R : Int_Type;
   begin
      Expect_Kind (P, Atom, "a int");
      R := P.Toks (P.Pos).Text; P.Pos := P.Pos + 1;
      return R;
   end Parse_Int;

   function Parse_Str (P : in out Parser) return Str_Type is
   R : Str_Type;
   begin
      Expect_Kind (P, Atom, "a str");
      R := P.Toks (P.Pos).Text; P.Pos := P.Pos + 1;
      return R;
   end Parse_Str;

   function Parse_Ws (P : in out Parser) return Ws_Type is
   R : Ws_Type;
   begin
      Expect_Kind (P, Atom, "a ws");
      R := P.Toks (P.Pos).Text; P.Pos := P.Pos + 1;
      return R;
   end Parse_Ws;

   function Parse_Message_1 (P : in out Parser) return Message_1_Type is
   R : Message_1_Type;
   Save : Natural;
   begin
      loop
         exit when Natural (R.Length) >= 1;
         Save := P.Pos;
         declare
            E : Message_1_Entry;
            Matched : Boolean := False;
         begin
            if not Matched then
               declare
                  El : Message_1_Entry;
               begin
                  Expect_Kind (P, Atword, "atword");
                  El.Atword := P.Toks (P.Pos).Text; P.Pos := P.Pos + 1;
                  Expect_Kind (P, Gap, "gap");
                  El.Gap := P.Toks (P.Pos).Text; P.Pos := P.Pos + 1;
                  E := El; Matched := True;
               exception
                  when Parse_Error => P.Pos := Save;
               end;
            end if;
            exit when not Matched;
            R.Append (E);
         end;
      end loop;
      return R;
   end Parse_Message_1;

   function Parse_Message_2 (P : in out Parser) return Message_2_Type is
   R : Message_2_Type;
   Save : Natural;
   begin
      loop
         exit when Natural (R.Length) >= 1;
         Save := P.Pos;
         declare
            E : Message_2_Entry;
            Matched : Boolean := False;
         begin
            if not Matched then
               declare
                  El : Message_2_Entry;
               begin
                  Expect_Kind (P, Colonword, "colonword");
                  El.Colonword := P.Toks (P.Pos).Text; P.Pos := P.Pos + 1;
                  Expect_Kind (P, Gap, "gap");
                  El.Gap := P.Toks (P.Pos).Text; P.Pos := P.Pos + 1;
                  E := El; Matched := True;
               exception
                  when Parse_Error => P.Pos := Save;
               end;
            end if;
            exit when not Matched;
            R.Append (E);
         end;
      end loop;
      return R;
   end Parse_Message_2;

   function Parse_Message_3 (P : in out Parser) return Message_3_Type is
   R : Message_3_Type;
   Save : Natural;
   begin
      loop
         Save := P.Pos;
         declare
            E : Message_3_Entry;
            Matched : Boolean := False;
         begin
            if not Matched then
               declare
                  El : Message_3_Entry;
               begin
                  Expect_Kind (P, Gap, "gap");
                  El.Gap := P.Toks (P.Pos).Text; P.Pos := P.Pos + 1;
                  Expect_Kind (P, Plainword, "plainword");
                  El.Plainword := P.Toks (P.Pos).Text; P.Pos := P.Pos + 1;
                  E := El; Matched := True;
               exception
                  when Parse_Error => P.Pos := Save;
               end;
            end if;
            exit when not Matched;
            R.Append (E);
         end;
      end loop;
      return R;
   end Parse_Message_3;

   function Parse_Message_4 (P : in out Parser) return Message_4_Type is
   R : Message_4_Type;
   Save : Natural;
   begin
      loop
         exit when P.Pos > Natural (P.Toks.Length) or else P.Toks (P.Pos).Kind = Eof;
         exit when Natural (R.Length) >= 1;
         declare
            Start : constant Natural := P.Pos;
         begin
            R.Append (new Trailing_Type'(Parse_Trailing (P)));
         exception
            when Parse_Error => P.Pos := Start; exit;
         end;
      end loop;
      return R;
   end Parse_Message_4;

   function Parse_Trailing_1 (P : in out Parser) return Trailing_1_Type is
   R : Trailing_1_Type;
   Save : Natural;
   begin
      loop
         Save := P.Pos;
         declare
            E : Trailing_1_Entry;
            Matched : Boolean := False;
         begin
            if not Matched then
               declare
                  El : Trailing_1_Entry;
               begin
                  Expect_Kind (P, Gap, "gap");
                  El.Gap := P.Toks (P.Pos).Text; P.Pos := P.Pos + 1;
                  Expect_Kind (P, Atword, "atword");
                  El.Atword := P.Toks (P.Pos).Text; P.Pos := P.Pos + 1;
                  E := El; Matched := True;
               exception
                  when Parse_Error => P.Pos := Save;
               end;
            end if;
            if not Matched then
               declare
                  El : Trailing_1_Entry;
               begin
                  Expect_Kind (P, Gap, "gap");
                  El.Gap := P.Toks (P.Pos).Text; P.Pos := P.Pos + 1;
                  Expect_Kind (P, Colonword, "colonword");
                  El.Colonword := P.Toks (P.Pos).Text; P.Pos := P.Pos + 1;
                  E := El; Matched := True;
               exception
                  when Parse_Error => P.Pos := Save;
               end;
            end if;
            if not Matched then
               declare
                  El : Trailing_1_Entry;
               begin
                  Expect_Kind (P, Gap, "gap");
                  El.Gap := P.Toks (P.Pos).Text; P.Pos := P.Pos + 1;
                  Expect_Kind (P, Plainword, "plainword");
                  El.Plainword := P.Toks (P.Pos).Text; P.Pos := P.Pos + 1;
                  E := El; Matched := True;
               exception
                  when Parse_Error => P.Pos := Save;
               end;
            end if;
            exit when not Matched;
            R.Append (E);
         end;
      end loop;
      return R;
   end Parse_Trailing_1;

   function Parse_Tokens
     (Toks  : Token_Vectors.Vector;
      Lines : Line_Vectors.Vector) return Message_Type is
      P : Parser := (Toks => Toks, Lines => Lines, Pos => 1);
      R : Message_Type;
   begin
      R := Parse_Message (P);
      if P.Pos <= Natural (P.Toks.Length) and then P.Toks (P.Pos).Kind /= Eof then
         Fail (P, "end of config");
      end if;
      return R;
   end Parse_Tokens;

   function Jet_Word (S : String; Pos, Len : Natural) return Natural is
      pragma Unreferenced (S, Pos, Len);
   begin
      return 0;
   end Jet_Word;

   function Jet_Int (S : String; Pos, Len : Natural) return Natural is
      pragma Unreferenced (S, Pos, Len);
   begin
      return 0;
   end Jet_Int;

   function Jet_Str (S : String; Pos, Len : Natural) return Natural is
      pragma Unreferenced (S, Pos, Len);
   begin
      return 0;
   end Jet_Str;

   function Jet_Ws (S : String; Pos, Len : Natural) return Natural is
      pragma Unreferenced (S, Pos, Len);
   begin
      return 0;
   end Jet_Ws;

   function Jet_Dispatch (S : String; Pos, Len : Natural; Kind : out Token_Kind) return Natural is
      N : Natural;
   begin
      N := Jet_Word (S, Pos, Len); if N > 0 then Kind := Word; return N; end if;
      N := Jet_Int (S, Pos, Len); if N > 0 then Kind := Int; return N; end if;
      N := Jet_Str (S, Pos, Len); if N > 0 then Kind := Str; return N; end if;
      N := Jet_Ws (S, Pos, Len); if N > 0 then Kind := Ws; return N; end if;
      return 0;
   end Jet_Dispatch;

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

   function Scan_Atword (S : String; Pos, Len : Natural) return Natural is
      Cp  : Natural;
      N   : Natural;
      Off : Natural := 0;
   begin
      N := Decode_Utf8 (S, Pos + Off, Len, Cp);
      if N = 0 or else not (Cp >= 64 and then Cp <= 64) then return 0; end if;
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
                  Match := N > 0 and then (Cp >= 33 and then Cp <= 126);
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
   end Scan_Atword;

   function Scan_Colonword (S : String; Pos, Len : Natural) return Natural is
      Cp  : Natural;
      N   : Natural;
      Off : Natural := 0;
   begin
      N := Decode_Utf8 (S, Pos + Off, Len, Cp);
      if N = 0 or else not (Cp >= 58 and then Cp <= 58) then return 0; end if;
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
                  Match := N > 0 and then (Cp >= 33 and then Cp <= 126);
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
   end Scan_Colonword;

   function Scan_Plainword (S : String; Pos, Len : Natural) return Natural is
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
                     Match := N > 0 and then (Cp >= 33 and then Cp <= 126);
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
         Ok := N > 0 and then (Cp >= 59 and then Cp <= 63);
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
                     Match := N > 0 and then (Cp >= 33 and then Cp <= 126);
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
         Ok := N > 0 and then (Cp >= 65 and then Cp <= 126);
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
                     Match := N > 0 and then (Cp >= 33 and then Cp <= 126);
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
   end Scan_Plainword;

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
   end Scan_Gap;

   function Char_Dispatch (S : String; Pos, Len : Natural; Kind : out Token_Kind) return Natural is
      Best : Natural := 0;
      N    : Natural;
   begin
      Kind := Eof;
      N := Scan_Atword (S, Pos, Len); if N > Best then Best := N; Kind := Atword; end if;
      N := Scan_Colonword (S, Pos, Len); if N > Best then Best := N; Kind := Colonword; end if;
      N := Scan_Plainword (S, Pos, Len); if N > Best then Best := N; Kind := Plainword; end if;
      N := Scan_Gap (S, Pos, Len); if N > Best then Best := N; Kind := Gap; end if;
      return Best;
   end Char_Dispatch;

   function Lex (Text : String) return Token_Vectors.Vector is
      Toks : Token_Vectors.Vector;
      I    : Natural := Text'First;
      Line : Natural := 1;
      Col  : Natural := 1;
      C    : Character;
   begin
      while I <= Text'Last loop
         C := Text (I);
         declare
            JK : Token_Kind;
            JL : constant Natural := Jet_Dispatch (Text, I, Text'Last, JK);
            CK : Token_Kind;
            CL : constant Natural := Char_Dispatch (Text, I, Text'Last, CK);
         begin
            if JL > 0 then
               Toks.Append (Token'(JK, To_Unbounded_String (Text (I .. I + JL - 1)), Line, Col));
               I := I + JL; Col := Col + JL;
            elsif CL > 0 then
               Toks.Append (Token'(CK, To_Unbounded_String (Text (I .. I + CL - 1)), Line, Col));
               I := I + CL; Col := Col + CL;
            elsif C = ' ' or else C = ASCII.HT or else C = ASCII.CR then
               I := I + 1; Col := Col + 1;
         elsif C = ASCII.LF then
            I := I + 1; Line := Line + 1; Col := 1;
         --  backslash-newline continues the line, as parse.y's lgetc()
         elsif C = '\' and then I < Text'Last and then Text (I + 1) = ASCII.LF then
            I := I + 2; Line := Line + 1; Col := 1;
         elsif C = '#' then
            while I <= Text'Last and then Text (I) /= ASCII.LF loop
               I := I + 1; Col := Col + 1;
            end loop;
         elsif C = '"' then
            declare
               SC  : constant Natural := Col;
               SL  : constant Natural := Line;
               Buf : Unbounded_String;
            begin
               I := I + 1; Col := Col + 1;
               while I <= Text'Last and then Text (I) /= '"' loop
                  --  inside quotes parse.y drops backslash-newline and a
                  --  bare newline, counting the line
                  if Text (I) = '\' and then I < Text'Last
                    and then Text (I + 1) = ASCII.LF
                  then
                     I := I + 2; Line := Line + 1; Col := 1;
                  elsif Text (I) = ASCII.LF then
                     I := I + 1; Line := Line + 1; Col := 1;
                  else
                     if Text (I) = '\' and then I < Text'Last then
                        I := I + 1; Col := Col + 1;
                     end if;
                     Append (Buf, Text (I));
                     I := I + 1; Col := Col + 1;
                  end if;
               end loop;
               if I <= Text'Last then
                  I := I + 1; Col := Col + 1;
               end if;
               Toks.Append (Token'(Str, Buf, SL, SC));
            end;
         elsif C in '0' .. '9'
           or else (C = '-' and then I < Text'Last
                    and then Text (I + 1) in '0' .. '9')
         then
            --  -N is a number too, as in parse.y's lexers
            declare
               SC      : constant Natural := Col;
               Start_I : constant Natural := I;
               Buf     : Unbounded_String;
            begin
               if C = '-' then
                  Append (Buf, C); I := I + 1; Col := Col + 1;
               end if;
               while I <= Text'Last and then Text (I) in '0' .. '9' loop
                  Append (Buf, Text (I)); I := I + 1; Col := Col + 1;
               end loop;
               if I <= Text'Last
                 and then (Text (I) in 'a' .. 'z' or else Text (I) in 'A' .. 'Z'
                   or else Text (I) = '.' or else Text (I) = '_'
                   or else Text (I) = '-')
               then
                  --  dotted/alphanumeric run (1.2.3.4, 123abc) is one word
                  I := Start_I; Col := SC;
                  Buf := Null_Unbounded_String;
                  while I <= Text'Last loop
                     C := Text (I);
                     exit when not (C in 'a' .. 'z' or else C in 'A' .. 'Z'
                       or else C in '0' .. '9' or else C = '_' or else C = '-'
                       or else C = '.');
                     Append (Buf, C); I := I + 1; Col := Col + 1;
                  end loop;
                  Toks.Append (Token'(Atom, Buf, Line, SC));
               else
                  Toks.Append (Token'(Int, Buf, Line, SC));
               end if;
            end;
         elsif C in 'a' .. 'z' or else C in 'A' .. 'Z' or else C = '_' or else C = '-' then
            declare
               SC  : constant Natural := Col;
               Buf : Unbounded_String;
            begin
               while I <= Text'Last loop
                  C := Text (I);
                  exit when not (C in 'a' .. 'z' or else C in 'A' .. 'Z'
                    or else C in '0' .. '9' or else C = '_' or else C = '-'
                    or else C = '.');
                  Append (Buf, C); I := I + 1; Col := Col + 1;
               end loop;
               Toks.Append (Token'(Atom, Buf, Line, SC));
            end;
         else
            declare
               Buf : Unbounded_String;
            begin
               Append (Buf, C);
               Toks.Append (Token'(Punct, Buf, Line, Col));
               I := I + 1; Col := Col + 1;
            end;
         end if;
         end;
      end loop;
      Toks.Append (Token'(Eof, Null_Unbounded_String, Line, Col));
      return Toks;
   end Lex;

   function Parse_Text (Text : String) return Message_Type is
      Toks  : Token_Vectors.Vector := Lex (Text);
      Lines : Line_Vectors.Vector;
      S     : Natural := Text'First;
   begin
      for K in Text'Range loop
         if Text (K) = ASCII.LF then
            Lines.Append (To_Unbounded_String (Text (S .. K - 1)));
            S := K + 1;
         end if;
      end loop;
      Lines.Append (To_Unbounded_String (Text (S .. Text'Last)));
      declare
         P : Parser := (Toks => Toks, Lines => Lines, Pos => 1);
         R : Message_Type;
      begin
         R := Parse_Message (P);
         if P.Pos <= Natural (P.Toks.Length) and then P.Toks (P.Pos).Kind /= Eof then
            Fail (P, "end of config");
         end if;
         return R;
      end;
   end Parse_Text;

end Schema.Parser;
