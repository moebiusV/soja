with Interfaces;

package body Service_Words.Parser is

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

   function Parse_Line (P : in out Parser) return Line_Type;
   function Parse_Ws (P : in out Parser) return Ws_Type;
   function Parse_Bsl (P : in out Parser) return Bsl_Type;
   function Parse_Dquote (P : in out Parser) return Dquote_Type;
   function Parse_Squote (P : in out Parser) return Squote_Type;
   function Parse_Other (P : in out Parser) return Other_Type;
   function Parse_Word (P : in out Parser) return Word_Type;
   function Parse_Int (P : in out Parser) return Int_Type;
   function Parse_Str (P : in out Parser) return Str_Type;

   function Parse_Line (P : in out Parser) return Line_Type is
   R : Line_Type;
   Save : Natural;
   begin
      loop
         Save := P.Pos;
         declare
            E : Line_Entry;
            Matched : Boolean := False;
         begin
            if not Matched then
               declare
                  El : Line_Entry;
               begin
                  Expect_Kind (P, Ws, "ws");
                  El.Ws := P.Toks (P.Pos).Text; P.Pos := P.Pos + 1;
                  E := El; Matched := True;
               exception
                  when Parse_Error => P.Pos := Save;
               end;
            end if;
            if not Matched then
               declare
                  El : Line_Entry;
               begin
                  Expect_Kind (P, Bsl, "bsl");
                  El.Bsl := P.Toks (P.Pos).Text; P.Pos := P.Pos + 1;
                  E := El; Matched := True;
               exception
                  when Parse_Error => P.Pos := Save;
               end;
            end if;
            if not Matched then
               declare
                  El : Line_Entry;
               begin
                  Expect_Kind (P, Dquote, "dquote");
                  El.Dquote := P.Toks (P.Pos).Text; P.Pos := P.Pos + 1;
                  E := El; Matched := True;
               exception
                  when Parse_Error => P.Pos := Save;
               end;
            end if;
            if not Matched then
               declare
                  El : Line_Entry;
               begin
                  Expect_Kind (P, Squote, "squote");
                  El.Squote := P.Toks (P.Pos).Text; P.Pos := P.Pos + 1;
                  E := El; Matched := True;
               exception
                  when Parse_Error => P.Pos := Save;
               end;
            end if;
            if not Matched then
               declare
                  El : Line_Entry;
               begin
                  Expect_Kind (P, Other, "other");
                  El.Other := P.Toks (P.Pos).Text; P.Pos := P.Pos + 1;
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
   end Parse_Line;

   function Parse_Ws (P : in out Parser) return Ws_Type is
   R : Ws_Type;
   begin
      Expect_Kind (P, Ws, "ws");
      R := P.Toks (P.Pos).Text; P.Pos := P.Pos + 1;
      return R;
   end Parse_Ws;

   function Parse_Bsl (P : in out Parser) return Bsl_Type is
   R : Bsl_Type;
   begin
      Expect_Kind (P, Bsl, "bsl");
      R := P.Toks (P.Pos).Text; P.Pos := P.Pos + 1;
      return R;
   end Parse_Bsl;

   function Parse_Dquote (P : in out Parser) return Dquote_Type is
   R : Dquote_Type;
   begin
      Expect_Kind (P, Dquote, "dquote");
      R := P.Toks (P.Pos).Text; P.Pos := P.Pos + 1;
      return R;
   end Parse_Dquote;

   function Parse_Squote (P : in out Parser) return Squote_Type is
   R : Squote_Type;
   begin
      Expect_Kind (P, Squote, "squote");
      R := P.Toks (P.Pos).Text; P.Pos := P.Pos + 1;
      return R;
   end Parse_Squote;

   function Parse_Other (P : in out Parser) return Other_Type is
   R : Other_Type;
   begin
      Expect_Kind (P, Other, "other");
      R := P.Toks (P.Pos).Text; P.Pos := P.Pos + 1;
      return R;
   end Parse_Other;

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

   function Parse_Tokens
     (Toks  : Token_Vectors.Vector;
      Lines : Line_Vectors.Vector) return Line_Type is
      P : Parser := (Toks => Toks, Lines => Lines, Pos => 1);
      R : Line_Type;
   begin
      R := Parse_Line (P);
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

   function Jet_Dispatch (S : String; Pos, Len : Natural; Kind : out Token_Kind) return Natural is
      N : Natural;
   begin
      N := Jet_Word (S, Pos, Len); if N > 0 then Kind := Word; return N; end if;
      N := Jet_Int (S, Pos, Len); if N > 0 then Kind := Int; return N; end if;
      N := Jet_Str (S, Pos, Len); if N > 0 then Kind := Str; return N; end if;
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

   function Scan_Ws (S : String; Pos, Len : Natural) return Natural is
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
         Ok := N > 0 and then (Cp >= 9 and then Cp <= 13);
         if Ok then Off := Off + N; end if;
      end if;
      if Ok and then Off > Best then Best := Off; end if;
      Off := 0;
      Ok := True;
      if Ok then
         N := Decode_Utf8 (S, Pos + Off, Len, Cp);
         Ok := N > 0 and then (Cp >= 32 and then Cp <= 32);
         if Ok then Off := Off + N; end if;
      end if;
      if Ok and then Off > Best then Best := Off; end if;
      return Best;
   end Scan_Ws;

   function Scan_Bsl (S : String; Pos, Len : Natural) return Natural is
      Cp  : Natural;
      N   : Natural;
      Off : Natural := 0;
   begin
      N := Decode_Utf8 (S, Pos + Off, Len, Cp);
      if N = 0 or else not (Cp >= 92 and then Cp <= 92) then return 0; end if;
      Off := Off + N;
      return Off;
   end Scan_Bsl;

   function Scan_Dquote (S : String; Pos, Len : Natural) return Natural is
      Cp  : Natural;
      N   : Natural;
      Off : Natural := 0;
   begin
      N := Decode_Utf8 (S, Pos + Off, Len, Cp);
      if N = 0 or else not (Cp >= 34 and then Cp <= 34) then return 0; end if;
      Off := Off + N;
      return Off;
   end Scan_Dquote;

   function Scan_Squote (S : String; Pos, Len : Natural) return Natural is
      Cp  : Natural;
      N   : Natural;
      Off : Natural := 0;
   begin
      N := Decode_Utf8 (S, Pos + Off, Len, Cp);
      if N = 0 or else not (Cp >= 39 and then Cp <= 39) then return 0; end if;
      Off := Off + N;
      return Off;
   end Scan_Squote;

   function Scan_Other (S : String; Pos, Len : Natural) return Natural is
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
         Ok := N > 0 and then (Cp <= 8);
         if Ok then Off := Off + N; end if;
      end if;
      if Ok and then Off > Best then Best := Off; end if;
      Off := 0;
      Ok := True;
      if Ok then
         N := Decode_Utf8 (S, Pos + Off, Len, Cp);
         Ok := N > 0 and then (Cp >= 14 and then Cp <= 31);
         if Ok then Off := Off + N; end if;
      end if;
      if Ok and then Off > Best then Best := Off; end if;
      Off := 0;
      Ok := True;
      if Ok then
         N := Decode_Utf8 (S, Pos + Off, Len, Cp);
         Ok := N > 0 and then (Cp >= 33 and then Cp <= 33);
         if Ok then Off := Off + N; end if;
      end if;
      if Ok and then Off > Best then Best := Off; end if;
      Off := 0;
      Ok := True;
      if Ok then
         N := Decode_Utf8 (S, Pos + Off, Len, Cp);
         Ok := N > 0 and then (Cp >= 35 and then Cp <= 38);
         if Ok then Off := Off + N; end if;
      end if;
      if Ok and then Off > Best then Best := Off; end if;
      Off := 0;
      Ok := True;
      if Ok then
         N := Decode_Utf8 (S, Pos + Off, Len, Cp);
         Ok := N > 0 and then (Cp >= 40 and then Cp <= 91);
         if Ok then Off := Off + N; end if;
      end if;
      if Ok and then Off > Best then Best := Off; end if;
      Off := 0;
      Ok := True;
      if Ok then
         N := Decode_Utf8 (S, Pos + Off, Len, Cp);
         Ok := N > 0 and then (Cp >= 93 and then Cp <= 255);
         if Ok then Off := Off + N; end if;
      end if;
      if Ok and then Off > Best then Best := Off; end if;
      return Best;
   end Scan_Other;

   function Char_Dispatch (S : String; Pos, Len : Natural; Kind : out Token_Kind) return Natural is
      Best : Natural := 0;
      N    : Natural;
   begin
      Kind := Eof;
      N := Scan_Ws (S, Pos, Len); if N > Best then Best := N; Kind := Ws; end if;
      N := Scan_Bsl (S, Pos, Len); if N > Best then Best := N; Kind := Bsl; end if;
      N := Scan_Dquote (S, Pos, Len); if N > Best then Best := N; Kind := Dquote; end if;
      N := Scan_Squote (S, Pos, Len); if N > Best then Best := N; Kind := Squote; end if;
      N := Scan_Other (S, Pos, Len); if N > Best then Best := N; Kind := Other; end if;
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

   function Parse_Text (Text : String) return Line_Type is
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
         R : Line_Type;
      begin
         R := Parse_Line (P);
         if P.Pos <= Natural (P.Toks.Length) and then P.Toks (P.Pos).Kind /= Eof then
            Fail (P, "end of config");
         end if;
         return R;
      end;
   end Parse_Text;

end Service_Words.Parser;
