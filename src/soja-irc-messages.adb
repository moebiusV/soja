pragma Ada_2022;

with Ada.Characters.Latin_1;

with Soja.Irc.Hbnf;

package body Soja.Irc.Messages is

   use Ada.Characters.Latin_1;

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
     (Soja.Irc.Hbnf.Parse_Attrs (Line));

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
     (Soja.Irc.Hbnf.Parse_Prefix (Line));

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
     (Soja.Irc.Hbnf.Parse (Line));

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
