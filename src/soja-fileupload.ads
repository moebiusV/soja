--  Soja.Fileupload -- the file upload of soju (fileupload/): the /uploads
--  handler of the HTTP listeners and the `fs` store behind it.
--
--    POST /uploads           stores the body of the request, for the user
--                            whose password is in the Authorization header
--                            (Basic); 201 with the file's address in Location.
--    GET, HEAD /uploads/<f>  the file, with its type, inline when it is safe
--                            to show (Content-Disposition), and Range support.
--    OPTIONS /uploads        204.
--
--  `file-upload fs <dir>` stores a file as <dir>/<user>/<random>-<name>.  The
--  size is limited to 50 MiB.  Not ported: chunked request bodies (411),
--  conditional requests (If-Modified-Since, ...), several ranges at once (the
--  whole file is sent), a Bearer token (no oauth2 driver), the system's
--  mime.types.  See PORTING.md.
pragma Ada_2022;

with Ada.Strings.Unbounded;

with Soja.Byte_Stream;
with Soja.Http;
with Soja.Server;
with Soja.Url;

package Soja.Fileupload is

   --  maxSize.
   Max_Size : constant := 50 * 1024 * 1024;

   --  Serves one /uploads request.  Common is the header fields every answer
   --  of the handler carries (Content-Security-Policy, the CORS fields).  The
   --  stream is not shut down here.
   procedure Serve
     (S      : in out Soja.Server.Server;
      Stream : not null Soja.Byte_Stream.Stream_Access;
      Req    : Soja.Http.Request;
      Common : String);

   ----------------------------------------------------------------------
   --  The pure parts (exposed for the tests)
   ----------------------------------------------------------------------

   --  path.Join ("/", P)[1:]: dots and doubled slashes resolved, no way out of
   --  the root.
   function Clean_Path (P : String) return String
     renames Soja.Url.Clean_Path;

   --  path.Base.
   function Path_Base (P : String) return String
     renames Soja.Url.Path_Base;

   --  url.PathEscape and the path of a request with its escapes taken off
   --  (Ok is False for a bad escape).
   function Path_Escape (S : String) return String
     renames Soja.Url.Path_Escape;
   function Path_Unescape (S : String; Ok : out Boolean) return String
     renames Soja.Url.Path_Unescape;

   --  The name a file is shown with: what follows the first '-' of its name
   --  (the random part before it is not the user's).
   function Shown_Name (Stored : String) return String
     with Global => null;

   --  Authorization: "Basic <base64 user:pass>".  Scheme is lower-cased; Ok is
   --  False when it is not a Basic header that decodes to user:password.
   procedure Basic_Credentials
     (Header   : String;
      Scheme   : out Ada.Strings.Unbounded.Unbounded_String;
      Username : out Ada.Strings.Unbounded.Unbounded_String;
      Password : out Ada.Strings.Unbounded.Unbounded_String;
      Ok       : out Boolean);

   --  A Range header against a file of Size bytes: the whole file (no header,
   --  or several ranges), one range (First .. Last), or none that can be
   --  served (416).
   type Range_Kind is (Whole, Partial, Unsatisfiable);
   procedure Parse_Range
     (Header : String; Size : Long_Long_Integer;
      Kind   : out Range_Kind; First, Last : out Long_Long_Integer);

end Soja.Fileupload;
