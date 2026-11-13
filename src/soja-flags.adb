pragma Ada_2022;

with Ada.Exceptions;

with Soja.Irc.Helpers;

package body Soja.Flags is

   use Soja.Irc.Genmsg.String_Vectors;

   function Find (FS : Flag_Set; Name : String) return Natural is
   begin
      for I in 1 .. Natural (FS.Defined.Length) loop
         if To_String (FS.Defined (I).Name) = Name then
            return I;
         end if;
      end loop;
      return 0;
   end Find;

   procedure Define (FS : in out Flag_Set; F : Flag) is
   begin
      FS.Defined.Append (F);
   end Define;

   procedure Add_String
     (FS : in out Flag_Set; Name : String; Default : String := "") is
   begin
      Define (FS, (Name => To_Unbounded_String (Name), Which => K_String,
                   Text => To_Unbounded_String (Default), others => <>));
   end Add_String;

   procedure Add_Bool
     (FS : in out Flag_Set; Name : String; Default : Boolean := False) is
   begin
      Define (FS, (Name => To_Unbounded_String (Name), Which => K_Bool,
                   Flag_B => Default, others => <>));
   end Add_Bool;

   procedure Add_Bool_Value (FS : in out Flag_Set; Name : String) is
   begin
      Define (FS, (Name => To_Unbounded_String (Name), Which => K_Bool_Value,
                   others => <>));
   end Add_Bool_Value;

   procedure Add_Int
     (FS : in out Flag_Set; Name : String; Default : Integer := 0) is
   begin
      Define (FS, (Name => To_Unbounded_String (Name), Which => K_Int,
                   Number => Default, others => <>));
   end Add_Int;

   procedure Add_List (FS : in out Flag_Set; Name : String) is
   begin
      Define (FS, (Name => To_Unbounded_String (Name), Which => K_List,
                   others => <>));
   end Add_List;

   function Parse_Bool (S : String) return Boolean is
   begin
      if S = "1" or else S = "t" or else S = "T" or else S = "TRUE"
        or else S = "true" or else S = "True"
      then
         return True;
      elsif S = "0" or else S = "f" or else S = "F" or else S = "FALSE"
        or else S = "false" or else S = "False"
      then
         return False;
      end if;
      raise Constraint_Error;
   end Parse_Bool;

   --  strconv.ParseInt (s, 0, 64) narrowed to Integer: "parse error" when
   --  malformed, "value out of range" when too big.
   function Parse_Int (S : String) return Integer is
      Pos      : Positive := S'First;
      Negative : Boolean := False;
      Base     : Natural := 10;
      Value    : Long_Long_Integer := 0;
      Digits_Seen : Boolean := False;
   begin
      if S'Length = 0 then
         raise Flag_Error with "parse error";
      end if;
      if S (Pos) = '+' or else S (Pos) = '-' then
         Negative := S (Pos) = '-';
         Pos := Pos + 1;
      end if;
      if Pos < S'Last and then S (Pos) = '0' then
         case S (Pos + 1) is
            when 'x' | 'X' => Base := 16; Pos := Pos + 2;
            when 'b' | 'B' => Base := 2;  Pos := Pos + 2;
            when 'o' | 'O' => Base := 8;  Pos := Pos + 2;
            when others    => Base := 8;  Pos := Pos + 1;
         end case;
         Digits_Seen := Base = 8 and then S (Pos - 1) = '0';
      end if;
      for K in Pos .. S'Last loop
         declare
            C : constant Character := S (K);
            D : Natural;
         begin
            if C in '0' .. '9' then
               D := Character'Pos (C) - Character'Pos ('0');
            elsif C in 'a' .. 'f' then
               D := Character'Pos (C) - Character'Pos ('a') + 10;
            elsif C in 'A' .. 'F' then
               D := Character'Pos (C) - Character'Pos ('A') + 10;
            else
               raise Flag_Error with "parse error";
            end if;
            if D >= Base then
               raise Flag_Error with "parse error";
            end if;
            Digits_Seen := True;
            if Value > (Long_Long_Integer (Integer'Last) + 1) / Long_Long_Integer (Base)
            then
               raise Flag_Error with "value out of range";
            end if;
            Value := Value * Long_Long_Integer (Base) + Long_Long_Integer (D);
         end;
      end loop;
      if not Digits_Seen then
         raise Flag_Error with "parse error";
      end if;
      if Negative then
         Value := -Value;
      end if;
      if Value > Long_Long_Integer (Integer'Last)
        or else Value < Long_Long_Integer (Integer'First)
      then
         raise Flag_Error with "value out of range";
      end if;
      return Integer (Value);
   end Parse_Int;

   --  flag.Value.Set; the error is Go's "invalid value ..." text.
   procedure Set_Value (F : in out Flag; Value : String) is
      function Invalid (Why : String) return String is
        ("invalid value " & Soja.Irc.Helpers.Quote (Value) & " for flag -"
         & To_String (F.Name) & ": " & Why);
   begin
      case F.Which is
         when K_String =>
            F.Text := To_Unbounded_String (Value);
         when K_List =>
            F.Items.Append (Value);
         when K_Bool | K_Bool_Value =>
            begin
               F.Flag_B := Parse_Bool (Value);
            exception
               when Constraint_Error =>
                  raise Flag_Error with Invalid
                    ("strconv.ParseBool: parsing "
                     & Soja.Irc.Helpers.Quote (Value)
                     & ": invalid syntax");
            end;
         when K_Int =>
            begin
               F.Number := Parse_Int (Value);
            exception
               when E : Flag_Error =>
                  raise Flag_Error with Invalid
                    (Ada.Exceptions.Exception_Message (E));
            end;
      end case;
      F.Seen := True;
   end Set_Value;

   procedure Parse (FS : in out Flag_Set; Args : String_Vector) is
      I : Natural := 1;
   begin
      FS.Rest.Clear;
      while I <= Natural (Args.Length) loop
         declare
            S : constant String := Args (I);
            Minuses : Natural := 1;
         begin
            --  A lone "-" or a word without a dash ends the flags.
            exit when S'Length < 2 or else S (S'First) /= '-';
            if S (S'First + 1) = '-' then
               Minuses := 2;
               if S'Length = 2 then   --  "--": the end, consumed
                  I := I + 1;
                  exit;
               end if;
            end if;
            I := I + 1;

            declare
               Name  : constant String := S (S'First + Minuses .. S'Last);
               Eq    : Natural := 0;
               Has_Value : Boolean := False;
            begin
               if Name'Length = 0 or else Name (Name'First) = '-'
                 or else Name (Name'First) = '='
               then
                  raise Flag_Error with "bad flag syntax: " & S;
               end if;
               for K in Name'Range loop
                  if Name (K) = '=' then
                     Eq := K;
                     Has_Value := True;
                     exit;
                  end if;
               end loop;

               declare
                  Key : constant String :=
                    (if Has_Value then Name (Name'First .. Eq - 1) else Name);
                  Idx : constant Natural := Find (FS, Key);
               begin
                  if Idx = 0 then
                     if Key = "help" or else Key = "h" then
                        raise Flag_Error with "flag: help requested";
                     end if;
                     raise Flag_Error with
                       "flag provided but not defined: -" & Key;
                  end if;

                  declare
                     F : Flag := FS.Defined (Idx);
                  begin
                     if Has_Value then
                        Set_Value (F, Name (Eq + 1 .. Name'Last));
                     elsif F.Which = K_Bool then
                        Set_Value (F, "true");
                     else
                        --  The value is the next argument.
                        if I > Natural (Args.Length) then
                           raise Flag_Error with
                             "flag needs an argument: -" & Key;
                        end if;
                        Set_Value (F, Args (I));
                        I := I + 1;
                     end if;
                     FS.Defined (Idx) := F;
                  end;
               end;
            end;
         end;
      end loop;

      while I <= Natural (Args.Length) loop
         FS.Rest.Append (Args (I));
         I := I + 1;
      end loop;
   end Parse;

   function Lookup (FS : Flag_Set; Name : String) return Flag is
      Idx : constant Natural := Find (FS, Name);
   begin
      if Idx = 0 then
         raise Program_Error with "undefined flag " & Name;
      end if;
      return FS.Defined (Idx);
   end Lookup;

   function Is_Set (FS : Flag_Set; Name : String) return Boolean is
     (Lookup (FS, Name).Seen);
   function Get (FS : Flag_Set; Name : String) return String is
     (To_String (Lookup (FS, Name).Text));
   function Get_Bool (FS : Flag_Set; Name : String) return Boolean is
     (Lookup (FS, Name).Flag_B);
   function Get_Int (FS : Flag_Set; Name : String) return Integer is
     (Lookup (FS, Name).Number);
   function Get_List (FS : Flag_Set; Name : String) return String_Vector is
     (Lookup (FS, Name).Items);

   function N_Arg (FS : Flag_Set) return Natural is
     (Natural (FS.Rest.Length));
   function Arg (FS : Flag_Set; I : Natural) return String is
     (if I < Natural (FS.Rest.Length) then FS.Rest (I + 1) else "");
   function Args (FS : Flag_Set) return String_Vector is (FS.Rest);

end Soja.Flags;
