pragma Ada_2022;

with Ada.Calendar;
with Ada.Streams;
with Ada.Strings.Fixed;

with Interfaces;

with Proxy_V1.Parser;

package body Soja.Proxy_Protocol is

   use Ada.Strings.Unbounded;
   use Interfaces;
   use type Ada.Streams.Stream_Element_Offset;
   use type Soja.Config.IP_Family;

   V1_Sig : constant String := "PROXY";
   V2_Sig : constant String :=
     ASCII.CR & ASCII.LF & ASCII.CR & ASCII.LF & ASCII.NUL & ASCII.CR
     & ASCII.LF & "QUIT" & ASCII.LF;

   Max_V1_Line : constant := 107;   --  the longest legal v1 line, with CRLF

   ----------------------------------------------------------------------
   --  IP addresses
   ----------------------------------------------------------------------

   function Is_V4 (Addr : Soja.Config.IP_Addr) return Boolean is
     ((for all I in 0 .. 9 => Addr (I) = 0)
      and then Addr (10) = 16#FF# and then Addr (11) = 16#FF#);

   function Parse_IP
     (Text : String; Addr : out Soja.Config.IP_Addr) return Boolean
   is
      A : Soja.Config.IP_Addr := [others => 0];

      function Parse_V4 return Boolean is
         Octet : Natural := 0;
         Digits_Seen : Natural := 0;
         Parts : Natural := 0;
      begin
         for I in Text'Range loop
            if Text (I) in '0' .. '9' then
               Octet := Octet * 10 + (Character'Pos (Text (I)) - 48);
               Digits_Seen := Digits_Seen + 1;
               if Octet > 255 or else Digits_Seen > 3 then
                  return False;
               end if;
            elsif Text (I) = '.' then
               if Digits_Seen = 0 or else Parts = 3 then
                  return False;
               end if;
               A (12 + Parts) := Unsigned_8 (Octet);
               Parts := Parts + 1;
               Octet := 0;
               Digits_Seen := 0;
            else
               return False;
            end if;
         end loop;
         if Digits_Seen = 0 or else Parts /= 3 then
            return False;
         end if;
         A (15) := Unsigned_8 (Octet);
         A (10) := 16#FF#;
         A (11) := 16#FF#;
         return True;
      end Parse_V4;

      function Parse_V6 return Boolean is
         Groups  : array (0 .. 7) of Natural := [others => 0];
         Count   : Natural := 0;       --  groups read
         Double  : Integer := -1;      --  groups before "::", -1 if none
         Val     : Natural := 0;
         Digits_Seen : Natural := 0;
         I       : Natural := Text'First;
      begin
         if Text'Length < 2 then
            return False;
         end if;
         if Text (Text'First) = ':' then
            if Text (Text'First + 1) /= ':' then
               return False;
            end if;
         end if;
         while I <= Text'Last loop
            declare
               C : constant Character := Text (I);
               D : Integer;
            begin
               case C is
                  when '0' .. '9' => D := Character'Pos (C) - 48;
                  when 'a' .. 'f' => D := Character'Pos (C) - 87;
                  when 'A' .. 'F' => D := Character'Pos (C) - 55;
                  when others     => D := -1;
               end case;
               if D >= 0 then
                  Val := Val * 16 + D;
                  Digits_Seen := Digits_Seen + 1;
                  if Digits_Seen > 4 then
                     return False;
                  end if;
               elsif C = ':' then
                  if Digits_Seen > 0 then
                     if Count > 7 then
                        return False;
                     end if;
                     Groups (Count) := Val;
                     Count := Count + 1;
                     Val := 0;
                     Digits_Seen := 0;
                  elsif I /= Text'First
                    and then not (Text (I - 1) = ':')
                  then
                     return False;
                  end if;
                  if I < Text'Last and then Text (I + 1) = ':' then
                     if Double >= 0 then
                        return False;   --  a second "::"
                     end if;
                     Double := Count;
                     I := I + 1;
                  elsif I = Text'Last then
                     return False;       --  a trailing single ':'
                  end if;
               else
                  return False;
               end if;
            end;
            I := I + 1;
         end loop;
         if Digits_Seen > 0 then
            if Count > 7 then
               return False;
            end if;
            Groups (Count) := Val;
            Count := Count + 1;
         end if;

         if Double < 0 and then Count /= 8 then
            return False;
         end if;
         if Double >= 0 and then Count >= 8 then
            return False;
         end if;

         declare
            Out_G : array (0 .. 7) of Natural := [others => 0];
            Shift : constant Natural := (if Double >= 0 then 8 - Count else 0);
         begin
            for K in 0 .. Count - 1 loop
               if Double >= 0 and then K >= Double then
                  Out_G (K + Shift) := Groups (K);
               else
                  Out_G (K) := Groups (K);
               end if;
            end loop;
            for K in 0 .. 7 loop
               A (2 * K) := Unsigned_8 (Out_G (K) / 256);
               A (2 * K + 1) := Unsigned_8 (Out_G (K) mod 256);
            end loop;
         end;
         return True;
      end Parse_V6;

      Ok : Boolean;
   begin
      if Text'Length = 0 then
         Addr := [others => 0];
         return False;
      end if;
      if Ada.Strings.Fixed.Index (Text, ":") > 0 then
         Ok := Parse_V6;
      else
         Ok := Parse_V4;
      end if;
      Addr := (if Ok then A else (others => 0));
      return Ok;
   end Parse_IP;

   function Image (Addr : Soja.Config.IP_Addr) return String is
      function Dec (N : Natural) return String is
        (Ada.Strings.Fixed.Trim (Natural'Image (N), Ada.Strings.Left));
   begin
      if Is_V4 (Addr) then
         return Dec (Natural (Addr (12))) & "." & Dec (Natural (Addr (13)))
           & "." & Dec (Natural (Addr (14))) & "." & Dec (Natural (Addr (15)));
      end if;

      declare
         G : array (0 .. 7) of Natural;
         Best_Start, Best_Len, Run_Start, Run_Len : Integer := 0;
         Hex : constant String := "0123456789abcdef";
         R   : Unbounded_String;

         function Group_Image (V : Natural) return String is
            S : String (1 .. 4);
            N : Natural := V;
            Last : Natural := 5;
         begin
            if V = 0 then
               return "0";
            end if;
            while N > 0 loop
               Last := Last - 1;
               S (Last) := Hex (N mod 16 + 1);
               N := N / 16;
            end loop;
            return S (Last .. 4);
         end Group_Image;
      begin
         for K in 0 .. 7 loop
            G (K) := Natural (Addr (2 * K)) * 256 + Natural (Addr (2 * K + 1));
         end loop;
         Best_Start := -1;
         Run_Start := -1;
         for K in 0 .. 7 loop
            if G (K) = 0 then
               if Run_Start < 0 then
                  Run_Start := K;
                  Run_Len := 0;
               end if;
               Run_Len := Run_Len + 1;
               if Run_Len > Best_Len then
                  Best_Len := Run_Len;
                  Best_Start := Run_Start;
               end if;
            else
               Run_Start := -1;
            end if;
         end loop;
         if Best_Len < 2 then
            Best_Start := -1;
         end if;

         declare
            K : Natural := 0;
         begin
            while K <= 7 loop
               if K = Best_Start then
                  Append (R, "::");
                  K := K + Best_Len;
               else
                  if Length (R) > 0
                    and then Element (R, Length (R)) /= ':'
                  then
                     Append (R, ':');
                  end if;
                  Append (R, Group_Image (G (K)));
                  K := K + 1;
               end if;
            end loop;
         end;
         return To_String (R);
      end;
   end Image;

   function Contains
     (Set : Soja.Config.IPSet; Addr : Soja.Config.IP_Addr) return Boolean
   is
      V4 : constant Boolean := Is_V4 (Addr);
   begin
      for Net of Set loop
         if (Net.Family = Soja.Config.IPv4) = V4 then
            declare
               --  Bits compared: from the start of the address (IPv6) or of
               --  its IPv4 part (the last four bytes of the mapped form).
               First_Byte : constant Natural := (if V4 then 12 else 0);
               Full       : constant Natural := Net.Prefix / 8;
               Rest       : constant Natural := Net.Prefix mod 8;
               Match      : Boolean := True;
            begin
               for B in 0 .. Full - 1 loop
                  if Addr (First_Byte + B) /= Net.Addr (First_Byte + B) then
                     Match := False;
                  end if;
               end loop;
               if Match and then Rest > 0 then
                  declare
                     Mask : constant Unsigned_8 :=
                       Shift_Left (16#FF#, 8 - Rest);
                  begin
                     if (Addr (First_Byte + Full) and Mask)
                       /= (Net.Addr (First_Byte + Full) and Mask)
                     then
                        Match := False;
                     end if;
                  end;
               end if;
               if Match then
                  return True;
               end if;
            end;
         end if;
      end loop;
      return False;
   end Contains;

   ----------------------------------------------------------------------
   --  The header
   ----------------------------------------------------------------------

   --  Whether Data (as far as it goes) is the beginning of Sig.
   function Starts_Like (Data, Sig : String) return Boolean is
      N : constant Natural := Natural'Min (Data'Length, Sig'Length);
   begin
      return Data (Data'First .. Data'First + N - 1)
             = Sig (Sig'First .. Sig'First + N - 1);
   end Starts_Like;

   use type Proxy_V1.Family_Type;
   use type Proxy_V1.Tcp_Access;

   function Valid_Port (N : Long_Long_Integer) return Boolean is
     (N in 0 .. 65_535);

   --  What a TCP line says, when its addresses are of the family it names and
   --  its ports are in range.
   procedure Read_Tcp
     (T : Proxy_V1.Tcp_Type; Result : in out Info; Ok : out Boolean)
   is
      Src, Dst : Soja.Config.IP_Addr;
      Want_V4  : constant Boolean := T.Family = Proxy_V1.Family_TCP4;
   begin
      Ok := Parse_IP (To_String (T.Source), Src)
        and then Parse_IP (To_String (T.Target), Dst)
        and then Is_V4 (Src) = Want_V4 and then Is_V4 (Dst) = Want_V4
        and then Valid_Port (T.Source_port)
        and then Valid_Port (T.Target_port);
      if Ok then
         Result :=
           (Local       => False,
            Source_Host => To_Unbounded_String (Image (Src)),
            Source_Port => Natural (T.Source_port),
            Dest_Host   => To_Unbounded_String (Image (Dst)),
            Dest_Port   => Natural (T.Target_port));
      end if;
   end Read_Tcp;

   --  The v1 line (without its CRLF), read by the generated parser
   --  (grammars/proxy-v1.hbnf); `PROXY UNKNOWN` leaves the connection's own
   --  address.
   procedure Examine_V1 (Line : String; Result : out Info) is
      Tree : Proxy_V1.Line_Type;
      Ok   : Boolean := True;
   begin
      Result := (others => <>);
      begin
         Tree := Proxy_V1.Parser.Parse_Text (Line);
      exception
         --  (A port too big for 64 bits is a Constraint_Error.)
         when Proxy_V1.Parser.Parse_Error | Constraint_Error =>
            raise Proxy_Error with "malformed PROXY header";
      end;
      if Tree.Line_1.Tcp /= null then
         Read_Tcp (Tree.Line_1.Tcp.all, Result, Ok);
      end if;
      Proxy_V1.Parser.Free_Line (Tree);
      if not Ok then
         raise Proxy_Error with "malformed PROXY header";
      end if;
   end Examine_V1;

   procedure Examine
     (Data : String; State : out Status; Consumed : out Natural;
      Result : out Info)
   is
      function Byte (I : Positive) return Natural is
        (Character'Pos (Data (Data'First + I - 1)));
   begin
      Consumed := 0;
      Result := (others => <>);
      if Data'Length = 0 then
         State := Need_More;
         return;
      end if;

      if Starts_Like (Data, V2_Sig) then
         if Data'Length < V2_Sig'Length + 4 then
            State := Need_More;
            return;
         end if;
         if Data (Data'First .. Data'First + 11) /= V2_Sig then
            State := No_Header;
            return;
         end if;

         declare
            Ver_Cmd : constant Natural := Byte (13);
            Fam_Pro : constant Natural := Byte (14);
            Len     : constant Natural := Byte (15) * 256 + Byte (16);
            Fam     : constant Natural := Fam_Pro / 16;
            Pro     : constant Natural := Fam_Pro mod 16;
         begin
            if Ver_Cmd / 16 /= 2 or else Ver_Cmd mod 16 > 1 then
               raise Proxy_Error with "malformed PROXY header";
            end if;
            if Data'Length < 16 + Len then
               State := Need_More;
               return;
            end if;
            State := Header;
            Consumed := 16 + Len;
            if Ver_Cmd mod 16 = 0 or else Pro /= 1
              or else (Fam /= 1 and then Fam /= 2)
            then
               return;   --  LOCAL, or a family/transport we do not report
            end if;

            if Fam = 1 then
               if Len < 12 then
                  raise Proxy_Error with "malformed PROXY header";
               end if;
               declare
                  function Quad (First : Positive) return String is
                     function D (I : Positive) return String is
                       (Ada.Strings.Fixed.Trim
                          (Natural'Image (Byte (I)), Ada.Strings.Left));
                  begin
                     return D (First) & "." & D (First + 1) & "."
                       & D (First + 2) & "." & D (First + 3);
                  end Quad;
               begin
                  Result.Local := False;
                  Result.Source_Host := To_Unbounded_String (Quad (17));
                  Result.Dest_Host := To_Unbounded_String (Quad (21));
                  Result.Source_Port := Byte (25) * 256 + Byte (26);
                  Result.Dest_Port := Byte (27) * 256 + Byte (28);
               end;
            else
               if Len < 36 then
                  raise Proxy_Error with "malformed PROXY header";
               end if;
               declare
                  Src, Dst : Soja.Config.IP_Addr;
               begin
                  for K in 0 .. 15 loop
                     Src (K) := Unsigned_8 (Byte (17 + K));
                     Dst (K) := Unsigned_8 (Byte (33 + K));
                  end loop;
                  Result.Local := False;
                  Result.Source_Host := To_Unbounded_String (Image (Src));
                  Result.Dest_Host := To_Unbounded_String (Image (Dst));
                  Result.Source_Port := Byte (49) * 256 + Byte (50);
                  Result.Dest_Port := Byte (51) * 256 + Byte (52);
               end;
            end if;
         end;

      elsif Starts_Like (Data, V1_Sig) then
         if Data'Length < V1_Sig'Length then
            State := Need_More;
            return;
         end if;
         --  The line ends at the first LF, which must follow a CR.
         declare
            LF : Natural := 0;
         begin
            for I in 1 .. Natural'Min (Data'Length, Max_V1_Line) loop
               if Data (Data'First + I - 1) = ASCII.LF then
                  LF := I;
                  exit;
               end if;
            end loop;
            if LF = 0 then
               if Data'Length >= Max_V1_Line then
                  raise Proxy_Error with "PROXY header line too long";
               end if;
               State := Need_More;
               return;
            end if;
            if LF < 2 or else Data (Data'First + LF - 2) /= ASCII.CR then
               raise Proxy_Error with "malformed PROXY header";
            end if;
            Examine_V1 (Data (Data'First .. Data'First + LF - 3), Result);
            State := Header;
            Consumed := LF;
         end;

      else
         State := No_Header;
      end if;
   end Examine;

   procedure Read_Header
     (Sock    : in out AWS.Net.Socket_Type'Class;
      Buffer  : in out Unbounded_String;
      Timeout : Duration;
      Result  : out Info)
   is
      use type Ada.Calendar.Time;
      Deadline : constant Ada.Calendar.Time :=
        Ada.Calendar.Clock + Timeout;
      Chunk    : Ada.Streams.Stream_Element_Array (1 .. 256);
      Last     : Ada.Streams.Stream_Element_Offset;
      State    : Status;
      Consumed : Natural;
   begin
      loop
         Examine (To_String (Buffer), State, Consumed, Result);
         case State is
            when Header =>
               Delete (Buffer, 1, Consumed);
               return;
            when No_Header =>
               Result := (others => <>);
               return;
            when Need_More =>
               declare
                  Left : constant Duration := Deadline - Ada.Calendar.Clock;
               begin
                  if Left <= 0.0 then
                     raise Proxy_Error with "timeout reading the PROXY header";
                  end if;
                  Sock.Set_Timeout (Left);
               end;
               begin
                  Sock.Receive (Chunk, Last);
               exception
                  when AWS.Net.Socket_Error =>
                     raise Proxy_Error with
                       "failed to read the PROXY header";
               end;
               if Last < Chunk'First then
                  raise Proxy_Error with
                    "the connection closed inside a PROXY header";
               end if;
               for K in Chunk'First .. Last loop
                  Append (Buffer, Character'Val (Chunk (K)));
               end loop;
         end case;
      end loop;
   end Read_Header;

end Soja.Proxy_Protocol;
