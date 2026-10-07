pragma Ada_2022;

--  Exercises connectToUpstream's certfp path against a self-signed TLS
--  listener.  Regenerate the fixtures on the host with:
--
--    openssl req -x509 -newkey rsa:2048 -keyout tests/certfp_key.pem \
--      -out tests/certfp_cert.pem -days 365 -nodes -subj "/CN=localhost"
--    openssl x509 -in tests/certfp_cert.pem -noout -fingerprint -sha256
--
--  then pass cert, key, and the "sha-256:<hex>" fingerprint as arguments.

with Ada.Text_IO;
with Ada.Command_Line;
with Ada.IO_Exceptions;
with Ada.Strings.Unbounded;

with AWS.Net;
with AWS.Net.SSL;
with AWS.Net.Std;

with Soja.Conn;
with Soja.Core;
with Soja.Database;
with Soja.Irc.Messages;
with Soja.Logging;
with Soja.Server;

procedure Certfp_Check is
   use Ada.Strings.Unbounded;
   use Soja.Core;

   Cert : constant String := Ada.Command_Line.Argument (1);
   Key  : constant String := Ada.Command_Line.Argument (2);
   Want : constant String := Ada.Command_Line.Argument (3);

   Listener : AWS.Net.Socket_Access := AWS.Net.Socket (False);
   Port     : Positive;
   Srv      : aliased Soja.Server.Server;
   Log      : aliased Soja.Logging.Standard_Logger;
   Rec      : Soja.Database.User := Soja.Database.New_User ("alice");
   U        : User_Access;

   --  Read until the peer closes, driving the server-side TLS handshake.
   procedure Hold (IC : not null Soja.Conn.IRC_Conn_Access) is
      M : Soja.Irc.Messages.Message;
      pragma Unreferenced (M);
   begin
      loop
         begin
            M := IC.Read_Message;
         exception
            when Ada.IO_Exceptions.End_Error | AWS.Net.Socket_Error =>
               exit;
         end;
      end loop;
      IC.Close;   --  reply with our close_notify so the peer's shutdown ends
   end Hold;

   --  Dial the TLS listener with the given certfp and report whether the
   --  connection was established.
   function Connect (FP : String) return Upstream_Conn_Access is
      NetRec : Soja.Database.Network :=
        Soja.Database.New_Network ("ircs://127.0.0.1:" & Positive'Image (Port));
      Net : Network_Access;
      UC  : Upstream_Conn_Access;
   begin
      NetRec.Cert_FP := To_Unbounded_String (FP);
      Net := New_Network (U, NetRec, Soja.Database.Channel_Lists.Empty_Vector);
      UC := Connect_To_Upstream (Net);
      if UC /= null then
         Soja.Conn.Close (UC.Conn);
      end if;
      return UC;
   end Connect;

begin
   Soja.Server.Initialize (Srv, Log'Unchecked_Access);
   Soja.Server.Set_Handler (Srv, Hold'Unrestricted_Access);
   U := New_User (Srv'Unchecked_Access, Rec);

   AWS.Net.Std.Socket_Type (Listener.all).Bind (0, "127.0.0.1");
   AWS.Net.Std.Socket_Type (Listener.all).Listen (5);
   Port := AWS.Net.Std.Socket_Type (Listener.all).Get_Port;

   declare
      task Serve_Task;
      task body Serve_Task is
      begin
         Soja.Server.Serve (Srv, Listener, Cert, Key);
      end Serve_Task;
   begin
      if Connect (Want) = null then
         raise Program_Error with "matching certfp must connect";
      end if;

      if Connect ("sha-256:" &
                  "0000000000000000000000000000000000000000000000000000000000000000")
        /= null
      then
         raise Program_Error with "mismatching certfp must not connect";
      end if;

      Soja.Server.Shutdown (Srv);
   end;

   AWS.Net.Free (Listener);
   AWS.Net.SSL.Abort_DH_Generation;
   Ada.Text_IO.Put_Line ("ALL PASS");
end Certfp_Check;
