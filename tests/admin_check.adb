pragma Ada_2022;

with Ada.Exceptions;
with Ada.IO_Exceptions;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;
with Ada.Text_IO;
with GNAT.OS_Lib;

with Soja.Bouncer;
with Soja.Conn.Unix;
with Soja.Database;
with Soja.Database.Sqlite;
with Soja.Irc.Genmsg;
with Soja.Irc.Messages;      use Soja.Irc.Messages;
with Soja.Logging;
with Soja.Server;
with Soja.Unix_Server;

--  The admin socket: BOUNCERSERV commands over a unix socket.
procedure Admin_Check is
   package SD renames Soja.Database;

   Path : constant String := "/tmp/soja-admin-check.sock";

   procedure Check (Cond : Boolean; What : String) is
   begin
      Ada.Text_IO.Put_Line ((if Cond then "ok   " else "FAIL ") & What);
      if not Cond then
         raise Program_Error with What;
      end if;
   end Check;

   Log : aliased Soja.Logging.Standard_Logger;
   Srv : aliased Soja.Server.Server;
   DB  : SD.Database_Access := Soja.Database.Sqlite.Open_Temp_Sqlite_DB;
   B   : aliased Soja.Bouncer.Bouncer;
   L   : Soja.Unix_Server.Listener_Access;

   task Serving is
      entry Go;
   end Serving;
   task body Serving is
   begin
      accept Go;
      Soja.Unix_Server.Serve (L, Soja.Bouncer.Handle_Admin'Access);
   end Serving;

   --  Send one line; the lines that come back up to and including the first
   --  that is not a PRIVMSG, joined with '|' (without prefixes).
   function Ask (C : in out Soja.Conn.Unix.Unix_IRC_Conn; Line : String)
      return String
   is
      Result : Unbounded_String;
   begin
      Soja.Conn.Unix.Write_Message (C, Parse_Message (Line));
      loop
         declare
            M : constant Message := Soja.Conn.Unix.Read_Message (C);
            Text : constant String :=
              To_String (M.Command) & " " & Trailing (M);
         begin
            if Length (Result) > 0 then
               Append (Result, "|");
            end if;
            Append (Result, Text);
            exit when To_String (M.Command) /= "PRIVMSG";
         end;
      end loop;
      return To_String (Result);
   end Ask;

   function Has (Text, Needle : String) return Boolean is
     (Ada.Strings.Fixed.Index (Text, Needle) > 0);
begin
   declare
      Ok : Boolean;
   begin
      GNAT.OS_Lib.Delete_File (Path, Ok);   --  (a leftover of a failed run)
   end;

   Srv.Initialize (Log'Unchecked_Access);
   Srv.Set_DB (DB);
   declare
      Rec : SD.User := SD.New_User ("alice");
   begin
      SD.Set_Password (Rec, "secret");
      SD.Store_User (DB.all, Rec);
   end;
   Soja.Bouncer.Initialize (B, Srv'Unchecked_Access);
   Soja.Bouncer.Start (B);

   L := Soja.Unix_Server.Listen (Path, 8#600#);
   Check (GNAT.OS_Lib.Is_Regular_File (Path)
          or else not GNAT.OS_Lib.Is_Directory (Path), "the socket exists");
   Serving.Go;

   --  A regular IRC client is told this is not a regular server, and is
   --  disconnected.
   declare
      procedure Refused (Line : String) is
         C : Soja.Conn.Unix.Unix_IRC_Conn := Soja.Conn.Unix.Connect (Path);
      begin
         Check (Has (Ask (C, Line), "ERROR This is not a regular IRC server"),
                Line & " is refused");
      end Refused;
   begin
      Refused ("CAP LS");
      Refused ("NICK mallory");
      Refused ("USER u 0 * :u");
      Refused ("PASS secret");
   end;

   declare
      C : Soja.Conn.Unix.Unix_IRC_Conn := Soja.Conn.Unix.Connect (Path);
   begin
      Check (Has (Ask (C, "BOUNCERSERV :user status"),
                  "PRIVMSG alice: 0 networks|BOUNCERSERV OK"),
             "user status: " & Ask (C, "BOUNCERSERV :user status"));
      Check (Has (Ask (C, "BOUNCERSERV :user create -username bob -password pw"),
                  "created user ""bob""|BOUNCERSERV OK"), "user create");
      Check (Has (Ask (C, "BOUNCERSERV :server status"), "users, "),
             "server status");
      Check (Has (Ask (C, "BOUNCERSERV :user run bob network status"),
                  "No network configured"), "user run");
      Check (Has (Ask (C, "BOUNCERSERV :frob"),
                  "FAIL command ""frob"" not found"), "a failing command");
      Check (Has (Ask (C, "BOUNCERSERV :network status"),
                  "this command must be run as a user"),
             "commands that need a user");
      Check (Has (Ask (C, "BOUNCERSERV"), " 461 ")
             or else Has (Ask (C, "BOUNCERSERV"), "Not enough parameters"),
             "BOUNCERSERV needs a command line");
      Check (Has (Ask (C, "FROB x"), "Unknown command"), "other commands");
      Soja.Conn.Unix.Close (C);
   end;

   --  Another client later, and two at the same time.
   declare
      C1 : Soja.Conn.Unix.Unix_IRC_Conn := Soja.Conn.Unix.Connect (Path);
   begin
      Check (Has (Ask (C1, "BOUNCERSERV :help"), "BOUNCERSERV OK"),
             "a client after another");
      declare
         C2 : Soja.Conn.Unix.Unix_IRC_Conn := Soja.Conn.Unix.Connect (Path);
      begin
         Check (Has (Ask (C2, "BOUNCERSERV :help"), "BOUNCERSERV OK")
                and then Has (Ask (C1, "BOUNCERSERV :help"), "BOUNCERSERV OK"),
                "two clients at once");
         Soja.Conn.Unix.Close (C2);
      end;
      Soja.Conn.Unix.Close (C1);
   end;

   Soja.Unix_Server.Stop (L);
   delay 0.4;
   Check (not GNAT.OS_Lib.Is_Regular_File (Path)
          and then not GNAT.OS_Lib.Is_Directory (Path),
          "the socket file is removed when serving ends");
   begin
      L := Soja.Unix_Server.Listen (Path, 8#600#);
      Soja.Unix_Server.Stop (L);   --  it can be listened on again
   exception
      when Soja.Unix_Server.Listen_Error =>
         Check (False, "the path is free again");
   end;
   Soja.Bouncer.Shutdown (B, Timeout => 10.0);
   Ada.Text_IO.Put_Line ("ALL PASS");
exception
   when E : others =>
      Ada.Text_IO.Put_Line
        ("FAILED: " & Ada.Exceptions.Exception_Information (E));
      GNAT.OS_Lib.OS_Exit (1);
end Admin_Check;
