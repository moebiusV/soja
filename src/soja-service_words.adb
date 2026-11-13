pragma Ada_2022;

with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;

with Service_Words;
with Service_Words.Parser;

package body Soja.Service_Words is

   use Soja.Irc.Genmsg.String_Vectors;

   function Split_Words (S : String)
      return Soja.Irc.Genmsg.String_Vectors.Vector
   is
      Tree    : Standard.Service_Words.Line_Type;
      Words   : Soja.Irc.Genmsg.String_Vectors.Vector;
      Current : Unbounded_String;
      In_Word : Boolean := False;       --  a word has begun
      Delim   : Character := ' ';       --  ' ' (none), '"' or '''
      Escape  : Boolean := False;

      procedure Take (Byte : Character; Cls : Character) is
         --  Cls: 'w' whitespace, '\' backslash, 'q' a quote, 'o' other.
      begin
         if Escape then
            --  The last byte was a backslash: take this one as it is.
            Append (Current, Byte);
            In_Word := True;
            Escape := False;
         elsif Cls = '\' then
            Escape := True;
            In_Word := True;
         elsif Delim = ' ' and then Cls = 'w' then
            --  The end of the word.  (Go tests the previous byte for white
            --  space, so an escaped space at the end of a word hid it;
            --  tracking In_Word fixes that, see SOJU-BUGS.md.)
            if In_Word then
               Words.Append (To_String (Current));
               Current := Null_Unbounded_String;
               In_Word := False;
            end if;
         elsif Byte = Delim then
            Delim := ' ';              --  back to space-delimited words
         elsif Cls = 'q' then
            if Delim = ' ' then
               Delim := Byte;          --  the start of a quoted word
               In_Word := True;
            else
               Append (Current, Byte); --  the other quote, literally
            end if;
         else
            Append (Current, Byte);
            In_Word := True;
         end if;
      end Take;

      procedure Take_Token (Text : Unbounded_String; Cls : Character) is
      begin
         for K in 1 .. Length (Text) loop
            Take (Element (Text, K), Cls);
         end loop;
      end Take_Token;
   begin
      begin
         Tree := Standard.Service_Words.Parser.Parse_Text (S);
      exception
         when Standard.Service_Words.Parser.Parse_Error =>
            raise Split_Error with "failed to parse command";
      end;

      for E of Tree loop
         if Length (E.Ws) > 0 then
            Take_Token (E.Ws, 'w');
         elsif Length (E.Bsl) > 0 then
            Take_Token (E.Bsl, '\');
         elsif Length (E.Dquote) > 0 then
            Take_Token (E.Dquote, 'q');
         elsif Length (E.Squote) > 0 then
            Take_Token (E.Squote, 'q');
         else
            Take_Token (E.Other, 'o');
         end if;
      end loop;

      if In_Word then
         Words.Append (To_String (Current));
      end if;
      if Delim /= ' ' then
         raise Split_Error with "unterminated quoted string";
      end if;
      if Escape then
         raise Split_Error with "unterminated backslash sequence";
      end if;
      return Words;
   end Split_Words;

end Soja.Service_Words;
