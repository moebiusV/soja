pragma Ada_2022;

with Ada.Exceptions;
with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;

with AWS.Client;
with AWS.Headers;
with AWS.Messages;
with AWS.Response;

with Soja.Base64;
with Soja.Tls_Default;

package body Soja.Auth.Http is

   use type AWS.Messages.Status_Code;

   Timeout : constant Duration := 30.0;

   protected Current is
      procedure Set (URL : String);
      function Get return String;
   private
      Value : Unbounded_String;
   end Current;

   protected body Current is
      procedure Set (URL : String) is
      begin
         Value := To_Unbounded_String (URL);
      end Set;
      function Get return String is (To_String (Value));
   end Current;

   procedure Setup (URL : String) is
   begin
      Current.Set (URL);
   end Setup;

   function Plain
     (Username, Password : String; Remote : String := "") return Result
   is
      URL      : constant String := Current.Get;
      Headers  : AWS.Headers.List;
      Response : AWS.Response.Data;
   begin
      if URL = "" then
         return (Ok => False,
                 Internal => To_Unbounded_String
                   ("the HTTP authentication server is not set up"),
                 External => To_Unbounded_String ("Authentication failed"));
      end if;
      Soja.Tls_Default.Ensure;
      AWS.Headers.Add
        (Headers, "Authorization",
         "Basic " & Soja.Base64.Encode (Username & ":" & Password));
      Add_Forwarded_Headers (Headers, Remote);
      begin
         Response := AWS.Client.Post
           (URL, "", Headers => Headers, User_Agent => "soju",
            Timeouts => AWS.Client.Timeouts (Each => Timeout));
      exception
         when E : others =>
            return (Ok => False,
                    Internal => To_Unbounded_String
                      ("failed to send HTTP auth request: "
                       & Ada.Exceptions.Exception_Message (E)),
                    External => To_Unbounded_String
                      ("Authentication failed"));
      end;
      declare
         Code : constant AWS.Messages.Status_Code :=
           AWS.Response.Status_Code (Response);
      begin
         if Code = AWS.Messages.S200 then
            return (Ok => True, others => <>);
         elsif Code = AWS.Messages.S403 then
            return (Ok => False,
                    Internal => To_Unbounded_String
                      ("HTTP auth server returned forbidden"),
                    External => To_Unbounded_String ("Invalid credentials"));
         end if;
         return (Ok => False,
                 Internal => To_Unbounded_String
                   ("HTTP auth error: " & AWS.Messages.Image (Code) & " "
                    & AWS.Messages.Reason_Phrase (Code)),
                 External => To_Unbounded_String ("Authentication failed"));
      end;
   end Plain;

end Soja.Auth.Http;
