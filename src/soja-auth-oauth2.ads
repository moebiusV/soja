--  Soja.Auth.OAuth2 -- soju's auth/oauth2.go: users are authenticated by an
--  external OAuth 2.0 authorization server, through its token introspection
--  endpoint (RFC 7662).  `auth oauth2 <url>`: the server is found by its
--  metadata (RFC 8414) at /.well-known/oauth-authorization-server<path of the
--  URL>, and the client ID and secret, if there are, are the user and password
--  of the URL.
--
--  The HTTP requests are made with AWS.Client; TLS certificates are verified
--  against the system's CA bundle.  The documents are read with Soja.Json.
pragma Ada_2022;

with Ada.Strings.Unbounded;

package Soja.Auth.OAuth2 is

   Setup_Error : exception;   --  Exception_Message is newOAuth2's error

   --  newOAuth2: discovers the server (10 s at most) and remembers where to
   --  introspect tokens.  A later call replaces the settings (a reload).
   procedure Setup (URL : String);

   --  AuthOAuthBearer: asks the server who the token is for.  Username is set
   --  when Ok.
   function Bearer
     (Token    : String;
      Username : out Ada.Strings.Unbounded.Unbounded_String;
      Remote   : String := "") return Result;

   --  AuthPlain: the password is the token, and its user must be Username.
   function Plain
     (Username, Password : String; Remote : String := "") return Result;

end Soja.Auth.OAuth2;
