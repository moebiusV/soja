pragma Ada_2022;

with Schema;
with Schema.Parser;
with Soja.Irc.Messages;

--  Walker from the hbnf-generated parse tree (Schema) to a Soja Message.
--  The grammar (grammars/irc-message.hbnf) captures the wire structure: the
--  optional @tags and :prefix words, the command, the middle params, and the
--  " :"-prefixed trailing param.  This package applies irc.v4's semantics on
--  top: it strips the '@'/':' markers, splits tags on ';'/'=', splits the
--  prefix on '!'/'@', upper-cases the command, and re-assembles the trailing
--  param.  Parse raises Messages.Parse_Error on any failure, so it is a
--  drop-in for Messages.Parse_Message.
package Soja.Irc.Hbnf is

   function Parse (Line : String) return Soja.Irc.Messages.Message;

   function From_Tree
     (Tree : Schema.Message_Type) return Soja.Irc.Messages.Message;

end Soja.Irc.Hbnf;
