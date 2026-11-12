pragma Ada_2022;

with Ada.Containers.Indefinite_Vectors;

with Soja.Irc.Members;
with Soja.Irc.Messages;

--  xirc/genmsg.go: generators for messages that must be split to fit the
--  512-byte line limit or the 15-parameter limit.
package Soja.Irc.Genmsg is

   package String_Vectors is new Ada.Containers.Indefinite_Vectors
     (Index_Type => Positive, Element_Type => String);

   subtype Message_Vector is Soja.Irc.Messages.Message_Vectors.Vector;

   --  A bare message (no prefix, no tags): Make ("CAP", ["REQ", Caps]).
   function Make
     (Command : String;
      Params  : String_Vectors.Vector := String_Vectors.Empty_Vector)
      return Soja.Irc.Messages.Message;

   --  GenerateJoin: Channels and Keys are parallel (Keys (I) is "" for no
   --  key).  Channels with a key come first, then by name.  (Go sorts the
   --  caller's slices in place; here the inputs are left untouched.)
   function Generate_Join
     (Channels, Keys : String_Vectors.Vector) return Message_Vector;

   --  GenerateIsupport: RPL_ISUPPORT messages of at most 13 tokens each.
   function Generate_Isupport (Tokens : String_Vectors.Vector)
      return Message_Vector;

   --  GenerateMOTD: 375, one 372 per line of Motd, 376.
   function Generate_MOTD (Motd : String) return Message_Vector;

   --  GenerateMonitor.
   function Generate_Monitor
     (Subcmd : String; Targets : String_Vectors.Vector) return Message_Vector;

   --  GenerateNamesReply: 353s then 366.
   function Generate_Names_Reply
     (Channel : String;
      Status  : Soja.Irc.Members.Channel_Status;
      Members : String_Vectors.Vector) return Message_Vector;

   --  GenerateSASL: AUTHENTICATE messages carrying the padded standard
   --  base64 of Resp in chunks of Max_SASL_Length.  Resp is a byte string.
   function Generate_SASL (Resp : String) return Message_Vector;

end Soja.Irc.Genmsg;
