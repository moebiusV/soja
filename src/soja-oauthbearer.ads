--  Soja.Oauthbearer -- the client's response of SASL OAUTHBEARER (RFC 7628),
--  as go-sasl's OAuthBearerServer reads it:
--  "n,a=user,^Aauth=Bearer <token>^A^A".  The response is read by the parser
--  hbnf makes of grammars/oauthbearer.hbnf.
pragma Ada_2022;

with Ada.Strings.Unbounded;

package Soja.Oauthbearer is

   --  sasl.OAuthBearerOptions.
   type Options is record
      Username : Ada.Strings.Unbounded.Unbounded_String;   --  a=, may be empty
      Token    : Ada.Strings.Unbounded.Unbounded_String;
      Host     : Ada.Strings.Unbounded.Unbounded_String;
      Port     : Natural := 0;
   end record;

   --  Ok is False for a response that is not one, one without a bearer token,
   --  or a port that is not a number.  (A key the server does not know is
   --  ignored, as RFC 7628 3.1 says.)
   procedure Parse
     (Response : String; Result : out Options; Ok : out Boolean);

end Soja.Oauthbearer;
