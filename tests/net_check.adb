pragma Ada_2022;

with Ada.Text_IO;
with Ada.Streams;
with Ada.Strings.Unbounded;
with AWS.Net;
with AWS.Net.Std;
with Soja.Irc.Messages;
with Soja.Conn.Net;

procedure Net_Check is
   use Ada.Strings.Unbounded;
   use Soja.Irc.Messages;

   Listener : AWS.Net.Socket_Access := AWS.Net.Socket (False);
   Client   : AWS.Net.Socket_Access := AWS.Net.Socket (False);
   Server   : AWS.Net.Socket_Access := AWS.Net.Socket (False);
   Port     : Positive;

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

begin
   AWS.Net.Std.Socket_Type (Listener.all).Bind (0, "127.0.0.1");
   AWS.Net.Std.Socket_Type (Listener.all).Listen (5);
   Port := AWS.Net.Std.Socket_Type (Listener.all).Get_Port;

   AWS.Net.Std.Socket_Type (Client.all).Connect ("127.0.0.1", Port);
   AWS.Net.Accept_Socket (Listener.all, Server.all);

   declare
      C : Soja.Conn.Net.Net_IRC_Conn := Soja.Conn.Net.Create (Client);
   begin
      --  Two messages in one receive must frame correctly.
      Send_Str (Server, "PING :hi" & ASCII.CR & ASCII.LF
               & "PRIVMSG #chan :hello world" & ASCII.CR & ASCII.LF);

      declare
         M1 : Message := Soja.Conn.Net.Read_Message (C);
         M2 : Message := Soja.Conn.Net.Read_Message (C);
      begin
         if To_String (M1.Command) /= "PING" then
            raise Program_Error with "message 1 not PING";
         end if;
         if Trailing (M1) /= "hi" then
            raise Program_Error with "message 1 trailing wrong";
         end if;
         if To_String (M2.Command) /= "PRIVMSG" then
            raise Program_Error with "message 2 not PRIVMSG";
         end if;
         if Trailing (M2) /= "hello world" then
            raise Program_Error with "message 2 trailing wrong";
         end if;
      end;

      --  Write: a message is serialized with CRLF.
      Soja.Conn.Net.Write_Message (C, Parse_Message ("NOTICE AUTH :*** hello"));
      declare
         Got : constant String := Recv_Str (Server);
      begin
         if Got /= "NOTICE AUTH :*** hello" & ASCII.CR & ASCII.LF then
            raise Program_Error with "write round-trip wrong: [" & Got & "]";
         end if;
      end;
   end;

   AWS.Net.Free (Server);
   AWS.Net.Free (Listener);
   Ada.Text_IO.Put_Line ("ALL PASS");
end Net_Check;
