pragma Ada_2022;

with Ada.Text_IO;
with Ada.Strings.Unbounded;

with AWS.Net;
with AWS.Net.Std;

with Soja.Conn;
with Soja.Conn.Net;
with Soja.Core;
with Soja.Database;
with Soja.Irc.Messages;
with Soja.Logging;
with Soja.Server;

procedure Upstream_Register_Check is
   use Ada.Strings.Unbounded;
   use Soja.Core;
   use Soja.Conn;

   Listener : AWS.Net.Socket_Access := AWS.Net.Socket (False);
   Port     : Positive;
   Log      : aliased Soja.Logging.Standard_Logger;
   Srv      : aliased Soja.Server.Server;
   Rec      : Soja.Database.User := Soja.Database.New_User ("alice");
   U        : User_Access;

begin
   Soja.Server.Initialize (Srv, Log'Unchecked_Access);
   U := New_User (Srv'Unchecked_Access, Rec);

   AWS.Net.Std.Socket_Type (Listener.all).Bind (0, "127.0.0.1");
   AWS.Net.Std.Socket_Type (Listener.all).Listen (1);
   Port := AWS.Net.Std.Socket_Type (Listener.all).Get_Port;

   declare
      --  A scripted fake IRC server: read the registration burst, answer the
      --  CAP probe, then send 001.  Raises on any unexpected message.
      task Server_Task;
      task body Server_Task is
         use Soja.Irc.Messages;
         New_Sock : AWS.Net.Socket_Access := AWS.Net.Socket (False);
         IC       : IRC_Conn_Access;
         M        : Message;

         procedure Expect (Command : String) is
         begin
            M := IC.Read_Message;
            if To_String (M.Command) /= Command then
               raise Program_Error with
                 "expected " & Command & ", got " & To_String (M.Command);
            end if;
         end Expect;
      begin
         AWS.Net.Accept_Socket (Listener.all, New_Sock.all);
         IC := new Soja.Conn.Net.Net_IRC_Conn'
           (Soja.Conn.Net.Create (New_Sock));

         Expect ("CAP");
         Expect ("NICK");
         Expect ("USER");

         IC.Write_Message (Parse_Message (":irc CAP * LS"));
         Expect ("CAP");

         IC.Write_Message (Parse_Message (":irc 001 alice :welcome"));
      end Server_Task;

      NetRec : Soja.Database.Network :=
        Soja.Database.New_Network ("irc+insecure://127.0.0.1:"
                                   & Positive'Image (Port));
      Net : Network_Access;
      UC  : Upstream_Conn_Access;
      RR  : Registration_Result;
   begin
      Net := New_Network (U, NetRec, Soja.Database.Channel_Lists.Empty_Vector);
      UC := Connect_To_Upstream (Net);
      if UC = null then
         raise Program_Error with "connectToUpstream failed";
      end if;

      Register (UC);
      RR := Run_Until_Registered (UC);

      if not RR.Success then
         raise Program_Error with
           "registration failed: " & To_String (RR.Reason);
      end if;
      if not UC.Registered then
         raise Program_Error with "registered flag not set";
      end if;
      if To_String (UC.Nick) /= "alice" then
         raise Program_Error with "nick not set from 001";
      end if;

      Soja.Conn.Close (UC.Conn);
   end;

   AWS.Net.Free (Listener);
   Ada.Text_IO.Put_Line ("ALL PASS");
end Upstream_Register_Check;
