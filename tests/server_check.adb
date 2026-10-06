pragma Ada_2022;

with Ada.Text_IO;
with Ada.Streams;
with Ada.Strings.Unbounded;
with Ada.IO_Exceptions;
with AWS.Net;
with AWS.Net.Std;
with Soja.Irc.Messages;
with Soja.Conn;
with Soja.Server;

procedure Server_Check is
   use Ada.Strings.Unbounded;
   use Soja.Irc.Messages;

   Listener : AWS.Net.Socket_Access := AWS.Net.Socket (False);
   Client   : AWS.Net.Socket_Access := AWS.Net.Socket (False);
   Port     : Positive;
   Srv      : Soja.Server.Server;

   procedure Send_Str (S : AWS.Net.Socket_Access; Text : String) is
      Buf : Ada.Streams.Stream_Element_Array (1 .. Text'Length);
   begin
      for I in Text'Range loop
         Buf (Ada.Streams.Stream_Element_Offset (I - Text'First + 1)) :=
           Ada.Streams.Stream_Element (Character'Pos (Text (I)));
      end loop;
      S.all.Send (Buf);
   end Send_Str;

   function Recv_Str (S : AWS.Net.Socket_Access) return String is
      Chunk : constant Ada.Streams.Stream_Element_Array := S.all.Receive;
      R     : Unbounded_String;
   begin
      for I in Chunk'Range loop
         Append (R, Character'Val (Ada.Streams.Stream_Element'Pos (Chunk (I))));
      end loop;
      return To_String (R);
   end Recv_Str;

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

   AWS.Net.Std.Socket_Type (Listener.all).Bind (0, "127.0.0.1");
   AWS.Net.Std.Socket_Type (Listener.all).Listen (5);
   Port := AWS.Net.Std.Socket_Type (Listener.all).Get_Port;

   declare
      task Serve_Task;
      task body Serve_Task is
      begin
         Soja.Server.Serve (Srv, Listener);
      end Serve_Task;
   begin
      AWS.Net.Std.Socket_Type (Client.all).Connect ("127.0.0.1", Port);

      Send_Str (Client, "PING" & ASCII.CR & ASCII.LF);
      declare
         Got : constant String := Recv_Str (Client);
      begin
         if Got /= "PING" & ASCII.CR & ASCII.LF then
            raise Program_Error with "echo wrong: [" & Got & "]";
         end if;
      end;

      --  Close the client so the echo task sees EOF and terminates; the
      --  connection task is a package-level master, so the program waits for
      --  it at exit.
      AWS.Net.Std.Socket_Type (Client.all).Shutdown (AWS.Net.Shut_Read_Write);

      Soja.Server.Shutdown (Srv);
   end;

   AWS.Net.Free (Client);
   AWS.Net.Free (Listener);
   Ada.Text_IO.Put_Line ("ALL PASS");
end Server_Check;
