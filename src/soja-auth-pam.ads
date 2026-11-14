--  Soja.Auth.Pam -- soju's auth/pam.go: the password is checked by PAM
--  (service "soju", as soju does).  libpam is loaded when first used (dlopen), so soja runs
--  where PAM is not installed and refuses `auth pam` there at startup.
pragma Ada_2022;

package Soja.Auth.Pam is

   --  Whether libpam can be loaded.
   function Available return Boolean;

   --  AuthPlain.
   function Plain (Username, Password : String) return Result;

end Soja.Auth.Pam;
