pragma Ada_2022;

with Ada.Characters.Handling;

with Json_Doc;
with Json_Doc.Parser;
with Soja.Utf8;

package body Soja.Json is

   use Ada.Strings.Unbounded;
   use Json_Doc;

   use type Json_Doc.Object_Access;
   use type Json_Doc.Array_Access;

   function Lower (S : String) return String is
     (Ada.Characters.Handling.To_Lower (S));

   ----------------------------------------------------------------------
   --  Strings
   ----------------------------------------------------------------------

   function Hex_Value (C : Character) return Natural is
     (case C is
         when '0' .. '9' => Character'Pos (C) - Character'Pos ('0'),
         when 'a' .. 'f' => Character'Pos (C) - Character'Pos ('a') + 10,
         when 'A' .. 'F' => Character'Pos (C) - Character'Pos ('A') + 10,
         when others     => 0);

   --  A code point as UTF-8.
   function Utf8 (Cp : Natural) return String is
     (if Cp < 16#80# then "" & Character'Val (Cp)
      elsif Cp < 16#800# then
        Character'Val (16#C0# + Cp / 64) & Character'Val (16#80# + Cp mod 64)
      elsif Cp < 16#10000# then
        Character'Val (16#E0# + Cp / 4096)
        & Character'Val (16#80# + (Cp / 64) mod 64)
        & Character'Val (16#80# + Cp mod 64)
      else
        Character'Val (16#F0# + Cp / 262_144)
        & Character'Val (16#80# + (Cp / 4096) mod 64)
        & Character'Val (16#80# + (Cp / 64) mod 64)
        & Character'Val (16#80# + Cp mod 64));

   function Decode_String (Literal : String) return String is
      Result : Unbounded_String;
      I      : Natural := Literal'First + 1;
      Last   : constant Natural := Literal'Last - 1;

      function Unit (At_I : Natural) return Natural is
        (((Hex_Value (Literal (At_I)) * 16 + Hex_Value (Literal (At_I + 1)))
          * 16 + Hex_Value (Literal (At_I + 2))) * 16
         + Hex_Value (Literal (At_I + 3)));
   begin
      while I <= Last loop
         if Literal (I) /= '\' then
            Append (Result, Literal (I));
            I := I + 1;
         else
            case Literal (I + 1) is
               when 'b' => Append (Result, ASCII.BS);
               when 'f' => Append (Result, ASCII.FF);
               when 'n' => Append (Result, ASCII.LF);
               when 'r' => Append (Result, ASCII.CR);
               when 't' => Append (Result, ASCII.HT);
               when 'u' =>
                  declare
                     Cp : Natural := Unit (I + 2);
                  begin
                     --  A surrogate pair is one character.
                     if Cp in 16#D800# .. 16#DBFF#
                       and then I + 11 <= Last
                       and then Literal (I + 6) = '\'
                       and then Literal (I + 7) = 'u'
                       and then Unit (I + 8) in 16#DC00# .. 16#DFFF#
                     then
                        Cp := 16#10000# + (Cp - 16#D800#) * 1024
                          + (Unit (I + 8) - 16#DC00#);
                        I := I + 6;
                     elsif Cp in 16#D800# .. 16#DFFF# then
                        Cp := 16#FFFD#;   --  a lone surrogate
                     end if;
                     Append (Result, Utf8 (Cp));
                     I := I + 4;
                  end;
               when others => Append (Result, Literal (I + 1));   -- " \ /
            end case;
            I := I + 2;
         end if;
      end loop;
      return To_String (Result);
   end Decode_String;

   ----------------------------------------------------------------------
   --  The members of the top-level object
   ----------------------------------------------------------------------

   --  Calls Visit for each member in order; the tree is released after.
   generic
      with procedure Visit (Name : String; Value : Value_Type);
   procedure Each_Member (Doc : String);

   procedure Each_Member (Doc : String) is
      Tree : Json_Type;
   begin
      begin
         Tree := Json_Doc.Parser.Parse_Text (Soja.Utf8.To_Valid (Doc));
      exception
         when Json_Doc.Parser.Parse_Error | Constraint_Error =>
            raise Parse_Error;
      end;
      if Tree.Object = null then
         Json_Doc.Parser.Free_Value (Tree);
         raise Parse_Error;
      end if;
      for E of Tree.Object.Object_1 loop
         Visit (Decode_String (To_String (E.Member.String)),
                E.Member.Value.all);
         for X of E.Object_1_1 loop
            Visit (Decode_String (To_String (X.Member.String)),
                   X.Member.Value.all);
         end loop;
      end loop;
      Json_Doc.Parser.Free_Value (Tree);
   exception
      when others =>
         Json_Doc.Parser.Free_Value (Tree);
         raise;
   end Each_Member;

   --  Whether Wanted names a member (exactly, else in any case: the last
   --  exact match wins over a match in another case, as encoding/json has it,
   --  but a later one of the same kind replaces an earlier).
   function Matches (Member, Wanted : String) return Boolean is
     (Member = Wanted or else Lower (Member) = Lower (Wanted));

   function Is_Null (V : Value_Type) return Boolean is
     (Length (V.Literal_null) > 0);

   procedure String_Member
     (Doc, Name : String;
      Value     : out Unbounded_String;
      Found     : out Boolean)
   is
      procedure Visit (Member : String; V : Value_Type) is
      begin
         if Matches (Member, Name) and then not Is_Null (V) then
            if Length (V.String) = 0 then
               raise Type_Error with Name & " is not a string";
            end if;
            Value := To_Unbounded_String (Decode_String (To_String (V.String)));
            Found := True;
         end if;
      end Visit;
      procedure Walk is new Each_Member (Visit);
   begin
      Value := Null_Unbounded_String;
      Found := False;
      Walk (Doc);
   end String_Member;

   procedure Bool_Member
     (Doc, Name : String; Value : out Boolean; Found : out Boolean)
   is
      procedure Visit (Member : String; V : Value_Type) is
      begin
         if Matches (Member, Name) and then not Is_Null (V) then
            if Length (V.Literal_true) > 0 then
               Value := True;
            elsif Length (V.Literal_false) > 0 then
               Value := False;
            else
               raise Type_Error with Name & " is not a boolean";
            end if;
            Found := True;
         end if;
      end Visit;
      procedure Walk is new Each_Member (Visit);
   begin
      Value := False;
      Found := False;
      Walk (Doc);
   end Bool_Member;

   procedure Strings_Member
     (Doc, Name : String;
      Values    : out Soja.Irc.Genmsg.String_Vectors.Vector;
      Found     : out Boolean)
   is
      procedure Add (V : Value_Type) is
      begin
         if Is_Null (V) then
            Values.Append ("");
         elsif Length (V.String) > 0 then
            Values.Append (Decode_String (To_String (V.String)));
         else
            raise Type_Error with Name & " holds something that is not a string";
         end if;
      end Add;

      procedure Visit (Member : String; V : Value_Type) is
      begin
         if Matches (Member, Name) and then not Is_Null (V) then
            if V.hyper_Array = null then
               raise Type_Error with Name & " is not an array";
            end if;
            Values.Clear;   --  (the last one of the name wins)
            for E of V.hyper_Array.Array_1 loop
               Add (E.Value.all);
               for X of E.Array_1_1 loop
                  Add (X.Value.all);
               end loop;
            end loop;
            Found := True;
         end if;
      end Visit;
      procedure Walk is new Each_Member (Visit);
   begin
      Values.Clear;
      Found := False;
      Walk (Doc);
   end Strings_Member;

end Soja.Json;
