--  soja: the bouncer daemon (soju's cmd/soju/main.go).
pragma Ada_2022;

with Ada.Command_Line;
with Ada.Environment_Variables;
with Ada.Directories;
with Ada.Exceptions;
with Ada.IO_Exceptions;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;
with Ada.Text_IO;

with AWS.Net;
with AWS.Net.Std;
with GNAT.OS_Lib;

with Soja.Auth.OAuth2;
with Soja.Auth.Pam;
with Soja.Bouncer;
with Soja.Core.Push;
with Soja.Webpush;
with Soja.Config;
with Soja.Database;
with Soja.Database.Sqlite;
with Soja.Flags;
with Soja.Identd;
with Soja.Irc.Genmsg;
with Soja.Irc.Helpers;
with Soja.Logging;
with Soja.Proxy_Protocol;
with Soja.Server;
with Soja.Unix_Server;
with Soja.Web;
with Soja_Signals;

procedure Soja_Main is

   Default_Config_Path : constant String := "/etc/soju/config";

   Log : aliased Soja.Logging.Standard_Logger;
   Srv : aliased Soja.Server.Server;
   B   : aliased Soja.Bouncer.Bouncer;

   Config_Path : Unbounded_String := To_Unbounded_String (Default_Config_Path);

   --  log.Fatal.
   procedure Fatal (Text : String) with No_Return;
   procedure Fatal (Text : String) is
   begin
      Log.Print (Text);
      GNAT.OS_Lib.OS_Exit (1);
      raise Program_Error;   --  (not reached)
   end Fatal;

   function Quote (S : String) return String renames Soja.Irc.Helpers.Quote;

   ----------------------------------------------------------------------
   --  loadConfig
   ----------------------------------------------------------------------

   function Read_File (Path : String) return String is
      use Ada.Text_IO;
      F      : File_Type;
      Result : Unbounded_String;
   begin
      Open (F, In_File, Path);
      while not End_Of_File (F) loop
         Append (Result, Get_Line (F));
         Append (Result, ASCII.LF);
      end loop;
      Close (F);
      return To_String (Result);
   end Read_File;

   --  What loadConfig makes: the raw configuration (listeners, database, TLS)
   --  and the part the server reads.
   type Loaded is record
      Raw : Soja.Config.Server;
      Cfg : Soja.Server.Server_Config_Access;
   end record;

   function Load_Config return Loaded is
      Result : Loaded;
   begin
      if Length (Config_Path) > 0 then
         begin
            Result.Raw := Soja.Config.Load (To_String (Config_Path));
         exception
            when E : others =>
               raise Program_Error with
                 "failed to load config file: "
                 & Ada.Exceptions.Exception_Message (E);
         end;
      else
         Result.Raw := Soja.Config.Defaults;
      end if;

      declare
         Raw : Soja.Config.Server renames Result.Raw;
         Cfg : constant Soja.Server.Server_Config_Access :=
           new Soja.Server.Server_Config;
      begin
         --  A hostname without a dot can confuse clients.
         if Ada.Strings.Fixed.Index (To_String (Raw.Hostname), ".") = 0 then
            Log.Print ("warning: hostname " & Quote (To_String (Raw.Hostname))
                       & " is not a fully qualified domain name");
         end if;

         if Length (Raw.MOTD_Path) > 0 then
            declare
               Text : Unbounded_String;
            begin
               Text := To_Unbounded_String
                 (Read_File (To_String (Raw.MOTD_Path)));
               if Length (Text) > 0
                 and then Element (Text, Length (Text)) = ASCII.LF
               then
                  Delete (Text, Length (Text), Length (Text));
               end if;
               Cfg.MOTD := Text;
            exception
               when E : Ada.IO_Exceptions.Name_Error
                      | Ada.IO_Exceptions.Use_Error =>
                  raise Program_Error with
                    "failed to load MOTD: "
                    & Ada.Exceptions.Exception_Message (E);
            end;
         end if;

         --  auth.New: the internal authenticator, or OAuth 2.0 (the server is
         --  discovered now, and again at a reload).  PAM is not ported: a
         --  bouncer that cannot check passwords must not start as if it could.
         declare
            Driver : constant String := To_String (Raw.Auth.Driver);
         begin
            if Driver = "oauth2" then
               begin
                  Soja.Auth.OAuth2.Setup (To_String (Raw.Auth.Source));
               exception
                  when E : Soja.Auth.OAuth2.Setup_Error =>
                     raise Program_Error with
                       "failed to create authenticator: "
                       & Ada.Exceptions.Exception_Message (E);
               end;
            elsif Driver = "pam" then
               if not Soja.Auth.Pam.Available then
                  raise Program_Error with
                    "failed to create authenticator: PAM is not available "
                    & "(libpam could not be loaded)";
               end if;
            elsif Driver /= "internal" then
               raise Program_Error with
                 "failed to create authenticator: the " & Quote (Driver)
                 & " authentication driver is not supported by soja";
            end if;
            Cfg.Auth_Driver := Raw.Auth.Driver;
         end;

         if Raw.TLS /= null then
            declare
               Why : constant String := Soja.Server.Check_TLS
                 (To_String (Raw.TLS.Cert_Path),
                  To_String (Raw.TLS.Key_Path));
            begin
               if Why /= "" then
                  raise Program_Error with
                    "failed to load TLS certificate and key: " & Why;
               end if;
            end;
            Cfg.TLS_Cert := Raw.TLS.Cert_Path;
            Cfg.TLS_Key := Raw.TLS.Key_Path;
         end if;


         Cfg.Hostname := Raw.Hostname;
         Cfg.Title := Raw.Title;
         --  The memory, database and file stores are all ported.
         if To_String (Raw.Msg_Store.Driver) /= "memory"
           and then To_String (Raw.Msg_Store.Driver) /= "db"
           and then To_String (Raw.Msg_Store.Driver) /= "fs"
         then
            Log.Print ("warning: the "
                       & Quote (To_String (Raw.Msg_Store.Driver))
                       & " message store is not supported by soja yet; "
                       & "using the in-memory one (no history across "
                       & "restarts)");
            Cfg.Msg_Store_Driver := To_Unbounded_String ("memory");
         else
            Cfg.Msg_Store_Driver := Raw.Msg_Store.Driver;
         end if;
         Cfg.Msg_Store_Path := Raw.Msg_Store.Source;
         Cfg.HTTP_Origins := Raw.HTTP_Origins;
         Cfg.HTTP_Ingress := Raw.HTTP_Ingress;
         Cfg.Accept_Proxy_IPs := Raw.Accept_Proxy_IPs;
         Cfg.Max_User_Networks := Raw.Max_User_Networks;
         Cfg.Upstream_User_IPs := Raw.Upstream_User_IPs;
         Cfg.Disable_Inactive_Users_Delay := Raw.Disable_Inactive_Users_Delay;
            Cfg.Message_Expiry := Raw.Message_Expiry;
         Cfg.Accept_Proxy_Unix := Raw.Accept_Proxy_Unix;
         Cfg.Client_Cert_Auth := Raw.Client_Cert_Auth;
         --  The icon: an https URL (told to clients as it is), or a file
         --  (served at /icon).
         declare
            Icon : constant String := To_String (Raw.Icon);
         begin
            if Ada.Strings.Fixed.Index (Icon, "://") > 0 then
               if Icon'Length < 8 or else Icon (Icon'First .. Icon'First + 7)
                                          /= "https://"
               then
                  Fatal ("unsupported icon URL scheme: "
                         & Icon (Icon'First .. Ada.Strings.Fixed.Index
                                   (Icon, "://") - 1));
               end if;
               Cfg.Icon_URL := Raw.Icon;
            elsif Icon /= "" then
               if not Ada.Directories.Exists (Icon) then
                  Fatal ("failed to load icon: " & Icon & " does not exist");
               end if;
               Cfg.Icon_Path := Raw.Icon;
            end if;
         end;
         Cfg.Enable_Users_On_Auth := Raw.Enable_Users_On_Auth;
         Cfg.Has_File_Uploader := Raw.File_Upload /= null;
         if Raw.File_Upload /= null then
            Cfg.File_Upload_Dir := Raw.File_Upload.Source;
         end if;
         Result.Cfg := Cfg;
      end;
      return Result;
   end Load_Config;

   ----------------------------------------------------------------------
   --  Listeners
   ----------------------------------------------------------------------

   type String_Access is access String;

   protected Serving is
      procedure Add;
      procedure Done;
      entry Wait_None;
   private
      Count : Natural := 0;
   end Serving;

   protected body Serving is
      procedure Add is
      begin
         Count := Count + 1;
      end Add;
      procedure Done is
      begin
         Count := Count - 1;
      end Done;
      entry Wait_None when Count = 0 is
      begin
         null;
      end Wait_None;
   end Serving;

   --  srv.Serve (ln, srv.Handle) on its own task.
   task type Listener_Task
     (L : not null AWS.Net.Socket_Access;
      Cert, Key : not null String_Access;
      Web : Soja.Server.Web_Handler;
      Name : not null String_Access);

   task body Listener_Task is
   begin
      Soja.Server.Serve (Srv, L, Cert.all, Key.all, Web);
      Serving.Done;
   exception
      when E : others =>
         Log.Print ("serving " & Quote (Name.all) & ": "
                    & Ada.Exceptions.Exception_Message (E));
         Serving.Done;
   end Listener_Task;
   type Listener_Task_Access is access Listener_Task;

   --  Identd.Serve on its own task (created by the first `ident://`
   --  listener; upstream connections are registered with it).
   Ident : aliased Soja.Identd.Identd;
   Ident_In_Use : Boolean := False;

   task type Ident_Task
     (L : not null AWS.Net.Socket_Access; Name : not null String_Access);

   --  accept-proxy-ip, for the ident listener.
   function Accepts_Proxy (Peer : String) return Boolean is
      Addr : Soja.Config.IP_Addr;
   begin
      return Soja.Proxy_Protocol.Parse_IP (Peer, Addr)
        and then Soja.Proxy_Protocol.Contains
                   (Soja.Server.Config (Srv).Accept_Proxy_IPs, Addr);
   end Accepts_Proxy;

   task body Ident_Task is
   begin
      Soja.Identd.Serve (Ident, L, Accepts_Proxy'Unrestricted_Access);
      Serving.Done;
   exception
      when E : others =>
         Log.Print ("serving " & Quote (Name.all) & ": "
                    & Ada.Exceptions.Exception_Message (E));
         Serving.Done;
   end Ident_Task;
   type Ident_Task_Access is access Ident_Task;

   --  Unix-domain listeners: `unix://path` serves IRC clients (Handle) and
   --  `unix+admin://[path]` the admin socket (Handle_Admin).
   Default_Admin_Path : constant String := "/run/soju/admin";

   Unix_Listeners : array (1 .. 16) of Soja.Unix_Server.Listener_Access;
   Unix_Count     : Natural := 0;

   task type Unix_Task
     (L : not null Soja.Unix_Server.Listener_Access;
      H : Soja.Server.Handler;
      Web : Soja.Server.Web_Handler;
      Name : not null String_Access);

   task body Unix_Task is
   begin
      Soja.Unix_Server.Serve (L, H, Srv'Access, Web);
      Serving.Done;
   exception
      when E : others =>
         Log.Print ("serving " & Quote (Name.all) & ": "
                    & Ada.Exceptions.Exception_Message (E));
         Serving.Done;
   end Unix_Task;
   type Unix_Task_Access is access Unix_Task;

   --  Web: the connections are HTTP or WebSocket (ws+unix, http+unix).
   procedure Start_Unix_Listener
     (Listen, Rest : String; Admin : Boolean;
      Web : Soja.Server.Web_Handler := null)
   is
      Has_Path : constant Boolean :=
        Rest'Length > 0 and then Rest (Rest'First) = '/';
      Path : constant String :=
        (if Has_Path then Rest
         elsif Admin then Default_Admin_Path else "");
      L    : Soja.Unix_Server.Listener_Access;
      Runner : Unix_Task_Access;
      pragma Unreferenced (Runner);
   begin
      if Path = "" then
         Fatal ("failed to start listener on " & Quote (Listen)
                & ": no socket path");
      end if;
      if Unix_Count = Unix_Listeners'Last then
         Fatal ("too many unix listeners");
      end if;
      begin
         --  Admin: only the owner may use it (rw-------), it is administrator
         --  access.  IRC: rwxrwxr-x, as soju sets it, so that a group (a web
         --  server, say) can connect.
         L := Soja.Unix_Server.Listen
           (Path, (if Admin then 8#600# else 8#775#));
      exception
         when E : Soja.Unix_Server.Listen_Error =>
            Fatal ("failed to start listener on " & Quote (Listen) & ": "
                   & Ada.Exceptions.Exception_Message (E));
      end;
      Unix_Count := Unix_Count + 1;
      Unix_Listeners (Unix_Count) := L;
      Serving.Add;
      Runner := new Unix_Task
        (L, (if Admin then Soja.Bouncer.Handle_Admin'Access
             else Soja.Bouncer.Handle'Access), Web, new String'(Listen));
   end Start_Unix_Listener;

   --  withDefaultPort for a "host[:port]" (or "[v6]:port") string; Host and
   --  Port are what is left after the default.
   procedure Split_Host_Port
     (Addr, Default_Port : String; Host : out Unbounded_String;
      Port : out Natural)
   is
      Colon : Natural := 0;
      Text  : constant String := Addr;
   begin
      Host := Null_Unbounded_String;
      Port := Natural'Value (Default_Port);
      --  The last ':' that is not inside "[...]" separates the port.
      for I in reverse Text'Range loop
         if Text (I) = ']' then
            exit;
         elsif Text (I) = ':' then
            Colon := I;
            exit;
         end if;
      end loop;
      if Colon > 0 then
         Host := To_Unbounded_String (Text (Text'First .. Colon - 1));
         begin
            Port := Natural'Value (Text (Colon + 1 .. Text'Last));
         exception
            when Constraint_Error =>
               raise Program_Error with "invalid port in " & Quote (Addr);
         end;
      else
         Host := To_Unbounded_String (Text);
      end if;
      --  Strip the brackets of an IPv6 literal.
      declare
         H : constant String := To_String (Host);
      begin
         if H'Length >= 2 and then H (H'First) = '['
           and then H (H'Last) = ']'
         then
            Host := To_Unbounded_String (H (H'First + 1 .. H'Last - 1));
         end if;
      end;
   end Split_Host_Port;

   procedure Start_Listener
     (Listen : String; Raw : Soja.Config.Server)
   is
      Sep    : constant Natural := Ada.Strings.Fixed.Index (Listen, "://");
      Scheme : constant String :=
        (if Sep > 0 then Listen (Listen'First .. Sep - 1) else "");
      Rest   : constant String :=
        (if Sep > 0 then Listen (Sep + 3 .. Listen'Last) else Listen);
      Slash  : constant Natural := Ada.Strings.Fixed.Index (Rest, "/");
      Host_Port : constant String :=
        (if Slash > 0 then Rest (Rest'First .. Slash - 1) else Rest);
      Host   : Unbounded_String;
      Port   : Natural;
      TLS    : Boolean;
      Is_Ident : Boolean := False;
      Web    : Soja.Server.Web_Handler := null;
   begin
      --  irc://, ws:// and http:// are the plain-text forms for localhost
      --  only; the ones for any host say "insecure".
      if Scheme in "irc" | "ws" | "http" then
         declare
            Local_Host : Unbounded_String;
            Local_Port : Natural;
         begin
            Split_Host_Port (Host_Port, "0", Local_Host, Local_Port);
            if To_String (Local_Host) /= "localhost" then
               Fatal ((if Scheme = "irc" then "Plain-text IRC"
                       elsif Scheme = "ws" then "Plain-text WebSocket"
                       else "Plain-text HTTP")
                      & " listening host must be localhost unless marked "
                      & "as insecure");
            end if;
         end;
      end if;

      if Scheme = "unix+admin" or else Scheme = "unix" then
         Start_Unix_Listener (Listen, Rest, Admin => Scheme = "unix+admin");
         Log.Print ("server listening on " & Quote (Listen));
         return;
      end if;
      if Scheme = "ws+unix" or else Scheme = "http+unix" then
         Start_Unix_Listener
           (Listen, Rest, Admin => False,
            Web => (if Scheme = "ws+unix" then Soja.Web.Handle_Ws'Access
                    else Soja.Web.Handle_Http'Access));
         Log.Print ("server listening on " & Quote (Listen));
         return;
      end if;
      if Scheme = "ircs" or else Scheme = "" then
         if Raw.TLS = null then
            Fatal ("failed to listen on " & Quote (Listen)
                   & ": missing TLS configuration");
         end if;
         Split_Host_Port (Host_Port, "6697", Host, Port);
         TLS := True;
      elsif Scheme = "irc+insecure" or else Scheme = "irc" then
         Split_Host_Port (Host_Port, "6667", Host, Port);
         TLS := False;
      elsif Scheme = "wss" or else Scheme = "https" then
         if Raw.TLS = null then
            Fatal ("failed to listen on " & Quote (Listen)
                   & ": missing TLS configuration");
         end if;
         Split_Host_Port (Host_Port, "443", Host, Port);
         TLS := True;
         Web := (if Scheme = "wss" then Soja.Web.Handle_Ws'Access
                 else Soja.Web.Handle_Http'Access);
      elsif Scheme in "ws+insecure" | "ws" | "http+insecure" | "http" then
         Split_Host_Port (Host_Port, "80", Host, Port);
         TLS := False;
         Web := (if Scheme in "ws+insecure" | "ws"
                 then Soja.Web.Handle_Ws'Access
                 else Soja.Web.Handle_Http'Access);
      elsif Scheme = "http+prometheus"
        or else Scheme = "http+insecure+prometheus"
      then
         --  Only localhost, for security reasons: a reverse proxy can expose
         --  it.  A port is required.
         if Ada.Strings.Fixed.Index (Host_Port, ":") = 0 then
            Fatal ("invalid host in URI " & Quote (Listen)
                   & ": missing port");
         end if;
         Split_Host_Port (Host_Port, "0", Host, Port);
         if Scheme = "http+prometheus" and then To_String (Host) /= "localhost"
         then
            Fatal ("Prometheus listening host must be localhost unless "
                   & "marked as insecure");
         end if;
         TLS := False;
         Web := Soja.Web.Handle_Metrics'Access;
      elsif Scheme = "ident" then
         Split_Host_Port (Host_Port, "113", Host, Port);
         TLS := False;
         Is_Ident := True;
      else
         Fatal ("failed to listen on " & Quote (Listen) & ": the scheme "
                & Quote (Scheme) & " is not supported by soja yet");
         return;
      end if;

      declare
         Sock : constant AWS.Net.Socket_Access := AWS.Net.Socket (False);
      begin
         begin
            AWS.Net.Std.Socket_Type (Sock.all).Bind
              (Port, To_String (Host), Reuse_Address => True);
            AWS.Net.Std.Socket_Type (Sock.all).Listen (128);
         exception
            when E : others =>
               Fatal ("failed to start " & (if TLS then "TLS " else "")
                      & "listener on " & Quote (Listen) & ": "
                      & Ada.Exceptions.Exception_Message (E));
         end;

         if Is_Ident then
            declare
               Runner : Ident_Task_Access;
               pragma Unreferenced (Runner);
            begin
               if not Ident_In_Use then
                  Ident_In_Use := True;
                  Srv.Set_Identd (Ident'Unchecked_Access);
               end if;
               Serving.Add;
               Runner := new Ident_Task (Sock, new String'(Listen));
            end;
         else
            declare
               Runner : Listener_Task_Access;
               pragma Unreferenced (Runner);
            begin
               Serving.Add;
               Runner := new Listener_Task
                 (L    => Sock,
                  Cert => new String'
                    (if TLS then To_String (Raw.TLS.Cert_Path) else ""),
                  Key  => new String'
                    (if TLS then To_String (Raw.TLS.Key_Path) else ""),
                  Web  => Web,
                  Name => new String'(Listen));
            end;
         end if;
      end;
      Log.Print ("server listening on " & Quote (Listen));
   end Start_Listener;

   ----------------------------------------------------------------------
   --  main
   ----------------------------------------------------------------------

   Args    : Soja.Flags.String_Vector;
   Flags   : Soja.Flags.Flag_Set;
   Loaded_Config : Loaded;
   DB      : Soja.Database.Database_Access;
   Sig     : Soja_Signals.Signal;
begin
   for I in 1 .. Ada.Command_Line.Argument_Count loop
      Args.Append (Ada.Command_Line.Argument (I));
   end loop;
   Flags.Add_List ("listen");
   Flags.Add_String ("config", Default_Config_Path);
   Flags.Add_Bool ("debug");
   begin
      Flags.Parse (Args);
   exception
      when E : Soja.Flags.Flag_Error =>
         Ada.Text_IO.Put_Line
           (Ada.Text_IO.Standard_Error,
            Ada.Exceptions.Exception_Message (E));
         Ada.Text_IO.Put_Line
           (Ada.Text_IO.Standard_Error,
            "usage: soja [-config path] [-listen addr]... [-debug]");
         GNAT.OS_Lib.OS_Exit (2);
   end;
   Config_Path := To_Unbounded_String (Flags.Get ("config"));
   Log.Debug_Enabled := Flags.Get_Bool ("debug");

   begin
      Loaded_Config := Load_Config;
   exception
      when E : Program_Error =>
         Fatal (Ada.Exceptions.Exception_Message (E));
   end;

   declare
      Raw : Soja.Config.Server renames Loaded_Config.Raw;
      Listen : Soja.Irc.Genmsg.String_Vectors.Vector;
   begin
      for L of Raw.Listen loop
         Listen.Append (To_String (L));
      end loop;
      for L of Flags.Get_List ("listen") loop
         Listen.Append (L);
      end loop;
      if Listen.Is_Empty then
         Listen.Append (":6697");
      end if;

      declare
         Driver : constant String := To_String (Raw.DB.Driver);
      begin
         if Driver /= "sqlite3" then
            Fatal ("failed to open database: the " & Quote (Driver)
                   & " driver is not supported by soja (SQLite only)");
         end if;
         begin
            DB := Soja.Database.Sqlite.Open_Sqlite_DB
              (To_String (Raw.DB.Source));
         exception
            when E : others =>
               Fatal ("failed to open database: "
                      & Ada.Exceptions.Exception_Message (E));
         end;
      end;

      --  (A test hook, see Soja.Webpush: off unless asked for.)
      Soja.Webpush.Allow_Internal_Endpoints :=
        Ada.Environment_Variables.Exists ("SOJA_WEBPUSH_TEST");

      Srv.Initialize (Log'Unchecked_Access);
      Srv.Set_DB (DB);
      begin
         Soja.Core.Push.Load_Config (Srv);
      exception
         when E : Constraint_Error =>
            Fatal ("failed to load Web push config: "
                   & Ada.Exceptions.Exception_Message (E));
      end;
      Srv.Set_Config (Loaded_Config.Cfg);
      Soja.Bouncer.Initialize (B, Srv'Unchecked_Access);

      for L of Listen loop
         Start_Listener (L, Raw);
      end loop;

      begin
         Soja.Bouncer.Start (B);
      exception
         when E : others =>
            Fatal (Ada.Exceptions.Exception_Message (E));
      end;
   end;

   loop
      Soja_Signals.Watcher.Wait (Sig);
      case Sig is
         when Soja_Signals.Reload =>
            Log.Print ("reloading configuration");
            begin
               Loaded_Config := Load_Config;
               Srv.Set_Config (Loaded_Config.Cfg);
               --  New TLS connections use the (re-read) certificate.
               Srv.Reload_TLS;
            exception
               when E : Program_Error =>
                  Log.Print ("failed to reloading configuration: "
                             & Ada.Exceptions.Exception_Message (E));
            end;
         when Soja_Signals.Stop =>
            Soja.Server.Shutdown (Srv);
            if Ident_In_Use then
               Soja.Identd.Stop (Ident);
            end if;
            for I in 1 .. Unix_Count loop
               Soja.Unix_Server.Stop (Unix_Listeners (I));
            end loop;
            Serving.Wait_None;   --  the accept loops have ended
            Soja.Bouncer.Shutdown (B);
            return;
      end case;
   end loop;
end Soja_Main;
