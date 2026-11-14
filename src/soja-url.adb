pragma Ada_2022;

with Ada.Characters.Handling;
with Ada.Containers.Indefinite_Vectors;

with Url_Parts;
with Url_Parts.Parser;

package body Soja.Url is

   package String_Vectors is new Ada.Containers.Indefinite_Vectors
     (Positive, String);

   function Clean_Path (P : String) return String is
      Parts : String_Vectors.Vector;
      From  : Positive := P'First;
      Result : Unbounded_String;

      procedure Take (Segment : String) is
      begin
         if Segment = "" or else Segment = "." then
            null;
         elsif Segment = ".." then
            if not Parts.Is_Empty then
               Parts.Delete_Last;   --  (the root is its own parent)
            end if;
         else
            Parts.Append (Segment);
         end if;
      end Take;
   begin
      for I in P'Range when P (I) = '/' loop
         Take (P (From .. I - 1));
         From := I + 1;
      end loop;
      Take (P (From .. P'Last));
      for Part of Parts loop
         Append (Result, (if Length (Result) > 0 then "/" else "") & Part);
      end loop;
      return To_String (Result);
   end Clean_Path;

   function Path_Base (P : String) return String is
      Last : Natural := P'Last;
   begin
      if P = "" then
         return ".";
      end if;
      while Last >= P'First and then P (Last) = '/' loop
         Last := Last - 1;
      end loop;
      if Last < P'First then
         return "/";
      end if;
      declare
         First : Natural := Last;
      begin
         while First > P'First and then P (First - 1) /= '/' loop
            First := First - 1;
         end loop;
         return P (First .. Last);
      end;
   end Path_Base;

   --  url.PathEscape: everything but the unreserved characters and "$&+=:@".
   function Path_Escape (S : String) return String is
      Hex    : constant String := "0123456789ABCDEF";
      Result : Unbounded_String;
   begin
      for C of S loop
         if C in 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '-' | '_' | '.' | '~'
                 | '$' | '&' | '+' | '=' | ':' | '@'
         then
            Append (Result, C);
         else
            Append (Result, '%');
            Append (Result, Hex (Character'Pos (C) / 16 + 1));
            Append (Result, Hex (Character'Pos (C) mod 16 + 1));
         end if;
      end loop;
      return To_String (Result);
   end Path_Escape;

   function Hex_Value (C : Character) return Integer is
     (case C is
         when '0' .. '9' => Character'Pos (C) - Character'Pos ('0'),
         when 'a' .. 'f' => Character'Pos (C) - Character'Pos ('a') + 10,
         when 'A' .. 'F' => Character'Pos (C) - Character'Pos ('A') + 10,
         when others     => -1);

   function Path_Unescape (S : String; Ok : out Boolean) return String is
      Result : Unbounded_String;
      I      : Natural := S'First;
   begin
      Ok := True;
      while I <= S'Last loop
         if S (I) = '%' then
            if I + 2 > S'Last or else Hex_Value (S (I + 1)) < 0
              or else Hex_Value (S (I + 2)) < 0
            then
               Ok := False;
               return "";
            end if;
            Append (Result, Character'Val
              (Hex_Value (S (I + 1)) * 16 + Hex_Value (S (I + 2))));
            I := I + 3;
         else
            Append (Result, S (I));
            I := I + 1;
         end if;
      end loop;
      return To_String (Result);
   end Path_Unescape;

   --  url.QueryEscape: everything but the unreserved characters, a blank as
   --  "+".
   function Query_Escape (S : String) return String is
      Hex    : constant String := "0123456789ABCDEF";
      Result : Unbounded_String;
   begin
      for C of S loop
         if C in 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '-' | '_' | '.' | '~'
         then
            Append (Result, C);
         elsif C = ' ' then
            Append (Result, '+');
         else
            Append (Result, '%');
            Append (Result, Hex (Character'Pos (C) / 16 + 1));
            Append (Result, Hex (Character'Pos (C) mod 16 + 1));
         end if;
      end loop;
      return To_String (Result);
   end Query_Escape;

   ----------------------------------------------------------------------
   --  Parse
   ----------------------------------------------------------------------

   procedure Parse (Text : String; P : out Parts; Ok : out Boolean) is
      use Url_Parts;

      Tree : Url_Type;
      Good : Boolean := True;

      function Unescaped (S : Unbounded_String) return Unbounded_String is
         Valid : Boolean;
         Plain : constant String := Path_Unescape (To_String (S), Valid);
      begin
         Good := Good and then Valid;
         return To_Unbounded_String (Plain);
      end Unescaped;

      procedure Read_Host_Port (HP : Host_port_Type) is
      begin
         if HP.Bracketed_port /= null then
            P.Host := HP.Bracketed_port.Ipv6;
            P.Port := HP.Bracketed_port.Port;
         elsif HP.Bracketed_only /= null then
            P.Host := HP.Bracketed_only.Ipv6;
         elsif HP.Plain_host_port.Host_with_port /= null then
            P.Host := HP.Plain_host_port.Host_with_port.Host;
            P.Port := HP.Plain_host_port.Host_with_port.Port;
         else
            P.Host := HP.Plain_host_port.Host_only.Host_name_1;
         end if;
      end Read_Host_Port;
   begin
      P := (others => <>);
      begin
         Tree := Url_Parts.Parser.Parse_Text (Text);
      exception
         when Url_Parts.Parser.Parse_Error | Constraint_Error =>
            Ok := False;
            return;
      end;
      P.Scheme := To_Unbounded_String
        (Ada.Characters.Handling.To_Lower (To_String (Tree.Scheme)));
      for Chars of Tree.Path loop
         P.Path := Chars;
      end loop;
      if Tree.Authority.With_user /= null then
         declare
            U : Userinfo_Type renames Tree.Authority.With_user.Userinfo.all;
         begin
            P.Has_User := True;
            if U.User_pass /= null then
               P.User := Unescaped (U.User_pass.User_name);
               P.Password := Unescaped (U.User_pass.Password);
               P.Has_Password := True;
            else
               P.User := Unescaped (U.User_only.User_name_1);
            end if;
            Read_Host_Port (Tree.Authority.With_user.Host_port.all);
         end;
      else
         Read_Host_Port (Tree.Authority.Without_user.Host_port.all);
      end if;
      Url_Parts.Parser.Free_Url (Tree);
      Ok := Good;
   end Parse;

end Soja.Url;
