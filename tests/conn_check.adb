pragma Ada_2022;

with Ada.Text_IO;
with Ada.Strings.Unbounded;
with Soja.Irc.Messages;
with Soja.Conn;

procedure Conn_Check is
   use Ada.Strings.Unbounded;
   use Soja.Irc.Messages;
   use Soja.Conn;

   --  A protected log of everything the fake transport wrote.
   type Item_Array is array (1 .. 16) of Unbounded_String;

   protected type Written_Log is
      procedure Append (S : String);
      function Count return Natural;
      function Item (I : Positive) return Unbounded_String;
   private
      Items : Item_Array;
      N     : Natural := 0;
   end Written_Log;

   protected body Written_Log is
      procedure Append (S : String) is
      begin
         if N < Items'Last then
            N := N + 1;
            Items (N) := To_Unbounded_String (S);
         end if;
      end Append;
      function Count return Natural is (N);
      function Item (I : Positive) return Unbounded_String is (Items (I));
   end Written_Log;

   --  A fake transport: writes are recorded, reads/close are tracked.
   type Fake_Transport is new IRC_Conn with record
      Log    : access Written_Log;
      Closed : Boolean := False;
   end record;

   overriding function Read_Message (C : in out Fake_Transport) return Message;
   overriding procedure Write_Message (C : in out Fake_Transport; M : Message);
   overriding procedure Close (C : in out Fake_Transport);
   overriding function Remote_Addr (C : Fake_Transport) return String;

   overriding function Read_Message
     (C : in out Fake_Transport) return Message is
   begin
      raise Program_Error with "read not expected in this test";
      return (others => <>);
   end Read_Message;

   overriding procedure Write_Message
     (C : in out Fake_Transport; M : Message) is
   begin
      C.Log.Append (Image (M));
   end Write_Message;

   overriding procedure Close (C : in out Fake_Transport) is
   begin
      C.Closed := True;
   end Close;

   overriding function Remote_Addr (C : Fake_Transport) return String is
     ("fake");

   Log : aliased Written_Log;
   F   : aliased Fake_Transport;

begin
   F.Log := Log'Unchecked_Access;

   --  Queue three messages, then shut down gracefully.
   declare
      C : Conn_Access := New_Conn
        (F'Unchecked_Access,
         (Logger => null, Rate_Limit_Delay => 0.0, Rate_Limit_Burst => 0,
         others => <>));
   begin
      Send_Message (C, Parse_Message ("PRIVMSG #chan one"));
      Send_Message (C, Parse_Message ("PRIVMSG #chan two"));
      Send_Message (C, Parse_Message ("PRIVMSG #chan three"));
      Shutdown (C);
   end;

   delay 0.2;

   if Log.Count /= 3 then
      raise Program_Error with
        "expected 3 written messages, got" & Natural'Image (Log.Count);
   end if;
   if Log.Item (1) /= "PRIVMSG #chan one" then
      raise Program_Error with "message 1 out of order";
   end if;
   if Log.Item (3) /= "PRIVMSG #chan three" then
      raise Program_Error with "message 3 out of order";
   end if;

   --  Closing before sending must drop the message silently.
   declare
      C : Conn_Access := New_Conn
        (F'Unchecked_Access,
         (Logger => null, Rate_Limit_Delay => 0.0, Rate_Limit_Burst => 0,
         others => <>));
   begin
      Close (C);
      Send_Message (C, Parse_Message ("PRIVMSG #chan dropped"));
   end;

   delay 0.1;
   if Log.Count /= 3 then
      raise Program_Error with
        "message sent after close was not dropped";
   end if;

   Ada.Text_IO.Put_Line ("ALL PASS");
end Conn_Check;
