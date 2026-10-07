pragma Ada_2022;

with Ada.Text_IO;
with Ada.IO_Exceptions;
with Ada.Strings.Unbounded;

with Soja.Conn;
with Soja.Core;
with Soja.Database;
with Soja.Database.Sqlite;
with Soja.Irc.Messages;
with Soja.Logging;
with Soja.Server;

procedure Downstream_Register_Check is
   use Ada.Strings.Unbounded;
   use Soja.Core;
   use Soja.Conn;

   --  A scripted client transport: replay the given messages, then EOF.
   type Msg_Array is array (1 .. 4) of Soja.Irc.Messages.Message;

   type Fake_Transport is new IRC_Conn with record
      Script : Msg_Array;
      Count  : Natural := 0;
      N      : Natural := 0;
   end record;

   overriding function Read_Message (C : in out Fake_Transport)
      return Soja.Irc.Messages.Message;
   overriding procedure Write_Message (C : in out Fake_Transport;
      M : Soja.Irc.Messages.Message);
   overriding procedure Close (C : in out Fake_Transport);
   overriding function Remote_Addr (C : Fake_Transport) return String;

   overriding function Read_Message (C : in out Fake_Transport)
      return Soja.Irc.Messages.Message
   is
   begin
      if C.N >= C.Count then
         raise Ada.IO_Exceptions.End_Error;
      end if;
      C.N := C.N + 1;
      return C.Script (C.N);
   end Read_Message;

   overriding procedure Write_Message (C : in out Fake_Transport;
      M : Soja.Irc.Messages.Message) is
   begin
      pragma Unreferenced (C, M);
      null;   --  replies are not asserted here
   end Write_Message;

   overriding procedure Close (C : in out Fake_Transport) is
   begin
      pragma Unreferenced (C);
      null;
   end Close;

   overriding function Remote_Addr (C : Fake_Transport) return String is
   begin
      pragma Unreferenced (C);
      return "fake";
   end Remote_Addr;

   --  Run a registration against a scripted client, returning the result.
   function Try (Script : Msg_Array; Count : Natural;
                 Srv : not null Soja.Server.Server_Access) return Boolean
   is
      F      : aliased Fake_Transport;
      DC     : Downstream_Conn_Access;
      Result : Boolean;
   begin
      F.Script := Script;
      F.Count := Count;
      DC := New_Downstream_Conn (Srv, F'Unchecked_Access, 1);
      Result := Run_Until_Registered_Downstream (DC);
      Soja.Conn.Close (DC.Conn);
      return Result;
   end Try;

   DB  : Soja.Database.Database_Access := Soja.Database.Sqlite.Open_Temp_Sqlite_DB;
   Rec : Soja.Database.User := Soja.Database.New_User ("alice");
   S   : aliased Soja.Server.Server;
   Log : aliased Soja.Logging.Standard_Logger;

   Good, Bad : Msg_Array;
   use Soja.Irc.Messages;

begin
   Soja.Database.Set_Password (Rec, "hunter2");
   Soja.Database.Store_User (DB.all, Rec);
   S.Initialize (Log'Unchecked_Access);
   Soja.Server.Set_DB (S, DB);

   Good (1) := Parse_Message ("PASS hunter2");
   Good (2) := Parse_Message ("NICK alice");
   Good (3) := Parse_Message ("USER alice 0 * :alice");

   Bad (1) := Parse_Message ("PASS wrong");
   Bad (2) := Parse_Message ("NICK alice");
   Bad (3) := Parse_Message ("USER alice 0 * :alice");

   if not Try (Good, 3, S'Unchecked_Access) then
      raise Program_Error with "correct credentials must register";
   end if;

   if Try (Bad, 3, S'Unchecked_Access) then
      raise Program_Error with "wrong credentials must not register";
   end if;

   Ada.Text_IO.Put_Line ("ALL PASS");
end Downstream_Register_Check;
