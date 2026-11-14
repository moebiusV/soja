pragma Ada_2022;

with Ada.Exceptions;
with Ada.Strings.Fixed;
with Ada.Unchecked_Deallocation;

package body Soja.Byte_Stream.Net is

   function Host_Port (Sock : AWS.Net.Socket_Type'Class) return String is
      Port : constant String := Ada.Strings.Fixed.Trim
        (Positive'Image (Sock.Peer_Port), Ada.Strings.Left);
      Addr : constant String := Sock.Peer_Addr;
   begin
      --  net.JoinHostPort: an IPv6 literal is bracketed.
      return (if Ada.Strings.Fixed.Index (Addr, ":") > 0
              then "[" & Addr & "]:" & Port else Addr & ":" & Port);
   end Host_Port;

   function Create
     (Sock : not null AWS.Net.Socket_Access) return Stream_Access
   is
   begin
      return new Net_Stream'
        (Sock => Sock, Addr => new String'(Host_Port (Sock.all)),
         G    => new Soja.Sock_Io.Gate);
   end Create;

   overriding procedure Receive
     (S    : in out Net_Stream;
      Buf  : out Stream_Element_Array;
      Last : out Stream_Element_Offset)
   is
   begin
      Soja.Sock_Io.Receive (S.Sock.all, S.G, Buf, Last);
   exception
      when E : AWS.Net.Socket_Error =>
         --  AWS reports an orderly close as an error: it is the EOF.
         if Ada.Strings.Fixed.Index
              (Ada.Exceptions.Exception_Message (E), "closed by peer") > 0
         then
            Last := Buf'First - 1;
         else
            raise;
         end if;
   end Receive;

   overriding procedure Send
     (S : in out Net_Stream; Data : Stream_Element_Array)
   is
      Sent : Stream_Element_Offset := Data'First - 1;
      Last : Stream_Element_Offset;
   begin
      while Sent < Data'Last loop
         Soja.Sock_Io.Send
           (S.Sock.all, S.G, Data (Sent + 1 .. Data'Last), Last);
         if Last <= Sent then
            raise AWS.Net.Socket_Error with "connection closed";
         end if;
         Sent := Last;
      end loop;
   end Send;

   overriding procedure Shutdown (S : in out Net_Stream) is
   begin
      S.Sock.Shutdown (AWS.Net.Shut_Read_Write);
   exception
      when AWS.Net.Socket_Error => null;   --  already gone
   end Shutdown;

   overriding procedure Release (S : in out Net_Stream) is
      procedure Free is new Ada.Unchecked_Deallocation
        (Soja.Sock_Io.Gate, Soja.Sock_Io.Gate_Access);
   begin
      AWS.Net.Free (S.Sock);
      Free (S.G);
   end Release;

   overriding function Peer (S : Net_Stream) return String is (S.Addr.all);

end Soja.Byte_Stream.Net;
