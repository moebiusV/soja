pragma Ada_2022;

with Ada.IO_Exceptions;
with Ada.Streams;
with GNAT.Sockets;
with Soja.Irc.Hbnf;

package body Soja.Conn.Net is

   use Ada.Strings.Unbounded;
   use GNAT.Sockets;
   use Soja.Irc.Messages;
   use type Ada.Streams.Stream_Element_Offset;

   LF : constant Character := ASCII.LF;
   CR : constant Character := ASCII.CR;

   function Create (Socket : GNAT.Sockets.Socket_Type) return Net_IRC_Conn is
   begin
      return Net_IRC_Conn'
        (IRC_Conn with Sock => Socket, Buffer => Null_Unbounded_String);
   end Create;

   function Socket (C : Net_IRC_Conn) return GNAT.Sockets.Socket_Type is
     (C.Sock);

   procedure Append_Chunk
     (Buf   : in out Unbounded_String;
      Chunk : Ada.Streams.Stream_Element_Array;
      Last  : Ada.Streams.Stream_Element_Offset)
   is
   begin
      for I in Chunk'First .. Last loop
         Append (Buf, Character'Val (Ada.Streams.Stream_Element'Pos (Chunk (I))));
      end loop;
   end Append_Chunk;

   overriding function Read_Message
     (C : in out Net_IRC_Conn) return Message
   is
      Chunk : Ada.Streams.Stream_Element_Array (1 .. 512);
      Last  : Ada.Streams.Stream_Element_Offset;
      NL    : Natural;
   begin
      loop
         NL := Index (C.Buffer, "" & LF);
         if NL > 0 then
            declare
               Raw      : constant String := Slice (C.Buffer, 1, NL - 1);
               Last_Idx : constant Natural :=
                 (if Raw'Length > 0 and then Raw (Raw'Last) = CR
                  then Raw'Last - 1 else Raw'Last);
               Content  : constant String := Raw (Raw'First .. Last_Idx);
            begin
               Delete (C.Buffer, 1, NL);
               return Soja.Irc.Hbnf.Parse (Content);
            end;
         end if;

         Receive_Socket (C.Sock, Chunk, Last);
         if Last < Chunk'First then
            --  Peer closed the connection.
            if Length (C.Buffer) = 0 then
               raise Ada.IO_Exceptions.End_Error;
            end if;
            declare
               Line : constant String := To_String (C.Buffer);
            begin
               C.Buffer := Null_Unbounded_String;
               return Soja.Irc.Hbnf.Parse (Line);
            end;
         end if;

         Append_Chunk (C.Buffer, Chunk, Last);
      end loop;
   end Read_Message;

   overriding procedure Write_Message
     (C : in out Net_IRC_Conn; M : Message)
   is
      Data    : constant String := Image (M) & CR & LF;
      Out_Buf : Ada.Streams.Stream_Element_Array (1 .. Data'Length);
      Sent    : Ada.Streams.Stream_Element_Offset := 0;
      Last    : Ada.Streams.Stream_Element_Offset;
   begin
      for I in Data'Range loop
         Out_Buf (Ada.Streams.Stream_Element_Offset (I - Data'First + 1)) :=
           Ada.Streams.Stream_Element (Character'Pos (Data (I)));
      end loop;

      while Sent < Ada.Streams.Stream_Element_Offset (Out_Buf'Length) loop
         declare
            Slice : Ada.Streams.Stream_Element_Array renames
              Out_Buf (Out_Buf'First + Sent .. Out_Buf'Last);
         begin
            Send_Socket (C.Sock, Slice, Last);
            exit when Last < Slice'First;
            Sent := Sent + (Last - Slice'First + 1);
         end;
      end loop;
   end Write_Message;

   overriding procedure Close (C : in out Net_IRC_Conn) is
   begin
      GNAT.Sockets.Close_Socket (C.Sock);
   end Close;

   overriding function Remote_Addr (C : Net_IRC_Conn) return String is
   begin
      return GNAT.Sockets.Image (GNAT.Sockets.Get_Peer_Name (C.Sock));
   end Remote_Addr;

end Soja.Conn.Net;
