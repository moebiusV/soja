pragma Ada_2022;

with Ada.IO_Exceptions;
with Interfaces;
with Ada.Streams;
with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;

with Soja.Irc.Hbnf;
with Soja.Utf8;

package body Soja.Conn.Ws is

   use Ada.Streams;
   use type Interfaces.Unsigned_8;

   Op_Continuation : constant := 0;
   Op_Text         : constant := 1;
   Op_Close        : constant := 8;
   Op_Ping         : constant := 9;
   Op_Pong         : constant := 10;

   Status_Normal      : constant := 1000;
   Status_Going_Away  : constant := 1001;
   Status_Protocol    : constant := 1002;
   Status_Bad_Payload : constant := 1007;
   Status_Too_Big     : constant := 1009;

   protected body Life is
      procedure Enter (Ok : out Boolean) is
      begin
         Ok := not Released;
         if Ok then
            Users := Users + 1;
         end if;
      end Enter;

      procedure Check (Release_Now : out Boolean) is
      begin
         Release_Now := Users = 0 and then Closed and then Done
           and then not Released;
         if Release_Now then
            Released := True;
         end if;
      end Check;

      procedure Leave (Release_Now : out Boolean) is
      begin
         Users := Users - 1;
         Check (Release_Now);
      end Leave;

      procedure Mark_Closed (Release_Now : out Boolean) is
      begin
         Closed := True;
         Check (Release_Now);
      end Mark_Closed;

      procedure Mark_Done (Release_Now : out Boolean) is
      begin
         Done := True;
         Check (Release_Now);
      end Mark_Done;
   end Life;

   protected body Write_Lock is
      entry Seize when not Busy is
      begin
         Busy := True;
      end Seize;

      procedure Try_Seize (Ok : out Boolean) is
      begin
         Ok := not Busy;
         if Ok then
            Busy := True;
         end if;
      end Try_Seize;

      procedure Release is
      begin
         Busy := False;
      end Release;
   end Write_Lock;

   function Create
     (Stream  : not null Soja.Byte_Stream.Stream_Access;
      Remote  : String;
      Initial : String := "") return Ws_IRC_Conn_Access
   is
      St : constant State_Access := new State;
   begin
      St.Stream := Stream;
      St.Remote := new String'(Remote);
      St.Buffer := To_Unbounded_String (Initial);
      return new Ws_IRC_Conn'(S => St);
   end Create;

   ----------------------------------------------------------------------
   --  Using the stream
   ----------------------------------------------------------------------

   function To_Bytes (S : String) return Stream_Element_Array is
      R : Stream_Element_Array (1 .. Stream_Element_Offset (S'Length));
   begin
      for I in S'Range loop
         R (Stream_Element_Offset (I - S'First + 1)) :=
           Stream_Element (Character'Pos (S (I)));
      end loop;
      return R;
   end To_Bytes;

   --  After the last user leaves a closed connection: give the socket back.
   procedure Leave (St : in out State) is
      Release_Now : Boolean;
   begin
      St.Lifetime.Leave (Release_Now);
      if Release_Now then
         St.Stream.Release;
      end if;
   end Leave;

   procedure Enter (St : in out State) is
      Ok : Boolean;
   begin
      St.Lifetime.Enter (Ok);
      if not Ok then
         raise Ada.IO_Exceptions.Use_Error with "connection closed";
      end if;
   end Enter;

   --  The eight bytes of a 64-bit length, most significant first.
   function Length_64 (Len : Natural) return String is
     ([for I in 1 .. 8 => Character'Val ((Len / (256 ** (8 - I))) mod 256)]);

   --  The frame header: FIN and the opcode (no RSV, no mask), then the length
   --  in the shortest of the three forms.
   function Frame_Header (Opcode, Len : Natural) return String is
     (Character'Val (128 + Opcode)
      & (if Len < 126 then "" & Character'Val (Len)
         elsif Len <= 65_535
         then Character'Val (126) & Character'Val (Len / 256)
              & Character'Val (Len mod 256)
         else Character'Val (127) & Length_64 (Len)));

   function Encode_Frame (Opcode : Natural; Payload : String) return String is
     (Frame_Header (Opcode, Payload'Length) & Payload);

   --  Sends one frame, serialised with the other writers.
   procedure Send_Frame
     (St : in out State; Opcode : Natural; Payload : String)
   is
   begin
      Enter (St);
      St.Lock.Seize;
      begin
         St.Stream.Send (To_Bytes (Encode_Frame (Opcode, Payload)));
      exception
         when others =>
            St.Lock.Release;
            Leave (St);
            raise;
      end;
      St.Lock.Release;
      Leave (St);
   end Send_Frame;

   --  A close frame's payload: the status, then a reason that fits (a control
   --  frame holds 125 bytes).
   function Close_Payload (Code : Natural; Reason : String) return String is
     (Character'Val (Code / 256) & Character'Val (Code mod 256)
      & (if Reason'Length > 123
         then Reason (Reason'First .. Reason'First + 122) else Reason));

   procedure Shutdown_Stream (St : in out State) is
   begin
      Enter (St);
      St.Stream.Shutdown;
      Leave (St);
   exception
      when Ada.IO_Exceptions.Use_Error => null;   --  already released
   end Shutdown_Stream;

   --  A protocol error: tell the peer, drop the connection, raise.
   procedure Fail (St : in out State; Code : Natural; Reason : String) is
   begin
      begin
         Send_Frame (St, Op_Close, Close_Payload (Code, Reason));
      exception
         when others => null;
      end;
      Shutdown_Stream (St);
      raise Ada.IO_Exceptions.Data_Error with Reason;
   end Fail;

   --  Makes sure at least Count bytes are in the buffer.
   procedure Need (St : in out State; Count : Natural) is
      Chunk : Stream_Element_Array (1 .. 4096);
      Last  : Stream_Element_Offset;
   begin
      while Length (St.Buffer) < Count loop
         Enter (St);
         begin
            St.Stream.Receive (Chunk, Last);
         exception
            when others =>
               Leave (St);
               raise;
         end;
         Leave (St);
         if Last < Chunk'First then
            raise Ada.IO_Exceptions.End_Error;   --  the peer is gone
         end if;
         for I in Chunk'First .. Last loop
            Append (St.Buffer, Character'Val (Chunk (I)));
         end loop;
      end loop;
   end Need;

   function Byte (St : State; I : Positive) return Natural is
     (Character'Pos (Element (St.Buffer, I)));

   ----------------------------------------------------------------------
   --  Reading
   ----------------------------------------------------------------------

   --  One frame: Payload is unmasked.
   procedure Read_Frame
     (St      : in out State;
      Fin     : out Boolean;
      Opcode  : out Natural;
      Payload : out Unbounded_String)
   is
      Pos    : Positive := 3;
      Len    : Natural;
      Masked : Boolean;
   begin
      Need (St, 2);
      Fin := Byte (St, 1) >= 128;
      Opcode := Byte (St, 1) mod 16;
      Masked := Byte (St, 2) >= 128;
      Len := Byte (St, 2) mod 128;

      if (Byte (St, 1) / 16) mod 8 /= 0 then
         Fail (St, Status_Protocol,
               "received header with unexpected rsv bits set");
      elsif Opcode in 3 .. 7 or else Opcode > 10 then
         Fail (St, Status_Protocol, "received unknown opcode"
               & Natural'Image (Opcode));
      elsif not Masked then
         Fail (St, Status_Protocol, "received unmasked frame from client");
      elsif Opcode >= Op_Close and then (not Fin or else Len > 125) then
         Fail (St, Status_Protocol, "received invalid control frame");
      end if;

      if Len = 126 then
         Need (St, 4);
         Len := Byte (St, 3) * 256 + Byte (St, 4);
         Pos := 5;
      elsif Len = 127 then
         Need (St, 10);
         if Byte (St, 3) >= 128 then
            Fail (St, Status_Protocol, "received frame with a huge length");
         end if;
         --  Anything above the limit is refused before it is read.
         for I in 3 .. 6 loop
            if Byte (St, I) /= 0 then
               Fail (St, Status_Too_Big, "read limited at"
                     & Natural'Image (Read_Limit) & " bytes");
            end if;
         end loop;
         Len := ((Byte (St, 7) * 256 + Byte (St, 8)) * 256 + Byte (St, 9))
                * 256 + Byte (St, 10);
         Pos := 11;
      end if;

      if Opcode < Op_Close
        and then Len + Length (St.Msg) > Read_Limit
      then
         Fail (St, Status_Too_Big,
               "read limited at" & Natural'Image (Read_Limit) & " bytes");
      end if;

      Need (St, Pos + 3 + Len);
      declare
         Raw : constant String := Slice (St.Buffer, Pos + 4, Pos + 3 + Len);
         Out_Text : String (1 .. Len);

         function Unmask (I : Positive) return Character is
            Data : constant Interfaces.Unsigned_8 :=
              Interfaces.Unsigned_8
                (Character'Pos (Raw (Raw'First + I - 1)));
            Key  : constant Interfaces.Unsigned_8 :=
              Interfaces.Unsigned_8 (Byte (St, Pos + ((I - 1) mod 4)));
         begin
            return Character'Val
              (Interfaces.Unsigned_8'Pos (Data xor Key));
         end Unmask;
      begin
         for I in 1 .. Len loop
            Out_Text (I) := Unmask (I);
         end loop;
         Payload := To_Unbounded_String (Out_Text);
         Delete (St.Buffer, 1, Pos + 3 + Len);
      end;
   end Read_Frame;

   overriding function Read_Message (C : in out Ws_IRC_Conn) return Message is
      St : State renames C.S.all;
   begin
      loop
         declare
            Fin     : Boolean;
            Opcode  : Natural;
            Payload : Unbounded_String;
         begin
            Read_Frame (St, Fin, Opcode, Payload);
            case Opcode is
               when Op_Ping =>
                  Send_Frame (St, Op_Pong, To_String (Payload));

               when Op_Pong =>
                  null;

               when Op_Close =>
                  declare
                     P    : constant String := To_String (Payload);
                     Code : Natural := 1005;   --  no status received
                  begin
                     if P'Length = 1 then
                        Fail (St, Status_Protocol,
                              "received invalid close payload");
                     elsif P'Length >= 2 then
                        Code := Character'Pos (P (P'First)) * 256
                          + Character'Pos (P (P'First + 1));
                     end if;
                     begin
                        Send_Frame
                          (St, Op_Close,
                           Close_Payload
                             ((if Code = 1005 then Status_Normal else Code),
                              ""));
                     exception
                        when others => null;
                     end;
                     Shutdown_Stream (St);
                     if Code = Status_Normal or else Code = Status_Going_Away
                     then
                        raise Ada.IO_Exceptions.End_Error;
                     end if;
                     raise Ada.IO_Exceptions.Data_Error with
                       "received close frame: status ="
                       & Natural'Image (Code);
                  end;

               when others =>   --  a data frame: text, binary, continuation
                  if Opcode = Op_Continuation then
                     if not St.In_Msg then
                        Fail (St, Status_Protocol,
                              "received continuation frame without text or "
                              & "binary frame");
                     end if;
                     Append (St.Msg, Payload);
                  else
                     if St.In_Msg then
                        Fail (St, Status_Protocol,
                              "received new data frame while fragmented");
                     end if;
                     St.Msg := Payload;
                     St.Msg_Op := Opcode;
                  end if;
                  St.In_Msg := not Fin;
                  if Fin then
                     declare
                        Text : constant String := To_String (St.Msg);
                        Op   : constant Natural := St.Msg_Op;
                     begin
                        St.Msg := Null_Unbounded_String;
                        St.Msg_Op := 0;
                        if Op = Op_Text
                          and then not Soja.Utf8.Is_Valid (Text)
                        then
                           Fail (St, Status_Bad_Payload,
                                 "text message is not valid UTF-8");
                        end if;
                        --  irc.ParseMessage trims the line end.
                        declare
                           Stop : Natural := Text'Last;
                        begin
                           while Stop >= Text'First
                             and then (Text (Stop) = ASCII.CR
                                       or else Text (Stop) = ASCII.LF)
                           loop
                              Stop := Stop - 1;
                           end loop;
                           return Soja.Irc.Hbnf.Parse
                             (Text (Text'First .. Stop));
                        end;
                     end;
                  end if;
            end case;
         end;
      end loop;
   end Read_Message;

   ----------------------------------------------------------------------
   --  Writing and closing
   ----------------------------------------------------------------------

   overriding procedure Write_Message (C : in out Ws_IRC_Conn; M : Message) is
   begin
      --  The message as UTF-8, with each invalid run replaced by U+FFFD.
      Send_Frame (C.S.all, Op_Text, Soja.Utf8.To_Valid (Image (M)));
   end Write_Message;

   overriding procedure Close (C : in out Ws_IRC_Conn) is
      St : State renames C.S.all;
      Ok : Boolean;
      Release_Now : Boolean;
   begin
      St.Lifetime.Enter (Ok);
      if not Ok then
         return;   --  already released
      end if;
      --  The closing handshake, as far as is possible without waiting: a
      --  writer stuck on a dead peer must not hold the close up.
      St.Lock.Try_Seize (Ok);
      if Ok then
         begin
            St.Stream.Send
              (To_Bytes
                 (Encode_Frame (Op_Close, Close_Payload (Status_Normal, ""))));
         exception
            when others => null;
         end;
         St.Lock.Release;
      end if;
      St.Stream.Shutdown;
      St.Lifetime.Mark_Closed (Release_Now);
      Leave (St);
      pragma Unreferenced (Release_Now);
   end Close;

   overriding function Remote_Addr (C : Ws_IRC_Conn) return String is
     (C.S.Remote.all);

   procedure Handler_Done (C : not null Ws_IRC_Conn_Access) is
      Release_Now : Boolean;
   begin
      C.S.Lifetime.Mark_Done (Release_Now);
      if Release_Now then
         C.S.Stream.Release;
      end if;
   end Handler_Done;

end Soja.Conn.Ws;
