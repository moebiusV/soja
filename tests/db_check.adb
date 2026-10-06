pragma Ada_2022;

with Ada.Text_IO;
with Ada.Strings.Unbounded;
with Soja.Database;

procedure Db_Check is
   use Ada.Strings.Unbounded;
   use Soja.Database;

   U : User := New_User ("alice");
   N : Network := New_Network ("irc.libera.chat");
begin
   --  A fresh user has no password: auth is disabled.
   begin
      declare
         Dummy : Boolean := Check_Password (U, "x");
      begin
         raise Program_Error with "expected disabled auth to raise";
      end;
   exception
      when Database_Error =>
         null;   -- expected
   end;

   --  Set and verify a password.
   Set_Password (U, "hunter2");
   if not U.Enabled then
      raise Program_Error with "new user must be enabled";
   end if;
   declare
      Upgraded : constant Boolean := Check_Password (U, "hunter2");
   begin
      if Upgraded then
         raise Program_Error with "fresh hash must not upgrade";
      end if;
   end;

   --  A wrong password must raise.
   begin
      declare
         Dummy : Boolean := Check_Password (U, "wrong");
      begin
         raise Program_Error with "expected wrong password to raise";
      end;
   exception
      when Database_Error =>
         null;   -- expected
   end;

   --  The stored hash has the bcrypt "$2" form and the default cost.
   declare
      H : constant String := To_String (U.Password);
   begin
      if H'Length < 7 or else H (H'First) /= '$' or else H (H'First + 1) /= '2' then
         raise Program_Error with "unexpected hash prefix: " & H;
      end if;
   end;

   --  Network helpers.
   if Get_Name (N) /= "irc.libera.chat" then
      raise Program_Error with "Get_Name wrong";
   end if;
   if Get_Nick (U, N) /= "alice" then
      raise Program_Error with "Get_Nick should fall back to username";
   end if;
   U.Nick := To_Unbounded_String ("bob");
   if Get_Nick (U, N) /= "bob" then
      raise Program_Error with "Get_Nick should prefer the user nick";
   end if;

   Ada.Text_IO.Put_Line ("ALL PASS");
end Db_Check;
