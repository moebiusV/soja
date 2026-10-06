pragma Ada_2022;

with Ada.Text_IO;
with Ada.Streams;
with Ada.Strings.Unbounded;
with Ada.IO_Exceptions;
with GNAT.Sockets;
with Soja.Irc.Messages;
with Soja.Conn;
with Soja.Server;

procedure Server_Check is
   use Ada.Strings.Unbounded;
   use GNAT.Sockets;
   use Soja.Irc.Messages;

   Listener, Client : Socket_Type;
   Port             : Port_Type;
   Srv              : Soja.Server.Server;

   procedure Send_Str (S : Socket_Type; Text : String) is
      Buf  : Ada.Streams.Stream_Element_Array (1 .. Text'Length);
      Last : Ada.Streams.Stream_Element_Offset;
   begin
      for I in Text'Range loop
         Buf (Ada.Streams.Stream_Element_Offset (I - Text'First + 1)) :=
           Ada.Streams.Stream_Element (Character'Pos (Text (I)));
      end loop;
      Send_Socket (S, Buf, Last);
   end Send_Str;

   function Recv_Str (S : Socket_Type) return String is
      Buf  : Ada.Streams.Stream_Element_Array (1 .. 1024);
      Last : Ada.Streams.Stream_Element_Offset;
      R    : Unbounded_String;
   begin
      Receive_Socket (S, Buf, Last);
      for I in Buf'First .. Last loop
         Append (R, Character'Val (Ada.Streams.Stream_Element'Pos (Buf (I))));
      end loop;
      return To_String (R);
   end Recv_Str;

   --  Echo handler: read a message, write it back, until the peer closes.
   procedure Echo (IC : not null Soja.Conn.IRC_Conn_Access) is
      M : Message;
   begin
      loop
         begin
            M := IC.Read_Message;
         exception
            when Ada.IO_Exceptions.End_Error =>
               exit;
         end;
         IC.Write_Message (M);
      end loop;
   end Echo;

begin
   Soja.Server.Initialize (Srv, null);
   Soja.Server.Set_Handler (Srv, Echo'Unrestricted_Access);

   Create_Socket (Listener, Family_Inet, Socket_Stream);
   Bind_Socket
     (Listener, (Family => Family_Inet, Addr => Loopback_Inet_Addr, Port => 0));
   Listen_Socket (Listener, 5);
   Port := Get_Socket_Name (Listener).Port;

   declare
      task Serve_Task;
      task body Serve_Task is
      begin
         Soja.Server.Serve (Srv, Listener);
      end Serve_Task;
   begin
      Create_Socket (Client, Family_Inet, Socket_Stream);
      Connect_Socket
        (Client, (Family => Family_Inet, Addr => Loopback_Inet_Addr,
                  Port => Port));

      Send_Str (Client, "PING" & ASCII.CR & ASCII.LF);
      declare
         Got : constant String := Recv_Str (Client);
      begin
         if Got /= "PING" & ASCII.CR & ASCII.LF then
            raise Program_Error with "echo wrong: [" & Got & "]";
         end if;
      end;

      Close_Socket (Client);
      Soja.Server.Shutdown (Srv);
   end;

   Close_Socket (Listener);
   Ada.Text_IO.Put_Line ("ALL PASS");
end Server_Check;
