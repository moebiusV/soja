pragma Ada_2022;

with Ada.Calendar.Formatting;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;   use Ada.Strings.Unbounded;
with Ada.Wide_Wide_Characters.Unicode;

with Soja.Irc.Numerics;

package body Soja.Irc.Helpers is

   use Soja.Irc.Members;
   use Soja.Irc.Messages;

   Rune_Error : constant Wide_Wide_Character :=
     Wide_Wide_Character'Val (16#FFFD#);

   -----------------------------
   -- Upper / Lower / Fields --
   -----------------------------

   function Upper (S : String) return String is
      R : String := S;
   begin
      for C of R loop
         if C in 'a' .. 'z' then
            C := Character'Val (Character'Pos (C) - 32);
         end if;
      end loop;
      return R;
   end Upper;

   function Lower (S : String) return String is
      R : String := S;
   begin
      for C of R loop
         if C in 'A' .. 'Z' then
            C := Character'Val (Character'Pos (C) + 32);
         end if;
      end loop;
      return R;
   end Lower;

   function Fields (S : String) return Soja.Irc.Genmsg.String_Vectors.Vector is
      V     : Soja.Irc.Genmsg.String_Vectors.Vector;
      Start : Natural := 0;
   begin
      for I in S'Range loop
         if S (I) in ' ' | ASCII.HT | ASCII.LF | ASCII.VT | ASCII.FF
           | ASCII.CR
         then
            if Start /= 0 then
               V.Append (S (Start .. I - 1));
               Start := 0;
            end if;
         elsif Start = 0 then
            Start := I;
         end if;
      end loop;
      if Start /= 0 then
         V.Append (S (Start .. S'Last));
      end if;
      return V;
   end Fields;

   function Split_Commas (S : String)
      return Soja.Irc.Genmsg.String_Vectors.Vector
   is
      V     : Soja.Irc.Genmsg.String_Vectors.Vector;
      Start : Positive := S'First;
   begin
      for I in S'Range loop
         if S (I) = ',' then
            V.Append (S (Start .. I - 1));
            Start := I + 1;
         end if;
      end loop;
      V.Append (S (Start .. S'Last));
      return V;
   end Split_Commas;

   --------------------------
   -- Format_Member_Prefix --
   --------------------------

   function Format_Member_Prefix
     (MS           : Membership_Vectors.Vector;
      Multi_Prefix : Boolean) return String
   is
   begin
      if not Multi_Prefix then
         if MS.Is_Empty then
            return "";
         end if;
         return [1 => MS.First_Element.Prefix];
      end if;

      declare
         R : String (1 .. Natural (MS.Length));
      begin
         for I in R'Range loop
            R (I) := MS (I).Prefix;
         end loop;
         return R;
      end;
   end Format_Member_Prefix;

   ---------------------------
   -- Strip_Member_Prefixes --
   ---------------------------

   --  Byte-wise (Go maps runes and compares byte(r)); identical for the
   --  ASCII flags strings WHO produces.
   function Strip_Member_Prefixes
     (Flags     : String;
      Available : Membership_Vectors.Vector) return String
   is
      R : Unbounded_String;
      Strip : Boolean;
   begin
      for C of Flags loop
         Strip := False;
         for V of Available loop
            if V.Prefix = C then
               Strip := True;
               exit;
            end if;
         end loop;
         if not Strip then
            Append (R, C);
         end if;
      end loop;
      return To_String (R);
   end Strip_Member_Prefixes;

   --------------------------
   -- Parse_Message_Params --
   --------------------------

   function Parse_Message_Params
     (Msg : Message; Count : Natural) return Params_Result
   is
   begin
      if Natural (Msg.Params.Length) < Count then
         return (Ok  => False,
                 Err => Soja.Downstream.New_Need_More_Params_Error
                          (To_String (Msg.Command)));
      end if;
      return (Ok => True);
   end Parse_Message_Params;

   ----------------------
   -- Copy_Client_Tags --
   ----------------------

   function Copy_Client_Tags (Tags : Tag_Map) return Tag_Map is
      T : Tag_Map;
   begin
      for C in Tags.Data.Iterate loop
         declare
            K : constant String := Tag_Maps.Key (C);
         begin
            if K'Length > 0 and then K (K'First) = '+' then
               T.Data.Insert (K, Tag_Maps.Element (C));
            end if;
         end;
      end loop;
      return T;
   end Copy_Client_Tags;

   ---------------------------------------------------------------
   --  UTF-8
   ---------------------------------------------------------------

   function Is_Cont (C : Character) return Boolean is
     (Character'Pos (C) in 16#80# .. 16#BF#);

   procedure Decode_Rune
     (S     : String;
      I     : Positive;
      R     : out Wide_Wide_Character;
      Width : out Positive)
   is
      B0 : constant Natural := Character'Pos (S (I));
      Need : Natural;
      Min  : Natural;
      V    : Natural;
   begin
      R := Rune_Error;
      Width := 1;
      if B0 < 16#80# then
         R := Wide_Wide_Character'Val (B0);
         return;
      elsif B0 in 16#C2# .. 16#DF# then
         Need := 2; Min := 16#80#;    V := B0 - 16#C0#;
      elsif B0 in 16#E0# .. 16#EF# then
         Need := 3; Min := 16#800#;   V := B0 - 16#E0#;
      elsif B0 in 16#F0# .. 16#F4# then
         Need := 4; Min := 16#10000#; V := B0 - 16#F0#;
      else
         return;
      end if;

      if I + Need - 1 > S'Last then
         return;
      end if;
      for K in 1 .. Need - 1 loop
         if not Is_Cont (S (I + K)) then
            return;
         end if;
         V := V * 64 + (Character'Pos (S (I + K)) - 16#80#);
      end loop;
      if V < Min or else V > 16#10FFFF#
        or else V in 16#D800# .. 16#DFFF#
      then
         return;
      end if;
      R := Wide_Wide_Character'Val (V);
      Width := Need;
   end Decode_Rune;

   procedure Decode_Last_Rune
     (S     : String;
      R     : out Wide_Wide_Character;
      Width : out Natural)
   is
      Start : Integer;
      Lim   : Integer;
      W     : Positive;
   begin
      R := Rune_Error;
      Width := 0;
      if S'Length = 0 then
         return;
      end if;
      Width := 1;
      if Character'Pos (S (S'Last)) < 16#80# then
         R := Wide_Wide_Character'Val (Character'Pos (S (S'Last)));
         return;
      end if;

      Lim := Integer'Max (S'First, S'Last - 3);
      Start := S'Last - 1;
      while Start >= Lim loop
         exit when not Is_Cont (S (Start));   --  a rune-start byte
         Start := Start - 1;
      end loop;
      if Start < S'First then
         Start := S'First;
      end if;

      Decode_Rune (S (S'First .. S'Last), Start, R, W);
      if Start + W - 1 /= S'Last then
         R := Rune_Error;
         Width := 1;
      else
         Width := W;
      end if;
   end Decode_Last_Rune;

   --  unicode.IsSpace.
   function Is_Space (R : Wide_Wide_Character) return Boolean is
      P : constant Natural := Wide_Wide_Character'Pos (R);
   begin
      return P in 9 .. 13 or else P = 32 or else P = 16#85#
        or else P = 16#A0# or else P = 16#1680#
        or else P in 16#2000# .. 16#200A#
        or else P = 16#2028# or else P = 16#2029# or else P = 16#202F#
        or else P = 16#205F# or else P = 16#3000#;
   end Is_Space;

   --  unicode.IsLetter / unicode.IsNumber.
   function Is_Letter_Or_Number (R : Wide_Wide_Character) return Boolean is
      use Ada.Wide_Wide_Characters.Unicode;
   begin
      case Get_Category (R) is
         when Lu | Ll | Lt | Lm | Lo | Nd | Nl | No => return True;
         when others => return False;
      end case;
   end Is_Letter_Or_Number;

   ----------------------
   -- Is_Word_Boundary --
   ----------------------

   function Is_Word_Boundary (R : Wide_Wide_Character) return Boolean is
   begin
      case R is
         --  Inspired from weechat.look.highlight_regex.
         when '-' | '_' | '|' => return False;
         when others          => return not Is_Letter_Or_Number (R);
      end case;
   end Is_Word_Boundary;

   -------------------
   -- Is_URI_Prefix --
   -------------------

   function Is_URI_Prefix (Text : String) return Boolean is
      I          : Positive := Text'First;
      Last_Space : Natural := 0;
      R          : Wide_Wide_Character;
      W          : Positive;
      Start      : Positive := Text'First;
   begin
      --  The text after the last space.
      while I <= Text'Last loop
         Decode_Rune (Text, I, R, W);
         if Is_Space (R) then
            Last_Space := I;
         end if;
         I := I + W;
      end loop;
      if Last_Space /= 0 then
         Start := Last_Space;
      end if;

      declare
         Sub : constant String := Text (Start .. Text'Last);
         Pos : constant Natural := Ada.Strings.Fixed.Index (Sub, "://");
         WL  : Natural;
      begin
         if Pos = 0 then
            return False;
         end if;

         --  See RFC 3986 section 3.
         Decode_Last_Rune (Sub (Sub'First .. Pos - 1), R, WL);
         case R is
            when '+' | '-' | '.' | '0' .. '9' | 'a' .. 'z' | 'A' .. 'Z' =>
               return True;
            when others =>
               return False;
         end case;
      end;
   end Is_URI_Prefix;

   ------------------
   -- Is_Highlight --
   ------------------

   function Is_Highlight (Text, Nick : String) return Boolean is
      Rest : Positive := Text'First;   --  Go re-slices text on each miss
      L, R : Wide_Wide_Character;
      W    : Natural;
      WP   : Positive;
   begin
      if Nick'Length = 0 then
         raise Program_Error with "isHighlight called with empty nick";
      end if;

      loop
         declare
            Pos : constant Natural :=
              Ada.Strings.Fixed.Index (Text (Rest .. Text'Last), Nick);
         begin
            if Pos = 0 then
               return False;
            end if;

            Decode_Last_Rune (Text (Rest .. Pos - 1), L, W);
            if Pos + Nick'Length <= Text'Last then
               Decode_Rune (Text, Pos + Nick'Length, R, WP);
            else
               R := Rune_Error;
            end if;

            if Is_Word_Boundary (L) and then Is_Word_Boundary (R)
              and then not Is_URI_Prefix (Text (Rest .. Pos - 1))
            then
               return True;
            end if;

            Rest := Pos + Nick'Length;
         end;
      end loop;
   end Is_Highlight;

   ------------------------------
   -- Parse_Chat_History_Bound --
   ------------------------------

   --  The layout is xirc.ServerTimeLayout, "2006-01-02T15:04:05.000Z",
   --  parsed as Go's time.Parse does: 4-digit year, 2-digit month/day/minute/
   --  second, a 1- or 2-digit hour, a '.' or ',' and exactly three digits,
   --  a literal 'Z'.  Out-of-range fields are errors.  Years outside
   --  Ada.Calendar's 1901 .. 2399 are also rejected (Go accepts 0 .. 9999).
   function Parse_Server_Time
     (S : String; Valid : out Boolean) return Ada.Calendar.Time
   is
      Zero : constant Ada.Calendar.Time := Ada.Calendar.Time_Of (1901, 1, 1);
   begin
      Valid := False;

      declare
         P : Positive := S'First;

         Bad : exception;

         function Digit (C : Character) return Boolean is (C in '0' .. '9');

         function Num (Count : Positive; Fixed : Boolean) return Natural is
            V : Natural := 0;
            N : Natural := 0;
         begin
            while N < Count and then P <= S'Last and then Digit (S (P)) loop
               V := V * 10 + (Character'Pos (S (P)) - Character'Pos ('0'));
               P := P + 1;
               N := N + 1;
            end loop;
            if N = 0 or else (Fixed and then N /= Count) then
               raise Bad;
            end if;
            return V;
         end Num;

         procedure Lit (C : Character) is
         begin
            if P > S'Last or else S (P) /= C then
               raise Bad;
            end if;
            P := P + 1;
         end Lit;

         Year, Month, Day, Hour, Min, Sec, Millis : Natural;
      begin
         Year := Num (4, True);   Lit ('-');
         Month := Num (2, True);  Lit ('-');
         Day := Num (2, True);    Lit ('T');
         Hour := Num (2, False);  Lit (':');
         Min := Num (2, True);    Lit (':');
         Sec := Num (2, True);
         if P <= S'Last and then (S (P) = '.' or else S (P) = ',') then
            P := P + 1;
         else
            raise Bad;
         end if;
         Millis := Num (3, True);
         Lit ('Z');
         if P <= S'Last then
            raise Bad;   --  trailing text
         end if;

         if Year not in 1901 .. 2399 or else Month not in 1 .. 12
           or else Day < 1 or else Hour > 23 or else Min > 59
           or else Sec > 59
         then
            return Zero;
         end if;
         declare
            Leap : constant Boolean :=
              (Year mod 4 = 0 and then Year mod 100 /= 0)
              or else Year mod 400 = 0;
            Days : constant array (1 .. 12) of Natural :=
              [31, (if Leap then 29 else 28), 31, 30, 31, 30,
               31, 31, 30, 31, 30, 31];
         begin
            if Day > Days (Month) then
               return Zero;
            end if;
         end;

         Valid := True;
         return Ada.Calendar.Formatting.Time_Of
           (Year       => Year,
            Month      => Month,
            Day        => Day,
            Hour       => Hour,
            Minute     => Min,
            Second     => Sec,
            Sub_Second => Ada.Calendar.Formatting.Second_Duration
                            (Duration (Millis) / 1000.0),
            Time_Zone  => 0);
      exception
         when Bad =>
            return Zero;
      end;
   end Parse_Server_Time;

   function Parse_Chat_History_Bound
     (Param : String; Valid : out Boolean) return Ada.Calendar.Time
   is
      Eq : constant Natural := Ada.Strings.Fixed.Index (Param, "=");
   begin
      if Eq = 0 or else Param (Param'First .. Eq - 1) /= "timestamp" then
         Valid := False;
         return Ada.Calendar.Time_Of (1901, 1, 1);
      end if;
      return Parse_Server_Time (Param (Eq + 1 .. Param'Last), Valid);
   end Parse_Chat_History_Bound;

   -----------
   -- Quote --
   -----------

   function Quote (S : String) return String is
      Hex : constant String := "0123456789abcdef";
      R   : Unbounded_String := To_Unbounded_String ("""");
   begin
      for C of S loop
         case C is
            when '"'      => Append (R, "\""");
            when '\'      => Append (R, "\\");
            when ASCII.LF => Append (R, "\n");
            when ASCII.CR => Append (R, "\r");
            when ASCII.HT => Append (R, "\t");
            when others   =>
               if Character'Pos (C) < 32 or else Character'Pos (C) = 127 then
                  Append (R, "\x");
                  Append (R, Hex (Character'Pos (C) / 16 + 1));
                  Append (R, Hex (Character'Pos (C) mod 16 + 1));
               else
                  Append (R, C);
               end if;
         end case;
      end loop;
      Append (R, '"');
      return To_String (R);
   end Quote;

   ----------------
   -- Is_Numeric --
   ----------------

   function Is_Numeric (Cmd : String) return Boolean is
   begin
      if Cmd'Length /= 3 then
         return False;
      end if;
      for C of Cmd loop
         if C not in '0' .. '9' then
            return False;
         end if;
      end loop;
      return True;
   end Is_Numeric;

   -------------------------
   -- Generate_Away_Reply --
   -------------------------

   function Generate_Away_Reply (Away : Boolean) return Message is
      M : Message := (others => <>);
   begin
      if Away then
         M.Command := To_Unbounded_String (Soja.Irc.Numerics.RPL_NOWAWAY);
         M.Params.Append (To_Unbounded_String ("*"));
         M.Params.Append
           (To_Unbounded_String ("You have been marked as being away"));
      else
         M.Command := To_Unbounded_String (Soja.Irc.Numerics.RPL_UNAWAY);
         M.Params.Append (To_Unbounded_String ("*"));
         M.Params.Append
           (To_Unbounded_String ("You are no longer marked as being away"));
      end if;
      return M;
   end Generate_Away_Reply;

   procedure Parse_Go_Duration
     (S : String; Value : out Duration; Ok : out Boolean)
   is
      Pos      : Positive := S'First;
      Negative : Boolean := False;
      Total    : Long_Long_Float := 0.0;
   begin
      Value := 0.0;
      Ok := False;
      if S'Length = 0 then
         return;
      end if;
      if S (Pos) = '-' or else S (Pos) = '+' then
         Negative := S (Pos) = '-';
         Pos := Pos + 1;
      end if;
      if Pos > S'Last then
         return;
      end if;
      if S (Pos .. S'Last) = "0" then
         Ok := True;
         return;
      end if;

      while Pos <= S'Last loop
         declare
            Whole, Frac : Long_Long_Float := 0.0;
            Scale       : Long_Long_Float := 1.0;
            Digits_Seen : Boolean := False;
            Unit        : Long_Long_Float;
            U_First     : Positive;
         begin
            while Pos <= S'Last and then S (Pos) in '0' .. '9' loop
               Whole := Whole * 10.0
                 + Long_Long_Float (Character'Pos (S (Pos)) - 48);
               Digits_Seen := True;
               Pos := Pos + 1;
            end loop;
            if Pos <= S'Last and then S (Pos) = '.' then
               Pos := Pos + 1;
               while Pos <= S'Last and then S (Pos) in '0' .. '9' loop
                  Scale := Scale / 10.0;
                  Frac := Frac
                    + Long_Long_Float (Character'Pos (S (Pos)) - 48) * Scale;
                  Digits_Seen := True;
                  Pos := Pos + 1;
               end loop;
            end if;
            if not Digits_Seen then
               return;
            end if;

            U_First := Pos;
            while Pos <= S'Last
              and then S (Pos) /= '.' and then S (Pos) not in '0' .. '9'
            loop
               Pos := Pos + 1;
            end loop;
            declare
               U : constant String := S (U_First .. Pos - 1);
            begin
               if U = "ns" then
                  Unit := 1.0E-9;
               elsif U = "us" or else U = Character'Val (16#C2#)
                 & Character'Val (16#B5#)
                 or else U = Character'Val (16#CE#) & Character'Val (16#BC#)
               then
                  Unit := 1.0E-6;
               elsif U = "ms" then
                  Unit := 1.0E-3;
               elsif U = "s" then
                  Unit := 1.0;
               elsif U = "m" then
                  Unit := 60.0;
               elsif U = "h" then
                  Unit := 3600.0;
               else
                  return;   --  missing or unknown unit
               end if;
            end;
            Total := Total + (Whole + Frac) * Unit;
            if Total > 9.0E9 then
               return;   --  more than any sensible duration: overflow
            end if;
         end;
      end loop;

      Value := Duration (if Negative then -Total else Total);
      Ok := True;
   end Parse_Go_Duration;

end Soja.Irc.Helpers;
