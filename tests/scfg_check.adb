pragma Ada_2022;

with Ada.Text_IO;
with Ada.Strings.Unbounded;
with Ada.Exceptions;
with Scfg;
with Scfg.Parser;
with Soja.Config;

procedure Scfg_Check is
   use Ada.Strings.Unbounded;
   use type Scfg.Directive_Access;

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
         if E.Directive /= null then
            Directives := Directives + 1;
            declare
               D : Scfg.Directive_Type renames E.Directive.all;
            begin
               Ada.Text_IO.Put (To_String (D.Word));
               for P of D.Directive_1 loop
                  Ada.Text_IO.Put (" ");
                  if Length (P.Word) /= 0 then
                     Ada.Text_IO.Put (To_String (P.Word));
                  else
                     Ada.Text_IO.Put (To_String (P.Str));
                  end if;
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
exception
   when Scfg.Parser.Parse_Error =>
      Ada.Text_IO.Put_Line ("PARSE ERROR");
   when E : others =>
      Ada.Text_IO.Put_Line ("FAIL: " & Ada.Exceptions.Exception_Message (E));
end Scfg_Check;
