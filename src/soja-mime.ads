--  Soja.Mime -- what the file upload needs of Go's mime and net/http packages:
--  reading and writing a media type with parameters (mime.ParseMediaType,
--  FormatMediaType), the type of a file name (mime.TypeByExtension) and of its
--  content (http.DetectContentType).
--
--  The media type is read by the generated parser of grammars/media-type.hbnf.
pragma Ada_2022;

with Ada.Containers.Indefinite_Ordered_Maps;
with Ada.Strings.Unbounded;

package Soja.Mime is

   package Param_Maps is new Ada.Containers.Indefinite_Ordered_Maps
     (String, String);

   --  mime.ParseMediaType: the media type lower-cased ("text/plain",
   --  "attachment"), the parameters with lower-cased names and their quotes
   --  and backslashes taken off.  An extended parameter (name*=utf-8''...,
   --  RFC 2231) is decoded and stored under its name without the star.  Ok is
   --  False for what Go refuses: bad syntax, a parameter named twice.  (A
   --  continuation, name*0=, is not joined.)
   procedure Parse_Media_Type
     (Value  : String;
      Media  : out Ada.Strings.Unbounded.Unbounded_String;
      Params : out Param_Maps.Map;
      Ok     : out Boolean);

   --  mime.FormatMediaType: "attachment; filename=x", a token as it is, other
   --  text quoted, non-ASCII text as filename*=utf-8''...; the parameters in
   --  order of name.  "" when Media is not a media type.
   function Format_Media_Type
     (Media : String; Params : Param_Maps.Map) return String;

   --  mime.TypeByExtension for the types Go knows without a system file:
   --  ".png" is "image/png", "" for an extension not known.  (Go also reads
   --  the system's mime.types; soja does not.)
   function Type_By_Extension (Ext : String) return String
     with Global => null;

   --  http.DetectContentType: the type of the first 512 bytes of Data.
   function Detect_Content_Type (Data : String) return String
     with Global => null;

   --  The types a browser may show inline (the upload handler's
   --  inlineMIMETypes); the media type has no parameters.
   function Is_Inline (Media : String) return Boolean
     with Global => null;

   --  The one extension an upload of this type gets when its name has none
   --  (the handler's primaryExts, and the types with a single extension in
   --  Go's table): ".png", "" when there is none.
   function Extension_Of (Media : String) return String
     with Global => null;

end Soja.Mime;
