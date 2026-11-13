pragma Ada_2022;

with Ada.Characters.Handling;
with Ada.Strings.Unbounded;

with Irc_Attrs;
with Irc_Attrs.Parser;
with Irc_Prefix;
with Irc_Prefix.Parser;
with Irc_Wire;
with Irc_Wire.Parser;
with Soja.Utf8;

package body Soja.Irc.Hbnf is

   use Ada.Strings.Unbounded;
   use Soja.Irc.Messages;

   --  The text of a field, as the line had it.
   function Text (S : Unbounded_String) return Unbounded_String is
     (To_Unbounded_String (Soja.Utf8.Restore (To_String (S))));

   --  strings.TrimRight (line, "\r\n").
   function Trim_Trailing_CRLF (S : String) return String is
      Last : Natural := S'Last;
   begin
      while Last >= S'First and then S (Last) in ASCII.CR | ASCII.LF loop
         Last := Last - 1;
      end loop;
      return S (S'First .. Last);
   end Trim_Trailing_CRLF;

   ----------------------------------------------------------------------
   --  Tags and attributes
   ----------------------------------------------------------------------

   procedure Add_Tag
     (Tags : in out Tag_Map; Key, Value : Unbounded_String;
      Has_Value : Boolean)
   is
   begin
      Set_Tag (Tags, To_String (Text (Key)),
               (if Has_Value
                then Parse_Tag_Value (To_String (Text (Value))) else ""));
   end Add_Tag;

   procedure Add_Tag (Tags : in out Tag_Map; T : Irc_Wire.Tag_Type) is
      use type Irc_Wire.Tag_pair_Access;
   begin
      if T.Tag_pair /= null then
         Add_Tag (Tags, T.Tag_pair.Tag_key, T.Tag_pair.Tag_value, True);
      else
         Add_Tag (Tags, T.Tag_key_only.Tag_key_1, Null_Unbounded_String,
                  False);
      end if;
   end Add_Tag;

   function Parse_Attrs (Text : String) return Tag_Map is
      use type Irc_Attrs.Attr_pair_Access;
      use type Irc_Attrs.Attr_empty_Access;
      use type Irc_Attrs.Attr_semi_Access;
      Result : Tag_Map := (Data => Tag_Maps.Empty_Map);
      Tree   : Irc_Attrs.Attrs_Type;
      --  The list ends with an attribute that is empty: nothing at all, or a
      --  last ";".
      Ends_Empty : Boolean := True;

      procedure Add (A : Irc_Attrs.Attr_Type) is
      begin
         if A.Attr_pair /= null then
            Add_Tag (Result, A.Attr_pair.Attr_name, A.Attr_pair.Attr_value,
                     True);
         else
            Add_Tag (Result, A.Attr_key_only.Attr_name_1,
                     Null_Unbounded_String, False);
         end if;
      end Add;
   begin
      --  (The parser takes no empty text; the list of nothing is one empty
      --  attribute, as are the ends of "a;" and ";a".)
      if Text /= "" then
         Tree := Irc_Attrs.Parser.Parse_Text
           (Soja.Utf8.Escape_Invalid (Text));
         for U of Tree loop
            if U.Attr_empty /= null then
               Ends_Empty := True;
               Set_Tag (Result, "", "");
            elsif U.Attr_semi /= null then
               Ends_Empty := True;
               Add (U.Attr_semi.Attr.all);
            else
               Ends_Empty := False;
               Add (U.Attr_final);
            end if;
         end loop;
         Irc_Attrs.Parser.Free_Attrs (Tree);
      end if;
      if Ends_Empty then
         Set_Tag (Result, "", "");
      end if;
      return Result;
   exception
      when Irc_Attrs.Parser.Parse_Error =>
         raise Soja.Irc.Messages.Parse_Error;
   end Parse_Attrs;

   ----------------------------------------------------------------------
   --  Prefix
   ----------------------------------------------------------------------

   function Parse_Prefix (Text : String) return Prefix is
      use Irc_Prefix;
      Tree   : Irc_Prefix.Bare_prefix_Type;
      Result : Prefix;
   begin
      if Text = "" then
         return (others => <>);   --  (the parser takes no empty text)
      end if;
      Tree := Irc_Prefix.Parser.Parse_Text (Soja.Utf8.Escape_Invalid (Text));
      if Tree.Bare_full /= null then
         Result := (Name => Tree.Bare_full.Bare_name,
                    User => Tree.Bare_full.Bare_user_name,
                    Host => Tree.Bare_full.Bare_host_name);
      elsif Tree.Bare_user /= null then
         Result := (Name => Tree.Bare_user.Bare_name,
                    User => Tree.Bare_user.Bare_user_name,
                    Host => Null_Unbounded_String);
      elsif Tree.Bare_host /= null then
         Result := (Name => Tree.Bare_host.Bare_name,
                    User => Null_Unbounded_String,
                    Host => Tree.Bare_host.Bare_host_name);
      else
         Result := (Name => Tree.Bare_nick.Bare_name, others => <>);
      end if;
      Irc_Prefix.Parser.Free_Bare_prefix (Tree);
      return (Name => Hbnf.Text (Result.Name), User => Hbnf.Text (Result.User),
              Host => Hbnf.Text (Result.Host));
   exception
      when Irc_Prefix.Parser.Parse_Error =>
         raise Soja.Irc.Messages.Parse_Error;
   end Parse_Prefix;

   ----------------------------------------------------------------------
   --  Message
   ----------------------------------------------------------------------

   function From_Tree (Tree : Irc_Wire.Message_Type) return Message is
      use Irc_Wire;

      Msg : Message;

      procedure Read_Prefix (P : Irc_Wire.Prefix_Type) is
         Name, User, Host : Unbounded_String;
      begin
         if P.Pfx_full /= null then
            Name := P.Pfx_full.Pfx_name;
            User := P.Pfx_full.Pfx_user_name;
            Host := P.Pfx_full.Pfx_host_name;
         elsif P.Pfx_user /= null then
            Name := P.Pfx_user.Pfx_name;
            User := P.Pfx_user.Pfx_user_name;
         elsif P.Pfx_host /= null then
            Name := P.Pfx_host.Pfx_name;
            Host := P.Pfx_host.Pfx_host_name;
         else
            Name := P.Pfx_nick.Pfx_name_1;
         end if;
         Msg.Prefix.all := (Name => Text (Name), User => Text (User),
                            Host => Text (Host));
      end Read_Prefix;

      procedure Read_Rest (R : Irc_Wire.Rest_Type) is
      begin
         if R.Only_trailing /= null then
            --  No command of its own: the trailing text is it.
            Msg.Command := To_Unbounded_String
              (Ada.Characters.Handling.To_Upper
                 (To_String (Text (R.Only_trailing.Trailing))));
         else
            declare
               W : Irc_Wire.With_command_Type renames R.With_command.all;
            begin
               Msg.Command := To_Unbounded_String
                 (Ada.Characters.Handling.To_Upper
                    (To_String (Text (W.Command))));
               for Item of W.Middles loop
                  Msg.Params.Append (Text (Item.Middle));
               end loop;
               for T of W.With_command_1 loop
                  Msg.Params.Append (Text (T.Trailing));
               end loop;
            end;
         end if;
      end Read_Rest;
   begin
      Msg.Tags := (Data => Tag_Maps.Empty_Map);
      Msg.Prefix := new Prefix'(others => <>);

      if Tree.Tags_part /= null then
         declare
            Ends_Empty : Boolean := True;
         begin
            for U of Tree.Tags_part.Tag_list loop
               if U.Empty_item /= null then
                  Ends_Empty := True;
                  Set_Tag (Msg.Tags, "", "");
               elsif U.Item_semi /= null then
                  Ends_Empty := True;
                  Add_Tag (Msg.Tags, U.Item_semi.Tag.all);
               else
                  Ends_Empty := False;
                  Add_Tag (Msg.Tags, U.Item_final);
               end if;
            end loop;
            if Ends_Empty then
               Set_Tag (Msg.Tags, "", "");   --  (as "" and "a;" do)
            end if;
         end;
      end if;

      if Tree.After_tags.Prefix_part /= null then
         for P of Tree.After_tags.Prefix_part.Prefix_part_1 loop
            Read_Prefix (P.all);
         end loop;
      end if;
      Read_Rest (Tree.After_tags.Rest.all);
      return Msg;
   end From_Tree;

   function Parse (Line : String) return Message is
      Clean : constant String := Trim_Trailing_CRLF (Line);
   begin
      if Clean = "" then
         raise Soja.Irc.Messages.Parse_Error;
      end if;
      declare
         Tree : Irc_Wire.Message_Type :=
           Irc_Wire.Parser.Parse_Text (Soja.Utf8.Escape_Invalid (Clean));
         Msg  : constant Message := From_Tree (Tree);
      begin
         Irc_Wire.Parser.Free_Message (Tree);
         return Msg;
      end;
   exception
      when Irc_Wire.Parser.Parse_Error =>
         raise Soja.Irc.Messages.Parse_Error;
   end Parse;

end Soja.Irc.Hbnf;
