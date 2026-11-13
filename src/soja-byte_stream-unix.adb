pragma Ada_2022;

package body Soja.Byte_Stream.Unix is

   function Create (Sock : GNAT.Sockets.Socket_Type) return Stream_Access is
   begin
      return new Unix_Stream'(Sock => Sock);
   end Create;

   overriding procedure Receive
     (S    : in out Unix_Stream;
      Buf  : out Stream_Element_Array;
      Last : out Stream_Element_Offset)
   is
   begin
      GNAT.Sockets.Receive_Socket (S.Sock, Buf, Last);
   exception
      when GNAT.Sockets.Socket_Error =>
         Last := Buf'First - 1;   --  shut down under us: the end
   end Receive;

   overriding procedure Send
     (S : in out Unix_Stream; Data : Stream_Element_Array)
   is
      Sent : Stream_Element_Offset := Data'First - 1;
      Last : Stream_Element_Offset;
   begin
      while Sent < Data'Last loop
         GNAT.Sockets.Send_Socket (S.Sock, Data (Sent + 1 .. Data'Last), Last);
         if Last <= Sent then
            raise GNAT.Sockets.Socket_Error with "connection closed";
         end if;
         Sent := Last;
      end loop;
   end Send;

   overriding procedure Shutdown (S : in out Unix_Stream) is
   begin
      GNAT.Sockets.Shutdown_Socket (S.Sock, GNAT.Sockets.Shut_Read_Write);
   exception
      when GNAT.Sockets.Socket_Error => null;
   end Shutdown;

   overriding procedure Release (S : in out Unix_Stream) is
   begin
      GNAT.Sockets.Close_Socket (S.Sock);
   exception
      when GNAT.Sockets.Socket_Error => null;
   end Release;

   --  Go's address of an unnamed unix peer is "@".
   overriding function Peer (S : Unix_Stream) return String is
      pragma Unreferenced (S);
   begin
      return "@";
   end Peer;

end Soja.Byte_Stream.Unix;
