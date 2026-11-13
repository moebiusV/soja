pragma Ada_2022;

with Soja.Irc.Messages;

--  What irc.v4 reads of a line, by the parsers hbnf makes of
--  grammars/irc-message.hbnf: a message (Irc_Wire), a list of attributes
--  written like tags (Irc_Attrs), a prefix on its own (Irc_Prefix).  This
--  package takes what is left to the code from the trees: the backslash
--  escapes of a tag value, the case of the command, the pieces of a prefix.
--
--  An IRC line is bytes, not always UTF-8: bytes that are not are carried
--  through the parser as private-use characters and come out as they went in
--  (Soja.Utf8.Escape_Invalid, Restore).
package Soja.Irc.Hbnf is

   --  irc.ParseMessage: Messages.Parse_Error for a line with no command, a
   --  tags or a prefix word without the space that ends it, or nothing.
   function Parse (Line : String) return Soja.Irc.Messages.Message;

   --  irc.ParseTags: "name=value;other" (the attributes of the BOUNCER
   --  commands).
   function Parse_Attrs (Text : String) return Soja.Irc.Messages.Tag_Map;

   --  irc.ParsePrefix: "name!user@host" ("!user" and "@host" may be missing).
   function Parse_Prefix (Text : String) return Soja.Irc.Messages.Prefix;

end Soja.Irc.Hbnf;
