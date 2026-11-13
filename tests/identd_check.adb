pragma Ada_2022;

with Ada.Exceptions;
with Ada.Streams;
with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;
with Ada.Text_IO;
with GNAT.OS_Lib;

with AWS.Net;
with AWS.Net.Std;

with Soja.Identd;

--  The ident server: queries, replies, and a real connection.
procedure Identd_Check is
   use type Ada.Streams.Stream_Element_Offset;

   procedure Check (Cond : Boolean; What : String) is
   begin
      if not Cond then
         raise Program_Error with What;
      end if;
   end Check;

   I : aliased Soja.Identd.Identd;

   procedure Parses (Line : String; L, R : Natural; Want : Boolean) is
      Local, Remote : Natural;
      Ok            : Boolean;
   begin
      Soja.Identd.Parse_Query (Line, Local, Remote, Ok);
      Check (Ok = Want, "parse " & Line);
      if Want then
         Check (Local = L and then Remote = R, "ports of " & Line);
      end if;
   end Parses;

   function Reply (Host, Line : String; Keep : out Boolean) return String is
      R : Unbounded_String;
   begin
      Soja.Identd.Answer (I, Host, Line, R, Keep);
      return To_String (R);
   end Reply;

   Keep : Boolean;

   Listener : AWS.Net.Socket_Access := AWS.Net.Socket (False);
   Port     : Positive;

   task Server is
      entry Go;
   end Server;
   task body Server is
   begin
      accept Go;
      Soja.Identd.Serve (I, Listener);
   end Server;

   --  One round trip: send Query, read what comes back until the line end.
   function Ask (Query : String) return String is
      Client : AWS.Net.Socket_Access := AWS.Net.Socket (False);
      Data   : Ada.Streams.Stream_Element_Array
        (1 .. Ada.Streams.Stream_Element_Offset (Query'Length));
      Sent   : Ada.Streams.Stream_Element_Offset;
      Buf    : Ada.Streams.Stream_Element_Array (1 .. 512);
      Last   : Ada.Streams.Stream_Element_Offset;
      Result : Unbounded_String;
   begin
      AWS.Net.Std.Socket_Type (Client.all).Connect ("127.0.0.1", Port);
      AWS.Net.Std.Socket_Type (Client.all).Set_Timeout (3.0);
      for K in Query'Range loop
         Data (Ada.Streams.Stream_Element_Offset (K - Query'First + 1)) :=
           Ada.Streams.Stream_Element (Character'Pos (Query (K)));
      end loop;
      AWS.Net.Std.Socket_Type (Client.all).Send (Data, Sent);
      loop
         AWS.Net.Std.Socket_Type (Client.all).Receive (Buf, Last);
         exit when Last < Buf'First;
         for K in Buf'First .. Last loop
            Append (Result, Character'Val (Buf (K)));
         end loop;
         exit when Index (Result, "" & ASCII.LF) > 0;
      end loop;
      AWS.Net.Free (Client);
      return To_String (Result);
   exception
      when AWS.Net.Socket_Error =>
         AWS.Net.Free (Client);
         return To_String (Result);
   end Ask;
begin
   Parses ("1234, 6697", 1234, 6697, True);
   Parses ("  1234 ,6697  ", 1234, 6697, True);
   Parses ("1,2", 1, 2, True);
   Parses ("0, 6697", 0, 0, False);
   Parses ("1234, 0", 0, 0, False);
   Parses ("1234", 0, 0, False);
   Parses ("a, b", 0, 0, False);
   Parses ("1, 2, 3", 0, 0, False);
   Parses ("", 0, 0, False);
   Parses ("99999999999999999999, 1", 0, 0, False);

   Soja.Identd.Store (I, "10.0.0.1", 6697, 40000, "abc123");
   Check (Reply ("10.0.0.1", "40000, 6697", Keep)
          = "40000, 6697 : USERID : UNKNOWN : abc123" and then Keep,
          "a known connection");
   Check (Reply ("10.0.0.2", "40000, 6697", Keep)
          = "40000, 6697 : ERROR : NO-USER" and then not Keep,
          "another host");
   Check (Reply ("10.0.0.1", "40001, 6697", Keep)
          = "40001, 6697 : ERROR : NO-USER" and then not Keep, "another port");
   Check (Reply ("10.0.0.1", "nonsense", Keep)
          = "nonsense : ERROR : INVALID-PORT" and then not Keep, "garbage");
   Soja.Identd.Delete (I, "10.0.0.1", 6697, 40000);
   Check (Reply ("10.0.0.1", "40000, 6697", Keep)
          = "40000, 6697 : ERROR : NO-USER", "deleted");

   --  Over a real connection (the client is 127.0.0.1).
   AWS.Net.Std.Socket_Type (Listener.all).Bind (0, "127.0.0.1");
   AWS.Net.Std.Socket_Type (Listener.all).Listen (5);
   Port := AWS.Net.Std.Socket_Type (Listener.all).Get_Port;
   Server.Go;
   Soja.Identd.Store (I, "127.0.0.1", 6697, 40000, "deadbeef");
   declare
      Got : constant String := Ask ("40000, 6697" & ASCII.CR & ASCII.LF);
   begin
      Check (Got = "40000, 6697 : USERID : UNKNOWN : deadbeef" & ASCII.CR
             & ASCII.LF, "over the wire: [" & Got & "]");
   end;
   Check (Ask ("1, 2" & ASCII.LF) = "1, 2 : ERROR : NO-USER" & ASCII.CR
          & ASCII.LF, "no user over the wire");
   Check (Ask ("oops" & ASCII.CR & ASCII.LF)
          = "oops : ERROR : INVALID-PORT" & ASCII.CR & ASCII.LF,
          "invalid over the wire");

   Soja.Identd.Stop (I);
   delay 0.3;
   AWS.Net.Free (Listener);
   Ada.Text_IO.Put_Line ("ALL PASS");
exception
   when E : others =>
      Ada.Text_IO.Put_Line
        ("FAILED: " & Ada.Exceptions.Exception_Information (E));
      GNAT.OS_Lib.OS_Exit (1);
end Identd_Check;
