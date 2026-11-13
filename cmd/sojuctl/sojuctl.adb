--  sojuctl: run BouncerServ commands on the running daemon through its admin
--  socket (soju's cmd/sojuctl/main.go).
pragma Ada_2022;

with Ada.Command_Line;
with Ada.Exceptions;
with Ada.IO_Exceptions;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;
with Ada.Text_IO;

with GNAT.OS_Lib;
with GNAT.Sockets;

with Soja.Config;
with Soja.Conn.Unix;
with Soja.Flags;
with Soja.Irc.Genmsg;
with Soja.Irc.Helpers;
with Soja.Irc.Messages;     use Soja.Irc.Messages;
with Soja.Logging;

procedure Sojuctl is

   Default_Config_Path : constant String := "/etc/soju/config";
   Default_Admin_Path  : constant String := "/run/soju/admin";

   Log : constant Soja.Logging.Standard_Logger := (Debug_Enabled => False);

   --  log.Fatalln.
   procedure Fatal (Text : String) with No_Return;
   procedure Fatal (Text : String) is
   begin
      Log.Print (Text);
      GNAT.OS_Lib.OS_Exit (1);
      raise Program_Error;   --  (not reached)
   end Fatal;

   --  quoteWords: each word Go-quoted, joined by spaces.
   function Quote_Words (Words : Soja.Flags.String_Vector) return String is
      R : Unbounded_String;
   begin
      for W of Words loop
         if Length (R) > 0 then
            Append (R, ' ');
         end if;
         Append (R, Soja.Irc.Helpers.Quote (W));
      end loop;
      return To_String (R);
   end Quote_Words;

   --  The path of the first `listen unix+admin://[path]` directive.
   function Admin_Path (Cfg : Soja.Config.Server) return String is
      Scheme : constant String := "unix+admin://";
   begin
      for L of Cfg.Listen loop
         declare
            S : constant String := To_String (L);
         begin
            if S'Length >= Scheme'Length
              and then S (S'First .. S'First + Scheme'Length - 1) = Scheme
            then
               declare
                  Rest : constant String :=
                    S (S'First + Scheme'Length .. S'Last);
               begin
                  return (if Rest'Length > 0 and then Rest (Rest'First) = '/'
                          then Rest else Default_Admin_Path);
               end;
            end if;
         end;
      end loop;
      return "";
   end Admin_Path;

   Args  : Soja.Flags.String_Vector;
   Flags : Soja.Flags.Flag_Set;
   Cfg   : Soja.Config.Server;
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
         Ada.Text_IO.Put_Line
           (Ada.Text_IO.Standard_Error,
            "usage: sojuctl [-config path] <command>");
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

   declare
      Path : constant String := Admin_Path (Cfg);
   begin
      if Path = "" then
         Fatal ("no listen unix+admin directive found in config");
      end if;

      declare
         C : Soja.Conn.Unix.Unix_IRC_Conn;
      begin
         begin
            C := Soja.Conn.Unix.Connect (Path);
         exception
            when E : GNAT.Sockets.Socket_Error =>
               Fatal ("dial " & Path & ": "
                      & Ada.Exceptions.Exception_Message (E));
         end;

         begin
            Soja.Conn.Unix.Write_Message
              (C, Soja.Irc.Genmsg.Make
                    ("BOUNCERSERV", [Quote_Words (Flags.Args)]));
         exception
            when E : others =>
               Fatal ("write: " & Ada.Exceptions.Exception_Message (E));
         end;

         loop
            declare
               M : Message;
            begin
               begin
                  M := Soja.Conn.Unix.Read_Message (C);
               exception
                  when Ada.IO_Exceptions.End_Error =>
                     Fatal ("read: EOF");
                  when E : others =>
                     Fatal ("read: " & Ada.Exceptions.Exception_Message (E));
               end;

               if To_String (M.Command) = "PRIVMSG" then
                  Ada.Text_IO.Put_Line (Trailing (M));
               elsif To_String (M.Command) = "BOUNCERSERV" then
                  if Param (M, 0) = "OK" then
                     return;
                  end if;
                  Fatal (Trailing (M));
               else
                  Fatal (Trailing (M));
               end if;
            end;
         end loop;
      end;
   end;
end Sojuctl;
