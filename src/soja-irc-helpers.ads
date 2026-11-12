pragma Ada_2022;

with Ada.Calendar;

with Soja.Downstream;
with Soja.Irc.Case_Mapping;
with Soja.Irc.Members;
with Soja.Irc.Messages;

--  The remaining helpers of irc.go (userModes and the channel-mode code live
--  in Soja.Irc.User_Modes and Soja.Irc.Modes).  Helpers that in Go take a
--  downstreamConn / upstreamConn take just the datum they read from it, so
--  this package does not depend on Soja.Core.
package Soja.Irc.Helpers is

   --  stdCaseMapping.
   Std_Case_Mapping : constant Soja.Irc.Case_Mapping.Kind :=
     Soja.Irc.Case_Mapping.Case_RFC1459;

   --  formatMemberPrefix: Multi_Prefix is dc.caps.IsEnabled("multi-prefix").
   --  Without it only the highest rank's prefix is shown.
   function Format_Member_Prefix
     (MS           : Soja.Irc.Members.Membership_Vectors.Vector;
      Multi_Prefix : Boolean) return String;

   --  stripMemberPrefixes: remove the status prefixes
   --  (uc.availableMemberships) from a WHO flags string.
   function Strip_Member_Prefixes
     (Flags     : String;
      Available : Soja.Irc.Members.Membership_Vectors.Vector) return String;

   --  parseMessageParams: Count is the number of parameters the caller is
   --  about to read; a message with fewer fails with ERR_NEEDMOREPARAMS.
   --  The caller then reads them with Messages.Param.
   type Params_Result (Ok : Boolean := True) is record
      case Ok is
         when True  => null;
         when False => Err : Soja.Downstream.Irc_Error;
      end case;
   end record;

   function Parse_Message_Params
     (Msg : Soja.Irc.Messages.Message; Count : Natural) return Params_Result;

   --  copyClientTags: only the client-only ("+"-prefixed) tags.
   function Copy_Client_Tags (Tags : Soja.Irc.Messages.Tag_Map)
      return Soja.Irc.Messages.Tag_Map;

   --  isWordBoundary, over a Unicode code point.
   function Is_Word_Boundary (R : Wide_Wide_Character) return Boolean;

   --  isURIPrefix / isHighlight.  Is_Highlight raises Program_Error on an
   --  empty nick (Go panics).
   function Is_URI_Prefix (Text : String) return Boolean;
   function Is_Highlight (Text, Nick : String) return Boolean;

   --  parseChatHistoryBound: parse "timestamp=<server-time>"; Valid is False
   --  (Go returns the zero time) on any error.
   function Parse_Chat_History_Bound
     (Param : String; Valid : out Boolean) return Ada.Calendar.Time;

   --  isNumeric: exactly three ASCII digits.
   function Is_Numeric (Cmd : String) return Boolean;

   --  generateAwayReply: RPL_NOWAWAY / RPL_UNAWAY.
   function Generate_Away_Reply (Away : Boolean)
      return Soja.Irc.Messages.Message;

   ---------------------------------------------------------------------
   --  UTF-8 helpers (Go's utf8.DecodeRuneInString / DecodeLastRuneInString
   --  and unicode.IsSpace).  Invalid input decodes as U+FFFD, width 1.
   ---------------------------------------------------------------------

   procedure Decode_Rune
     (S     : String;
      I     : Positive;
      R     : out Wide_Wide_Character;
      Width : out Positive);

   --  Width is 0 (and R is U+FFFD) for an empty string.
   procedure Decode_Last_Rune
     (S     : String;
      R     : out Wide_Wide_Character;
      Width : out Natural);

   function Is_Space (R : Wide_Wide_Character) return Boolean;

end Soja.Irc.Helpers;
