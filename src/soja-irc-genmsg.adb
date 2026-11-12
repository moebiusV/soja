pragma Ada_2022;

with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;

with Soja.Base64;
with Soja.Irc.Numerics;
with Soja.Irc.Xirc;

package body Soja.Irc.Genmsg is

   use Soja.Irc.Messages;

   function Make (Command : String; Params : Param_Vectors.Vector)
      return Message
   is
      M : Message := (others => <>);
   begin
      M.Command := To_Unbounded_String (Command);
      M.Params := Params;
      return M;
   end Make;

   function PV (A : String) return Param_Vectors.Vector is
      V : Param_Vectors.Vector;
   begin
      V.Append (To_Unbounded_String (A));
      return V;
   end PV;

   --------------------
   -- Generate_Join --
   --------------------

   function Generate_Join
     (Channels, Keys : String_Vectors.Vector) return Message_Vector
   is
      type Pair is record
         Channel : Unbounded_String;
         Key     : Unbounded_String;
      end record;
      type Pair_Array is array (Positive range <>) of Pair;

      N : constant Natural := Natural (Channels.Length);
      Items : Pair_Array (1 .. N);
      Msgs  : Message_Vector;

      --  joinSorter.Less: keyed channels first, then by name.
      function Less (A, B : Pair) return Boolean is
         KA : constant Boolean := Length (A.Key) > 0;
         KB : constant Boolean := Length (B.Key) > 0;
      begin
         if KA /= KB then
            return KA;
         end if;
         return To_String (A.Channel) < To_String (B.Channel);
      end Less;

      --  Two spaces because there are three words (JOIN, channels, keys).
      Join_Word : constant String := "JOIN";
      Max_Length : constant Natural :=
        Soja.Irc.Xirc.Max_Message_Length - (Join_Word'Length + 2);

      Channels_Buf, Keys_Buf : Unbounded_String;

      procedure Flush is
         Params : Param_Vectors.Vector;
      begin
         Params.Append (Channels_Buf);
         if Length (Keys_Buf) > 0 then
            Params.Append (Keys_Buf);
         end if;
         Msgs.Append (Make ("JOIN", Params));
      end Flush;
   begin
      for I in Items'Range loop
         Items (I).Channel := To_Unbounded_String (Channels (I));
         Items (I).Key := To_Unbounded_String (Keys (I));
      end loop;

      --  Insertion sort (stable; the lists are short).
      for I in Items'First + 1 .. Items'Last loop
         declare
            Cur : constant Pair := Items (I);
            J   : Integer := I - 1;
         begin
            while J >= Items'First and then Less (Cur, Items (J)) loop
               Items (J + 1) := Items (J);
               J := J - 1;
            end loop;
            Items (J + 1) := Cur;
         end;
      end loop;

      for It of Items loop
         declare
            Len : Natural := Length (Channels_Buf) + Length (Keys_Buf) + 1
              + Length (It.Channel);
         begin
            if Length (It.Key) > 0 then
               Len := Len + 1 + Length (It.Key);
            end if;

            if Length (Channels_Buf) > 0 and then Len > Max_Length then
               --  No room for the new channel in this message.
               Flush;
               Channels_Buf := Null_Unbounded_String;
               Keys_Buf := Null_Unbounded_String;
            end if;

            if Length (Channels_Buf) > 0 then
               Append (Channels_Buf, ',');
            end if;
            Append (Channels_Buf, It.Channel);
            if Length (It.Key) > 0 then
               if Length (Keys_Buf) > 0 then
                  Append (Keys_Buf, ',');
               end if;
               Append (Keys_Buf, It.Key);
            end if;
         end;
      end loop;
      if Length (Channels_Buf) > 0 then
         Flush;
      end if;
      return Msgs;
   end Generate_Join;

   -----------------------
   -- Generate_Isupport --
   -----------------------

   function Encode_Isupport (Tok : String) return String is
      R : Unbounded_String;
   begin
      for C of Tok loop
         case C is
            when ' '    => Append (R, "\x20");
            when '\'    => Append (R, "\x5C");
            when others => Append (R, C);
         end case;
      end loop;
      return To_String (R);
   end Encode_Isupport;

   function Generate_Isupport (Tokens : String_Vectors.Vector)
      return Message_Vector
   is
      --  2 reserved params: nick + text.
      Max_Tokens : constant Positive := Soja.Irc.Xirc.Max_Message_Params - 2;
      Msgs : Message_Vector;
      I    : Positive := 1;
      N    : constant Natural := Natural (Tokens.Length);
   begin
      while I <= N loop
         declare
            Params : Param_Vectors.Vector;
            Last   : constant Natural := Natural'Min (N, I + Max_Tokens - 1);
         begin
            Params.Append (To_Unbounded_String ("*"));
            for K in I .. Last loop
               Params.Append
                 (To_Unbounded_String (Encode_Isupport (Tokens (K))));
            end loop;
            Params.Append (To_Unbounded_String ("are supported"));
            Msgs.Append (Make (Soja.Irc.Numerics.RPL_ISUPPORT, Params));
            I := Last + 1;
         end;
      end loop;
      return Msgs;
   end Generate_Isupport;

   -------------------
   -- Generate_MOTD --
   -------------------

   function Generate_MOTD (Motd : String) return Message_Vector is
      Msgs  : Message_Vector;
      Start : Positive := Motd'First;

      procedure Line (S : String) is
         P : Param_Vectors.Vector;
      begin
         P.Append (To_Unbounded_String ("*"));
         P.Append (To_Unbounded_String (S));
         Msgs.Append (Make (Soja.Irc.Numerics.RPL_MOTD, P));
      end Line;

      P0 : Param_Vectors.Vector;
   begin
      P0.Append (To_Unbounded_String ("*"));
      P0.Append (To_Unbounded_String ("- Message of the Day -"));
      Msgs.Append (Make (Soja.Irc.Numerics.RPL_MOTDSTART, P0));

      --  strings.Split(motd, "\n"): "a\nb" -> a, b; "" -> one empty line.
      for I in Motd'Range loop
         if Motd (I) = ASCII.LF then
            Line (Motd (Start .. I - 1));
            Start := I + 1;
         end if;
      end loop;
      Line (Motd (Start .. Motd'Last));

      declare
         P : Param_Vectors.Vector;
      begin
         P.Append (To_Unbounded_String ("*"));
         P.Append (To_Unbounded_String ("End of /MOTD command."));
         Msgs.Append (Make (Soja.Irc.Numerics.RPL_ENDOFMOTD, P));
      end;
      return Msgs;
   end Generate_MOTD;

   ----------------------
   -- Generate_Monitor --
   ----------------------

   function Generate_Monitor
     (Subcmd : String; Targets : String_Vectors.Vector) return Message_Vector
   is
      Prefix_Text : constant String := "MONITOR " & Subcmd & " ";
      Max_Length : constant Natural :=
        Soja.Irc.Xirc.Max_Message_Length - Prefix_Text'Length;
      Msgs : Message_Vector;
      Buf  : Unbounded_String;
      Have : Boolean := False;   --  len(buf) > 0 in Go
      N    : Natural := 0;

      procedure Flush is
         P : Param_Vectors.Vector;
      begin
         P.Append (To_Unbounded_String (Subcmd));
         P.Append (Buf);
         Msgs.Append (Make ("MONITOR", P));
      end Flush;
   begin
      for T of Targets loop
         if N + T'Length + 1 > Max_Length then
            Flush;
            Buf := Null_Unbounded_String;
            Have := False;
            N := 0;
         end if;
         if Have then
            Append (Buf, ',');
         end if;
         Append (Buf, T);
         Have := True;
         N := N + T'Length + 1;
      end loop;
      if Have then
         Flush;
      end if;
      return Msgs;
   end Generate_Monitor;

   --------------------------
   -- Generate_Names_Reply --
   --------------------------

   function Generate_Names_Reply
     (Channel : String;
      Status  : Soja.Irc.Members.Channel_Status;
      Members : String_Vectors.Vector) return Message_Vector
   is
      St : constant String := [1 => Soja.Irc.Members.Code (Status)];

      function Reply (Names : String) return Message is
         P : Param_Vectors.Vector;
      begin
         P.Append (To_Unbounded_String ("*"));
         P.Append (To_Unbounded_String (St));
         P.Append (To_Unbounded_String (Channel));
         P.Append (To_Unbounded_String (Names));
         return Make (Soja.Irc.Numerics.RPL_NAMREPLY, P);
      end Reply;

      Max_Length : constant Natural :=
        Soja.Irc.Xirc.Max_Message_Length - Image (Reply (""))'Length;
      Msgs : Message_Vector;
      Buf  : Unbounded_String;
   begin
      for S of Members loop
         if Length (Buf) /= 0
           and then Length (Buf) + 1 + S'Length > Max_Length
         then
            --  Not enough space for the next space + nick.
            Msgs.Append (Reply (To_String (Buf)));
            Buf := Null_Unbounded_String;
         end if;
         if Length (Buf) /= 0 then
            Append (Buf, ' ');
         end if;
         Append (Buf, S);
      end loop;
      if Length (Buf) /= 0 then
         Msgs.Append (Reply (To_String (Buf)));
      end if;

      declare
         P : Param_Vectors.Vector;
      begin
         P.Append (To_Unbounded_String ("*"));
         P.Append (To_Unbounded_String (Channel));
         P.Append (To_Unbounded_String ("End of /NAMES list"));
         Msgs.Append (Make (Soja.Irc.Numerics.RPL_ENDOFNAMES, P));
      end;
      return Msgs;
   end Generate_Names_Reply;

   -------------------
   -- Generate_SASL --
   -------------------

   function Generate_SASL (Resp : String) return Message_Vector is
      Encoded : constant String := Soja.Base64.Encode (Resp);
      Msgs    : Message_Vector;
      I       : Natural := 0;   --  0-based, as in Go
   begin
      --  <= instead of < because a final empty response is needed if the
      --  last chunk is exactly Max_SASL_Length bytes long.
      while I <= Encoded'Length loop
         declare
            J : constant Natural :=
              Natural'Min (I + Soja.Irc.Xirc.Max_SASL_Length,
                           Encoded'Length);
            Chunk : constant String := Encoded (I + 1 .. J);
         begin
            Msgs.Append
              (Make ("AUTHENTICATE",
                     PV (if Chunk = "" then "+" else Chunk)));
         end;
         I := I + Soja.Irc.Xirc.Max_SASL_Length;
      end loop;
      return Msgs;
   end Generate_SASL;

end Soja.Irc.Genmsg;
