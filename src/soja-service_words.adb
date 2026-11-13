pragma Ada_2022;

with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;

with Service_Words;
with Service_Words.Parser;

package body Soja.Service_Words is

   use Standard.Service_Words;


   --  The text with each backslash taken off and the character after it kept
   --  (a backslash takes the next character as it is).
   function Unescape (S : String) return String is
      Result : Unbounded_String;
      I      : Natural := S'First;
   begin
      while I <= S'Last loop
         if S (I) = '\' and then I < S'Last then
            I := I + 1;
         end if;
         Append (Result, S (I));
         I := I + 1;
      end loop;
      return To_String (Result);
   end Unescape;

   --  What a piece adds to its word: plain text as it is, an escaped
   --  character without its backslash, a quoted string without its quotes.
   function Value (P : Piece_Type) return String is
     (if Length (P.Plain) > 0 then To_String (P.Plain)
      elsif Length (P.Escaped) > 0 then Unescape (To_String (P.Escaped))
      elsif P.Dquoted /= null then Unescape (To_String (P.Dquoted.Dq_body))
      elsif P.Squoted /= null then Unescape (To_String (P.Squoted.Sq_body))
      else "");

   --  The pieces that stand for what Go refuses: a quote never closed, and a
   --  backslash at the end.
   function Unterminated_Quote (T : Line_Type) return Boolean is
     (for some Item of T =>
        (for some P of Item.Cmd_word => Length (P.Bad_quote) > 0));

   function Unterminated_Backslash (T : Line_Type) return Boolean is
     (for some Item of T =>
        (for some P of Item.Cmd_word => Length (P.Bad_slash) > 0));

   --  A word is its pieces run together.
   function Word_Text (Pieces : Cmd_word_Type) return String is
      Result : Unbounded_String;
   begin
      for P of Pieces loop
         Append (Result, Value (P.all));
      end loop;
      return To_String (Result);
   end Word_Text;

   --  The line is read by the generated parser
   --  (grammars/service-words.hbnf); the words are what is left of it.
   function Split_Words (S : String)
      return Soja.Irc.Genmsg.String_Vectors.Vector
   is
      Tree  : Line_Type;
      Words : Soja.Irc.Genmsg.String_Vectors.Vector;
   begin
      begin
         Tree := Standard.Service_Words.Parser.Parse_Text (S);
      exception
         when Standard.Service_Words.Parser.Parse_Error =>
            raise Split_Error with "failed to parse command";
      end;

      --  (Go reports the quote first when both are there.)
      if Unterminated_Quote (Tree) then
         Standard.Service_Words.Parser.Free_Line (Tree);
         raise Split_Error with "unterminated quoted string";
      elsif Unterminated_Backslash (Tree) then
         Standard.Service_Words.Parser.Free_Line (Tree);
         raise Split_Error with "unterminated backslash sequence";
      end if;

      for Item of Tree when not Item.Cmd_word.Is_Empty loop
         Words.Append (Word_Text (Item.Cmd_word));
      end loop;
      Standard.Service_Words.Parser.Free_Line (Tree);
      return Words;
   end Split_Words;

end Soja.Service_Words;
