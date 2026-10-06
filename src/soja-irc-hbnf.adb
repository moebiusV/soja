pragma Ada_2022;

with Ada.Characters.Handling;
with Ada.Characters.Latin_1;
with Ada.Strings.Unbounded;

package body Soja.Irc.Hbnf is

   use Ada.Strings.Unbounded;
   use Soja.Irc.Messages;

   --  Trim trailing CR/LF, as irc.v4's strings.TrimRight(line, "\r\n").
   function Trim_Trailing_CRLF (S : String) return String is
      Last : Natural := S'Last;
   begin
      while Last >= S'First
        and then (S (Last) = Ada.Characters.Latin_1.CR
                  or else S (Last) = Ada.Characters.Latin_1.LF)
      loop
         Last := Last - 1;
      end loop;
      if Last < S'First then
         return "";
      end if;
      return S (S'First .. Last);
   end Trim_Trailing_CRLF;

   --  Strip the leading marker character ('@' or ':') from a word.
   function Strip_First (S : Unbounded_String) return String is
   begin
      if Length (S) <= 1 then
         return "";
      end if;
      return Slice (S, 2, Length (S));
   end Strip_First;

   --  The word held by a trailing-rest entry: exactly one of Atword,
   --  Colonword, Plainword is non-empty (the "|" alternatives).
   function Entry_Word (E : Schema.Trailing_1_Entry) return String is
   begin
      if Length (E.Atword) /= 0 then
         return To_String (E.Atword);
      elsif Length (E.Colonword) /= 0 then
         return To_String (E.Colonword);
      else
         return To_String (E.Plainword);
      end if;
   end Entry_Word;

   function From_Tree (Tree : Schema.Message_Type) return Message is
      Msg : Message;
   begin
      Msg.Tags := (Data => Tag_Maps.Empty_Map);
      Msg.Prefix := new Prefix'(Name => Null_Unbounded_String,
                                User => Null_Unbounded_String,
                                Host => Null_Unbounded_String);

      --  Optional tags: the "@..." word, with its '@' stripped.
      if not Schema.Message_1_Vectors.Is_Empty (Tree.Message_1) then
         declare
            E : constant Schema.Message_1_Entry :=
              Schema.Message_1_Vectors.First_Element (Tree.Message_1);
         begin
            Msg.Tags := Parse_Tags (Strip_First (E.Atword));
         end;
      end if;

      --  Optional prefix: the ":..." word, with its ':' stripped.
      if not Schema.Message_2_Vectors.Is_Empty (Tree.Message_2) then
         declare
            E : constant Schema.Message_2_Entry :=
              Schema.Message_2_Vectors.First_Element (Tree.Message_2);
         begin
            Msg.Prefix.all := Parse_Prefix (Strip_First (E.Colonword));
         end;
      end if;

      --  Command, upper-cased (irc.v4's strings.ToUpper).
      Msg.Command := To_Unbounded_String
        (Ada.Characters.Handling.To_Upper (To_String (Tree.Plainword)));

      --  Middle params.
      for E of Tree.Message_3 loop
         Param_Vectors.Append (Msg.Params, E.Plainword);
      end loop;

      --  Trailing param: strip the ':' off the first word, then append the
      --  remaining words with their (space-preserving) separators.
      if not Schema.Message_4_Vectors.Is_Empty (Tree.Message_4) then
         declare
            T   : constant Schema.Trailing_Type :=
              Schema.Message_4_Vectors.First_Element (Tree.Message_4).all;
            Buf : Unbounded_String :=
              To_Unbounded_String (Strip_First (T.Colonword));
         begin
            for R of T.Trailing_1 loop
               Append (Buf, To_String (R.Gap));
               Append (Buf, Entry_Word (R));
            end loop;
            Param_Vectors.Append (Msg.Params, Buf);
         end;
      end if;

      return Msg;
   end From_Tree;

   function Parse (Line : String) return Message is
   begin
      return From_Tree
        (Schema.Parser.Parse_Text (Trim_Trailing_CRLF (Line)));
   exception
      when Schema.Parser.Parse_Error =>
         raise Soja.Irc.Messages.Parse_Error;
   end Parse;

end Soja.Irc.Hbnf;
