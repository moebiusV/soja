pragma Ada_2022;

with Ada.IO_Exceptions;
with Ada.Streams;

with Soja.Irc.Hbnf;

package body Soja.Conn.Unix is

   use Ada.Strings.Unbounded;
   use type Ada.Streams.Stream_Element_Offset;

   LF : constant Character := ASCII.LF;
   CR : constant Character := ASCII.CR;

   protected body Fd_State is
      procedure Init (S : GNAT.Sockets.Socket_Type) is
      begin
         Sock := S;
      end Init;

      function Socket return GNAT.Sockets.Socket_Type is (Sock);
      function Is_Closed return Boolean is (Closed);

      procedure Close_If_Finished is
      begin
         if Shut and then Done and then not Closed then
            Closed := True;
            begin
               GNAT.Sockets.Close_Socket (Sock);
            exception
               when others => null;
            end;
         end if;
      end Close_If_Finished;

      procedure Shutdown is
      begin
         if not Closed then
            begin
               GNAT.Sockets.Shutdown_Socket
                 (Sock, GNAT.Sockets.Shut_Read_Write);
            exception
               when GNAT.Sockets.Socket_Error => null;
            end;
         end if;
         Shut := True;
         Close_If_Finished;
      end Shutdown;

      procedure Reader_Done is
      begin
         Done := True;
         Close_If_Finished;
      end Reader_Done;
   end Fd_State;

   function Create (Sock : GNAT.Sockets.Socket_Type) return Unix_IRC_Conn is
      S : constant Fd_State_Access := new Fd_State;
   begin
      S.Init (Sock);
      return (State => S, Buffer => Null_Unbounded_String);
   end Create;

   function Connect (Path : String) return Unix_IRC_Conn is
      Sock : GNAT.Sockets.Socket_Type;
   begin
      GNAT.Sockets.Create_Socket
        (Sock, GNAT.Sockets.Family_Unix, GNAT.Sockets.Socket_Stream);
      GNAT.Sockets.Connect_Socket
        (Sock, GNAT.Sockets.Unix_Socket_Address (Path));
      return Create (Sock);
   exception
      when others =>
         begin
            GNAT.Sockets.Close_Socket (Sock);
         exception
            when others => null;
         end;
         raise;
   end Connect;

   overriding function Read_Message (C : in out Unix_IRC_Conn) return Message
   is
      Chunk : Ada.Streams.Stream_Element_Array (1 .. 512);
      Last  : Ada.Streams.Stream_Element_Offset;
   begin
      loop
         declare
            NL : constant Natural := Index (C.Buffer, "" & LF);
         begin
            if NL > 0 then
               declare
                  Raw  : constant String := Slice (C.Buffer, 1, NL - 1);
                  Stop : constant Natural :=
                    (if Raw'Length > 0 and then Raw (Raw'Last) = CR
                     then Raw'Last - 1 else Raw'Last);
               begin
                  Delete (C.Buffer, 1, NL);
                  return Soja.Irc.Hbnf.Parse (Raw (Raw'First .. Stop));
               end;
            end if;
         end;

         begin
            GNAT.Sockets.Receive_Socket (C.State.Socket, Chunk, Last);
         exception
            when GNAT.Sockets.Socket_Error =>
               Last := Chunk'First - 1;   --  shut down under us: the end
         end;

         if Last < Chunk'First then
            --  The peer closed (or we did): this is the end of the stream.
            C.State.Reader_Done;
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

         for I in Chunk'First .. Last loop
            Append (C.Buffer, Character'Val (Chunk (I)));
         end loop;
      end loop;
   end Read_Message;

   overriding procedure Write_Message
     (C : in out Unix_IRC_Conn; M : Message)
   is
      Data : constant String := Image (M) & CR & LF;
      Out_Buf : Ada.Streams.Stream_Element_Array (1 .. Data'Length);
      Sent : Ada.Streams.Stream_Element_Offset := 0;
      Last : Ada.Streams.Stream_Element_Offset;
   begin
      for I in Data'Range loop
         Out_Buf (Ada.Streams.Stream_Element_Offset (I - Data'First + 1)) :=
           Ada.Streams.Stream_Element (Character'Pos (Data (I)));
      end loop;
      if C.State.Is_Closed then
         raise GNAT.Sockets.Socket_Error with "connection closed";
      end if;
      while Sent < Out_Buf'Length loop
         GNAT.Sockets.Send_Socket
           (C.State.Socket,
            Out_Buf (Out_Buf'First + Sent .. Out_Buf'Last), Last);
         exit when Last < Out_Buf'First + Sent;
         Sent := Last - Out_Buf'First + 1;
      end loop;
   end Write_Message;

   overriding procedure Close (C : in out Unix_IRC_Conn) is
   begin
      --  Shut down only: a task blocked in Read_Message wakes up with the end
      --  of the stream, and the descriptor is closed once both are done.
      C.State.Shutdown;
   end Close;

   overriding function Remote_Addr (C : Unix_IRC_Conn) return String is
      pragma Unreferenced (C);
   begin
      --  Go's address of an unnamed unix peer is "@".
      return "@";
   end Remote_Addr;

end Soja.Conn.Unix;
