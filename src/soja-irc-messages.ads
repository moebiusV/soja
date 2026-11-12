pragma Ada_2022;

with Ada.Containers.Indefinite_Ordered_Maps;
with Ada.Containers.Indefinite_Vectors;
with Ada.Containers.Vectors;
with Ada.Strings.Unbounded;

--  IRC message types, translated from gopkg.in/irc.v4's parser.go: the
--  Message, its Prefix and the IRCv3 tag map, with parse and serialize
--  (Image) operations.  Message.Prefix is an access value (null when the
--  message has no prefix), matching Go's *Prefix.  Reproduces irc.v4's
--  parse/serialize quirks exactly; see PORTING.md for the deviations from
--  RFC 2812 / IRCv3.
package Soja.Irc.Messages is

   use Ada.Strings.Unbounded;

   Parse_Error : exception;

   package Tag_Maps is new Ada.Containers.Indefinite_Ordered_Maps
     (Key_Type     => String,
      Element_Type => String);

   type Tag_Map is record
      Data : Tag_Maps.Map;
   end record;

   function Has_Tag (Tags : Tag_Map; Name : String) return Boolean;
   function Get_Tag (Tags : Tag_Map; Name : String) return String;
   procedure Set_Tag (Tags : in out Tag_Map; Name, Value : String);
   function Tag_Count (Tags : Tag_Map) return Natural;

   function Copy (Tags : Tag_Map) return Tag_Map;
   function Image (Tags : Tag_Map) return String;
   function Parse_Tags (Line : String) return Tag_Map;
   function Parse_Tag_Value (V : String) return String;
   function Encode_Tag_Value (V : String) return String;

   type Prefix is record
      Name : Unbounded_String;
      User : Unbounded_String;
      Host : Unbounded_String;
   end record;

   type Prefix_Access is access Prefix;

   function Parse_Prefix (Line : String) return Prefix;
   function Image (P : Prefix) return String;

   package Param_Vectors is new Ada.Containers.Indefinite_Vectors
     (Index_Type   => Positive,
      Element_Type => Unbounded_String);

   type Message is record
      Tags    : Tag_Map;
      Prefix  : Prefix_Access;
      Command : Unbounded_String;
      Params  : Param_Vectors.Vector;
   end record;

   package Message_Vectors is new Ada.Containers.Vectors
     (Index_Type   => Positive,
      Element_Type => Message);

   function Parse_Message (Line : String) return Message;
   function Param (M : Message; I : Natural) return String;
   function Trailing (M : Message) return String;
   function Copy (M : Message) return Message;
   function Image (M : Message) return String;

end Soja.Irc.Messages;
