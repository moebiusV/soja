pragma Ada_2022;

with Soja.Irc.Messages;

--  What soja read IRC lines with before the grammar did (a hand-written
--  split, as irc.v4's), kept to check the grammar against: the two must agree
--  on every line.
package Irc_Oracle is

   function Parse_Tags_By_Hand (Line : String) return Soja.Irc.Messages.Tag_Map;
   function Parse_Prefix_By_Hand
     (Line : String) return Soja.Irc.Messages.Prefix;
   function Parse_Message_By_Hand
     (Line : String) return Soja.Irc.Messages.Message;

end Irc_Oracle;
