--  Soja.Config — the port of soju's config/config.go (the Load walk).
pragma Ada_2022;

with Ada.Text_IO;
with GNAT.Sockets;

with Scfg;
with Scfg.Parser;

package body Soja.Config is

   use Ada.Strings.Unbounded;
   use type Scfg.Directive_Access;

   ----------
   -- Helpers (private to the body; config.go's unexported functions) --
   ----------

   --  Unescape a quoted-string token: the Scfg lexer returns the whole
   --  `"..."` (quotes kept, backslashes kept).  go-scfg's splitWords drops
   --  the quotes and treats `\` as an escape for the next byte (no C-style
   --  escapes), so `\"` is `"`, `\\` is `\`, and `\n` is a literal `n`.
   function Unescape (S : String) return Unbounded_String is
      R : Unbounded_String;
      I : Natural := S'First;
   begin
      if S'Length >= 2 and then S (S'First) = '"' then
         I := S'First + 1;
      end if;
      while I <= S'Last loop
         declare
            C : constant Character := S (I);
         begin
            if C = '"' and then I = S'Last then
               null;                       -- the closing quote
            elsif C = '\' and then I < S'Last then
               I := I + 1;
               Append (R, S (I));          -- escape: drop the backslash
            else
               Append (R, C);
            end if;
         end;
         I := I + 1;
      end loop;
      return R;
   end Unescape;

   --  The parameters of a directive as strings (barewords as-is, quoted
   --  strings unescaped).
   function Params (D : Scfg.Directive_Type) return String_Vectors.Vector is
      R : String_Vectors.Vector;
   begin
      for E of D.Directive_1 loop
         if Length (E.Word) /= 0 then
            R.Append (E.Word);
         else
            R.Append (Unescape (To_String (E.Str)));
         end if;
      end loop;
      return R;
   end Params;

   procedure Error (Msg : String) is
   begin
      raise Config_Error with Msg;
   end Error;

   --  parseDriverSource: exactly 1 or 2 parameters -> (driver, source).
   procedure Parse_Driver_Source
     (Name   : String;
      P      : String_Vectors.Vector;
      Driver : out Unbounded_String;
      Source : out Unbounded_String)
   is
   begin
      case Natural (P.Length) is
         when 2 =>
            Source := P (2);
            Driver := P (1);
         when 1 =>
            Driver := P (1);
         when others =>
            Error ("directive " & Name
                   & " requires exactly 1 or 2 parameters");
      end case;
   end Parse_Driver_Source;

   --  parseDuration: a decimal number with a trailing "d" (days), as
   --  config.go's parseDuration.  Returns the duration in days' worth of
   --  seconds (soju stores it as a time.Duration of v*24h).
   function Parse_Duration (S : String) return Duration is
      V : Float;
   begin
      if S'Length = 0 or else S (S'Last) /= 'd' then
         Error ("missing 'd' suffix in duration");
      end if;
      begin
         V := Float'Value (S (S'First .. S'Last - 1));
      exception
         when Constraint_Error =>
            Error ("invalid duration: " & S (S'First .. S'Last - 1));
      end;
      return Duration (V * 24.0 * 3600.0);
   end Parse_Duration;

   --  strconv.ParseBool's accepted spellings.
   function Parse_Bool (S : String) return Boolean is
   begin
      if S = "1" or else S = "t" or else S = "T"
        or else S = "true" or else S = "TRUE" or else S = "True"
      then
         return True;
      elsif S = "0" or else S = "f" or else S = "F"
        or else S = "false" or else S = "FALSE" or else S = "False"
      then
         return False;
      else
         Error ("invalid bool parameter """ & S & '"');
      end if;
   end Parse_Bool;

   --  strconv.ParseInt (base 10).
   function Parse_Int (S : String) return Integer is
      V : Integer;
   begin
      begin
         V := Integer'Value (S);
      exception
         when Constraint_Error =>
            Error ("invalid integer parameter """ & S & '"');
      end;
      return V;
   end Parse_Int;

   --  net.ParseCIDR: parse "a.b.c.d/len" or "hex:.../len" into an IPNet.
   function Parse_CIDR (S : String) return IPNet is
      Slash : Natural := 0;
      Addr  : IP_Addr := (others => 0);
      Prefix : Natural := 0;
      Is_V4 : Boolean := False;

      function Hex_Digit (C : Character) return Natural is
      begin
         case C is
            when '0' .. '9' => return Character'Pos (C) - Character'Pos ('0');
            when 'a' .. 'f' => return Character'Pos (C) - Character'Pos ('a')
              + 10;
            when 'A' .. 'F' => return Character'Pos (C) - Character'Pos ('A')
              + 10;
            when others     => return 99;
         end case;
      end Hex_Digit;

      --  Parse the address part (before the slash) and fill Addr.
      procedure Parse_Address (A : String) is
         Dot       : Natural := 0;
         Has_Colon : Boolean := False;
      begin
         --  v4: contains '.' and no ':'
         for I in A'Range loop
            if A (I) = ':' then
               Has_Colon := True;
               exit;
            elsif A (I) = '.' then
               Dot := Dot + 1;
            end if;
         end loop;

         if Dot = 3 and then not Has_Colon then
            --  IPv4 dotted-quad.
            Is_V4 := True;
            declare
               Octet : Natural := 0;
               N     : Natural := 0;
               Idx   : Natural := 12;   -- v4-mapped position
            begin
               for I in A'Range loop
                  if A (I) = '.' then
                     if Octet > 255 then
                        Error ("failed to parse CIDR: " & A);
                     end if;
                     Addr (Idx) := Unsigned_8 (Octet);
                     Idx := Idx + 1;
                     Octet := 0;
                     N := 0;
                  elsif A (I) in '0' .. '9' then
                     Octet := Octet * 10 + (Character'Pos (A (I)) -
                       Character'Pos ('0'));
                     N := N + 1;
                  else
                     Error ("failed to parse CIDR: " & A);
                  end if;
               end loop;
               if Octet > 255 then
                  Error ("failed to parse CIDR: " & A);
               end if;
               Addr (Idx) := Unsigned_8 (Octet);
               Addr (10) := 16#FF#;
               Addr (11) := 16#FF#;
            end;
         else
            --  IPv6: 8 groups with possible "::" compression.
            Is_V4 := False;
            declare
               Groups : array (0 .. 7) of Natural := (others => 0);
               G      : Integer := 0;      -- current group index
               Val    : Natural := 0;
               In_Val : Boolean := False;
               I      : Natural := A'First;
               Double : Integer := -1;     -- index where "::" was seen
            begin
               while I <= A'Last loop
                  if A (I) = ':' then
                     if In_Val then
                        Groups (G) := Val;
                        G := G + 1;
                        Val := 0;
                        In_Val := False;
                     end if;
                     if I < A'Last and then A (I + 1) = ':' then
                        Double := G;
                        I := I + 1;
                     end if;
                  else
                     declare
                        H : constant Natural := Hex_Digit (A (I));
                     begin
                        if H = 99 then
                           Error ("failed to parse CIDR: " & A);
                        end if;
                        Val := Val * 16 + H;
                        In_Val := True;
                     end;
                  end if;
                  I := I + 1;
               end loop;
               if In_Val then
                  Groups (G) := Val;
                  G := G + 1;
               end if;

               --  Expand "::" by shifting the tail to the end.
               declare
                  Expanded : array (0 .. 7) of Natural := (others => 0);
                  Shift    : constant Integer :=
                    (if Double >= 0 then 8 - G else 0);
               begin
                  if Double < 0 and then G /= 8 then
                     Error ("failed to parse CIDR: " & A);
                  end if;
                  for K in 0 .. G - 1 loop
                     if Double >= 0 and then K >= Double then
                        Expanded (K + Shift) := Groups (K);
                     else
                        Expanded (K) := Groups (K);
                     end if;
                  end loop;
                  for K in 0 .. 7 loop
                     Addr (2 * K)     := Unsigned_8 (Expanded (K) / 256);
                     Addr (2 * K + 1) := Unsigned_8 (Expanded (K) mod 256);
                  end loop;
               end;
            end;
         end if;
      end Parse_Address;

   begin
      for I in S'Range loop
         if S (I) = '/' then
            Slash := I;
            exit;
         end if;
      end loop;

      if Slash = 0 then
         Error ("failed to parse CIDR: " & S);
      end if;

      Parse_Address (S (S'First .. Slash - 1));

      begin
         Prefix := Integer'Value (S (Slash + 1 .. S'Last));
      exception
         when Constraint_Error =>
            Error ("failed to parse CIDR: " & S);
      end;

      if (Is_V4 and then Prefix > 32) or else (not Is_V4 and then Prefix >
        128) then
         Error ("failed to parse CIDR: " & S);
      end if;

      return (Family => (if Is_V4 then IPv4 else IPv6),
              Addr   => Addr,
              Prefix => Prefix);
   end Parse_CIDR;

   --  path.Match's ErrBadPattern checks, enough to validate an http-origin
   --  pattern: a trailing backslash or an unterminated `[...]` class.
   function Valid_Glob (P : String) return Boolean is
      I : Natural := P'First;
   begin
      while I <= P'Last loop
         case P (I) is
            when '\' =>
               if I = P'Last then
                  return False;
               end if;
               I := I + 2;
            when '[' =>
               I := I + 1;
               if I > P'Last then
                  return False;
               end if;
               if P (I) = ']' then
                  I := I + 1;   -- a leading ']' is a literal member
               end if;
               declare
                  Closed : Boolean := False;
               begin
                  while I <= P'Last loop
                     if P (I) = ']' then
                        Closed := True;
                        I := I + 1;
                        exit;
                     elsif P (I) = '\' then
                        I := I + 1;
                     end if;
                     I := I + 1;
                  end loop;
                  if not Closed then
                     return False;
                  end if;
               end;
            when others =>
               I := I + 1;
         end case;
      end loop;
      return True;
   end Valid_Glob;

   ---------
   -- Defaults --
   ---------

   function Defaults return Server is
      Host : Unbounded_String;
   begin
      begin
         Host := To_Unbounded_String (GNAT.Sockets.Host_Name);
      exception
         when others =>
            Host := To_Unbounded_String ("localhost");
      end;
      return Server'
        (Listen        => String_Vectors.Empty_Vector,
         TLS           => null,
         Hostname      => Host,
         Title         => Null_Unbounded_String,
         MOTD_Path     => Null_Unbounded_String,
         DB            => (Driver => To_Unbounded_String ("sqlite3"),
                           Source => To_Unbounded_String ("soju.db")),
         Msg_Store     => (Driver => To_Unbounded_String ("memory"),
                           Source => Null_Unbounded_String),
         Auth          => (Driver => To_Unbounded_String ("internal"),
                           Source => Null_Unbounded_String),
         File_Upload   => null,
         HTTP_Origins  => String_Vectors.Empty_Vector,
         HTTP_Ingress  => "https://" & Host,
         Accept_Proxy_IPs => IPNet_Vectors.Empty_Vector,
         Max_User_Networks => -1,
         Upstream_User_IPs => IPNet_Vectors.Empty_Vector,
         Disable_Inactive_Users_Delay => 0.0,
         Enable_Users_On_Auth => False);
   end Defaults;

   ---------
   -- Parse --
   ---------

   function Parse (Text : String) return Server is
      Tree : constant Scfg.Config_Type := Scfg.Parser.Parse_Text (Text);
      Srv  : Server := Defaults;

      --  raw message-store and its `log` alias, resolved after the walk
      Msg_Store_Raw : String_Vectors.Vector;
      Log_Raw       : String_Vectors.Vector;

      Has_Msg_Store : Boolean := False;
      Has_Log       : Boolean := False;
   begin
      for E of Tree loop
         if E.Directive = null then
            goto Next;   -- a blank or comment line: skip, don't stop
         end if;

         declare
            D      : Scfg.Directive_Type renames E.Directive.all;
            Name   : constant String := To_String (D.Word);
            P      : constant String_Vectors.Vector := Params (D);
            N      : constant Natural := Natural (P.Length);

            procedure Want (Count : Natural) is
            begin
               if N /= Count then
                  Error ("directive " & Name & " requires exactly "
                         & Count'Image & " parameter(s)");
               end if;
            end Want;

            procedure Want_At_Least (Count : Natural) is
            begin
               if N < Count then
                  Error ("directive " & Name & " requires at least "
                         & Count'Image & " parameter(s)");
               end if;
            end Want_At_Least;

         begin
            if Name = "listen" then
               Want (1);
               Srv.Listen.Append (P (1));

            elsif Name = "hostname" then
               Want (1);
               Srv.Hostname := P (1);

            elsif Name = "title" then
               Want (1);
               Srv.Title := P (1);

            elsif Name = "motd" then
               Want (1);
               Srv.MOTD_Path := P (1);

            elsif Name = "tls" then
               Want (2);
               Srv.TLS := new TLS'(Cert_Path => P (1), Key_Path => P (2));

            elsif Name = "db" then
               Want (2);
               Srv.DB := (Driver => P (1), Source => P (2));

            elsif Name = "message-store" then
               Msg_Store_Raw := P;
               Has_Msg_Store := True;

            elsif Name = "log" then
               Log_Raw := P;
               Has_Log := True;

            elsif Name = "auth" then
               declare
                  Driver, Source : Unbounded_String;
               begin
                  Parse_Driver_Source (Name, P, Driver, Source);
                  if Driver /= "internal" and then Driver /= "pam"
                    and then Driver /= "oauth2"
                  then
                     Error ("directive auth: unknown driver """ &
                            To_String (Driver) & '"');
                  elsif Driver = "oauth2" and then Length (Source) = 0 then
                     Error ("directive auth: driver """ & To_String (Driver)
                            & """ requires a source");
                  end if;
                  Srv.Auth := (Driver => Driver, Source => Source);
               end;

            elsif Name = "file-upload" then
               declare
                  Driver, Source : Unbounded_String;
               begin
                  Parse_Driver_Source (Name, P, Driver, Source);
                  if Driver /= "fs" then
                     Error ("directive file-upload: unknown driver """ &
                            To_String (Driver) & '"');
                  elsif Length (Source) = 0 then
                     Error ("directive file-upload: driver """ &
                            To_String (Driver) & """ requires a source");
                  end if;
                  Srv.File_Upload := new File_Upload'
                    (Driver => Driver, Source => Source);
               end;

            elsif Name = "http-origin" then
               Want_At_Least (1);
               for I in 1 .. N loop
                  if not Valid_Glob (To_String (P (I))) then
                     Error ("directive http-origin: " & To_String (P (I)));
                  end if;
               end loop;
               Srv.HTTP_Origins := P;

            elsif Name = "http-ingress" then
               Want (1);
               Srv.HTTP_Ingress := P (1);

            elsif Name = "accept-proxy-ip" then
               Want_At_Least (1);
               for I in 1 .. N loop
                  declare
                     S : constant String := To_String (P (I));
                  begin
                     if S = "localhost" then
                        Srv.Accept_Proxy_IPs.Append
                          (Parse_CIDR ("127.0.0.0/8"));
                        Srv.Accept_Proxy_IPs.Append (Parse_CIDR ("::1/128"));
                     else
                        Srv.Accept_Proxy_IPs.Append (Parse_CIDR (S));
                     end if;
                  end;
               end loop;

            elsif Name = "max-user-networks" then
               Want (1);
               Srv.Max_User_Networks := Parse_Int (To_String (P (1)));

            elsif Name = "upstream-user-ip" then
               Want_At_Least (1);
               declare
                  Has_V4, Has_V6 : Boolean := False;
               begin
                  for I in 1 .. N loop
                     declare
                        Nw : constant IPNet := Parse_CIDR (To_String (P (I)));
                     begin
                        if Nw.Family = IPv4 then
                           if Has_V4 then
                              Error
                                ("directive upstream-user-ip: "
                                 & "found two IPv4 CIDRs");
                           end if;
                           Has_V4 := True;
                        else
                           if Has_V6 then
                              Error
                                ("directive upstream-user-ip: "
                                 & "found two IPv6 CIDRs");
                           end if;
                           Has_V6 := True;
                        end if;
                        Srv.Upstream_User_IPs.Append (Nw);
                     end;
                  end loop;
               end;

            elsif Name = "disable-inactive-user" then
               Want (1);
               declare
                  Dur : constant Duration := Parse_Duration (To_String (P
                    (1)));
               begin
                  if Dur < 0.0 then
                     Error
                       ("directive disable-inactive-user: "
                        & "duration must be positive");
                  end if;
                  Srv.Disable_Inactive_Users_Delay := Dur;
               end;

            elsif Name = "enable-user-on-auth" then
               Want (1);
               Srv.Enable_Users_On_Auth := Parse_Bool (To_String (P (1)));

            else
               Error ("unknown directive " & Name);
            end if;
         end;
         <<Next>>
         null;
      end loop;

      --  message-store, with the deprecated `log` alias (config.go: if
      --  message-store is absent, log fills in).
      if Has_Msg_Store then
         null;
      elsif Has_Log then
         Msg_Store_Raw := Log_Raw;
      end if;

      if Has_Msg_Store or else Has_Log then
         declare
            Driver, Source : Unbounded_String;
         begin
            Parse_Driver_Source ("message-store", Msg_Store_Raw, Driver,
              Source);
            if Driver /= "memory" and then Driver /= "db"
              and then Driver /= "fs"
            then
               Error ("directive message-store: unknown driver """ &
                      To_String (Driver) & '"');
            elsif Driver = "fs" and then Length (Source) = 0 then
               Error ("directive message-store: driver """ & To_String (Driver)
                      & """ requires a source");
            end if;
            Srv.Msg_Store := (Driver => Driver, Source => Source);
         end;
      end if;

      return Srv;
   end Parse;

   ---------
   -- Load --
   ---------

   function Load (Filename : String) return Server is
      F : Ada.Text_IO.File_Type;
      Content : Unbounded_String;
      Line : String (1 .. 4096);
      Last : Natural;
   begin
      Ada.Text_IO.Open (F, Ada.Text_IO.In_File, Filename);
      begin
         while not Ada.Text_IO.End_Of_File (F) loop
            Ada.Text_IO.Get_Line (F, Line, Last);
            Append (Content, Line (1 .. Last));
            Append (Content, ASCII.LF);
         end loop;
      exception
         when others =>
            Ada.Text_IO.Close (F);
            raise;
      end;
      Ada.Text_IO.Close (F);
      return Parse (To_String (Content));
   exception
      when Ada.Text_IO.Name_Error =>
         raise Config_Error with "cannot open config file: " & Filename;
   end Load;

end Soja.Config;
