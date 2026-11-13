--  sojadb: create users and change passwords directly in the database
--  (soju's cmd/sojudb/main.go).
pragma Ada_2022;

with Ada.Command_Line;
with Ada.Exceptions;
with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;
with Ada.Text_IO;
with Interfaces.C;

with GNAT.OS_Lib;

with Soja.Config;
with Soja.Database;
with Soja.Database.Sqlite;
with Soja.Flags;
with Soja.Irc.Helpers;
with Soja.Logging;

procedure Sojadb is

   Default_Config_Path : constant String := "/etc/soju/config";

   Usage : constant String :=
     "usage: sojadb [-config path] <action> [options...]" & ASCII.LF
     & ASCII.LF
     & "  create-user <username> [-admin]  Create a new user" & ASCII.LF
     & "  change-password <username>       Change password for a user"
     & ASCII.LF
     & "  help                             Show this help message" & ASCII.LF;

   Log : constant Soja.Logging.Standard_Logger := (Debug_Enabled => False);

   procedure Fatal (Text : String) with No_Return;
   procedure Fatal (Text : String) is
   begin
      Log.Print (Text);
      GNAT.OS_Lib.OS_Exit (1);
      raise Program_Error;   --  (not reached)
   end Fatal;

   procedure Show_Usage is
   begin
      Ada.Text_IO.Put (Ada.Text_IO.Standard_Error, Usage);
   end Show_Usage;

   use type GNAT.OS_Lib.String_Access;

   function Is_A_Terminal return Boolean is
      function C_Isatty (FD : Interfaces.C.int) return Interfaces.C.int
        with Import, Convention => C, External_Name => "isatty";
      use type Interfaces.C.int;
   begin
      return C_Isatty (0) /= 0;
   end Is_A_Terminal;

   --  Echo on or off on the terminal (stty, as there is no portable Ada way).
   procedure Set_Echo (On : Boolean) is
      Stty : GNAT.OS_Lib.String_Access :=
        GNAT.OS_Lib.Locate_Exec_On_Path ("stty");
      Args : GNAT.OS_Lib.Argument_List (1 .. 1);
      Ok   : Boolean;
   begin
      if Stty = null then
         return;
      end if;
      Args (1) := new String'(if On then "echo" else "-echo");
      GNAT.OS_Lib.Spawn (Stty.all, Args, Ok);
      GNAT.OS_Lib.Free (Args (1));
      GNAT.OS_Lib.Free (Stty);
   end Set_Echo;

   function Read_Password return String is
   begin
      if Is_A_Terminal then
         Ada.Text_IO.Put ("Password: ");
         Ada.Text_IO.Flush;
         Set_Echo (False);
         declare
            Line : constant String := Ada.Text_IO.Get_Line;
         begin
            Set_Echo (True);
            Ada.Text_IO.New_Line;
            return Line;
         exception
            when others =>
               Set_Echo (True);
               raise;
         end;
      else
         Ada.Text_IO.Put_Line
           (Ada.Text_IO.Standard_Error,
            "Warning: Reading password from stdin.");
         declare
            Line : constant String := Ada.Text_IO.Get_Line;
         begin
            if Line'Length = 0 then
               raise Program_Error with "zero length password";
            end if;
            return Line;
         end;
      end if;
   exception
      when Ada.Text_IO.End_Error =>
         raise Program_Error with "unexpected EOF";
   end Read_Password;

   Args  : Soja.Flags.String_Vector;
   Flags : Soja.Flags.Flag_Set;
   Cfg   : Soja.Config.Server;
   DB    : Soja.Database.Database_Access;
begin
   for I in 1 .. Ada.Command_Line.Argument_Count loop
      Args.Append (Ada.Command_Line.Argument (I));
   end loop;
   Flags.Add_String ("config", Default_Config_Path);
   begin
      Flags.Parse (Args);
   exception
      when E : Soja.Flags.Flag_Error =>
         Ada.Text_IO.Put_Line
           (Ada.Text_IO.Standard_Error, Ada.Exceptions.Exception_Message (E));
         Show_Usage;
         GNAT.OS_Lib.OS_Exit (2);
   end;

   if Flags.Get ("config") /= "" then
      begin
         Cfg := Soja.Config.Load (Flags.Get ("config"));
      exception
         when E : others =>
            Fatal ("failed to load config file: "
                   & Ada.Exceptions.Exception_Message (E));
      end;
   else
      Cfg := Soja.Config.Defaults;
   end if;

   --  (As in Go, the database is opened before the action is checked.)
   if To_String (Cfg.DB.Driver) /= "sqlite3" then
      Fatal ("failed to open database: the "
             & Soja.Irc.Helpers.Quote (To_String (Cfg.DB.Driver))
             & " driver is not supported by soja (SQLite only)");
   end if;
   begin
      DB := Soja.Database.Sqlite.Open_Sqlite_DB (To_String (Cfg.DB.Source));
   exception
      when E : others =>
         Fatal ("failed to open database: "
                & Ada.Exceptions.Exception_Message (E));
   end;

   declare
      Action   : constant String := Flags.Arg (0);
      Username : constant String := Flags.Arg (1);
   begin
      if Action = "create-user" then
         if Username = "" then
            Show_Usage;
            GNAT.OS_Lib.OS_Exit (1);
         end if;

         declare
            Sub  : Soja.Flags.Flag_Set;
            Rest : Soja.Flags.String_Vector;
         begin
            Sub.Add_Bool ("admin");
            for I in 2 .. Flags.N_Arg - 1 loop
               Rest.Append (Flags.Arg (I));
            end loop;
            begin
               Sub.Parse (Rest);
            exception
               when E : Soja.Flags.Flag_Error =>
                  Ada.Text_IO.Put_Line
                    (Ada.Text_IO.Standard_Error,
                     Ada.Exceptions.Exception_Message (E));
                  GNAT.OS_Lib.OS_Exit (2);
            end;

            declare
               Password : constant String := Read_Password;
               User     : Soja.Database.User :=
                 Soja.Database.New_User (Username);
            begin
               User.Admin := Sub.Get_Bool ("admin");
               begin
                  Soja.Database.Set_Password (User, Password);
               exception
                  when E : others =>
                     Fatal ("failed to set user password: "
                            & Ada.Exceptions.Exception_Message (E));
               end;
               begin
                  Soja.Database.Store_User (DB.all, User);
               exception
                  when E : others =>
                     Fatal ("failed to create user: "
                            & Ada.Exceptions.Exception_Message (E));
               end;
            end;
         end;

      elsif Action = "change-password" then
         if Username = "" then
            Show_Usage;
            GNAT.OS_Lib.OS_Exit (1);
         end if;

         declare
            User : Soja.Database.User;
         begin
            begin
               User := Soja.Database.Get_User (DB.all, Username);
            exception
               when E : others =>
                  Fatal ("failed to get user: "
                         & Ada.Exceptions.Exception_Message (E));
            end;
            declare
               Password : constant String := Read_Password;
            begin
               begin
                  Soja.Database.Set_Password (User, Password);
               exception
                  when E : others =>
                     Fatal ("failed to set user password: "
                            & Ada.Exceptions.Exception_Message (E));
               end;
               begin
                  Soja.Database.Store_User (DB.all, User);
               exception
                  when E : others =>
                     Fatal ("failed to update password: "
                            & Ada.Exceptions.Exception_Message (E));
               end;
            end;
         end;

      else
         Show_Usage;
         if Action /= "help" then
            GNAT.OS_Lib.OS_Exit (1);
         end if;
      end if;
   end;

   Soja.Database.Close (DB.all);
exception
   when E : Program_Error =>
      Fatal (Ada.Exceptions.Exception_Message (E));
end Sojadb;
