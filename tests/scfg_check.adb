pragma Ada_2022;

with Ada.Text_IO;
with Ada.Strings.Unbounded;
with Ada.Exceptions;
with GNAT.OS_Lib;
with Scfg;
with Scfg.Parser;
with Soja.Config;

procedure Scfg_Check is
   use Ada.Strings.Unbounded;
   use type Scfg.Directive_line_Access;

   LF : constant Character := ASCII.LF;

   Config : constant String :=
     "listen ircs://" & LF &
     "# a whole-line comment" & LF &
     "db sqlite3 /var/lib/soju/main.db" & LF &
     LF &
     "  # an indented comment" & LF &
     "hostname example.org" & LF &
     "tls cert.pem key.pem" & LF &
     "listen :6697  # trailing comment (lexer eats it)" & LF &
     "max-user-networks 10" & LF &
     "enable-user-on-auth true" & LF &
     "accept-proxy-ip localhost 10.0.0.0/8" & LF &
     "disable-inactive-user 30d" & LF &
     "message-store db" & LF &
     "auth oauth2 ""https://auth.example.com""" & LF &
     "http-origin https://example.com" & LF;

   Directives : Natural := 0;

begin
   --  1. The raw grammar: comments and blank lines must be skipped, and each
   --     directive must surface once with its parameters.
   declare
      Tree : constant Scfg.Config_Type := Scfg.Parser.Parse_Text (Config);
   begin
      for E of Tree loop
         if E.Directive_line /= null then
            Directives := Directives + 1;
            declare
               D : Scfg.Directive_Type renames E.Directive_line.Directive.all;
            begin
               Ada.Text_IO.Put (To_String (D.Name));
               for P of D.Params loop
                  Ada.Text_IO.Put (" " & To_String (P.Value));
               end loop;
               Ada.Text_IO.New_Line;
            end;
         end if;
      end loop;
   end;

   --  2. The walker: typed Server, with string unescaping and validation.
   declare
      S : constant Soja.Config.Server := Soja.Config.Parse (Config);
   begin
      if Directives /= 12 then
         raise Program_Error with "expected 12 directives, got"
           & Natural'Image (Directives);
      end if;
      if Natural (S.Listen.Length) /= 2 then
         raise Program_Error with "expected 2 listen URIs";
      end if;
      if To_String (S.Hostname) /= "example.org" then
         raise Program_Error with "hostname wrong";
      end if;
      --  The default http-ingress follows the configured hostname.
      if To_String (S.HTTP_Ingress) /= "https://example.org" then
         raise Program_Error with "http-ingress default wrong: "
           & To_String (S.HTTP_Ingress);
      end if;
      if S.TLS = null
        or else To_String (S.TLS.all.Cert_Path) /= "cert.pem"
        or else To_String (S.TLS.all.Key_Path) /= "key.pem"
      then
         raise Program_Error with "tls wrong";
      end if;
      if To_String (S.DB.Driver) /= "sqlite3" then
         raise Program_Error with "db driver wrong";
      end if;
      if To_String (S.Msg_Store.Driver) /= "db" then
         raise Program_Error with "message-store wrong";
      end if;
      if To_String (S.Auth.Driver) /= "oauth2"
        or else To_String (S.Auth.Source) /= "https://auth.example.com"
      then
         raise Program_Error with "auth wrong (unescape?)";
      end if;
      if S.Max_User_Networks /= 10 then
         raise Program_Error with "max-user-networks wrong";
      end if;
      if not S.Enable_Users_On_Auth then
         raise Program_Error with "enable-user-on-auth wrong";
      end if;
      if Natural (S.Accept_Proxy_IPs.Length) /= 3 then
         raise Program_Error with "accept-proxy-ip wrong (localhost = 2 nets)";
      end if;
      if S.Disable_Inactive_Users_Delay <= 0.0 then
         raise Program_Error with "disable-inactive-user wrong";
      end if;
      if Natural (S.HTTP_Origins.Length) /= 1 then
         raise Program_Error with "http-origin wrong";
      end if;

      Ada.Text_IO.Put_Line ("OK");
   end;

   --  3. The syntax: quotes, escapes, comments, line ends.
   declare
      function Title (Text : String) return String is
        (To_String (Soja.Config.Parse (Text).Title));

      function Fails (Text : String) return Boolean is
      begin
         declare
            S : constant Soja.Config.Server := Soja.Config.Parse (Text);
            pragma Unreferenced (S);
         begin
            return False;
         end;
      exception
         when Soja.Config.Config_Error => return True;
      end Fails;

      procedure Check (Cond : Boolean; What : String) is
      begin
         if not Cond then
            raise Program_Error with What;
         end if;
      end Check;
   begin
      Check (Title ("title plain") = "plain", "a bareword");
      Check (Title ("title ""two words""") = "two words", "double quotes");
      Check (Title ("title 'two words'") = "two words", "single quotes");
      Check (Title ("title ""a\"" b""") = "a"" b", "an escaped quote");
      Check (Title ("title ""a\\b""") = "a\b", "an escaped backslash");
      Check (Title ("title 'a\b'") = "a\b", "single quotes keep a backslash");
      Check (Title ("title ""it's""") = "it's", "a quote of the other kind");
      Check (Title ("title a\ b") = "a b", "an escaped space in a bareword");
      Check (Title ("title /var/lib/(x)/[y]~,;:!&^|<>{}") = "/var/lib/(x)/[y]~,;:!&^|<>{}",
             "a bareword takes what a lexer of letters would not");
      Check (Title ("title x   # a comment") = "x", "a trailing comment");
      Check (Title ("title ""x # not a comment""") = "x # not a comment",
             "# inside quotes");
      Check (Title ("   title x" & LF) = "x", "an indented directive");
      Check (Title ("title x") = "x", "no line end at the end of the file");
      Check (Title ("title x" & ASCII.CR & LF & "hostname h" & ASCII.CR & LF) = "x",
             "CR LF line ends");
      Check (Title (LF & LF & "  " & LF & "# c" & LF & "title x" & LF & "#" ) = "x",
             "blank lines and comments");
      Check (Title ("title ""h" & Character'Val (16#E9#) & "llo""")
             = "h" & Character'Val (16#E9#) & "llo", "bytes that are not UTF-8");
      Check (Title ("title ""h" & Character'Val (16#C3#) & Character'Val (16#A9#) & "llo""")
             = "h" & Character'Val (16#C3#) & Character'Val (16#A9#) & "llo", "UTF-8");

      Check (Fails ("title ""open"), "an unterminated quote");
      Check (Fails ("title 'open"), "an unterminated single quote");
      Check (Fails ("title ""a""b"), "a word after a quoted string");
      Check (Fails ("title a""b"""), "a quote in a bareword");
      Check (Fails ("title a\"), "a backslash at the end of the line");
      Check (Fails ("title ""a" & LF & "b"""), "a string over a line");
      Check (Fails ("nonsense x"), "an unknown directive");
      Check (Fails ("title"), "a missing parameter");

      --  Drivers: the message store is the database when none is named; a
      --  driver that needs no source refuses one, as soju does.
      Check (To_String (Soja.Config.Parse ("title x").Msg_Store.Driver) = "db",
             "the default message store is the database");
      Check (To_String (Soja.Config.Parse ("message-store memory").Msg_Store
                          .Driver) = "memory", "message-store memory");
      Check (To_String (Soja.Config.Parse ("message-store fs /tmp/x")
                          .Msg_Store.Source) = "/tmp/x", "message-store fs");
      Check (Fails ("message-store db /tmp/x"), "db takes no source");
      Check (Fails ("message-store memory x"), "memory takes no source");
      Check (Fails ("message-store fs"), "fs needs a source");
      Check (Fails ("auth internal x"), "internal takes no source");
      Check (Fails ("auth pam x"), "pam takes no source");
      Check (Fails ("auth oauth2"), "oauth2 needs a source");
   end;
   Ada.Text_IO.Put_Line ("ALL PASS");
exception
   when Scfg.Parser.Parse_Error =>
      Ada.Text_IO.Put_Line ("PARSE ERROR");
      GNAT.OS_Lib.OS_Exit (1);
   when E : others =>
      Ada.Text_IO.Put_Line ("FAIL: " & Ada.Exceptions.Exception_Message (E));
      GNAT.OS_Lib.OS_Exit (1);
end Scfg_Check;
