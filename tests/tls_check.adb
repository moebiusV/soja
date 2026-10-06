pragma Ada_2022;

with Ada.Text_IO;
with Ada.Streams;
with Ada.Strings.Unbounded;
with Ada.IO_Exceptions;
with Ada.Command_Line;
with AWS.Net;
with AWS.Net.Std;
with AWS.Net.SSL;
with Soja.Irc.Messages;
with Soja.Conn;
with Soja.Server;

procedure Tls_Check is
   use Ada.Strings.Unbounded;
   use Soja.Irc.Messages;

   Listener : AWS.Net.Socket_Access := AWS.Net.Socket (False);
   Client   : AWS.Net.Socket_Access := AWS.Net.Socket (False);
   Port     : Positive;
   Srv      : Soja.Server.Server;

   Cert : constant String := Ada.Command_Line.Argument (1);
   Key  : constant String := Ada.Command_Line.Argument (2);

   procedure Send_SSL (S : in out AWS.Net.SSL.Socket_Type; Text : String) is
      Buf  : Ada.Streams.Stream_Element_Array (1 .. Text'Length);
      Last : Ada.Streams.Stream_Element_Offset;
   begin
      for I in Text'Range loop
         Buf (Ada.Streams.Stream_Element_Offset (I - Text'First + 1)) :=
           Ada.Streams.Stream_Element (Character'Pos (Text (I)));
      end loop;
      S.Send (Buf, Last);
   end Send_SSL;

   function Recv_SSL (S : in out AWS.Net.SSL.Socket_Type) return String is
      Buf  : Ada.Streams.Stream_Element_Array (1 .. 1024);
      Last : Ada.Streams.Stream_Element_Offset;
      R    : Unbounded_String;
   begin
      S.Receive (Buf, Last);
      for I in Buf'First .. Last loop
         Append (R, Character'Val (Ada.Streams.Stream_Element'Pos (Buf (I))));
      end loop;
      return To_String (R);
   end Recv_SSL;

   procedure Echo (IC : not null Soja.Conn.IRC_Conn_Access) is
      M : Message;
   begin
      loop
         begin
            M := IC.Read_Message;
         exception
            when Ada.IO_Exceptions.End_Error | AWS.Net.Socket_Error =>
               exit;   -- peer closed
         end;
         IC.Write_Message (M);
      end loop;
   end Echo;

begin
   Soja.Server.Initialize (Srv, null);
   Soja.Server.Set_Handler (Srv, Echo'Unrestricted_Access);

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
      AWS.Net.Std.Socket_Type (Client.all).Connect ("127.0.0.1", Port);

      declare
         Cfg   : AWS.Net.SSL.Config;
         TLS_C : AWS.Net.SSL.Socket_Type;
      begin
         AWS.Net.SSL.Initialize
           (Cfg,
            Security_Mode    => AWS.Net.SSL.TLS,
            Check_Certificate => False);
         TLS_C := AWS.Net.SSL.Secure_Client (Client.all, Cfg, "localhost");

         Send_SSL (TLS_C, "PING" & ASCII.CR & ASCII.LF);
         declare
            Got : constant String := Recv_SSL (TLS_C);
         begin
            if Got /= "PING" & ASCII.CR & ASCII.LF then
               raise Program_Error with "tls echo wrong: [" & Got & "]";
            end if;
         end;

         TLS_C.Shutdown;
         AWS.Net.SSL.Release (Cfg);
      end;

      Soja.Server.Shutdown (Srv);
   end;

   AWS.Net.Free (Client);
   AWS.Net.Free (Listener);
   --  AWS spawns a background DH-parameter task on first TLS use; stop it so
   --  the test process can terminate.
   AWS.Net.SSL.Abort_DH_Generation;
   Ada.Text_IO.Put_Line ("ALL PASS");
end Tls_Check;
