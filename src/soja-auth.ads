pragma Ada_2022;

with Ada.Strings.Unbounded;

with AWS.Headers;

with Soja.Database;

--  soju's auth/ package: password authentication of a user.  Only the
--  "internal" driver (the bcrypt hashes in the database) is ported; "pam"
--  and "oauth2" are not, and always fail.
package Soja.Auth is

   use Ada.Strings.Unbounded;

   --  The outcome of an authentication attempt.  Internal is for the log;
   --  External is safe to show the user (auth.Error's ExternalMsg), and is
   --  "Authentication failed" for errors that are not credential failures.
   type Result is record
      Ok       : Boolean := True;
      Internal : Unbounded_String;
      External : Unbounded_String;
   end record;

   --  setHTTPForwardedHeader: the headers that tell an authentication server
   --  who the request is for (the client's address, "host:port").  Remote ""
   --  gives none.
   procedure Add_Forwarded_Headers
     (Headers : in out AWS.Headers.List; Remote : String);

   --  Whether the driver can authenticate with a password
   --  (PlainAuthenticator): internal, pam, http, and oauth-plain, which is a
   --  bearer token given as the password.
   function Supports_Plain (Driver : String) return Boolean;

   --  Whether the driver can authenticate with an OAuth 2.0 bearer token
   --  (OAuthBearerAuthenticator): `oauth2`.
   function Supports_Bearer (Driver : String) return Boolean;

   --  AuthOAuthBearer: the user a token is for; Username is set when Ok.
   function Auth_Bearer
     (Driver   : String;
      Token    : String;
      Username : out Unbounded_String;
      Remote   : String := "") return Result;

   --  AuthPlain.  DB may be null only for drivers that don't use it.
   function Auth_Plain
     (Driver   : String;
      DB       : Soja.Database.Database_Access;
      Username : String;
      Password : String;
      Remote   : String := "") return Result;

end Soja.Auth;
