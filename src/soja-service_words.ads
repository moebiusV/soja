--  service.go splitWords: BouncerServ's command line into words.  The
--  grammar (grammars/service-words.hbnf) classifies the bytes; the quoting
--  state machine is here.
pragma Ada_2022;

with Soja.Irc.Genmsg;

package Soja.Service_Words is

   --  Exception_Message is the text Go's error carries ("unterminated quoted
   --  string" or "unterminated backslash sequence").
   Split_Error : exception;

   --  Words are separated by whitespace; '"' and ''' quote (the other quote
   --  is literal inside), and '\' takes the next byte literally.
   function Split_Words (S : String)
      return Soja.Irc.Genmsg.String_Vectors.Vector;

end Soja.Service_Words;
