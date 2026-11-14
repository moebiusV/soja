pragma Ada_2022;

with Ada.Exceptions;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;

with AWS.Client;
with AWS.Headers;
with AWS.Messages;
with AWS.Response;

with Soja.Base64;
with Soja.Irc.Genmsg;
with Soja.Json;
with Soja.Tls_Default;
with Soja.Url;

package body Soja.Auth.OAuth2 is

   use type AWS.Messages.Status_Code;

   Timeout : constant Duration := 10.0;

   --  What newOAuth2 found out.
   type Settings is record
      Introspection : Unbounded_String;
      Client_ID     : Unbounded_String;
      Client_Secret : Unbounded_String;
   end record;

   protected Current is
      procedure Set (S : Settings);
      function Get return Settings;
   private
      Value : Settings;
   end Current;

   protected body Current is
      procedure Set (S : Settings) is
      begin
         Value := S;
      end Set;
      function Get return Settings is (Value);
   end Current;

   --  "404 Not Found", as Go's resp.Status.
   function Status_Line (D : AWS.Response.Data) return String is
      Code : constant AWS.Messages.Status_Code := AWS.Response.Status_Code (D);
   begin
      return AWS.Messages.Image (Code) & " "
             & AWS.Messages.Reason_Phrase (Code);
   end Status_Line;

   function Failure_Of (Internal : String) return Result is
     (Ok       => False,
      Internal => To_Unbounded_String (Internal),
      External => To_Unbounded_String ("Authentication failed"));

   function Invalid_Credentials (Internal : String) return Result is
     (Ok       => False,
      Internal => To_Unbounded_String (Internal),
      External => To_Unbounded_String ("Invalid credentials"));

   ----------------------------------------------------------------------
   --  Setup
   ----------------------------------------------------------------------

   procedure Setup (URL : String) is
      Parts : Soja.Url.Parts;
      Ok    : Boolean;
   begin
      Soja.Url.Parse (URL, Parts, Ok);
      if not Ok then
         raise Setup_Error with
           "failed to parse OAuth 2.0 server URL: invalid URL";
      end if;

      declare
         Path : constant String :=
           "/" & Soja.Url.Clean_Path
                   (".well-known/oauth-authorization-server/"
                    & To_String (Parts.Path));
         Host : constant String :=
           (if Ada.Strings.Fixed.Index (To_String (Parts.Host), ":") > 0
            then "[" & To_String (Parts.Host) & "]"
            else To_String (Parts.Host));
         Discovery : constant String :=
           To_String (Parts.Scheme) & "://" & Host
           & (if Length (Parts.Port) > 0 then ":" & To_String (Parts.Port)
              else "")
           & Path;
         Headers   : AWS.Headers.List;
         Response  : AWS.Response.Data;
      begin
         Soja.Tls_Default.Ensure;
         AWS.Headers.Add (Headers, "Accept", "application/json");
         begin
            Response := AWS.Client.Get
              (Discovery, Timeouts => AWS.Client.Timeouts (Each => Timeout),
               Follow_Redirection => True, Headers => Headers);
         exception
            when E : others =>
               raise Setup_Error with
                 "OAuth 2.0 discovery failed: failed to send request: "
                 & Ada.Exceptions.Exception_Message (E);
         end;
         if AWS.Response.Status_Code (Response) /= AWS.Messages.S200 then
            raise Setup_Error with
              "OAuth 2.0 discovery failed: OAuth 2.0 HTTP error: "
              & Status_Line (Response);
         end if;

         declare
            Doc : constant String := AWS.Response.Message_Body (Response);
            Issuer, Endpoint : Unbounded_String;
            Found   : Boolean;
            Methods : Soja.Irc.Genmsg.String_Vectors.Vector;
            Has_Methods, Supports_None, Supports_Basic : Boolean := False;
         begin
            begin
               Soja.Json.String_Member (Doc, "issuer", Issuer, Found);
               Soja.Json.String_Member
                 (Doc, "introspection_endpoint", Endpoint, Found);
               Soja.Json.Strings_Member
                 (Doc, "introspection_endpoint_auth_methods_supported",
                  Methods, Has_Methods);
            exception
               when Soja.Json.Parse_Error | Soja.Json.Type_Error =>
                  raise Setup_Error with
                    "OAuth 2.0 discovery failed: failed to decode response: "
                    & "invalid JSON";
            end;
            if Length (Issuer) = 0 then
               raise Setup_Error with
                 "OAuth 2.0 discovery failed: missing issuer in response";
            end if;
            if Length (Endpoint) = 0 then
               raise Setup_Error with
                 "OAuth 2.0 server doesn't support token introspection";
            end if;
            declare
               Introspection : Soja.Url.Parts;
               Valid : Boolean;
            begin
               Soja.Url.Parse (To_String (Endpoint), Introspection, Valid);
               if not Valid then
                  raise Setup_Error with
                    "failed to parse OAuth 2.0 introspection URL";
               end if;
            end;

            --  The authentication the endpoint takes.
            if Has_Methods then
               for Name of Methods loop
                  if Name = "none" then
                     Supports_None := True;
                  elsif Name = "client_secret_basic" then
                     Supports_Basic := True;
                  end if;
               end loop;
               if not Parts.Has_User and then not Supports_None then
                  raise Setup_Error with
                    "OAuth 2.0 server requires authentication for "
                    & "introspection";
               elsif Parts.Has_User and then not Supports_Basic then
                  raise Setup_Error with
                    "OAuth 2.0 server doesn't support Basic HTTP "
                    & "authentication for introspection";
               end if;
            end if;

            Current.Set
              ((Introspection => Endpoint,
                Client_ID     => (if Parts.Has_User then Parts.User
                                  else Null_Unbounded_String),
                Client_Secret => Parts.Password));
         end;
      end;
   end Setup;

   ----------------------------------------------------------------------
   --  Bearer and Plain
   ----------------------------------------------------------------------

   function Bearer
     (Token    : String;
      Username : out Unbounded_String;
      Remote   : String := "") return Result
   is
      S        : constant Settings := Current.Get;
      Headers  : AWS.Headers.List;
      Response : AWS.Response.Data;
   begin
      Username := Null_Unbounded_String;
      if Length (S.Introspection) = 0 then
         return Failure_Of ("the OAuth 2.0 server is not set up");
      end if;
      Soja.Tls_Default.Ensure;
      AWS.Headers.Add (Headers, "Accept", "application/json");
      Add_Forwarded_Headers (Headers, Remote);
      if Length (S.Client_ID) > 0 then
         AWS.Headers.Add
           (Headers, "Authorization",
            "Basic " & Soja.Base64.Encode
                         (Soja.Url.Query_Escape (To_String (S.Client_ID)) & ":"
                          & Soja.Url.Query_Escape
                              (To_String (S.Client_Secret))));
      end if;

      begin
         Response := AWS.Client.Post
           (To_String (S.Introspection),
            "token=" & Soja.Url.Query_Escape (Token),
            Content_Type => "application/x-www-form-urlencoded",
            Timeouts => AWS.Client.Timeouts (Each => Timeout),
            Headers  => Headers);
      exception
         when E : others =>
            return Failure_Of
              ("failed to send OAuth 2.0 introspection request: "
               & Ada.Exceptions.Exception_Message (E));
      end;
      if AWS.Response.Status_Code (Response) /= AWS.Messages.S200 then
         return Failure_Of
           ("OAuth 2.0 introspection error: " & Status_Line (Response));
      end if;

      declare
         Doc    : constant String := AWS.Response.Message_Body (Response);
         Active, Found : Boolean;
         Name   : Unbounded_String;
      begin
         begin
            Soja.Json.Bool_Member (Doc, "active", Active, Found);
            Soja.Json.String_Member (Doc, "username", Name, Found);
         exception
            when Soja.Json.Parse_Error | Soja.Json.Type_Error =>
               return Failure_Of
                 ("failed to decode OAuth 2.0 introspection response: "
                  & "invalid JSON");
         end;
         if not Active then
            return Invalid_Credentials ("invalid access token");
         elsif Length (Name) = 0 then
            --  We really need the username here, otherwise an OAuth 2.0 user
            --  can impersonate any other user.
            return Failure_Of
              ("missing username in OAuth 2.0 introspection response");
         end if;
         Username := Name;
         return (Ok => True, others => <>);
      end;
   end Bearer;

   function Plain
     (Username, Password : String; Remote : String := "") return Result
   is
      Effective : Unbounded_String;
      R         : constant Result := Bearer (Password, Effective, Remote);
   begin
      if not R.Ok then
         return R;
      elsif To_String (Effective) /= Username then
         return Invalid_Credentials
           ("username mismatch (OAuth 2.0 server returned "
            & '"' & To_String (Effective) & '"' & ")");
      end if;
      return R;
   end Plain;

end Soja.Auth.OAuth2;
