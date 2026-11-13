pragma Ada_2022;

with Ada.Characters.Handling;
with Ada.Characters.Latin_1;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;

package body Irc_Oracle is

   use Ada.Characters.Latin_1;
   use Soja.Irc.Messages;
   use Ada.Strings.Unbounded;

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

   function Parse_Tags_By_Hand (Line : String) return Tag_Map is
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
   end Parse_Tags_By_Hand;

   function Parse_Prefix_By_Hand (Line : String) return Prefix is
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
   end Parse_Prefix_By_Hand;

   function Parse_Message_By_Hand (Line : String) return Message is
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
         Msg.Tags := Parse_Tags_By_Hand (Slice (Rest, 2, Loc - 1));
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
         Msg.Prefix.all := Parse_Prefix_By_Hand (Slice (Rest, 2, Loc - 1));
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
   end Parse_Message_By_Hand;

end Irc_Oracle;
