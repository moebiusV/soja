pragma Ada_2022;

with Ada.Exceptions;
with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;
with Ada.Text_IO;
with GNAT.OS_Lib;

with Soja.Irc.Genmsg;
with Soja.Service_Words;

--  splitWords: the quoting rules of BouncerServ's command line.
procedure Service_Words_Check is
   TAB : constant Character := ASCII.HT;

   --  The words, each in brackets; "!<message>" when it fails.
   function Split (Line : String) return String is
      Words  : Soja.Irc.Genmsg.String_Vectors.Vector;
      Result : Unbounded_String;
   begin
      Words := Soja.Service_Words.Split_Words (Line);
      for W of Words loop
         Append (Result, "[" & W & "]");
      end loop;
      return To_String (Result);
   exception
      when E : Soja.Service_Words.Split_Error =>
         return "!" & Ada.Exceptions.Exception_Message (E);
   end Split;

   procedure Expect (Line, Want : String) is
      Got : constant String := Split (Line);
   begin
      if Got /= Want then
         Ada.Text_IO.Put_Line
           ("FAILED: " & Line & " -> " & Got & " (wanted " & Want & ")");
         GNAT.OS_Lib.OS_Exit (1);
      end if;
   end Expect;
begin
   Expect ("", "");
   Expect ("   ", "");
   Expect ("network create -addr foo", "[network][create][-addr][foo]");
   Expect ("  a   b  ", "[a][b]");
   Expect ("a" & TAB & "b", "[a][b]");
   Expect ("say ""hello world""", "[say][hello world]");
   Expect ("say 'hello world'", "[say][hello world]");
   Expect ("""it's""", "[it's]");
   Expect ("'say ""x""'", "[say ""x""]");
   Expect ("a\ b", "[a b]");
   Expect ("a\\b", "[a\b]");
   Expect ("a\""b", "[a""b]");
   Expect ("""""", "[]");
   Expect ("a """" b", "[a][][b]");
   Expect ("a""b c""d", "[ab cd]");
   Expect ("""a\""b""", "[a""b]");
   Expect ("-name=""my net""", "[-name=my net]");
   --  Go loses a word that ends in an escaped space, or glues it to the
   --  next one; both are fixed (SOJU-BUGS.md).
   Expect ("a\ ", "[a ]");
   Expect ("a\  b", "[a ][b]");
   Expect ("""abc", "!unterminated quoted string");
   Expect ("'abc", "!unterminated quoted string");
   Expect ("abc\", "!unterminated backslash sequence");
   Expect ("""abc\", "!unterminated quoted string");
   --  White space is what Go's unicode.IsSpace says: U+00A0 and U+3000 and
   --  U+0085 separate words (they did not, with the ASCII-only grammar).
   Expect ("a" & Character'Val (16#C2#) & Character'Val (16#A0#) & "b",
           "[a][b]");
   Expect ("a" & Character'Val (16#E3#) & Character'Val (16#80#)
           & Character'Val (16#80#) & "b", "[a][b]");
   Expect ("a" & Character'Val (16#C2#) & Character'Val (16#85#) & "b",
           "[a][b]");
   --  ...but an escaped or quoted one does not.
   Expect ("a\" & Character'Val (16#C2#) & Character'Val (16#A0#) & "b",
           "[a" & Character'Val (16#C2#) & Character'Val (16#A0#) & "b]");
   Expect ("""a" & Character'Val (16#C2#) & Character'Val (16#A0#) & "b""",
           "[a" & Character'Val (16#C2#) & Character'Val (16#A0#) & "b]");
   --  Other multi-byte text is kept, in words and escaped.
   Expect ("h\é ""日本""", "[hé][日本]");
   --  Bytes that are not UTF-8 are refused (Go would make each a U+FFFD).
   Expect ("a" & Character'Val (16#FF#) & "b", "!failed to parse command");
   Ada.Text_IO.Put_Line ("ALL PASS");
end Service_Words_Check;
