pragma Ada_2022;

with Ada.Exceptions;
with Ada.Strings.Fixed;
with Ada.Unchecked_Deallocation;

with Soja.Bare;

package body Soja.Msgstore.Memory is

   use Ada.Strings.Unbounded;
   use Soja.Irc.Messages;

   --  The memoryMsgID body is just the sequence number (bare.Uint).

   function Format_Memory_Msg_ID
     (Net_ID : Long_Long_Integer; Entity : String; Seq : Unsigned_64)
      return String
   is
      Buf : Unbounded_String;
   begin
      Soja.Bare.Write_Uint (Buf, Seq);
      return Format_Msg_ID (Net_ID, Entity, Msg_ID_Memory, To_String (Buf));
   end Format_Memory_Msg_ID;

   function Parse_Memory_Msg_ID (S : String) return Unsigned_64 is
      Net_ID : Long_Long_Integer;
      Target : Unbounded_String;
      Bytes  : Unbounded_String;
   begin
      Parse_Msg_ID (S, Net_ID, Target, Bytes, Expected => Msg_ID_Memory);
      declare
         R : Soja.Bare.Reader := Soja.Bare.New_Reader (To_String (Bytes));
      begin
         return Soja.Bare.Read_Uint (R);
      exception
         when E : Soja.Bare.Bare_Error =>
            raise Store_Error with
              "invalid internal message ID: " &
              Ada.Exceptions.Exception_Message (E);
      end;
   end Parse_Memory_Msg_ID;

   function Key (Net_ID : Long_Long_Integer; Entity : String) return String is
   begin
      return Ada.Strings.Fixed.Trim (Long_Long_Integer'Image (Net_ID),
                                     Ada.Strings.Left) & "/" & Entity;
   end Key;

   function New_Ring return Ring_Access is (new Message_Ring);

   --  messageRingBuffer.Append: returns the message's sequence number.
   function Ring_Append (RB : Ring_Access; Msg : Message) return Unsigned_64
   is
      Seq : constant Unsigned_64 := RB.Cur;
      I   : constant Natural :=
        Natural (Seq mod Unsigned_64 (Message_Ring_Buffer_Cap));
   begin
      RB.Buf (I) := new Message'(Copy (Msg));
      RB.Cur := RB.Cur + 1;
      return Seq;
   end Ring_Append;

   --  messageRingBuffer.LoadLatestSeq: the messages after Seq (excluded),
   --  oldest first, at most Limit.
   function Ring_Load_Latest_Seq
     (RB : Ring_Access; Seq : Unsigned_64; Limit : Integer)
      return Message_Vectors.Vector
   is
      Result : Message_Vectors.Vector;
      Cap    : constant Unsigned_64 := Unsigned_64 (Message_Ring_Buffer_Cap);
      Diff   : Unsigned_64;
   begin
      if Seq > RB.Cur then
         raise Store_Error with
           "loading messages from sequence number ("
           & Unsigned_64'Image (Seq) & ") greater than current ("
           & Unsigned_64'Image (RB.Cur) & ")";
      elsif Seq = RB.Cur then
         return Result;
      end if;
      if Limit < 0 then
         raise Store_Error with "negative message limit";
      end if;

      --  The query excludes the message with the sequence number Seq.
      Diff := RB.Cur - Seq - 1;
      if Diff > Cap then
         Diff := Cap;   --  we dropped Diff - Cap entries
      end if;
      if Diff > Unsigned_64 (Limit) then
         Diff := Unsigned_64 (Limit);
      end if;

      --  (Diff is modular: a 0 .. Diff - 1 loop would wrap when Diff = 0.)
      for I in 0 .. Natural (Diff) - 1 loop
         Result.Append
           (Copy (RB.Buf (Natural ((RB.Cur - Diff + Unsigned_64 (I)) mod Cap))
                  .all));
      end loop;
      return Result;
   end Ring_Load_Latest_Seq;

   ---------------------
   -- New_Memory_Store --
   ---------------------

   function New_Memory_Store return Store_Access is
   begin
      return new Memory_Store;
   end New_Memory_Store;

   ---------------------
   -- Is_Memory_Store --
   ---------------------

   function Is_Memory_Store (S : Store'Class) return Boolean is
   begin
      return S in Memory_Store;
   end Is_Memory_Store;

   -----------
   -- Close --
   -----------

   procedure Free is new Ada.Unchecked_Deallocation (Message, Message_Access);
   procedure Free is new Ada.Unchecked_Deallocation
     (Message_Ring, Ring_Access);

   overriding procedure Close (S : in out Memory_Store) is
   begin
      for RB of S.Buffers loop
         declare
            R : Ring_Access := RB;
         begin
            for M of R.Buf loop
               declare
                  P : Message_Access := M;
               begin
                  Free (P);
               end;
            end loop;
            Free (R);
         end;
      end loop;
      S.Buffers.Clear;
   end Close;

   -----------------
   -- Last_Msg_ID --
   -----------------

   overriding function Last_Msg_ID
     (S : in out Memory_Store; Network : Soja.Database.Network;
      Entity : String; T : Ada.Calendar.Time) return String
   is
      pragma Unreferenced (T);
      Seq : Unsigned_64 := 0;
      K   : constant String := Key (Network.ID, Entity);
   begin
      if S.Buffers.Contains (K) then
         Seq := S.Buffers (K).Cur;
      end if;
      return Format_Memory_Msg_ID (Network.ID, Entity, Seq);
   end Last_Msg_ID;

   ------------
   -- Append --
   ------------

   overriding function Append
     (S : in out Memory_Store; Network : Soja.Database.Network;
      Entity : String; Msg : Message) return String
   is
      Cmd : constant String := To_String (Msg.Command);
   begin
      if Cmd /= "PRIVMSG" and then Cmd /= "NOTICE" then
         return "";
      end if;

      declare
         K : constant String := Key (Network.ID, Entity);
      begin
         if not S.Buffers.Contains (K) then
            S.Buffers.Insert (K, New_Ring);
         end if;
         return Format_Memory_Msg_ID
           (Network.ID, Entity, Ring_Append (S.Buffers (K), Msg));
      end;
   end Append;

   --------------------
   -- Load_Latest_ID --
   --------------------

   overriding function Load_Latest_ID
     (S : in out Memory_Store; ID : String; Options : Load_Message_Options)
      return Message_Vectors.Vector
   is
   begin
      if Options.Events then
         raise Store_Error with
           "events are unsupported for memory message store";
      end if;

      declare
         Seq : constant Unsigned_64 := Parse_Memory_Msg_ID (ID);
         K   : constant String :=
           Key (Options.Network.ID, To_String (Options.Entity));
      begin
         if not S.Buffers.Contains (K) then
            return Message_Vectors.Empty_Vector;
         end if;
         return Ring_Load_Latest_Seq (S.Buffers (K), Seq, Options.Limit);
      end;
   end Load_Latest_ID;

end Soja.Msgstore.Memory;
