pragma Ada_2022;

with Ada.Exceptions;

with Soja.Auth.OAuth2;
with Soja.Auth.Pam;

package body Soja.Auth is

   use type Soja.Database.Database_Access;

   Invalid : constant String := "Invalid credentials";

   function Failure (Internal, External : String) return Result is
     (Ok       => False,
      Internal => To_Unbounded_String (Internal),
      External => To_Unbounded_String (External));

   function Supports_Plain (Driver : String) return Boolean is
   begin
      return Driver = "internal" or else Driver = "pam"
        or else Driver = "oauth2";
   end Supports_Plain;

   function Supports_Bearer (Driver : String) return Boolean is
     (Driver = "oauth2");

   function Auth_Bearer
     (Driver   : String;
      Token    : String;
      Username : out Unbounded_String) return Result
   is
   begin
      Username := Null_Unbounded_String;
      if Driver /= "oauth2" then
         return Failure ("the " & Driver & " authenticator has no bearer "
                         & "tokens", "Authentication failed");
      end if;
      return Soja.Auth.OAuth2.Bearer (Token, Username);
   end Auth_Bearer;

   function Auth_Plain
     (Driver   : String;
      DB       : Soja.Database.Database_Access;
      Username : String;
      Password : String) return Result
   is
      U : Soja.Database.User;
   begin
      if Driver = "oauth2" then
         return Soja.Auth.OAuth2.Plain (Username, Password);
      elsif Driver = "pam" then
         return Soja.Auth.Pam.Plain (Username, Password);
      elsif Driver /= "internal" then
         return Failure
           ("the " & Driver & " authenticator is not ported",
            "Authentication failed");
      end if;
      if DB = null then
         return Failure ("no database", "Authentication failed");
      end if;

      begin
         U := Soja.Database.Get_User (DB.all, Username);
      exception
         when E : Soja.Database.Not_Found | Soja.Database.Database_Error =>
            return Failure
              ("user not found: " & Ada.Exceptions.Exception_Message (E),
               Invalid);
      end;

      declare
         Upgraded : Boolean;
      begin
         Upgraded := Soja.Database.Check_Password (U, Password);
         if Upgraded then
            --  The hash was upgraded to the current cost: keep it.
            begin
               Soja.Database.Store_User (DB.all, U);
            exception
               when E : Soja.Database.Database_Error =>
                  return Failure
                    (Ada.Exceptions.Exception_Message (E),
                     "Authentication failed");
            end;
         end if;
      exception
         when E : Soja.Database.Database_Error =>
            return Failure (Ada.Exceptions.Exception_Message (E), Invalid);
      end;
      return (Ok => True, others => <>);
   end Auth_Plain;

end Soja.Auth;
