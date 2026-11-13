pragma Ada_2022;

with Ada.Containers.Indefinite_Vectors;
with Ada.Exceptions;
with Ada.IO_Exceptions;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;
with Ada.Text_IO;
with GNAT.OS_Lib;

with Soja.Bouncer;
with Soja.Core;
with Soja.Conn;
with Soja.Database;
with Soja.Database.Sqlite;
with Soja.Irc.Messages;     use Soja.Irc.Messages;
with Soja.Logging;
with Soja.Server;

--  Server glue: the user table, the connection handler, shutdown.
procedure Bouncer_Check is
   package SD renames Soja.Database;
   use type Soja.Core.User_Access;

   procedure Check (Cond : Boolean; What : String) is
   begin
      if not Cond then
         raise Program_Error with What;
      end if;
   end Check;

   package String_Vectors is new Ada.Containers.Indefinite_Vectors
     (Positive, String);

   protected type Recorder is
      procedure Add (Line : String);
      function Count return Natural;
      function Line (I : Positive) return String;
      function Has (Needle : String) return Boolean;
   private
      V : String_Vectors.Vector;
   end Recorder;
   type Recorder_Access is access all Recorder;

   protected body Recorder is
      procedure Add (Line : String) is
      begin
         V.Append (Line);
      end Add;
      function Count return Natural is (Natural (V.Length));
      function Line (I : Positive) return String is (V (I));
      function Has (Needle : String) return Boolean is
      begin
         for L of V loop
            if Ada.Strings.Fixed.Index (L, Needle) > 0 then
               return True;
            end if;
         end loop;
         return False;
      end Has;
   end Recorder;

   protected type Gate is
      procedure Open;
      entry Wait;
      function Is_Open return Boolean;
   private
      Opened : Boolean := False;
   end Gate;
   protected body Gate is
      procedure Open is
      begin
         Opened := True;
      end Open;
      entry Wait when Opened is
      begin
         null;
      end Wait;
      function Is_Open return Boolean is (Opened);
   end Gate;
   type Gate_Access is access all Gate;

   type Script_Access is access all String_Vectors.Vector;

   --  A client that says its script, then waits (Hang) until it is closed.
   type Fake_Client is new Soja.Conn.IRC_Conn with record
      Log    : Recorder_Access;
      Script : Script_Access;
      Next   : Natural := 0;
      Hang   : Boolean := False;
      Closed : Gate_Access;
   end record;
   overriding function Read_Message
     (C : in out Fake_Client) return Message;
   overriding procedure Write_Message
     (C : in out Fake_Client; M : Message);
   overriding procedure Close (C : in out Fake_Client);
   overriding function Remote_Addr (C : Fake_Client) return String is
     ("1.2.3.4:6667");

   overriding function Read_Message (C : in out Fake_Client) return Message is
   begin
      if C.Next < Natural (C.Script.Length) then
         C.Next := C.Next + 1;
         return Parse_Message (C.Script (C.Next));
      end if;
      if C.Hang then
         C.Closed.Wait;
      end if;
      raise Ada.IO_Exceptions.End_Error;
   end Read_Message;
   overriding procedure Write_Message
     (C : in out Fake_Client; M : Message) is
   begin
      C.Log.Add (Image (M));
   end Write_Message;
   overriding procedure Close (C : in out Fake_Client) is
   begin
      C.Closed.Open;
   end Close;
   type Fake_Client_Access is access all Fake_Client;

   function New_Client
     (Script : String_Vectors.Vector; Hang : Boolean := False)
      return Fake_Client_Access is
     (new Fake_Client'
        (Soja.Conn.IRC_Conn with Log => new Recorder,
         Script => new String_Vectors.Vector'(Script), Next => 0,
         Hang => Hang, Closed => new Gate));

   --  Server.Handle runs on its own task, as the accept loop would.
   task type Runner (T : Fake_Client_Access) is
      entry Join;
   end Runner;
   task body Runner is
   begin
      Soja.Bouncer.Handle (T.all'Unchecked_Access);
      accept Join;
   exception
      when others =>
         accept Join;
   end Runner;

   function Wait_For (R : Recorder_Access; Needle : String) return Boolean is
      Waited : Duration := 0.0;
   begin
      while not R.Has (Needle) and then Waited < 5.0 loop
         delay 0.02;
         Waited := Waited + 0.02;
      end loop;
      return R.Has (Needle);
   end Wait_For;

   function Script (A, B, C, D, E : String := "") return String_Vectors.Vector
   is
      V : String_Vectors.Vector;
   begin
      if A /= "" then V.Append (A); end if;
      if B /= "" then V.Append (B); end if;
      if C /= "" then V.Append (C); end if;
      if D /= "" then V.Append (D); end if;
      if E /= "" then V.Append (E); end if;
      return V;
   end Script;

   Log : aliased Soja.Logging.Standard_Logger;
   Srv : aliased Soja.Server.Server;
   DB  : SD.Database_Access := Soja.Database.Sqlite.Open_Temp_Sqlite_DB;
   Rec : SD.User := SD.New_User ("alice");
   B   : aliased Soja.Bouncer.Bouncer;
   Shown : Fake_Client_Access;
begin
   Srv.Initialize (Log'Unchecked_Access);
   Srv.Set_DB (DB);
   SD.Set_Password (Rec, "secret");
   Rec.Enabled := True;
   SD.Store_User (DB.all, Rec);

   Soja.Bouncer.Initialize (B, Srv'Unchecked_Access);
   Soja.Bouncer.Start (B);
   Check (Soja.Bouncer.Get_User (B, "alice") /= null, "alice is loaded");
   Check (Soja.Bouncer.Get_User (B, "nobody") = null, "nobody is not");

   --  create user
   declare
      Bob : SD.User := SD.New_User ("bob");
   begin
      Check (Soja.Bouncer.Create_User (B, Bob) /= null
             and then Soja.Bouncer.Get_User (B, "bob") /= null,
             "created users run");
      Check (SD.Get_User (DB.all, "bob").Username = To_Unbounded_String ("bob"),
             "and are stored");
      begin
         Bob := SD.New_User ("bob");
         declare
            Again : constant Soja.Core.User_Access :=
              Soja.Bouncer.Create_User (B, Bob);
            pragma Unreferenced (Again);
         begin
            Check (False, "a duplicate user");
         end;
      exception
         when Soja.Bouncer.Bouncer_Error =>
            null;
      end;
   end;

   --  getOrCreate: an unloaded user is refused unless enabled-on-auth.
   begin
      declare
         Nobody : constant Soja.Core.User_Access :=
           Soja.Bouncer.Get_Or_Create_User (B, "carol");
         pragma Unreferenced (Nobody);
      begin
         Check (False, "carol must not be created");
      end;
   exception
      when Soja.Bouncer.Bouncer_Error =>
         null;
   end;
   Soja.Server.Config (Srv).Enable_Users_On_Auth := True;
   Check (Soja.Bouncer.Get_Or_Create_User (B, "carol") /= null
          and then Soja.Bouncer.Get_Or_Create_User (B, "alice") /= null,
          "enabled-on-auth creates users; known ones are returned");
   Soja.Server.Config (Srv).Enable_Users_On_Auth := False;

   --  A client registers through Handle and is served by its user's task.
   Shown := New_Client
     (Script ("PASS secret", "NICK alice", "USER alice 0 * :Alice",
              "PING hello"),
      Hang => True);
   declare
      R : Runner (Shown);
   begin
      Check (Wait_For (Shown.Log, " 001 alice "), "welcome");
      Check (Wait_For (Shown.Log, "PONG localhost hello"),
             "commands reach the user's task and are answered");
      Shown.Closed.Open;   --  the client hangs up
      R.Join;
   end;

   --  A bad password is refused and the connection ends.
   declare
      Bad : constant Fake_Client_Access := New_Client
        (Script ("PASS wrong", "NICK alice", "USER alice 0 * :Alice"));
      R : Runner (Bad);
   begin
      R.Join;
      Check (Wait_For (Bad.Log, " 464 "), "a wrong password is answered");
   end;

   --  Shutdown stops the users; later clients are turned away.
   Soja.Bouncer.Shutdown (B, Timeout => 10.0);
   Check (Soja.Bouncer.Get_User (B, "alice") = null, "users are gone");
   declare
      Late : constant Fake_Client_Access := New_Client
        (Script ("PASS secret", "NICK alice", "USER alice 0 * :Alice"));
      R : Runner (Late);
   begin
      R.Join;
      Check (Wait_For (Late.Log, "ERROR :Server is shutting down"),
             "no new clients while shutting down");
   end;
   Ada.Text_IO.Put_Line ("ALL PASS");
exception
   when E : others =>
      Ada.Text_IO.Put_Line
        ("FAILED: " & Ada.Exceptions.Exception_Information (E));
      if Shown /= null then
         for I in 1 .. Shown.Log.Count loop
            Ada.Text_IO.Put_Line (Shown.Log.Line (I));
         end loop;
      end if;
      GNAT.OS_Lib.OS_Exit (1);
end Bouncer_Check;
