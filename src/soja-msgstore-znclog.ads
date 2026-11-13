--  Soja.Msgstore.Znclog -- msgstore/znclog: the line format of ZNC's log
--  module ("[12:34:56] <nick> text"), which the file message store writes and
--  reads, so that the logs can be read (and written) by other tools.
--
--  Lines are read by splitting at the first delimiter the way the Go code
--  does, not with an hbnf grammar: what follows a delimiter is free text that
--  may itself contain the delimiter ("<a> b> c"), which hbnf's lexer cannot
--  express (see PORTING.md).
pragma Ada_2022;

with Ada.Calendar;

with Soja.Database;
with Soja.Irc.Messages;

package Soja.Msgstore.Znclog is

   --  MarshalLine: the log line (without its newline) for Msg, which
   --  happened at T (local time); "" for a message that is not logged
   --  (anything but NICK, JOIN, PART, KICK, QUIT, TOPIC, MODE, NOTICE and
   --  PRIVMSG).
   function Marshal_Line
     (Msg : Soja.Irc.Messages.Message; T : Ada.Calendar.Time) return String;

   --  UnmarshalLine: the message a line stands for, on the day of Ref.  Found
   --  is False for a line that is not a message (or is an event and Events
   --  is not set).  Store_Error when the time at its start is malformed.  The
   --  entity of a message sent to us by the entity itself becomes our nick.
   procedure Unmarshal_Line
     (Line    : String;
      User    : Soja.Database.User;
      Network : Soja.Database.Network;
      Entity  : String;
      Ref     : Ada.Calendar.Time;
      Events  : Boolean;
      Msg     : out Soja.Irc.Messages.Message;
      T       : out Ada.Calendar.Time;
      Found   : out Boolean);

end Soja.Msgstore.Znclog;
