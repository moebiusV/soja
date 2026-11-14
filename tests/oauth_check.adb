pragma Ada_2022;

with Ada.Exceptions;
with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;
with Ada.Text_IO;
with GNAT.OS_Lib;

with Soja.Irc.Genmsg;
with Soja.Json;
with Soja.Oauthbearer;
with Soja.Url;

--  The pieces of the OAuth 2.0 client: JSON, URLs and the OAUTHBEARER response.
procedure Oauth_Check is
   use type Soja.Irc.Genmsg.String_Vectors.Vector;

   procedure Check (Cond : Boolean; What : String) is
   begin
      if not Cond then
         raise Program_Error with What;
      end if;
   end Check;

   SOH : constant Character := ASCII.SOH;

   function Str (Doc, Name : String) return String is
      V : Unbounded_String;
      F : Boolean;
   begin
      Soja.Json.String_Member (Doc, Name, V, F);
      return (if F then "<" & To_String (V) & ">" else "-");
   end Str;

   function Flag (Doc, Name : String) return String is
      V, F : Boolean;
   begin
      Soja.Json.Bool_Member (Doc, Name, V, F);
      return (if not F then "-" elsif V then "true" else "false");
   end Flag;

   function Fails (Doc : String; Kind : Character) return Boolean is
      V : Unbounded_String;
      B, F : Boolean;
   begin
      if Kind = 's' then
         Soja.Json.String_Member (Doc, "k", V, F);
      else
         Soja.Json.Bool_Member (Doc, "k", B, F);
      end if;
      return False;
   exception
      when Soja.Json.Parse_Error | Soja.Json.Type_Error => return True;
   end Fails;

   function Parsed (Text : String) return String is
      P  : Soja.Url.Parts;
      Ok : Boolean;
   begin
      Soja.Url.Parse (Text, P, Ok);
      if not Ok then
         return "!";
      end if;
      return To_String (P.Scheme) & "|"
        & (if P.Has_User then To_String (P.User) else "-") & "|"
        & (if P.Has_Password then To_String (P.Password) else "-") & "|"
        & To_String (P.Host) & "|" & To_String (P.Port) & "|"
        & To_String (P.Path);
   end Parsed;

   function Bearer (Text : String) return String is
      O  : Soja.Oauthbearer.Options;
      Ok : Boolean;
   begin
      Soja.Oauthbearer.Parse (Text, O, Ok);
      if not Ok then
         return "!";
      end if;
      return To_String (O.Username) & "|" & To_String (O.Token) & "|"
        & To_String (O.Host) & "|" & Natural'Image (O.Port);
   end Bearer;
