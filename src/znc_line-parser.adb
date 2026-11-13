
with Interfaces;
with Ada.Unchecked_Deallocation;

package body Znc_Line.Parser is

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

   function Scan_Stamp (S : String; Pos, Len : Natural) return Natural is
      Cp  : Natural;
      N   : Natural;
      Off : Natural := 0;
   begin
      N := Decode_Utf8 (S, Pos + Off, Len, Cp);
      if N = 0 or else not (Cp >= 91 and then Cp <= 91) then return 0; end if;
      Off := Off + N;
      declare
         Cnt : Natural := 0;
      begin
         while Cnt < 2 loop
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
         if Cnt < 2 then return 0; end if;
      end;
      N := Decode_Utf8 (S, Pos + Off, Len, Cp);
      if N = 0 or else not (Cp >= 58 and then Cp <= 58) then return 0; end if;
      Off := Off + N;
      declare
         Cnt : Natural := 0;
      begin
         while Cnt < 2 loop
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
         if Cnt < 2 then return 0; end if;
      end;
      N := Decode_Utf8 (S, Pos + Off, Len, Cp);
      if N = 0 or else not (Cp >= 58 and then Cp <= 58) then return 0; end if;
      Off := Off + N;
      declare
         Cnt : Natural := 0;
      begin
         while Cnt < 2 loop
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
         if Cnt < 2 then return 0; end if;
      end;
      N := Decode_Utf8 (S, Pos + Off, Len, Cp);
      if N = 0 or else not (Cp >= 93 and then Cp <= 93) then return 0; end if;
      Off := Off + N;
      N := Decode_Utf8 (S, Pos + Off, Len, Cp);
      if N = 0 or else not (Cp >= 32 and then Cp <= 32) then return 0; end if;
      Off := Off + N;
      return Off;
   end Scan_Stamp;

   function Scan_Join_start (S : String; Pos, Len : Natural) return Natural is
      type Table is array (Natural range <>) of Natural;
      Lo    : constant Table := (74, 80, 81, 111, 97, 117, 105, 114, 105, 110, 116, 115, 58, 32, 1, 1);
      Hi    : constant Table := (74, 80, 81, 111, 97, 117, 105, 114, 105, 110, 116, 115, 58, 32, 0, 0);
      To    : constant Table := (1, 2, 3, 4, 5, 6, 7, 8, 8, 9, 9, 10, 11, 12, 0, 0);
      First : constant Table := (0, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 14);
      Acc   : constant Table := (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0);
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
   end Scan_Join_start;

   function Look_Sender_gt_look_2 (S : String; Pos, Len : Natural) return Boolean is
      Cp   : Natural;
      N    : Natural;
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
      if Ok then return True; end if;
      return False;
   end Look_Sender_gt_look_2;

   function Loop_Sender_gt_loop_1 (S : String; Pos, Len : Natural) return Natural is
      Cp   : Natural;
      N    : Natural;
      Off  : Natural;
      Ok   : Boolean;
      Best : Natural := 0;
   begin
      Off := 0;
      Ok := True;
      if Ok then
         N := Decode_Utf8 (S, Pos + Off, Len, Cp);
         Ok := N > 0 and then (Cp <= 9);
         if Ok then Off := Off + N; end if;
      end if;
      if Ok and then Off > Best then Best := Off; end if;
      Off := 0;
      Ok := True;
      if Ok then
         N := Decode_Utf8 (S, Pos + Off, Len, Cp);
         Ok := N > 0 and then (Cp >= 11 and then Cp <= 61);
         if Ok then Off := Off + N; end if;
      end if;
      if Ok and then Off > Best then Best := Off; end if;
      Off := 0;
      Ok := True;
      if Ok then
         N := Decode_Utf8 (S, Pos + Off, Len, Cp);
         Ok := N > 0 and then (Cp >= 63 and then Cp <= 1114111);
         if Ok then Off := Off + N; end if;
      end if;
      if Ok and then Off > Best then Best := Off; end if;
      Off := 0;
      Ok := True;
      if Ok then
         N := Decode_Utf8 (S, Pos + Off, Len, Cp);
         Ok := N > 0 and then (Cp >= 62 and then Cp <= 62);
         if Ok then Off := Off + N; end if;
      end if;
      if Ok then
         if Look_Sender_gt_look_2 (S, Pos + Off, Len) then Ok := False; end if;
      end if;
      if Ok and then Off > Best then Best := Off; end if;
      return Best;
   end Loop_Sender_gt_loop_1;

   function Scan_Sender_gt (S : String; Pos, Len : Natural) return Natural is
      Cp  : Natural;
      N   : Natural;
      Off : Natural := 0;
   begin
      declare
         Mo  : Natural;
      begin
         loop
            Mo := Loop_Sender_gt_loop_1 (S, Pos + Off, Len);
            exit when Mo = 0;
            Off := Off + Mo;
         end loop;
      end;
      return Off;
   end Scan_Sender_gt;

   function Look_Sender_dash_look_2 (S : String; Pos, Len : Natural) return Boolean is
      Cp   : Natural;
      N    : Natural;
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
      if Ok then return True; end if;
      return False;
   end Look_Sender_dash_look_2;

   function Loop_Sender_dash_loop_1 (S : String; Pos, Len : Natural) return Natural is
      Cp   : Natural;
      N    : Natural;
      Off  : Natural;
      Ok   : Boolean;
      Best : Natural := 0;
   begin
      Off := 0;
      Ok := True;
      if Ok then
         N := Decode_Utf8 (S, Pos + Off, Len, Cp);
         Ok := N > 0 and then (Cp <= 9);
         if Ok then Off := Off + N; end if;
      end if;
      if Ok and then Off > Best then Best := Off; end if;
      Off := 0;
      Ok := True;
      if Ok then
         N := Decode_Utf8 (S, Pos + Off, Len, Cp);
         Ok := N > 0 and then (Cp >= 11 and then Cp <= 44);
         if Ok then Off := Off + N; end if;
      end if;
      if Ok and then Off > Best then Best := Off; end if;
      Off := 0;
      Ok := True;
      if Ok then
         N := Decode_Utf8 (S, Pos + Off, Len, Cp);
         Ok := N > 0 and then (Cp >= 46 and then Cp <= 1114111);
         if Ok then Off := Off + N; end if;
      end if;
      if Ok and then Off > Best then Best := Off; end if;
      Off := 0;
      Ok := True;
      if Ok then
         N := Decode_Utf8 (S, Pos + Off, Len, Cp);
         Ok := N > 0 and then (Cp >= 45 and then Cp <= 45);
         if Ok then Off := Off + N; end if;
      end if;
      if Ok then
         if Look_Sender_dash_look_2 (S, Pos + Off, Len) then Ok := False; end if;
      end if;
      if Ok and then Off > Best then Best := Off; end if;
      return Best;
   end Loop_Sender_dash_loop_1;

   function Scan_Sender_dash (S : String; Pos, Len : Natural) return Natural is
      Cp  : Natural;
      N   : Natural;
      Off : Natural := 0;
   begin
      declare
         Mo  : Natural;
      begin
         loop
            Mo := Loop_Sender_dash_loop_1 (S, Pos + Off, Len);
            exit when Mo = 0;
            Off := Off + Mo;
         end loop;
      end;
      return Off;
   end Scan_Sender_dash;

   function Scan_Sender_sp (S : String; Pos, Len : Natural) return Natural is
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
                  Match := N > 0 and then (Cp <= 9);
                  if Match then O := O + N; end if;
               end if;
               if Match and then O > Br then Br := O; end if;
               O := 0;
               Match := True;
               if Match then
                  N := Decode_Utf8 (S, Pos + Off + O, Len, Cp);
                  Match := N > 0 and then (Cp >= 11 and then Cp <= 31);
                  if Match then O := O + N; end if;
               end if;
               if Match and then O > Br then Br := O; end if;
               O := 0;
               Match := True;
               if Match then
                  N := Decode_Utf8 (S, Pos + Off + O, Len, Cp);
                  Match := N > 0 and then (Cp >= 33 and then Cp <= 1114111);
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
   end Scan_Sender_sp;

   function Scan_Nick (S : String; Pos, Len : Natural) return Natural is
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
                  Match := N > 0 and then (Cp <= 9);
                  if Match then O := O + N; end if;
               end if;
               if Match and then O > Br then Br := O; end if;
               O := 0;
               Match := True;
               if Match then
                  N := Decode_Utf8 (S, Pos + Off + O, Len, Cp);
                  Match := N > 0 and then (Cp >= 11 and then Cp <= 31);
                  if Match then O := O + N; end if;
               end if;
               if Match and then O > Br then Br := O; end if;
               O := 0;
               Match := True;
               if Match then
                  N := Decode_Utf8 (S, Pos + Off + O, Len, Cp);
                  Match := N > 0 and then (Cp >= 33 and then Cp <= 1114111);
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
   end Scan_Nick;

   function Scan_Kicker (S : String; Pos, Len : Natural) return Natural is
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
                  Match := N > 0 and then (Cp <= 9);
                  if Match then O := O + N; end if;
               end if;
               if Match and then O > Br then Br := O; end if;
               O := 0;
               Match := True;
               if Match then
                  N := Decode_Utf8 (S, Pos + Off + O, Len, Cp);
                  Match := N > 0 and then (Cp >= 11 and then Cp <= 31);
                  if Match then O := O + N; end if;
               end if;
               if Match and then O > Br then Br := O; end if;
               O := 0;
               Match := True;
               if Match then
                  N := Decode_Utf8 (S, Pos + Off + O, Len, Cp);
                  Match := N > 0 and then (Cp >= 33 and then Cp <= 1114111);
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
   end Scan_Kicker;

   function Scan_Mask (S : String; Pos, Len : Natural) return Natural is
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
                  Match := N > 0 and then (Cp <= 9);
                  if Match then O := O + N; end if;
               end if;
               if Match and then O > Br then Br := O; end if;
               O := 0;
               Match := True;
               if Match then
                  N := Decode_Utf8 (S, Pos + Off + O, Len, Cp);
                  Match := N > 0 and then (Cp >= 11 and then Cp <= 31);
                  if Match then O := O + N; end if;
               end if;
               if Match and then O > Br then Br := O; end if;
               O := 0;
               Match := True;
               if Match then
                  N := Decode_Utf8 (S, Pos + Off + O, Len, Cp);
                  Match := N > 0 and then (Cp >= 33 and then Cp <= 1114111);
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
   end Scan_Mask;

   function Scan_Reason (S : String; Pos, Len : Natural) return Natural is
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
                  Match := N > 0 and then (Cp <= 9);
                  if Match then O := O + N; end if;
               end if;
               if Match and then O > Br then Br := O; end if;
               O := 0;
               Match := True;
               if Match then
                  N := Decode_Utf8 (S, Pos + Off + O, Len, Cp);
                  Match := N > 0 and then (Cp >= 11 and then Cp <= 1114111);
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
   end Scan_Reason;

   function Scan_Text (S : String; Pos, Len : Natural) return Natural is
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
                  Match := N > 0 and then (Cp <= 9);
                  if Match then O := O + N; end if;
               end if;
               if Match and then O > Br then Br := O; end if;
               O := 0;
               Match := True;
               if Match then
                  N := Decode_Utf8 (S, Pos + Off + O, Len, Cp);
                  Match := N > 0 and then (Cp >= 11 and then Cp <= 1114111);
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
   end Scan_Text;

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

   procedure Dealloc_Znc_line is new Ada.Unchecked_Deallocation (Znc_line_Type, Znc_line_Access);
   procedure Dealloc_Log_entry is new Ada.Unchecked_Deallocation (Log_entry_Type, Log_entry_Access);
   procedure Dealloc_Privmsg is new Ada.Unchecked_Deallocation (Privmsg_Type, Privmsg_Access);
   procedure Dealloc_Notice is new Ada.Unchecked_Deallocation (Notice_Type, Notice_Access);
   procedure Dealloc_Action is new Ada.Unchecked_Deallocation (Action_Type, Action_Access);
   procedure Dealloc_Event is new Ada.Unchecked_Deallocation (Event_Type, Event_Access);
   procedure Dealloc_Joined_why is new Ada.Unchecked_Deallocation (Joined_why_Type, Joined_why_Access);
   procedure Dealloc_Joined is new Ada.Unchecked_Deallocation (Joined_Type, Joined_Access);
   procedure Dealloc_Renamed is new Ada.Unchecked_Deallocation (Renamed_Type, Renamed_Access);
   procedure Dealloc_Kicked is new Ada.Unchecked_Deallocation (Kicked_Type, Kicked_Access);
   procedure Dealloc_Retopic is new Ada.Unchecked_Deallocation (Retopic_Type, Retopic_Access);
   procedure Dealloc_Remode is new Ada.Unchecked_Deallocation (Remode_Type, Remode_Access);
   procedure Dealloc_Unknown is new Ada.Unchecked_Deallocation (Unknown_Type, Unknown_Access);
   procedure Dealloc_Other is new Ada.Unchecked_Deallocation (Other_Type, Other_Access);
   procedure Dealloc_Event_1 is new Ada.Unchecked_Deallocation (Event_1_Type, Event_1_Access);

   procedure Free_Znc_line (V : in out Znc_line_Type) is
   begin
   if V.Log_entry /= null then
      Free_Log_entry (V.Log_entry.all);
      Dealloc_Log_entry (V.Log_entry);
   end if;
   end Free_Znc_line;

   procedure Free_Log_entry (V : in out Log_entry_Type) is
   begin
   if V.Privmsg /= null then
      Free_Privmsg (V.Privmsg.all);
      Dealloc_Privmsg (V.Privmsg);
   end if;
   if V.Notice /= null then
      Free_Notice (V.Notice.all);
      Dealloc_Notice (V.Notice);
   end if;
   if V.Action /= null then
      Free_Action (V.Action.all);
      Dealloc_Action (V.Action);
   end if;
   if V.Event /= null then
      Free_Event (V.Event.all);
      Dealloc_Event (V.Event);
   end if;
   if V.Other /= null then
      Free_Other (V.Other.all);
      Dealloc_Other (V.Other);
   end if;
   end Free_Log_entry;

   procedure Free_Privmsg (V : in out Privmsg_Type) is
      pragma Unreferenced (V);
   begin
      null;
   end Free_Privmsg;

   procedure Free_Notice (V : in out Notice_Type) is
      pragma Unreferenced (V);
   begin
      null;
   end Free_Notice;

   procedure Free_Action (V : in out Action_Type) is
      pragma Unreferenced (V);
   begin
      null;
   end Free_Action;

   procedure Free_Event (V : in out Event_Type) is
   begin
   if V.Event_1 /= null then
      Free_Event_1 (V.Event_1.all);
      Dealloc_Event_1 (V.Event_1);
   end if;
   end Free_Event;

   procedure Free_Joined_why (V : in out Joined_why_Type) is
      pragma Unreferenced (V);
   begin
      null;
   end Free_Joined_why;

   procedure Free_Joined (V : in out Joined_Type) is
      pragma Unreferenced (V);
   begin
      null;
   end Free_Joined;

   procedure Free_Renamed (V : in out Renamed_Type) is
      pragma Unreferenced (V);
   begin
      null;
   end Free_Renamed;

   procedure Free_Kicked (V : in out Kicked_Type) is
      pragma Unreferenced (V);
   begin
      null;
   end Free_Kicked;

   procedure Free_Retopic (V : in out Retopic_Type) is
      pragma Unreferenced (V);
   begin
      null;
   end Free_Retopic;

   procedure Free_Remode (V : in out Remode_Type) is
      pragma Unreferenced (V);
   begin
      null;
   end Free_Remode;

   procedure Free_Unknown (V : in out Unknown_Type) is
      pragma Unreferenced (V);
   begin
      null;
   end Free_Unknown;

   procedure Free_Other (V : in out Other_Type) is
      pragma Unreferenced (V);
   begin
      null;
   end Free_Other;

   procedure Free_Event_1 (V : in out Event_1_Type) is
   begin
   if V.Joined_why /= null then
      Free_Joined_why (V.Joined_why.all);
      Dealloc_Joined_why (V.Joined_why);
   end if;
   if V.Joined /= null then
      Free_Joined (V.Joined.all);
      Dealloc_Joined (V.Joined);
   end if;
   if V.Renamed /= null then
      Free_Renamed (V.Renamed.all);
      Dealloc_Renamed (V.Renamed);
   end if;
   if V.Kicked /= null then
      Free_Kicked (V.Kicked.all);
      Dealloc_Kicked (V.Kicked);
   end if;
   if V.Retopic /= null then
      Free_Retopic (V.Retopic.all);
      Dealloc_Retopic (V.Retopic);
   end if;
   if V.Remode /= null then
      Free_Remode (V.Remode.all);
      Dealloc_Remode (V.Remode);
   end if;
   if V.Unknown /= null then
      Free_Unknown (V.Unknown.all);
      Dealloc_Unknown (V.Unknown);
   end if;
   end Free_Event_1;

   function Parse_Znc_line (P : in out Parser) return Znc_line_Type;
   function Parse_Log_entry (P : in out Parser) return Log_entry_Type;
   function Parse_Stamp (P : in out Parser) return Stamp_Type;
   function Parse_Privmsg (P : in out Parser) return Privmsg_Type;
   function Parse_Notice (P : in out Parser) return Notice_Type;
   function Parse_Action (P : in out Parser) return Action_Type;
   function Parse_Event (P : in out Parser) return Event_Type;
   function Parse_Joined_why (P : in out Parser) return Joined_why_Type;
   function Parse_Joined (P : in out Parser) return Joined_Type;
   function Parse_Renamed (P : in out Parser) return Renamed_Type;
   function Parse_Kicked (P : in out Parser) return Kicked_Type;
   function Parse_Retopic (P : in out Parser) return Retopic_Type;
   function Parse_Remode (P : in out Parser) return Remode_Type;
   function Parse_Unknown (P : in out Parser) return Unknown_Type;
   function Parse_Other (P : in out Parser) return Other_Type;
   function Parse_Join_start (P : in out Parser) return Join_start_Type;
   function Parse_Join_word (P : in out Parser) return Join_word_Type;
   function Parse_Sender_gt (P : in out Parser) return Sender_gt_Type;
   function Parse_Sender_dash (P : in out Parser) return Sender_dash_Type;
   function Parse_Sender_sp (P : in out Parser) return Sender_sp_Type;
   function Parse_Nick (P : in out Parser) return Nick_Type;
   function Parse_Kicker (P : in out Parser) return Kicker_Type;
   function Parse_Mask (P : in out Parser) return Mask_Type;
   function Parse_Reason (P : in out Parser) return Reason_Type;
   function Parse_Text (P : in out Parser) return Text_Type;
   function Parse_At_end (P : in out Parser) return At_end_Type;
   function Parse_Rune (P : in out Parser) return Rune_Type;
   function Parse_Word (P : in out Parser) return Word_Type;
   function Parse_Int (P : in out Parser) return Int_Type;
   function Parse_Str (P : in out Parser) return Str_Type;
   function Parse_Ws (P : in out Parser) return Ws_Type;
   function Parse_Event_1 (P : in out Parser) return Event_1_Type;

   function Body_Of_Znc_line (P : in out Parser) return Znc_line_Type is
   R : Znc_line_Type;
   begin
      declare
         N : constant Natural := Scan_Stamp (P.Text.all, P.Pos, Limit (P));
      begin
         if N = 0 then Fail (P, "stamp"); return R; end if;
         R.Stamp := To_Unbounded_String (P.Text (P.Pos .. P.Pos + N - 1)); P.Pos := P.Pos + N;
      end;
      declare V : Log_entry_Type := Parse_Log_entry (P); begin if P.Failed then return R; end if; R.Log_entry := new Log_entry_Type'(V); end;
      return R;
   end Body_Of_Znc_line;

   function Parse_Znc_line (P : in out Parser) return Znc_line_Type is
   begin
      Enter (P, 1);
      declare
         R : constant Znc_line_Type := Body_Of_Znc_line (P);
      begin
         P.Depth := P.Depth - 1;
         return R;
      end;
   end Parse_Znc_line;

   function Body_Of_Log_entry (P : in out Parser) return Log_entry_Type is
   R : Log_entry_Type;
   begin
      declare
         Save : constant Natural := P.Pos;
      begin
         declare
            R : Log_entry_Type;
         begin
            declare V : Privmsg_Type := Parse_Privmsg (P); begin if P.Failed then goto Alt_Fail_1; end if; R.Privmsg := new Privmsg_Type'(V); end;
            return R;
            <<Alt_Fail_1>> null;
         end;
         P.Failed := False; P.Pos := Save;
         declare
            R : Log_entry_Type;
         begin
            declare V : Notice_Type := Parse_Notice (P); begin if P.Failed then goto Alt_Fail_2; end if; R.Notice := new Notice_Type'(V); end;
            return R;
            <<Alt_Fail_2>> null;
         end;
         P.Failed := False; P.Pos := Save;
         declare
            R : Log_entry_Type;
         begin
            declare V : Action_Type := Parse_Action (P); begin if P.Failed then goto Alt_Fail_3; end if; R.Action := new Action_Type'(V); end;
            return R;
            <<Alt_Fail_3>> null;
         end;
         P.Failed := False; P.Pos := Save;
         declare
            R : Log_entry_Type;
         begin
            declare V : Event_Type := Parse_Event (P); begin if P.Failed then goto Alt_Fail_4; end if; R.Event := new Event_Type'(V); end;
            return R;
            <<Alt_Fail_4>> null;
         end;
         P.Failed := False; P.Pos := Save;
         declare
            R : Log_entry_Type;
         begin
            declare V : Other_Type := Parse_Other (P); begin if P.Failed then goto Alt_Fail_5; end if; R.Other := new Other_Type'(V); end;
            return R;
            <<Alt_Fail_5>> null;
         end;
         P.Failed := False; P.Pos := Save;
         P.Pos := Save;
         Fail (P, "a log-entry");
         return R;
      end;
   end Body_Of_Log_entry;

   function Parse_Log_entry (P : in out Parser) return Log_entry_Type is
   begin
      Enter (P, 2);
      declare
         R : constant Log_entry_Type := Body_Of_Log_entry (P);
      begin
         P.Depth := P.Depth - 1;
         return R;
      end;
   end Parse_Log_entry;

   function Body_Of_Stamp (P : in out Parser) return Stamp_Type is
   R : Stamp_Type;
   begin
      declare
         N : constant Natural := Scan_Stamp (P.Text.all, P.Pos, Limit (P));
      begin
         if N = 0 then Fail (P, "stamp"); return R; end if;
         R := To_Unbounded_String (P.Text (P.Pos .. P.Pos + N - 1));
         P.Pos := P.Pos + N;
         return R;
      end;
   end Body_Of_Stamp;

   function Parse_Stamp (P : in out Parser) return Stamp_Type is
   begin
      Enter (P, 3);
      declare
         R : constant Stamp_Type := Body_Of_Stamp (P);
      begin
         P.Depth := P.Depth - 1;
         return R;
      end;
   end Parse_Stamp;

   function Body_Of_Privmsg (P : in out Parser) return Privmsg_Type is
   R : Privmsg_Type;
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
            if Ok then Expect_Lit (P, "<"); if P.Failed then P.Failed := False; Ok := False; end if; end if;
            if Ok then Hit := True; end if;
         end if;
         P := Sv;
         if not Hit then Fail (P, "`<`"); return R; end if;
      end;
      Expect_Lit (P, "<"); if P.Failed then return R; end if;
      declare
         N : constant Natural := Scan_Sender_gt (P.Text.all, P.Pos, Limit (P));
      begin
         R.Sender_gt := To_Unbounded_String (P.Text (P.Pos .. P.Pos + N - 1)); P.Pos := P.Pos + N;
      end;
      Expect_Lit (P, "> "); if P.Failed then return R; end if;
      declare
         N : constant Natural := Scan_Text (P.Text.all, P.Pos, Limit (P));
      begin
         R.Text := To_Unbounded_String (P.Text (P.Pos .. P.Pos + N - 1)); P.Pos := P.Pos + N;
      end;
      R.At_end := Parse_At_end (P); if P.Failed then return R; end if;
      return R;
   end Body_Of_Privmsg;

   function Parse_Privmsg (P : in out Parser) return Privmsg_Type is
   begin
      Enter (P, 4);
      declare
         R : constant Privmsg_Type := Body_Of_Privmsg (P);
      begin
         P.Depth := P.Depth - 1;
         return R;
      end;
   end Parse_Privmsg;

   function Body_Of_Notice (P : in out Parser) return Notice_Type is
   R : Notice_Type;
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
            if Ok then Expect_Lit (P, "-"); if P.Failed then P.Failed := False; Ok := False; end if; end if;
            if Ok then Hit := True; end if;
         end if;
         P := Sv;
         if not Hit then Fail (P, "`-`"); return R; end if;
      end;
      Expect_Lit (P, "-"); if P.Failed then return R; end if;
      declare
         N : constant Natural := Scan_Sender_dash (P.Text.all, P.Pos, Limit (P));
      begin
         R.Sender_dash := To_Unbounded_String (P.Text (P.Pos .. P.Pos + N - 1)); P.Pos := P.Pos + N;
      end;
      Expect_Lit (P, "- "); if P.Failed then return R; end if;
      declare
         N : constant Natural := Scan_Text (P.Text.all, P.Pos, Limit (P));
      begin
         R.Text := To_Unbounded_String (P.Text (P.Pos .. P.Pos + N - 1)); P.Pos := P.Pos + N;
      end;
      R.At_end := Parse_At_end (P); if P.Failed then return R; end if;
      return R;
   end Body_Of_Notice;

   function Parse_Notice (P : in out Parser) return Notice_Type is
   begin
      Enter (P, 5);
      declare
         R : constant Notice_Type := Body_Of_Notice (P);
      begin
         P.Depth := P.Depth - 1;
         return R;
      end;
   end Parse_Notice;

   function Body_Of_Action (P : in out Parser) return Action_Type is
   R : Action_Type;
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
            if Ok then Expect_Lit (P, "* "); if P.Failed then P.Failed := False; Ok := False; end if; end if;
            if Ok then Hit := True; end if;
         end if;
         P := Sv;
         if not Hit then Fail (P, "`* `"); return R; end if;
      end;
      Expect_Lit (P, "* "); if P.Failed then return R; end if;
      declare
         N : constant Natural := Scan_Sender_sp (P.Text.all, P.Pos, Limit (P));
      begin
         R.Sender_sp := To_Unbounded_String (P.Text (P.Pos .. P.Pos + N - 1)); P.Pos := P.Pos + N;
      end;
      Expect_Lit (P, " "); if P.Failed then return R; end if;
      declare
         N : constant Natural := Scan_Text (P.Text.all, P.Pos, Limit (P));
      begin
         R.Text := To_Unbounded_String (P.Text (P.Pos .. P.Pos + N - 1)); P.Pos := P.Pos + N;
      end;
      R.At_end := Parse_At_end (P); if P.Failed then return R; end if;
      return R;
   end Body_Of_Action;

   function Parse_Action (P : in out Parser) return Action_Type is
   begin
      Enter (P, 6);
      declare
         R : constant Action_Type := Body_Of_Action (P);
      begin
         P.Depth := P.Depth - 1;
         return R;
      end;
   end Parse_Action;

   function Body_Of_Event (P : in out Parser) return Event_Type is
   R : Event_Type;
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
            if Ok then Expect_Lit (P, "*** "); if P.Failed then P.Failed := False; Ok := False; end if; end if;
            if Ok then Hit := True; end if;
         end if;
         P := Sv;
         if not Hit then Fail (P, "`*** `"); return R; end if;
      end;
      Expect_Lit (P, "*** "); if P.Failed then return R; end if;
      declare V : Event_1_Type := Parse_Event_1 (P); begin if P.Failed then return R; end if; R.Event_1 := new Event_1_Type'(V); end;
      return R;
   end Body_Of_Event;

   function Parse_Event (P : in out Parser) return Event_Type is
   begin
      Enter (P, 7);
      declare
         R : constant Event_Type := Body_Of_Event (P);
      begin
         P.Depth := P.Depth - 1;
         return R;
      end;
   end Parse_Event;

   function Body_Of_Joined_why (P : in out Parser) return Joined_why_Type is
   R : Joined_why_Type;
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
            if Ok then declare N : constant Natural := Scan_Join_start (P.Text.all, P.Pos, Limit (P)); begin if N > 0 then P.Pos := P.Pos + N; else Ok := False; end if; end; end if;
            if Ok then Hit := True; end if;
         end if;
         P := Sv;
         if not Hit then Fail (P, "join-start"); return R; end if;
      end;
      R.Join_word := Parse_Join_word (P); if P.Failed then return R; end if;
      Expect_Lit (P, " "); if P.Failed then return R; end if;
      declare
         N : constant Natural := Scan_Nick (P.Text.all, P.Pos, Limit (P));
      begin
         R.Nick := To_Unbounded_String (P.Text (P.Pos .. P.Pos + N - 1)); P.Pos := P.Pos + N;
      end;
      Expect_Lit (P, " "); if P.Failed then return R; end if;
      declare
         N : constant Natural := Scan_Mask (P.Text.all, P.Pos, Limit (P));
      begin
         R.Mask := To_Unbounded_String (P.Text (P.Pos .. P.Pos + N - 1)); P.Pos := P.Pos + N;
      end;
      Expect_Lit (P, " "); if P.Failed then return R; end if;
      declare
         N : constant Natural := Scan_Reason (P.Text.all, P.Pos, Limit (P));
      begin
         R.Reason := To_Unbounded_String (P.Text (P.Pos .. P.Pos + N - 1)); P.Pos := P.Pos + N;
      end;
      R.At_end := Parse_At_end (P); if P.Failed then return R; end if;
      return R;
   end Body_Of_Joined_why;

   function Parse_Joined_why (P : in out Parser) return Joined_why_Type is
   begin
      Enter (P, 8);
      declare
         R : constant Joined_why_Type := Body_Of_Joined_why (P);
      begin
         P.Depth := P.Depth - 1;
         return R;
      end;
   end Parse_Joined_why;

   function Body_Of_Joined (P : in out Parser) return Joined_Type is
   R : Joined_Type;
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
            if Ok then declare N : constant Natural := Scan_Join_start (P.Text.all, P.Pos, Limit (P)); begin if N > 0 then P.Pos := P.Pos + N; else Ok := False; end if; end; end if;
            if Ok then Hit := True; end if;
         end if;
         P := Sv;
         if not Hit then Fail (P, "join-start"); return R; end if;
      end;
      R.Join_word := Parse_Join_word (P); if P.Failed then return R; end if;
      Expect_Lit (P, " "); if P.Failed then return R; end if;
      declare
         N : constant Natural := Scan_Nick (P.Text.all, P.Pos, Limit (P));
      begin
         R.Nick := To_Unbounded_String (P.Text (P.Pos .. P.Pos + N - 1)); P.Pos := P.Pos + N;
      end;
      Expect_Lit (P, " "); if P.Failed then return R; end if;
      declare
         N : constant Natural := Scan_Mask (P.Text.all, P.Pos, Limit (P));
      begin
         R.Mask := To_Unbounded_String (P.Text (P.Pos .. P.Pos + N - 1)); P.Pos := P.Pos + N;
      end;
      R.At_end := Parse_At_end (P); if P.Failed then return R; end if;
      return R;
   end Body_Of_Joined;

   function Parse_Joined (P : in out Parser) return Joined_Type is
   begin
      Enter (P, 9);
      declare
         R : constant Joined_Type := Body_Of_Joined (P);
      begin
         P.Depth := P.Depth - 1;
         return R;
      end;
   end Parse_Joined;

   function Body_Of_Renamed (P : in out Parser) return Renamed_Type is
   R : Renamed_Type;
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
            if Ok then declare N : constant Natural := Scan_Join_start (P.Text.all, P.Pos, Limit (P)); begin if N > 0 then P.Pos := P.Pos + N; else Ok := False; end if; end; end if;
            if Ok then Hit := True; end if;
         end if;
         P := Sv;
         if Hit then Fail (P, "something other than join-start"); return R; end if;
      end;
      declare
         N : constant Natural := Scan_Nick (P.Text.all, P.Pos, Limit (P));
      begin
         R.Nick := To_Unbounded_String (P.Text (P.Pos .. P.Pos + N - 1)); P.Pos := P.Pos + N;
      end;
      Expect_Lit (P, " is now known as "); if P.Failed then return R; end if;
      declare
         N : constant Natural := Scan_Text (P.Text.all, P.Pos, Limit (P));
      begin
         R.Text := To_Unbounded_String (P.Text (P.Pos .. P.Pos + N - 1)); P.Pos := P.Pos + N;
      end;
      R.At_end := Parse_At_end (P); if P.Failed then return R; end if;
      return R;
   end Body_Of_Renamed;

   function Parse_Renamed (P : in out Parser) return Renamed_Type is
   begin
      Enter (P, 10);
      declare
         R : constant Renamed_Type := Body_Of_Renamed (P);
      begin
         P.Depth := P.Depth - 1;
         return R;
      end;
   end Parse_Renamed;

   function Body_Of_Kicked (P : in out Parser) return Kicked_Type is
   R : Kicked_Type;
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
            if Ok then declare N : constant Natural := Scan_Join_start (P.Text.all, P.Pos, Limit (P)); begin if N > 0 then P.Pos := P.Pos + N; else Ok := False; end if; end; end if;
            if Ok then Hit := True; end if;
         end if;
         P := Sv;
         if Hit then Fail (P, "something other than join-start"); return R; end if;
      end;
      declare
         N : constant Natural := Scan_Nick (P.Text.all, P.Pos, Limit (P));
      begin
         R.Nick := To_Unbounded_String (P.Text (P.Pos .. P.Pos + N - 1)); P.Pos := P.Pos + N;
      end;
      Expect_Lit (P, " was kicked by "); if P.Failed then return R; end if;
      declare
         N : constant Natural := Scan_Kicker (P.Text.all, P.Pos, Limit (P));
      begin
         R.Kicker := To_Unbounded_String (P.Text (P.Pos .. P.Pos + N - 1)); P.Pos := P.Pos + N;
      end;
      Expect_Lit (P, " "); if P.Failed then return R; end if;
      declare
         N : constant Natural := Scan_Reason (P.Text.all, P.Pos, Limit (P));
      begin
         R.Reason := To_Unbounded_String (P.Text (P.Pos .. P.Pos + N - 1)); P.Pos := P.Pos + N;
      end;
      R.At_end := Parse_At_end (P); if P.Failed then return R; end if;
      return R;
   end Body_Of_Kicked;

   function Parse_Kicked (P : in out Parser) return Kicked_Type is
   begin
      Enter (P, 11);
      declare
         R : constant Kicked_Type := Body_Of_Kicked (P);
      begin
         P.Depth := P.Depth - 1;
         return R;
      end;
   end Parse_Kicked;

   function Body_Of_Retopic (P : in out Parser) return Retopic_Type is
   R : Retopic_Type;
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
            if Ok then declare N : constant Natural := Scan_Join_start (P.Text.all, P.Pos, Limit (P)); begin if N > 0 then P.Pos := P.Pos + N; else Ok := False; end if; end; end if;
            if Ok then Hit := True; end if;
         end if;
         P := Sv;
         if Hit then Fail (P, "something other than join-start"); return R; end if;
      end;
      declare
         N : constant Natural := Scan_Nick (P.Text.all, P.Pos, Limit (P));
      begin
         R.Nick := To_Unbounded_String (P.Text (P.Pos .. P.Pos + N - 1)); P.Pos := P.Pos + N;
      end;
      Expect_Lit (P, " changes topic to "); if P.Failed then return R; end if;
      declare
         N : constant Natural := Scan_Text (P.Text.all, P.Pos, Limit (P));
      begin
         R.Text := To_Unbounded_String (P.Text (P.Pos .. P.Pos + N - 1)); P.Pos := P.Pos + N;
      end;
      R.At_end := Parse_At_end (P); if P.Failed then return R; end if;
      return R;
   end Body_Of_Retopic;

   function Parse_Retopic (P : in out Parser) return Retopic_Type is
   begin
      Enter (P, 12);
      declare
         R : constant Retopic_Type := Body_Of_Retopic (P);
      begin
         P.Depth := P.Depth - 1;
         return R;
      end;
   end Parse_Retopic;

   function Body_Of_Remode (P : in out Parser) return Remode_Type is
   R : Remode_Type;
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
            if Ok then declare N : constant Natural := Scan_Join_start (P.Text.all, P.Pos, Limit (P)); begin if N > 0 then P.Pos := P.Pos + N; else Ok := False; end if; end; end if;
            if Ok then Hit := True; end if;
         end if;
         P := Sv;
         if Hit then Fail (P, "something other than join-start"); return R; end if;
      end;
      declare
         N : constant Natural := Scan_Nick (P.Text.all, P.Pos, Limit (P));
      begin
         R.Nick := To_Unbounded_String (P.Text (P.Pos .. P.Pos + N - 1)); P.Pos := P.Pos + N;
      end;
      Expect_Lit (P, " sets mode: "); if P.Failed then return R; end if;
      declare
         N : constant Natural := Scan_Text (P.Text.all, P.Pos, Limit (P));
      begin
         R.Text := To_Unbounded_String (P.Text (P.Pos .. P.Pos + N - 1)); P.Pos := P.Pos + N;
      end;
      R.At_end := Parse_At_end (P); if P.Failed then return R; end if;
      return R;
   end Body_Of_Remode;

   function Parse_Remode (P : in out Parser) return Remode_Type is
   begin
      Enter (P, 13);
      declare
         R : constant Remode_Type := Body_Of_Remode (P);
      begin
         P.Depth := P.Depth - 1;
         return R;
      end;
   end Parse_Remode;

   function Body_Of_Unknown (P : in out Parser) return Unknown_Type is
   R : Unknown_Type;
   begin
      declare
         N : constant Natural := Scan_Text (P.Text.all, P.Pos, Limit (P));
      begin
         R.Text := To_Unbounded_String (P.Text (P.Pos .. P.Pos + N - 1)); P.Pos := P.Pos + N;
      end;
      R.At_end := Parse_At_end (P); if P.Failed then return R; end if;
      return R;
   end Body_Of_Unknown;

   function Parse_Unknown (P : in out Parser) return Unknown_Type is
   begin
      Enter (P, 14);
      declare
         R : constant Unknown_Type := Body_Of_Unknown (P);
      begin
         P.Depth := P.Depth - 1;
         return R;
      end;
   end Parse_Unknown;

   function Body_Of_Other (P : in out Parser) return Other_Type is
   R : Other_Type;
   begin
      declare
         N : constant Natural := Scan_Text (P.Text.all, P.Pos, Limit (P));
      begin
         R.Text := To_Unbounded_String (P.Text (P.Pos .. P.Pos + N - 1)); P.Pos := P.Pos + N;
      end;
      R.At_end := Parse_At_end (P); if P.Failed then return R; end if;
      return R;
   end Body_Of_Other;

   function Parse_Other (P : in out Parser) return Other_Type is
   begin
      Enter (P, 15);
      declare
         R : constant Other_Type := Body_Of_Other (P);
      begin
         P.Depth := P.Depth - 1;
         return R;
      end;
   end Parse_Other;

   function Body_Of_Join_start (P : in out Parser) return Join_start_Type is
   R : Join_start_Type;
   begin
      declare
         N : constant Natural := Scan_Join_start (P.Text.all, P.Pos, Limit (P));
      begin
         if N = 0 then Fail (P, "join-start"); return R; end if;
         R := To_Unbounded_String (P.Text (P.Pos .. P.Pos + N - 1));
         P.Pos := P.Pos + N;
         return R;
      end;
   end Body_Of_Join_start;

   function Parse_Join_start (P : in out Parser) return Join_start_Type is
   begin
      Enter (P, 16);
      declare
         R : constant Join_start_Type := Body_Of_Join_start (P);
      begin
         P.Depth := P.Depth - 1;
         return R;
      end;
   end Parse_Join_start;

   function Body_Of_Join_word (P : in out Parser) return Join_word_Type is
   R : Join_word_Type;
   begin
      if P.Pos > Limit (P) then Fail (P, "a Join_word_Type"); return R; end if;
      if P.Pos + 6 - 1 <= Limit (P) and then P.Text (P.Pos .. P.Pos + 6 - 1) = "Joins:" then
         R := Join_word_Joins; P.Pos := P.Pos + 6;
      elsif P.Pos + 6 - 1 <= Limit (P) and then P.Text (P.Pos .. P.Pos + 6 - 1) = "Parts:" then
         R := Join_word_Parts; P.Pos := P.Pos + 6;
      elsif P.Pos + 6 - 1 <= Limit (P) and then P.Text (P.Pos .. P.Pos + 6 - 1) = "Quits:" then
         R := Join_word_Quits; P.Pos := P.Pos + 6;
      else Fail (P, "`Joins:` or `Parts:` or `Quits:`"); end if;
      return R;
   end Body_Of_Join_word;

   function Parse_Join_word (P : in out Parser) return Join_word_Type is
   begin
      Enter (P, 17);
      declare
         R : constant Join_word_Type := Body_Of_Join_word (P);
      begin
         P.Depth := P.Depth - 1;
         return R;
      end;
   end Parse_Join_word;

   function Body_Of_Sender_gt (P : in out Parser) return Sender_gt_Type is
   R : Sender_gt_Type;
   Save : Natural;
   begin
      declare
         N : constant Natural := Scan_Sender_gt (P.Text.all, P.Pos, Limit (P));
      begin
         R := To_Unbounded_String (P.Text (P.Pos .. P.Pos + N - 1));
         P.Pos := P.Pos + N;
         return R;
      end;
   end Body_Of_Sender_gt;

   function Parse_Sender_gt (P : in out Parser) return Sender_gt_Type is
   begin
      Enter (P, 18);
      declare
         R : constant Sender_gt_Type := Body_Of_Sender_gt (P);
      begin
         P.Depth := P.Depth - 1;
         return R;
      end;
   end Parse_Sender_gt;

   function Body_Of_Sender_dash (P : in out Parser) return Sender_dash_Type is
   R : Sender_dash_Type;
   Save : Natural;
   begin
      declare
         N : constant Natural := Scan_Sender_dash (P.Text.all, P.Pos, Limit (P));
      begin
         R := To_Unbounded_String (P.Text (P.Pos .. P.Pos + N - 1));
         P.Pos := P.Pos + N;
         return R;
      end;
   end Body_Of_Sender_dash;

   function Parse_Sender_dash (P : in out Parser) return Sender_dash_Type is
   begin
      Enter (P, 19);
      declare
         R : constant Sender_dash_Type := Body_Of_Sender_dash (P);
      begin
         P.Depth := P.Depth - 1;
         return R;
      end;
   end Parse_Sender_dash;

   function Body_Of_Sender_sp (P : in out Parser) return Sender_sp_Type is
   R : Sender_sp_Type;
   begin
      declare
         N : constant Natural := Scan_Sender_sp (P.Text.all, P.Pos, Limit (P));
      begin
         R := To_Unbounded_String (P.Text (P.Pos .. P.Pos + N - 1));
         P.Pos := P.Pos + N;
         return R;
      end;
   end Body_Of_Sender_sp;

   function Parse_Sender_sp (P : in out Parser) return Sender_sp_Type is
   begin
      Enter (P, 20);
      declare
         R : constant Sender_sp_Type := Body_Of_Sender_sp (P);
      begin
         P.Depth := P.Depth - 1;
         return R;
      end;
   end Parse_Sender_sp;

   function Body_Of_Nick (P : in out Parser) return Nick_Type is
   R : Nick_Type;
   begin
      declare
         N : constant Natural := Scan_Nick (P.Text.all, P.Pos, Limit (P));
      begin
         R := To_Unbounded_String (P.Text (P.Pos .. P.Pos + N - 1));
         P.Pos := P.Pos + N;
         return R;
      end;
   end Body_Of_Nick;

   function Parse_Nick (P : in out Parser) return Nick_Type is
   begin
      Enter (P, 21);
      declare
         R : constant Nick_Type := Body_Of_Nick (P);
      begin
         P.Depth := P.Depth - 1;
         return R;
      end;
   end Parse_Nick;

   function Body_Of_Kicker (P : in out Parser) return Kicker_Type is
   R : Kicker_Type;
   begin
      declare
         N : constant Natural := Scan_Kicker (P.Text.all, P.Pos, Limit (P));
      begin
         R := To_Unbounded_String (P.Text (P.Pos .. P.Pos + N - 1));
         P.Pos := P.Pos + N;
         return R;
      end;
   end Body_Of_Kicker;

   function Parse_Kicker (P : in out Parser) return Kicker_Type is
   begin
      Enter (P, 22);
      declare
         R : constant Kicker_Type := Body_Of_Kicker (P);
      begin
         P.Depth := P.Depth - 1;
         return R;
      end;
   end Parse_Kicker;

   function Body_Of_Mask (P : in out Parser) return Mask_Type is
   R : Mask_Type;
   begin
      declare
         N : constant Natural := Scan_Mask (P.Text.all, P.Pos, Limit (P));
      begin
         R := To_Unbounded_String (P.Text (P.Pos .. P.Pos + N - 1));
         P.Pos := P.Pos + N;
         return R;
      end;
   end Body_Of_Mask;

   function Parse_Mask (P : in out Parser) return Mask_Type is
   begin
      Enter (P, 23);
      declare
         R : constant Mask_Type := Body_Of_Mask (P);
      begin
         P.Depth := P.Depth - 1;
         return R;
      end;
   end Parse_Mask;

   function Body_Of_Reason (P : in out Parser) return Reason_Type is
   R : Reason_Type;
   begin
      declare
         N : constant Natural := Scan_Reason (P.Text.all, P.Pos, Limit (P));
      begin
         R := To_Unbounded_String (P.Text (P.Pos .. P.Pos + N - 1));
         P.Pos := P.Pos + N;
         return R;
      end;
   end Body_Of_Reason;

   function Parse_Reason (P : in out Parser) return Reason_Type is
   begin
      Enter (P, 24);
      declare
         R : constant Reason_Type := Body_Of_Reason (P);
      begin
         P.Depth := P.Depth - 1;
         return R;
      end;
   end Parse_Reason;

   function Body_Of_Text (P : in out Parser) return Text_Type is
   R : Text_Type;
   begin
      declare
         N : constant Natural := Scan_Text (P.Text.all, P.Pos, Limit (P));
      begin
         R := To_Unbounded_String (P.Text (P.Pos .. P.Pos + N - 1));
         P.Pos := P.Pos + N;
         return R;
      end;
   end Body_Of_Text;

   function Parse_Text (P : in out Parser) return Text_Type is
   begin
      Enter (P, 25);
      declare
         R : constant Text_Type := Body_Of_Text (P);
      begin
         P.Depth := P.Depth - 1;
         return R;
      end;
   end Parse_Text;

   function Body_Of_At_end (P : in out Parser) return At_end_Type is
   R : At_end_Type;
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
         if Hit then Fail (P, "something other than rune"); return R; end if;
      end;
      return R;
   end Body_Of_At_end;

   function Parse_At_end (P : in out Parser) return At_end_Type is
   begin
      Enter (P, 26);
      declare
         R : constant At_end_Type := Body_Of_At_end (P);
      begin
         P.Depth := P.Depth - 1;
         return R;
      end;
   end Parse_At_end;

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
      Enter (P, 27);
      declare
         R : constant Rune_Type := Body_Of_Rune (P);
      begin
         P.Depth := P.Depth - 1;
         return R;
      end;
   end Parse_Rune;

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
      Enter (P, 33);
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
      Enter (P, 34);
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
      Enter (P, 35);
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
      Enter (P, 36);
      declare
         R : constant Ws_Type := Body_Of_Ws (P);
      begin
         P.Depth := P.Depth - 1;
         return R;
      end;
   end Parse_Ws;

   function Body_Of_Event_1 (P : in out Parser) return Event_1_Type is
   R : Event_1_Type;
   begin
      declare
         Save : constant Natural := P.Pos;
      begin
         declare
            R : Event_1_Type;
         begin
            declare V : Joined_why_Type := Parse_Joined_why (P); begin if P.Failed then goto Alt_Fail_6; end if; R.Joined_why := new Joined_why_Type'(V); end;
            return R;
            <<Alt_Fail_6>> null;
         end;
         P.Failed := False; P.Pos := Save;
         declare
            R : Event_1_Type;
         begin
            declare V : Joined_Type := Parse_Joined (P); begin if P.Failed then goto Alt_Fail_7; end if; R.Joined := new Joined_Type'(V); end;
            return R;
            <<Alt_Fail_7>> null;
         end;
         P.Failed := False; P.Pos := Save;
         declare
            R : Event_1_Type;
         begin
            declare V : Renamed_Type := Parse_Renamed (P); begin if P.Failed then goto Alt_Fail_8; end if; R.Renamed := new Renamed_Type'(V); end;
            return R;
            <<Alt_Fail_8>> null;
         end;
         P.Failed := False; P.Pos := Save;
         declare
            R : Event_1_Type;
         begin
            declare V : Kicked_Type := Parse_Kicked (P); begin if P.Failed then goto Alt_Fail_9; end if; R.Kicked := new Kicked_Type'(V); end;
            return R;
            <<Alt_Fail_9>> null;
         end;
         P.Failed := False; P.Pos := Save;
         declare
            R : Event_1_Type;
         begin
            declare V : Retopic_Type := Parse_Retopic (P); begin if P.Failed then goto Alt_Fail_10; end if; R.Retopic := new Retopic_Type'(V); end;
            return R;
            <<Alt_Fail_10>> null;
         end;
         P.Failed := False; P.Pos := Save;
         declare
            R : Event_1_Type;
         begin
            declare V : Remode_Type := Parse_Remode (P); begin if P.Failed then goto Alt_Fail_11; end if; R.Remode := new Remode_Type'(V); end;
            return R;
            <<Alt_Fail_11>> null;
         end;
         P.Failed := False; P.Pos := Save;
         declare
            R : Event_1_Type;
         begin
            declare V : Unknown_Type := Parse_Unknown (P); begin if P.Failed then goto Alt_Fail_12; end if; R.Unknown := new Unknown_Type'(V); end;
            return R;
            <<Alt_Fail_12>> null;
         end;
         P.Failed := False; P.Pos := Save;
         P.Pos := Save;
         Fail (P, "a event_1");
         return R;
      end;
   end Body_Of_Event_1;

   function Parse_Event_1 (P : in out Parser) return Event_1_Type is
   begin
      Enter (P, 37);
      declare
         R : constant Event_1_Type := Body_Of_Event_1 (P);
      begin
         P.Depth := P.Depth - 1;
         return R;
      end;
   end Parse_Event_1;

   function Rule_Name (I : Natural) return String is
     (case I is
        when 1 => "znc-line",
        when 2 => "log-entry",
        when 3 => "stamp",
        when 4 => "privmsg",
        when 5 => "notice",
        when 6 => "action",
        when 7 => "event",
        when 8 => "joined-why",
        when 9 => "joined",
        when 10 => "renamed",
        when 11 => "kicked",
        when 12 => "retopic",
        when 13 => "remode",
        when 14 => "unknown",
        when 15 => "other",
        when 16 => "join-start",
        when 17 => "join-word",
        when 18 => "sender-gt",
        when 19 => "sender-dash",
        when 20 => "sender-sp",
        when 21 => "nick",
        when 22 => "kicker",
        when 23 => "mask",
        when 24 => "reason",
        when 25 => "text",
        when 26 => "at-end",
        when 27 => "rune",
        when 28 => "DIGIT",
        when 29 => "not-x0-9_B-3D_3F-10FFFF",
        when 30 => "not-x0-9_B-2C_2E-10FFFF",
        when 31 => "not-x0-9_B-1F_21-10FFFF",
        when 32 => "not-x0-9_B-10FFFF",
        when 33 => "word",
        when 34 => "int",
        when 35 => "str",
        when 36 => "ws",
        when 37 => "",
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
   
   function Parse_Text (Text : String) return Znc_line_Type is
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
      R : Znc_line_Type;
   begin
      begin
         R := Parse_Znc_line (P);
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

end Znc_Line.Parser;

