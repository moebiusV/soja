pragma Ada_2022;

with Ada.Characters.Handling;
with Ada.Exceptions;
with Ada.Streams;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;

with AWS.Translator;
with GNAT.SHA1;

with Soja.Config;
with Soja.Conn;
with Soja.Conn.Ws;
with Soja.Fileupload;
with Soja.Glob;
with Soja.Http;
with Soja.Logging;
with Soja.Metrics;
with Soja.Proxy_Protocol;

package body Soja.Web is

   use type Soja.Logging.Logger_Access;
   use type Ada.Streams.Stream_Element_Offset;

   CRLF : constant String := ASCII.CR & ASCII.LF;

   Subprotocol : constant String := "text.ircv3.net";
   GUID : constant String := "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

   function Lower (S : String) return String is
     (Ada.Characters.Handling.To_Lower (S));

   function Nibble (C : Character) return Natural is
     (if C in '0' .. '9' then Character'Pos (C) - Character'Pos ('0')
      else Character'Pos (Ada.Characters.Handling.To_Lower (C))
           - Character'Pos ('a') + 10);

   --  The bytes a hexadecimal text spells.
   function From_Hex (Hex : String)
      return Ada.Streams.Stream_Element_Array
   is
     ([for I in 1 .. Ada.Streams.Stream_Element_Offset (Hex'Length / 2) =>
         Ada.Streams.Stream_Element
           (Nibble (Hex (Hex'First + 2 * Natural (I - 1))) * 16
            + Nibble (Hex (Hex'First + 2 * Natural (I - 1) + 1)))]);

   function Accept_Key (Key : String) return String is
     (AWS.Translator.Base64_Encode (From_Hex (GNAT.SHA1.Digest (Key & GUID))));

   --  net.SplitHostPort's host, for "host:port" or "[v6]:port"; "" if there
   --  is none ("@" of a unix peer, say).
   function Host_Of (Addr : String) return String is
      Colon : Natural := 0;
   begin
      for I in reverse Addr'Range loop
         if Addr (I) = ':' then
            Colon := I;
            exit;
         end if;
      end loop;
      if Colon = 0 then
         return "";
      end if;
      declare
         H : constant String := Addr (Addr'First .. Colon - 1);
      begin
         return (if H'Length >= 2 and then H (H'First) = '['
                      and then H (H'Last) = ']'
                 then H (H'First + 1 .. H'Last - 1) else H);
      end;
   end Host_Of;

   --  Whether the request's Origin is allowed (authenticateOrigin): the
   --  request's own host, or one of the http-origin patterns (matched without
   --  regard to case).  "" when allowed, else the message of the 403.
   function Origin_Error
     (Req : Soja.Http.Request; Cfg : Soja.Server.Server_Config_Access)
      return String
   is
      Origin : constant String := Soja.Http.Get (Req, "origin");
      Ok     : Boolean;
   begin
      if Origin = "" then
         return "";
      end if;
      declare
         Host : constant String := Soja.Http.URL_Host (Origin, Ok);
      begin
         if not Ok then
            return "failed to parse Origin header " & '"' & Origin & '"';
         end if;
         if Lower (Soja.Http.Host (Req)) = Lower (Host) then
            return "";
         end if;
         for Pattern of Cfg.HTTP_Origins loop
            if Soja.Glob.Match (Lower (To_String (Pattern)), Lower (Host))
            then
               return "";
            end if;
         end loop;
         if Host = "" then
            return "request Origin " & '"' & Origin
              & """ is not a valid URL with a host";
         end if;
         return "request Origin " & '"' & Origin
           & """ is not authorized for Host " & '"'
           & Soja.Http.Host (Req) & '"';
      end;
   end Origin_Error;

   --  The client's subprotocol: text.ircv3.net when it is among the ones it
   --  offers (a comma separated list), else "".
   function Chosen_Subprotocol (Req : Soja.Http.Request) return String is
   begin
      return (if Soja.Http.Has_Token (Req, "sec-websocket-protocol",
                                      Subprotocol)
              then Subprotocol else "");
   end Chosen_Subprotocol;

   --  websocket.Accept, then Server.Handle.  False when the request was
   --  answered with an error (the stream is still ours to release).
   procedure Upgrade
     (S      : in out Soja.Server.Server;
      Stream : not null Soja.Byte_Stream.Stream_Access;
      Req    : Soja.Http.Request;
      H      : Soja.Server.Handler;
      Done   : out Boolean)
   is
      Cfg : constant Soja.Server.Server_Config_Access :=
        Soja.Server.Config (S);
      Key : constant String := Soja.Http.Get (Req, "sec-websocket-key");
   begin
      Done := False;
      if Req.Major < 1 or else (Req.Major = 1 and then Req.Minor < 1) then
         Soja.Http.Write_Error
           (Stream.all, 426,
            "WebSocket protocol violation: handshake request must be at "
            & "least HTTP/1.1: " & """HTTP/"
            & Ada.Strings.Fixed.Trim (Natural'Image (Req.Major),
                                      Ada.Strings.Left)
            & '.'
            & Ada.Strings.Fixed.Trim (Natural'Image (Req.Minor),
                                      Ada.Strings.Left)
            & '"');
         return;
      elsif not Soja.Http.Has_Token (Req, "connection", "Upgrade") then
         Soja.Http.Write_Error
           (Stream.all, 426,
            "WebSocket protocol violation: Connection header "
            & '"' & Soja.Http.Get (Req, "connection")
            & """ does not contain Upgrade",
            "Connection: Upgrade" & CRLF & "Upgrade: websocket" & CRLF);
         return;
      elsif not Soja.Http.Has_Token (Req, "upgrade", "websocket") then
         Soja.Http.Write_Error
           (Stream.all, 426,
            "WebSocket protocol violation: Upgrade header "
            & '"' & Soja.Http.Get (Req, "upgrade")
            & """ does not contain websocket",
            "Connection: Upgrade" & CRLF & "Upgrade: websocket" & CRLF);
         return;
      elsif To_String (Req.Method) /= "GET" then
         Soja.Http.Write_Error
           (Stream.all, 405,
            "WebSocket protocol violation: handshake request method is not "
            & "GET but " & To_String (Req.Method));
         return;
      elsif Soja.Http.Get (Req, "sec-websocket-version") /= "13" then
         Soja.Http.Write_Error
           (Stream.all, 400,
            "WebSocket protocol violation: unsupported WebSocket protocol "
            & "version (only 13 is supported): " & '"'
            & Soja.Http.Get (Req, "sec-websocket-version") & '"',
            "Sec-WebSocket-Version: 13" & CRLF);
         return;
      elsif Key = "" then
         Soja.Http.Write_Error
           (Stream.all, 400,
            "WebSocket protocol violation: missing Sec-WebSocket-Key");
         return;
      end if;

      declare
         Why : constant String := Origin_Error (Req, Cfg);
      begin
         if Why /= "" then
            Soja.Http.Write_Error (Stream.all, 403, Why);
            if S.Logger /= null then
               S.Logger.Print
                 ("failed to serve HTTP connection: " & Why);
            end if;
            return;
         end if;
      end;

      --  Only trust the Forwarded header field if this is a trusted proxy IP
      --  to prevent users from spoofing the remote address.
      declare
         Peer : constant String := Stream.Peer;
         Addr : Soja.Config.IP_Addr;
         Is_Proxy : constant Boolean :=
           Soja.Proxy_Protocol.Parse_IP (Host_Of (Peer), Addr)
           and then Soja.Proxy_Protocol.Contains (Cfg.Accept_Proxy_IPs, Addr);
         Forwarded : constant String :=
           (if Is_Proxy then Soja.Http.Forwarded_For (Req) else "");
         Remote : constant String :=
           (if Forwarded /= "" then Forwarded else Peer);
         Protocol : constant String := Chosen_Subprotocol (Req);
         IC : Soja.Conn.Ws.Ws_IRC_Conn_Access;
      begin
         Soja.Http.Write_Response
           (Stream.all, 101,
            "Upgrade: websocket" & CRLF & "Connection: Upgrade" & CRLF
            & "Sec-WebSocket-Accept: " & Accept_Key (Key) & CRLF
            & (if Protocol /= "" then "Sec-WebSocket-Protocol: "
               & Protocol & CRLF else ""));
         IC := Soja.Conn.Ws.Create
           (Stream, Remote, To_String (Req.Leftover));
         Done := True;
         begin
            H (Soja.Conn.IRC_Conn_Access (IC));
         exception
            when others =>
               Soja.Conn.Ws.Handler_Done (IC);
               raise;
         end;
         Soja.Conn.Ws.Handler_Done (IC);
      end;
   end Upgrade;

   --  The request, then what the mux (Mux) or ServeHTTP alone does with it.
   procedure Serve
     (S      : in out Soja.Server.Server;
      Stream : not null Soja.Byte_Stream.Stream_Access;
      H      : Soja.Server.Handler;
      Mux    : Boolean)
   is
      Req  : Soja.Http.Request;
      Done : Boolean := False;
   begin
      begin
         Soja.Http.Read_Request (Stream.all, Req);
      exception
         when Soja.Http.Closed =>
            Stream.Shutdown;
            Stream.Release;
            return;
         when E : Soja.Http.Bad_Request =>
            Soja.Http.Write_Response
              (Stream.all, 400,
               "Content-Type: text/plain; charset=utf-8" & CRLF,
               "400 Bad Request: " & Ada.Exceptions.Exception_Message (E));
            Stream.Shutdown;
            Stream.Release;
            return;
      end;

      declare
         Path : constant String := Soja.Http.Path (Req);
      begin
         if Mux and then Path = "/socket" then
            Upgrade (S, Stream, Req, H, Done);
         elsif Mux
           and then (Path = "/uploads"
                     or else (Path'Length >= 9
                              and then Path (Path'First .. Path'First + 8)
                                       = "/uploads/"))
         then
            --  fileupload.Handler: the CORS check first, then the upload
            --  (404 when there is no `file-upload`).
            declare
               Why : constant String :=
                 Origin_Error (Req, Soja.Server.Config (S));
               Origin : constant String := Soja.Http.Get (Req, "origin");
               Common : constant String :=
                 "Content-Security-Policy: sandbox; default-src 'none'; "
                 & "script-src 'none';" & CRLF
                 & "Access-Control-Allow-Credentials: true" & CRLF
                 & "Access-Control-Allow-Headers: Authorization, "
                 & "Content-Type, Content-Disposition" & CRLF
                 & "Access-Control-Expose-Headers: Location, "
                 & "Content-Disposition" & CRLF
                 & (if Origin /= "" and then Why = ""
                    then "Access-Control-Allow-Origin: " & Origin & CRLF
                         & "Vary: Origin" & CRLF
                    else "");
            begin
               if Why /= "" then
                  Soja.Http.Write_Error
                    (Stream.all, 403, "unauthorized Origin", Common);
               else
                  Soja.Fileupload.Serve (S, Stream, Req, Common);
               end if;
            end;
         elsif Mux then
            Soja.Http.Write_Error (Stream.all, 404, "404 page not found");
         else
            Upgrade (S, Stream, Req, H, Done);
         end if;
      end;

      if not Done then
         Stream.Shutdown;
         Stream.Release;
      end if;
   exception
      when E : others =>
         if S.Logger /= null then
            S.Logger.Print
              ("failed to serve HTTP connection: "
               & Ada.Exceptions.Exception_Message (E));
         end if;
         --  Before the upgrade the stream is still ours: give it back (the
         --  WebSocket connection owns it after).
         if not Done then
            Stream.Shutdown;
            Stream.Release;
         end if;
   end Serve;

   procedure Handle_Metrics
     (S      : in out Soja.Server.Server;
      Stream : not null Soja.Byte_Stream.Stream_Access;
      H      : Soja.Server.Handler)
   is
      pragma Unreferenced (H);
      Req : Soja.Http.Request;
   begin
      Soja.Http.Read_Request (Stream.all, Req);
      Soja.Http.Write_Response
        (Stream.all, 200,
         "Content-Type: " & Soja.Metrics.Content_Type & CRLF,
         (if To_String (Req.Method) = "HEAD" then ""
          else Soja.Server.Metrics_Text (S)));
      Stream.Shutdown;
      Stream.Release;
   exception
      when others =>
         Stream.Shutdown;
         Stream.Release;
   end Handle_Metrics;

   procedure Handle_Ws
     (S      : in out Soja.Server.Server;
      Stream : not null Soja.Byte_Stream.Stream_Access;
      H      : Soja.Server.Handler)
   is
   begin
      Serve (S, Stream, H, Mux => False);
   end Handle_Ws;

   procedure Handle_Http
     (S      : in out Soja.Server.Server;
      Stream : not null Soja.Byte_Stream.Stream_Access;
      H      : Soja.Server.Handler)
   is
   begin
      Serve (S, Stream, H, Mux => True);
   end Handle_Http;

end Soja.Web;
