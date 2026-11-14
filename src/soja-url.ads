--  Soja.Url -- what soja needs of Go's net/url and path packages: an absolute
--  URL split into its pieces (by the parser hbnf makes of grammars/url.hbnf),
--  and the escaping and cleaning of paths.
pragma Ada_2022;

with Ada.Strings.Unbounded;

package Soja.Url is

   use Ada.Strings.Unbounded;

   --  url.Parse of an absolute URL, as far as the pieces go: the user and the
   --  password (percent escapes taken off) of the authority, the host (without
   --  the brackets of an IPv6 literal), the port as written, the path as
   --  written.  The query and the fragment are not kept.
   type Parts is record
      Scheme       : Unbounded_String;
      User         : Unbounded_String;
      Password     : Unbounded_String;
      Has_User     : Boolean := False;
      Has_Password : Boolean := False;
      Host         : Unbounded_String;
      Port         : Unbounded_String;
      Path         : Unbounded_String;
   end record;

   --  Ok is False for what Go refuses as well as for what is not a URL with an
   --  authority.
   procedure Parse (Text : String; P : out Parts; Ok : out Boolean);

   --  url.PathUnescape / PathEscape (segments), url.QueryEscape, and
   --  url.QueryUnescape.  Ok is False for a bad escape.
   function Path_Escape (S : String) return String
     with Global => null;
   function Path_Unescape (S : String; Ok : out Boolean) return String
     with Global => null;
   function Query_Escape (S : String) return String
     with Global => null;

   --  path.Join ("/", P)[1:]: dots and doubled slashes resolved, no way out of
   --  the root.
   function Clean_Path (P : String) return String
     with Global => null;

   --  path.Base.
   function Path_Base (P : String) return String
     with Global => null;

end Soja.Url;