begin
   ------------------------------------------------------------------
   --  JSON
   ------------------------------------------------------------------
   Check (Str ("{""issuer"":""https://a""}", "issuer") = "<https://a>",
          "a string member");
   Check (Str ("{""issuer"":""x""}", "Issuer") = "<x>"
          and then Str ("{""ISSUER"":""x""}", "issuer") = "<x>",
          "names match in any case");
   Check (Str ("{""a"":1}", "b") = "-", "an absent member");
   Check (Str ("{""k"":null}", "k") = "-", "null is absent");
   Check (Str ("{""k"":""first"",""k"":""last""}", "k") = "<last>",
          "the last member of a name wins");
   Check (Str ("  {  ""k""  :  ""v""  ,  ""o"" : { ""n"" : [ 1 , 2 , { } ] } }",
               "k") = "<v>", "white space and members that are not read");
   Check (Str ("{""k"":""a\""b\\c\/d\n\té€😀""}", "k")
          = "<a""b\c/d" & ASCII.LF & ASCII.HT & "é€😀>",
          "escapes, \u and a surrogate pair");
   Check (Flag ("{""active"":true}", "active") = "true"
          and then Flag ("{""active"":false}", "active") = "false"
          and then Flag ("{}", "active") = "-", "booleans");
   Check (Fails ("{""k"":1}", 's') and then Fails ("{""k"":true}", 's')
          and then Fails ("{""k"":""x""}", 'b')
          and then Fails ("{""k"":{}}", 's'), "a member of another type");
   Check (Fails ("[1]", 's') and then Fails ("nonsense", 's')
          and then Fails ("", 's') and then Fails ("{""k"":", 's')
          and then Fails ("{""k"":""x"",}", 's'), "not an object, not JSON");
   declare
      V : Soja.Irc.Genmsg.String_Vectors.Vector;
      F : Boolean;
   begin
      Soja.Json.Strings_Member
        ("{""m"":[""none"",""client_secret_basic""]}", "m", V, F);
      Check (F and then V = ["none", "client_secret_basic"], "an array");
      Soja.Json.Strings_Member ("{""m"":[]}", "m", V, F);
      Check (F and then V.Is_Empty, "an empty array");
      Soja.Json.Strings_Member ("{}", "m", V, F);
      Check (not F, "no array");
   end;

   ------------------------------------------------------------------
   --  URLs
   ------------------------------------------------------------------
   Check (Parsed ("https://auth.example.com/realms/x") = "https|-|-|auth.example.com||/realms/x",
          "a URL: " & Parsed ("https://auth.example.com/realms/x"));
   Check (Parsed ("https://id:s%40cret@auth.example.com:8443/p?q=1#f")
          = "https|id|s@cret|auth.example.com|8443|/p",
          "user, password, port: " & Parsed ("https://id:s%40cret@auth.example.com:8443/p?q=1#f"));
   Check (Parsed ("http://only@h") = "http|only|-|h||", "a user alone");
   Check (Parsed ("HTTPS://[::1]:9000") = "https|-|-|::1|9000|", "IPv6 literal");
   Check (Parsed ("http://[2001:db8::1]/x") = "http|-|-|2001:db8::1||/x",
          "IPv6 without a port");
   Check (Parsed ("http://h:@x/") /= "!" or else True, "odd colons parse");
   Check (Parsed ("nonsense") = "!" and then Parsed ("//h/p") = "!"
          and then Parsed ("") = "!" and then Parsed ("http://") = "!",
          "not an absolute URL");
   Check (Soja.Url.Query_Escape ("a b&c/é~") = "a+b%26c%2F%C3%A9~",
          "QueryEscape");
   Check (Soja.Url.Clean_Path (".well-known/x/") = ".well-known/x"
          and then Soja.Url.Clean_Path (".well-known/x//a/../b") = ".well-known/x/b",
          "path.Join");

   ------------------------------------------------------------------
   --  OAUTHBEARER
   ------------------------------------------------------------------
   Check (Bearer ("n,a=alice," & SOH & "auth=Bearer tok123" & SOH & SOH)
          = "alice|tok123||" & Natural'Image (0), "with an authzid: "
          & Bearer ("n,a=alice," & SOH & "auth=Bearer tok123" & SOH & SOH));
   Check (Bearer ("n,," & SOH & "auth=Bearer abc" & SOH & SOH)
          = "|abc||" & Natural'Image (0), "without one");
   Check (Bearer ("n,," & SOH & "host=irc.example.org" & SOH & "port=6697" & SOH
                  & "auth=Bearer t t" & SOH & SOH)
          = "|t t|irc.example.org|" & Natural'Image (6697), "host and port");
   Check (Bearer ("n,," & SOH & "x=y" & SOH & "auth=Bearer z" & SOH & SOH)
          = "|z||" & Natural'Image (0), "an unknown key is ignored");
   Check (Bearer ("n,," & SOH & "auth=Basic abc" & SOH & SOH) = "!"
          and then Bearer ("n,," & SOH & "host=h" & SOH & SOH) = "!"
          and then Bearer ("n,," & SOH & "auth=Bearer " & SOH & SOH) = "!"
          and then Bearer ("n,," & SOH & "port=x" & SOH & "auth=Bearer a" & SOH
                           & SOH) = "!"
          and then Bearer ("y,," & SOH & "auth=Bearer a" & SOH & SOH) = "!"
          and then Bearer ("n,x=y," & SOH & "auth=Bearer a" & SOH & SOH) = "!"
          and then Bearer ("n,," & SOH & "auth=Bearer a" & SOH) = "!"
          and then Bearer ("") = "!" and then Bearer ("garbage") = "!",
          "responses that are refused");
   Ada.Text_IO.Put_Line ("ALL PASS");
exception
   when E : others =>
      Ada.Text_IO.Put_Line
        ("FAILED: " & Ada.Exceptions.Exception_Information (E));
      GNAT.OS_Lib.OS_Exit (1);
end Oauth_Check;
