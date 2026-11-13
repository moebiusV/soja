--  Soja.Web -- what the ws, wss, ws+insecure, ws+unix and the http, https,
--  http+insecure, http+unix listeners serve (server.go's Server.ServeHTTP and
--  cmd/soju's HTTP mux).
--
--  Handle_Ws: every request is a WebSocket upgrade (the ws listeners hand the
--  whole server to ServeHTTP).  Handle_Http: only /socket is the WebSocket
--  (as the mux routes it); /uploads is the file-upload handler, which without
--  an uploader answers 404 (after its CORS check); anything else is a 404.
--
--  Handshake and checks as nhooyr.io/websocket's Accept: HTTP/1.1, a GET
--  with `Connection: Upgrade` and `Upgrade: websocket`, version 13, a key;
--  the Origin must be the request's host or match an `http-origin` pattern;
--  the subprotocol is text.ircv3.net when the client offers it; no
--  extensions (no compression).  A request behind a trusted proxy
--  (`accept-proxy-ip`) takes its client address from Forwarded or
--  X-Forwarded-For.
pragma Ada_2022;

with Soja.Byte_Stream;
with Soja.Server;

package Soja.Web is

   --  Web_Handler for the ws listeners.
   procedure Handle_Ws
     (S      : in out Soja.Server.Server;
      Stream : not null Soja.Byte_Stream.Stream_Access;
      H      : Soja.Server.Handler);

   --  Web_Handler for the http listeners.
   procedure Handle_Http
     (S      : in out Soja.Server.Server;
      Stream : not null Soja.Byte_Stream.Stream_Access;
      H      : Soja.Server.Handler);

   --  The Sec-WebSocket-Accept value for a Sec-WebSocket-Key (RFC 6455 4.2.2).
   --  Exposed for the tests.
   function Accept_Key (Key : String) return String;

end Soja.Web;
