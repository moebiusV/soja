pragma Ada_2022;

with Ada.Containers.Indefinite_Ordered_Maps;
with Ada.Containers.Ordered_Maps;
with Ada.Strings.Unbounded;

with Soja.Irc.Members;
with Soja.Irc.Messages;

--  irc.go's channel modes: the standard mode-type table, the channelModes
--  value map, applyChannelModes and channelModes.Format.
package Soja.Irc.Modes is

   --  Raised by Apply_Channel_Modes on a malformed modestring; the message is
   --  Go's error text.
   Mode_Error : exception;

   --  Standard channel mode types, as explained in
   --  https://modern.ircdocs.horse/#mode-message
   type Channel_Mode_Type is
     (Mode_Type_A,   --  adds/removes an address to/from a list
      Mode_Type_B,   --  setting; always has a parameter
      Mode_Type_C,   --  setting; parameter only when being set
      Mode_Type_D);  --  setting; never has a parameter

   --  Go's map[byte]channelModeType (an upstream's availableChannelModes).
   package Mode_Type_Maps is new Ada.Containers.Ordered_Maps
     (Key_Type => Character, Element_Type => Channel_Mode_Type);

   --  stdChannelModes.
   function Std_Channel_Modes return Mode_Type_Maps.Map;

   package Mode_Value_Maps is new Ada.Containers.Indefinite_Ordered_Maps
     (Key_Type => Character, Element_Type => String);

   --  Go's channelModes (map[byte]string).  Go keeps a nil map until the
   --  first RPL_CHANNELMODEIS and does not record modes while it is nil;
   --  Known is False in that state.
   type Channel_Modes is record
      Known  : Boolean := False;
      Values : Mode_Value_Maps.Map;
   end record;

   --  applyChannelModes: apply a MODE message's mode string and arguments.
   --  Membership changes (e.g. +o nick) are applied to Members; mode values
   --  are recorded in Modes only when Modes.Known.
   --  Raises Mode_Error on a malformed modestring.
   procedure Apply_Channel_Modes
     (Available_Memberships : Soja.Irc.Members.Membership_Vectors.Vector;
      Available_Modes       : Mode_Type_Maps.Map;
      Members               : Soja.Irc.Members.Member_Maps.Map;
      Modes                 : in out Channel_Modes;
      Mode_Str              : String;
      Arguments             : Soja.Irc.Messages.Param_Vectors.Vector);

   --  channelModes.Format: "+" then the modes with a value, then those
   --  without; Parameters receives the values in that same order.
   --  (Go iterates a map, so its order is random; this one is sorted by mode
   --  letter, which is wire-equivalent.)
   procedure Format
     (CM          : Channel_Modes;
      Mode_String : out Ada.Strings.Unbounded.Unbounded_String;
      Parameters  : out Soja.Irc.Messages.Param_Vectors.Vector);

end Soja.Irc.Modes;
