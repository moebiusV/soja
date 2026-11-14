--  Soja.Sock_Io -- reading and writing an AWS.Net socket from two tasks.
--
--  A connection is read by one task and written by others.  OpenSSL does not
--  allow SSL_read and SSL_write at the same time on one connection (TLS 1.3
--  session tickets and renegotiation make each touch the other's state), and
--  AWS does not guard against it: a TLS connection met with that now and then
--  was torn down.  So each call to the socket is made holding the connection's
--  Gate.  A reader waits for input without holding it, so a quiet connection
--  does not keep its writers out.
pragma Ada_2022;

with Ada.Streams;

with AWS.Net;

package Soja.Sock_Io is

   protected type Gate is
      entry Seize;
      procedure Release;
   private
      Held : Boolean := False;
   end Gate;

   type Gate_Access is access Gate;

   --  Waits for something to read, then reads it (AWS.Net.Receive).
   procedure Receive
     (Sock : AWS.Net.Socket_Type'Class;
      G    : not null Gate_Access;
      Buf  : out Ada.Streams.Stream_Element_Array;
      Last : out Ada.Streams.Stream_Element_Offset);

   --  AWS.Net.Send, under the gate.
   procedure Send
     (Sock : AWS.Net.Socket_Type'Class;
      G    : not null Gate_Access;
      Data : Ada.Streams.Stream_Element_Array;
      Last : out Ada.Streams.Stream_Element_Offset);

end Soja.Sock_Io;
