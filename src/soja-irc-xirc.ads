pragma Ada_2022;

with Ada.Calendar;
with Ada.Strings.Unbounded;

with Soja.Irc.Messages;

--  The parts of soju's xirc/xirc.go not already covered by Soja.Irc.Members
--  (ChannelStatus, Membership, MembershipSet) and Soja.Irc.Numerics.
package Soja.Irc.Xirc is

   Max_Message_Length : constant := 512;   --  maxMessageLength
   Max_Message_Params : constant := 15;    --  maxMessageParams
   Max_SASL_Length    : constant := 400;   --  MaxSASLLength

   --  FormatServerTime: the IRCv3 server-time layout
   --  ("2006-01-02T15:04:05.000Z", UTC, milliseconds truncated).
   function Format_Server_Time (T : Ada.Calendar.Time) return String;

   --  ParseCTCPMessage: Ok is False unless Msg is a PRIVMSG/NOTICE with at
   --  least two params whose text starts with \x01.  Cmd is upper-cased.
   procedure Parse_CTCP_Message
     (Msg    : Soja.Irc.Messages.Message;
      Cmd    : out Ada.Strings.Unbounded.Unbounded_String;
      Params : out Ada.Strings.Unbounded.Unbounded_String;
      Ok     : out Boolean);

end Soja.Irc.Xirc;
