pragma Ada_2022;

with Ada.Text_IO;
with Ada.Streams;
with Ada.Strings.Unbounded;
with GNAT.Sockets;
with Soja.Irc.Messages;
with Soja.Conn.Net;

procedure Net_Check is
   use Ada.Strings.Unbounded;
   use GNAT.Sockets;
   use Soja.Irc.Messages;
   use Soja.Conn.Net;

   Left, Right : Socket_Type;

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

begin
   Create_Socket_Pair (Left, Right);

   declare
      C : Net_IRC_Conn := Create (Left);
   begin
      --  Read: two lines in one receive must be framed correctly.
      Send_Str (Right, "PING :hi" & ASCII.CR & ASCII.LF
               & "PRIVMSG #chan :hello world" & ASCII.CR & ASCII.LF);

      declare
         M1 : Message := Read_Message (C);
         M2 : Message := Read_Message (C);
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
      Write_Message (C, Parse_Message ("NOTICE AUTH :*** hello"));
      declare
         Got : constant String := Recv_Str (Right);
      begin
         if Got /= "NOTICE AUTH :*** hello" & ASCII.CR & ASCII.LF then
            raise Program_Error with "write round-trip wrong: [" & Got & "]";
         end if;
      end;
   end;

   Close_Socket (Right);
   Ada.Text_IO.Put_Line ("ALL PASS");
end Net_Check;
