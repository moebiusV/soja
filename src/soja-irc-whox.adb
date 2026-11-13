pragma Ada_2022;

with Soja.Irc.Numerics;

package body Soja.Irc.Whox is

   use Soja.Irc.Messages;

   --  All WHOX field letters, by order of appearance in RPL_WHOSPCRPL.
   All_Fields : constant String := "tcuihsnfdlaor";

   function Has (Fields : String; C : Character) return Boolean is
   begin
      for F of Fields loop
         if F = C then
            return True;
         end if;
      end loop;
      return False;
   end Has;

   --  The hostname cannot start with a colon, as this would get parsed as a
   --  trailing parameter: IPv6 addresses such as "::1" get a leading zero.
   function Safe_Hostname (Host : Unbounded_String) return String is
      H : constant String := To_String (Host);
   begin
      return (if H'Length > 0 and then H (H'First) = ':' then "0" & H else H);
   end Safe_Hostname;

   function Channel_Or_Star (Info : Whox_Info) return String is
     (if Length (Info.Channel) = 0 then "*" else To_String (Info.Channel));

   --  info.get(k)
   function Get (Info : Whox_Info; K : Character) return String is
   begin
      case K is
         when 't'    => return To_String (Info.Token);
         when 'c'    => return Channel_Or_Star (Info);
         when 'u'    => return To_String (Info.Username);
         when 'i'    => return "255.255.255.255";
         when 'h'    => return Safe_Hostname (Info.Hostname);
         when 's'    => return To_String (Info.Server);
         when 'n'    => return To_String (Info.Nickname);
         when 'f'    => return To_String (Info.Flags);
         when 'd'    => return "0";
         when 'l'    => return "0";   --  idle time
         when 'a'    =>
            --  WHOX uses "0" to mean "no account".
            if Length (Info.Account) > 0
              and then To_String (Info.Account) /= "*"
            then
               return To_String (Info.Account);
            end if;
            return "0";
         when 'o'    => return "0";
         when 'r'    => return To_String (Info.Realname);
         when others => return "";
      end case;
   end Get;

   --  info.set(k, v)
   procedure Set (Info : in out Whox_Info; K : Character; V : String) is
      U : constant Unbounded_String := To_Unbounded_String (V);
   begin
      case K is
         when 't'    => Info.Token := U;
         when 'c'    => Info.Channel := U;
         when 'u'    => Info.Username := U;
         when 'h'    => Info.Hostname := U;
         when 's'    => Info.Server := U;
         when 'n'    => Info.Nickname := U;
         when 'f'    => Info.Flags := U;
         when 'a'    => Info.Account := U;
         when 'r'    => Info.Realname := U;
         when others => null;
      end case;
   end Set;

   -------------------------
   -- Generate_Whox_Reply --
   -------------------------

   function Generate_Whox_Reply
     (Fields : String; Info : Whox_Info) return Message
   is
      M : Message := (others => <>);

      procedure Add (S : String) is
      begin
         M.Params.Append (To_Unbounded_String (S));
      end Add;
   begin
      if Fields = "" then
         M.Command := To_Unbounded_String (Soja.Irc.Numerics.RPL_WHOREPLY);
         Add ("*");
         Add (Channel_Or_Star (Info));
         Add (To_String (Info.Username));
         Add (Safe_Hostname (Info.Hostname));
         Add (To_String (Info.Server));
         Add (To_String (Info.Nickname));
         Add (To_String (Info.Flags));
         Add ("0 " & To_String (Info.Realname));
         return M;
      end if;

      M.Command := To_Unbounded_String (Soja.Irc.Numerics.RPL_WHOSPCRPL);
      Add ("*");
      for F of All_Fields loop
         if Has (Fields, F) then
            Add (Get (Info, F));
         end if;
      end loop;
      return M;
   end Generate_Whox_Reply;

   ------------------------
   -- Parse_Whox_Options --
   ------------------------

   procedure Parse_Whox_Options
     (Options : String;
      Fields  : out Unbounded_String;
      Token   : out Unbounded_String)
   is
      Pct : Natural := 0;
   begin
      Fields := Null_Unbounded_String;
      Token := Null_Unbounded_String;
      for I in Options'Range loop
         if Options (I) = '%' then
            Pct := I;
            exit;
         end if;
      end loop;
      if Pct = 0 then
         return;
      end if;

      --  TODO (Go): add support for WHOX flags before the '%'.
      declare
         Rest  : constant String := Options (Pct + 1 .. Options'Last);
         Comma : Natural := 0;
      begin
         for I in Rest'Range loop
            if Rest (I) = ',' then
               Comma := I;
               exit;
            end if;
         end loop;

         declare
            Raw : constant String :=
              (if Comma = 0 then Rest else Rest (Rest'First .. Comma - 1));
            F   : String := Raw;
         begin
            for C of F loop
               if C in 'A' .. 'Z' then
                  C := Character'Val (Character'Pos (C) + 32);
               end if;
            end loop;
            Fields := To_Unbounded_String (F);
            if Comma /= 0 and then Has (F, 't') then
               Token := To_Unbounded_String (Rest (Comma + 1 .. Rest'Last));
            end if;
         end;
      end;
   end Parse_Whox_Options;

   ----------------------
   -- Parse_Whox_Reply --
   ----------------------

   function Parse_Whox_Reply
     (Msg : Message; Fields : String) return Whox_Info
   is
      Info : Whox_Info;
      Next : Positive := 2;   --  Params (1) is the target
   begin
      if To_String (Msg.Command) /= Soja.Irc.Numerics.RPL_WHOSPCRPL then
         raise Whox_Error with
           "invalid WHOX reply """ & To_String (Msg.Command) & """";
      elsif Msg.Params.Is_Empty then
         raise Whox_Error with "invalid RPL_WHOSPCRPL: no params";
      end if;

      for F of All_Fields loop
         if Has (Fields, F) then
            if Next > Natural (Msg.Params.Length) then
               raise Whox_Error with
                 "invalid RPL_WHOSPCRPL: missing value for field """
                 & F & """";
            end if;
            Set (Info, F, To_String (Msg.Params (Next)));
            Next := Next + 1;
         end if;
      end loop;
      return Info;
   end Parse_Whox_Reply;

end Soja.Irc.Whox;
