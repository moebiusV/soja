--  Soja.Json -- reading the members of a JSON object, for the documents the
--  OAuth 2.0 client reads (RFC 8414 server metadata, RFC 7662 introspection):
--  what Go does by decoding into a struct.  The text is read by the parser
--  hbnf makes of grammars/json.hbnf.
--
--  As encoding/json does: a member is found by its name exactly or else in any
--  case, the last of several of one name wins, a member that is null is as if
--  it were not there, and one of another type than asked for is an error
--  (Type_Error).  Members that are not asked for may hold anything.
pragma Ada_2022;

with Ada.Strings.Unbounded;

with Soja.Irc.Genmsg;

package Soja.Json is

   Parse_Error : exception;   --  not JSON, or not an object
   Type_Error  : exception;   --  a member of another type than asked for

   --  The string a member holds; Found is False when there is none.
   procedure String_Member
     (Doc, Name : String;
      Value     : out Ada.Strings.Unbounded.Unbounded_String;
      Found     : out Boolean);

   --  The boolean a member holds.
   procedure Bool_Member
     (Doc, Name : String; Value : out Boolean; Found : out Boolean);

   --  The strings of an array a member holds.
   procedure Strings_Member
     (Doc, Name : String;
      Values    : out Soja.Irc.Genmsg.String_Vectors.Vector;
      Found     : out Boolean);

   --  A JSON string literal (with its quotes) as the text it stands for.
   function Decode_String (Literal : String) return String;

end Soja.Json;
