pragma Ada_2022;

with Ada.Characters.Handling;
with Ada.Characters.Latin_1;
with Ada.Strings.Fixed;

package body Soja.Irc.Messages is

   use Ada.Characters.Latin_1;

   --  Trim any trailing CR/LF bytes, as Go's strings.TrimRight(line, "\r\n").
   function Trim_Trailing_CRLF (S : String) return String is
      Last : Natural := S'Last;
   begin
      while Last >= S'First
        and then (S (Last) = CR or else S (Last) = LF)
      loop
         Last := Last - 1;
      end loop;
      if Last < S'First then
         return "";
      end if;
      return S (S'First .. Last);
   end Trim_Trailing_CRLF;

   --  Split S on runs of ' ', matching Go's strings.FieldsFunc with a space
   --  predicate (consecutive separators collapse).
   function Split_Spaces (S : String) return Param_Vectors.Vector is
      Result : Param_Vectors.Vector;
      I      : Positive := S'First;
   begin
      while I <= S'Last loop
         while I <= S'Last and then S (I) = ' ' loop
            I := I + 1;
         end loop;
         exit when I > S'Last;
         declare
            Start : constant Positive := I;
         begin
            while I <= S'Last and then S (I) /= ' ' loop
               I := I + 1;
            end loop;
            Param_Vectors.Append
              (Result, To_Unbounded_String (S (Start .. I - 1)));
         end;
      end loop;
      return Result;
   end Split_Spaces;

   --  Tag map --------------------------------------------------------------

   function Has_Tag (Tags : Tag_Map; Name : String) return Boolean is
   begin
      return Tags.Data.Contains (Name);
   end Has_Tag;

   function Get_Tag (Tags : Tag_Map; Name : String) return String is
   begin
      if Tags.Data.Contains (Name) then
         return Tags.Data.Element (Name);
      end if;
      return "";
   end Get_Tag;

   procedure Set_Tag (Tags : in out Tag_Map; Name, Value : String) is
   begin
      Tags.Data.Include (Name, Value);
   end Set_Tag;

   function Tag_Count (Tags : Tag_Map) return Natural is
   begin
      return Natural (Tag_Maps.Length (Tags.Data));
   end Tag_Count;

   function Copy (Tags : Tag_Map) return Tag_Map is
   begin
      return Tags;
   end Copy;

   function Image (Tags : Tag_Map) return String is
      Buf : Unbounded_String;
   begin
      for C in Tags.Data.Iterate loop
         declare
            Name  : constant String := Tag_Maps.Key (C);
            Value : constant String := Tag_Maps.Element (C);
         begin
            Append (Buf, ';');
            Append (Buf, Name);
            if Value /= "" then
               Append (Buf, '=');
               Append (Buf, Encode_Tag_Value (Value));
            end if;
         end;
      end loop;
      if Length (Buf) > 0 then
         Delete (Buf, 1, 1);
      end if;
      return To_String (Buf);
   end Image;

   function Parse_Tags (Line : String) return Tag_Map is
      Result : Tag_Map := (Data => Tag_Maps.Empty_Map);
      Start  : Positive := Line'First;

      procedure Add_Segment (Seg : String) is
         Eq : constant Natural := Ada.Strings.Fixed.Index (Seg, "=");
      begin
         if Eq = 0 then
            Set_Tag (Result, Seg, "");
         else
            Set_Tag (Result, Seg (Seg'First .. Eq - 1),
                     Parse_Tag_Value (Seg (Eq + 1 .. Seg'Last)));
         end if;
      end Add_Segment;
   begin
      for I in Line'Range loop
         if Line (I) = ';' then
            Add_Segment (Line (Start .. I - 1));
            Start := I + 1;
         end if;
      end loop;
      Add_Segment (Line (Start .. Line'Last));
      return Result;
   end Parse_Tags;

   function Parse_Tag_Value (V : String) return String is
      Buf : Unbounded_String;
      I   : Positive := V'First;
   begin
      while I <= V'Last loop
         if V (I) = '\' and then I < V'Last then
            I := I + 1;
            case V (I) is
               when ':' => Append (Buf, ';');
               when 's' => Append (Buf, ' ');
               when '\' => Append (Buf, '\');
               when 'r' => Append (Buf, CR);
               when 'n' => Append (Buf, LF);
               when others => Append (Buf, V (I));
            end case;
         elsif V (I) = '\' then
            exit;
         else
            Append (Buf, V (I));
         end if;
         I := I + 1;
      end loop;
      return To_String (Buf);
   end Parse_Tag_Value;

   function Encode_Tag_Value (V : String) return String is
      Buf : Unbounded_String;
   begin
      for C of V loop
         case C is
            when ';' => Append (Buf, "\:");
            when ' ' => Append (Buf, "\s");
            when '\' => Append (Buf, "\\");
            when CR  => Append (Buf, "\r");
            when LF  => Append (Buf, "\n");
            when others => Append (Buf, C);
         end case;
      end loop;
      return To_String (Buf);
   end Encode_Tag_Value;

   --  Prefix ---------------------------------------------------------------

   function Parse_Prefix (Line : String) return Prefix is
      Name : Unbounded_String := To_Unbounded_String (Line);
      User : Unbounded_String;
      Host : Unbounded_String;
      At_Pos : Natural;
      Bang   : Natural;
   begin
      At_Pos := Index (Name, "@");
      if At_Pos > 0 then
         Host := Unbounded_Slice (Name, At_Pos + 1, Length (Name));
         Name := Unbounded_Slice (Name, 1, At_Pos - 1);
      end if;
      Bang := Index (Name, "!");
      if Bang > 0 then
         User := Unbounded_Slice (Name, Bang + 1, Length (Name));
         Name := Unbounded_Slice (Name, 1, Bang - 1);
      end if;
      return (Name => Name, User => User, Host => Host);
   end Parse_Prefix;

   function Image (P : Prefix) return String is
      Buf : Unbounded_String := P.Name;
   begin
      if Length (P.User) /= 0 then
         Append (Buf, '!');
         Append (Buf, P.User);
      end if;
      if Length (P.Host) /= 0 then
         Append (Buf, '@');
         Append (Buf, P.Host);
      end if;
      return To_String (Buf);
   end Image;

   --  Message --------------------------------------------------------------

   function Parse_Message (Line : String) return Message is
      Rest : Unbounded_String :=
        To_Unbounded_String (Trim_Trailing_CRLF (Line));
      Msg : Message;
      Loc : Natural;
   begin
      if Length (Rest) = 0 then
         raise Parse_Error;
      end if;

      Msg.Tags := (Data => Tag_Maps.Empty_Map);
      Msg.Prefix := new Prefix'(Name => Null_Unbounded_String,
                                User => Null_Unbounded_String,
                                Host => Null_Unbounded_String);

      if Element (Rest, 1) = '@' then
         Loc := Index (Rest, " ");
         if Loc = 0 then
            raise Parse_Error;
         end if;
         Msg.Tags := Parse_Tags (Slice (Rest, 2, Loc - 1));
         if Loc < Length (Rest) then
            Rest := Unbounded_Slice (Rest, Loc + 1, Length (Rest));
         else
            Rest := Null_Unbounded_String;
         end if;
      end if;

      if Length (Rest) > 0 and then Element (Rest, 1) = ':' then
         Loc := Index (Rest, " ");
         if Loc = 0 then
            raise Parse_Error;
         end if;
         Msg.Prefix.all := Parse_Prefix (Slice (Rest, 2, Loc - 1));
         if Loc < Length (Rest) then
            Rest := Unbounded_Slice (Rest, Loc + 1, Length (Rest));
         else
            Rest := Null_Unbounded_String;
         end if;
      end if;

      Loc := Index (Rest, " :");
      if Loc = 0 then
         Msg.Params := Split_Spaces (To_String (Rest));
      else
         Msg.Params := Split_Spaces (Slice (Rest, 1, Loc - 1));
         Param_Vectors.Append
           (Msg.Params, Unbounded_Slice (Rest, Loc + 2, Length (Rest)));
      end if;

      if Param_Vectors.Is_Empty (Msg.Params) then
         raise Parse_Error;
      end if;

      Msg.Command := Param_Vectors.First_Element (Msg.Params);
      --  Quirk: irc.v4 stores the command upper-cased (strings.ToUpper);
      --  RFC 2812 only requires commands be case-insensitive.  See PORTING.md.
      Msg.Command := To_Unbounded_String
        (Ada.Characters.Handling.To_Upper (To_String (Msg.Command)));
      Param_Vectors.Delete_First (Msg.Params);

      return Msg;
   end Parse_Message;

   function Param (M : Message; I : Natural) return String is
   begin
      if I >= Natural (Param_Vectors.Length (M.Params)) then
         return "";
      end if;
      return To_String (M.Params (I + 1));
   end Param;

   function Trailing (M : Message) return String is
   begin
      if Param_Vectors.Is_Empty (M.Params) then
         return "";
      end if;
      return To_String (M.Params (Param_Vectors.Last_Index (M.Params)));
   end Trailing;

   function Copy (M : Message) return Message is
      Result : Message := M;
   begin
      if M.Prefix /= null then
         Result.Prefix := new Prefix'(M.Prefix.all);
      end if;
      return Result;
   end Copy;

   function Image (M : Message) return String is
      Buf : Unbounded_String;
   begin
      if Tag_Count (M.Tags) > 0 then
         Append (Buf, '@');
         Append (Buf, Image (M.Tags));
         Append (Buf, ' ');
      end if;

      if M.Prefix /= null and then Length (M.Prefix.Name) > 0 then
         Append (Buf, ':');
         Append (Buf, Image (M.Prefix.all));
         Append (Buf, ' ');
      end if;

      Append (Buf, M.Command);

      declare
         Count : constant Natural :=
           Natural (Param_Vectors.Length (M.Params));
      begin
         if Count > 0 then
            for I in 1 .. Count - 1 loop
               Append (Buf, ' ');
               Append (Buf, M.Params (I));
            end loop;
            declare
               T : constant Unbounded_String := M.Params (Count);
            begin
               --  Faithful to irc.v4: emit " :" only when the trailing is
               --  empty, has a space, or starts with ':'; a plain-word
               --  trailing re-emits as a middle param (see PORTING.md).
               if Length (T) = 0
                 or else Index (T, " ") > 0
                 or else Element (T, 1) = ':'
               then
                  Append (Buf, " :");
               else
                  Append (Buf, ' ');
               end if;
               Append (Buf, T);
            end;
         end if;
      end;

      return To_String (Buf);
   end Image;

end Soja.Irc.Messages;
