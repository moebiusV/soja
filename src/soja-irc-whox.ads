pragma Ada_2022;

with Ada.Strings.Unbounded;

with Soja.Irc.Messages;

--  xirc/whox.go: WHOX (extended WHO) replies.  Field letters, in the order
--  they appear in RPL_WHOSPCRPL: "tcuihsnfdlaor".
package Soja.Irc.Whox is

   use Ada.Strings.Unbounded;

   Whox_Error : exception;

   type Whox_Info is record
      Token    : Unbounded_String;
      Channel  : Unbounded_String;
      Username : Unbounded_String;
      Hostname : Unbounded_String;
      Server   : Unbounded_String;
      Nickname : Unbounded_String;
      Flags    : Unbounded_String;
      Account  : Unbounded_String;
      Realname : Unbounded_String;
   end record;

   --  GenerateWHOXReply: the reply for Info.  With no Fields it is a plain
   --  RPL_WHOREPLY; otherwise an RPL_WHOSPCRPL with the requested fields.
   function Generate_Whox_Reply
     (Fields : String; Info : Whox_Info) return Soja.Irc.Messages.Message;

   --  ParseWHOXOptions: split the "%fields,token" part of a WHO mask's
   --  options.  Fields is lower-cased; Token is only set when Fields has 't'.
   procedure Parse_Whox_Options
     (Options : String;
      Fields  : out Unbounded_String;
      Token   : out Unbounded_String);

   --  ParseWHOXReply: read the values of an RPL_WHOSPCRPL for Fields.  Raises
   --  Whox_Error when it is not one or a value is missing.
   function Parse_Whox_Reply
     (Msg : Soja.Irc.Messages.Message; Fields : String) return Whox_Info;

end Soja.Irc.Whox;
