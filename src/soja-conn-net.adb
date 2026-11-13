pragma Ada_2022;

with Ada.Exceptions;
with Ada.IO_Exceptions;
with Ada.Streams;
with Ada.Strings.Fixed;
with AWS.Net;
with Soja.Irc.Hbnf;

package body Soja.Conn.Net is

   use Ada.Strings.Unbounded;
   use Soja.Irc.Messages;
   use type Ada.Streams.Stream_Element_Offset;

   LF : constant Character := ASCII.LF;
   CR : constant Character := ASCII.CR;

   function Create (Sock : not null AWS.Net.Socket_Access) return Net_IRC_Conn is
   begin
      return Net_IRC_Conn'
        (IRC_Conn with Sock => Sock, Buffer => Null_Unbounded_String);
   end Create;

   function Socket (C : Net_IRC_Conn) return AWS.Net.Socket_Access is
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

         begin
            C.Sock.Receive (Chunk, Last);
         exception
            when E : AWS.Net.Socket_Error =>
               --  AWS reports an orderly close as an error: it is the EOF.
               if Ada.Strings.Fixed.Index
                    (Ada.Exceptions.Exception_Message (E), "closed by peer") > 0
               then
                  Last := Chunk'First - 1;
               else
                  raise;
               end if;
         end;
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
            C.Sock.Send (Slice, Last);
            exit when Last < Slice'First;
            Sent := Sent + (Last - Slice'First + 1);
         end;
      end loop;
   end Write_Message;

   overriding procedure Close (C : in out Net_IRC_Conn) is
   begin
      C.Sock.Shutdown (AWS.Net.Shut_Read_Write);
   end Close;

   overriding function Remote_Addr (C : Net_IRC_Conn) return String is
      Port : constant String :=
        Ada.Strings.Fixed.Trim
          (Positive'Image (C.Sock.Peer_Port), Ada.Strings.Left);
      Addr : constant String := C.Sock.Peer_Addr;
   begin
      --  net.JoinHostPort: an IPv6 literal is bracketed.
      if Ada.Strings.Fixed.Index (Addr, ":") > 0 then
         return "[" & Addr & "]:" & Port;
      end if;
      return Addr & ":" & Port;
   end Remote_Addr;

end Soja.Conn.Net;
