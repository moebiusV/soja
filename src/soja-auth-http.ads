--  Soja.Auth.Http -- soju's auth/http.go: `auth http <url>`.  The password is
--  checked by a POST to the URL with the user name and password as Basic
--  credentials: 200 is yes, 403 is wrong credentials, anything else an error.
pragma Ada_2022;

package Soja.Auth.Http is

   --  Remembers the URL.
   procedure Setup (URL : String);

   --  AuthPlain.  Remote is the client's address ("host:port"), told to the
   --  server in the Forwarded and X-Forwarded-For headers when it is known.
   function Plain
     (Username, Password : String; Remote : String := "") return Result;

end Soja.Auth.Http;
