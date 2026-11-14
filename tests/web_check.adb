pragma Ada_2022;

with Ada.Exceptions;
with Interfaces;
with Ada.IO_Exceptions;
with Ada.Streams;           use Ada.Streams;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;
with Ada.Streams.Stream_IO;
with Ada.Directories;
with Ada.Text_IO;
with GNAT.OS_Lib;

with Soja.Byte_Stream;
with Soja.Config;
with Soja.Conn;
with Soja.Conn.Ws;
with Soja.Glob;
with Soja.Http;
with Soja.Irc.Messages;     use Soja.Irc.Messages;
with Soja.Server;
with Soja.Utf8;
with Soja.Web;

--  Glob, UTF-8, the HTTP head, the WebSocket framing and the web handlers,
--  over a scripted stream (no sockets).
procedure Web_Check is
   use type Interfaces.Unsigned_8;

   procedure Check (Cond : Boolean; What : String) is
   begin
      if not Cond then
         raise Program_Error with What;
      end if;
   end Check;

   CRLF : constant String := ASCII.CR & ASCII.LF;

   function Contains (Text, Part : String) return Boolean is
     (Ada.Strings.Fixed.Index (Text, Part) > 0);

   function Starts (Text, Prefix : String) return Boolean is
     (Text'Length >= Prefix'Length
      and then Text (Text'First .. Text'First + Prefix'Length - 1) = Prefix);

   ------------------------------------------------------------------
   --  A scripted stream
   ------------------------------------------------------------------
   package Fakes is
      type Fake is limited new Soja.Byte_Stream.Stream with record
         Incoming : Unbounded_String;
         Pos      : Natural := 0;
         Sent     : Unbounded_String;
         Is_Shut  : Boolean := False;
         Released : Boolean := False;
         Addr     : Unbounded_String :=
           To_Unbounded_String ("203.0.113.9:4000");
      end record;

      overriding procedure Receive
        (S : in out Fake; Buf : out Stream_Element_Array;
         Last : out Stream_Element_Offset);
      overriding procedure Send
        (S : in out Fake; Data : Stream_Element_Array);
      overriding procedure Shutdown (S : in out Fake);
      overriding procedure Release (S : in out Fake);
      overriding function Peer (S : Fake) return String;
   end Fakes;

   package body Fakes is
      overriding procedure Receive
        (S : in out Fake; Buf : out Stream_Element_Array;
         Last : out Stream_Element_Offset)
      is
         Left : constant Natural := Length (S.Incoming) - S.Pos;
         N    : constant Natural := Natural'Min (Left, Buf'Length);
      begin
         if N = 0 then
            Last := Buf'First - 1;
            return;
         end if;
         for I in 1 .. N loop
            Buf (Buf'First + Stream_Element_Offset (I - 1)) :=
              Stream_Element
                (Character'Pos (Element (S.Incoming, S.Pos + I)));
         end loop;
         S.Pos := S.Pos + N;
         Last := Buf'First + Stream_Element_Offset (N) - 1;
      end Receive;

      overriding procedure Send
        (S : in out Fake; Data : Stream_Element_Array) is
      begin
         for B of Data loop
            Append (S.Sent, Character'Val (B));
         end loop;
      end Send;

      overriding procedure Shutdown (S : in out Fake) is
      begin
         S.Is_Shut := True;
      end Shutdown;

      overriding procedure Release (S : in out Fake) is
      begin
         S.Released := True;
      end Release;

      overriding function Peer (S : Fake) return String is
        (To_String (S.Addr));
   end Fakes;
   use Fakes;

   type Fake_Access is access all Fake;

   function As_Stream (F : Fake_Access) return Soja.Byte_Stream.Stream_Access
   is (F.all'Unchecked_Access);

   function New_Fake (Incoming : String; Addr : String := "")
      return Fake_Access
   is
      F : constant Fake_Access := new Fake;
   begin
      F.Incoming := To_Unbounded_String (Incoming);
      if Addr /= "" then
         F.Addr := To_Unbounded_String (Addr);
      end if;
      return F;
   end New_Fake;

   --  A frame as a client sends it: masked.
   function Client_Frame
     (Op : Natural; Payload : String; Fin : Boolean := True;
      Masked : Boolean := True; Rsv : Natural := 0) return String
   is
      Key : constant String := "wxyz";
      Len : constant Natural := Payload'Length;
      R   : Unbounded_String;
      M   : constant Natural := (if Masked then 128 else 0);
   begin
      Append (R, Character'Val ((if Fin then 128 else 0) + Rsv * 16 + Op));
      if Len < 126 then
         Append (R, Character'Val (M + Len));
      elsif Len <= 65_535 then
         Append (R, Character'Val (M + 126));
         Append (R, Character'Val (Len / 256));
         Append (R, Character'Val (Len mod 256));
      else
         Append (R, Character'Val (M + 127));
         for I in reverse 0 .. 7 loop
            Append (R, Character'Val ((Len / (256 ** I)) mod 256));
         end loop;
      end if;
      if Masked then
         Append (R, Key);
         for I in Payload'Range loop
            Append
              (R, Character'Val
                 (Natural
                    (Interfaces.Unsigned_8 (Character'Pos (Payload (I)))
                     xor Interfaces.Unsigned_8
                           (Character'Pos
                              (Key (1 + (I - Payload'First) mod 4))))));
         end loop;
      else
         Append (R, Payload);
      end if;
      return To_String (R);
   end Client_Frame;

   --  What follows the HTTP head in what was sent.
   function After_Head (Sent : String) return String is
      I : constant Natural := Ada.Strings.Fixed.Index (Sent, CRLF & CRLF);
   begin
      return (if I = 0 then "" else Sent (I + 4 .. Sent'Last));
   end After_Head;

   --  The server's frames in Data as (opcode, payload) lines "op:payload".
   function Frames (Data : String) return String is
      R : Unbounded_String;
      I : Natural := Data'First;
   begin
      while I < Data'Last loop
         declare
            Op  : constant Natural := Character'Pos (Data (I)) mod 16;
            Len : Natural := Character'Pos (Data (I + 1));
            P   : Natural := I + 2;
         begin
            if Len = 126 then
               Len := Character'Pos (Data (I + 2)) * 256
                 + Character'Pos (Data (I + 3));
               P := I + 4;
            end if;
            Append (R, Natural'Image (Op) & ":" & Data (P .. P + Len - 1)
                    & "|");
            I := P + Len;
         end;
      end loop;
      return To_String (R);
   end Frames;

   function Close_Code (Payload : String) return Natural is
     (Character'Pos (Payload (Payload'First)) * 256
      + Character'Pos (Payload (Payload'First + 1)));

   function Raised_Data_Error (C : Soja.Conn.Ws.Ws_IRC_Conn_Access)
      return Boolean
   is
      M : Message;
   begin
      M := Soja.Conn.Ws.Read_Message (C.all);
      return False;
   exception
      when Ada.IO_Exceptions.Data_Error => return True;
   end Raised_Data_Error;

begin
   ------------------------------------------------------------------
   --  Glob (path.Match)
   ------------------------------------------------------------------
   Check (Soja.Glob.Match ("*.example.org", "a.example.org"), "glob *.x");
   Check (not Soja.Glob.Match ("*.example.org", "example.org"), "glob *.x 2");
   Check (Soja.Glob.Match ("a?c", "abc") and then not Soja.Glob.Match ("a?c", "ac"),
          "glob ?");
   Check (Soja.Glob.Match ("a[b-d]e", "ace")
          and then not Soja.Glob.Match ("a[b-d]e", "aee"), "glob class");
   Check (not Soja.Glob.Match ("a[^b]e", "abe")
          and then Soja.Glob.Match ("a[^b]e", "ace"), "glob negated class");
   Check (Soja.Glob.Match ("*", "") and then Soja.Glob.Match ("**", "abc"),
          "glob star");
   Check (not Soja.Glob.Match ("*", "a/b") and then not Soja.Glob.Match ("?", "/"),
          "glob star stops at slash");
   Check (Soja.Glob.Match ("a\*b", "a*b") and then not Soja.Glob.Match ("a\*b", "aXb"),
          "glob escape");
   Check (not Soja.Glob.Match ("[", "[") and then not Soja.Glob.Match ("a[b", "ab"),
          "a malformed pattern matches nothing");
   Check (Soja.Glob.Match ("a*b*c", "aXXbYYc")
          and then not Soja.Glob.Match ("a*b*c", "aXXbYY"), "glob two stars");
   Check (Soja.Glob.Match ("?", "é") and then Soja.Glob.Match ("é?", "éx")
          and then Soja.Glob.Match ("[à-ü]", "é"), "glob UTF-8 characters");
   Check (Soja.Glob.Match ("https://*", "https://x.org")
          and then Soja.Glob.Match ("localhost:*", "localhost:8080"),
          "glob origin patterns");

   ------------------------------------------------------------------
   --  UTF-8
   ------------------------------------------------------------------
   Check (Soja.Utf8.Is_Valid ("héllo 日本 " & Character'Val (16#F0#)
            & Character'Val (16#9F#) & Character'Val (16#98#)
            & Character'Val (16#80#)), "valid UTF-8");
   Check (not Soja.Utf8.Is_Valid ("" & Character'Val (16#C0#) & Character'Val (16#80#))
          and then not Soja.Utf8.Is_Valid
            ("" & Character'Val (16#ED#) & Character'Val (16#A0#)
             & Character'Val (16#80#))
          and then not Soja.Utf8.Is_Valid
            ("" & Character'Val (16#F4#) & Character'Val (16#90#)
             & Character'Val (16#80#) & Character'Val (16#80#))
          and then not Soja.Utf8.Is_Valid ("a" & Character'Val (16#80#))
          and then not Soja.Utf8.Is_Valid
            ("" & Character'Val (16#E2#) & Character'Val (16#82#)),
          "overlong, surrogate, too large, lone continuation, truncated");
   Check (Soja.Utf8.To_Valid ("a" & Character'Val (16#80#) & Character'Val (16#81#) & "b")
          = "a" & Character'Val (16#EF#) & Character'Val (16#BF#)
            & Character'Val (16#BD#) & "b",
          "a run of invalid bytes is one U+FFFD");
   Check (Soja.Utf8.To_Valid ("fine é") = "fine é", "valid text is kept");

   ------------------------------------------------------------------
   --  The HTTP head
   ------------------------------------------------------------------
   declare
      F   : constant Fake_Access := New_Fake
        ("GET /socket?x=1 HTTP/1.1" & CRLF
         & "Host: bouncer.example.org:8080" & CRLF
         & "oRiGiN: https://app.example.com:3000" & CRLF
         & "Connection: keep-alive, Upgrade" & CRLF
         & "X-Test: a:b:c é ""q"" 12" & CRLF
         & CRLF & "leftover");
      Req : Soja.Http.Request;
      Ok  : Boolean;
   begin
      Soja.Http.Read_Request (F.all, Req);
      Check (To_String (Req.Method) = "GET" and then Soja.Http.Path (Req) = "/socket"
             and then To_String (Req.Target) = "/socket?x=1"
             and then Req.Major = 1 and then Req.Minor = 1, "request line");
      Check (Soja.Http.Host (Req) = "bouncer.example.org:8080"
             and then Soja.Http.Get (Req, "ORIGIN") = "https://app.example.com:3000",
             "fields, any case");
      Check (Soja.Http.Has_Token (Req, "connection", "upgrade")
             and then not Soja.Http.Has_Token (Req, "connection", "close"),
             "a token of a list");
      Check (Soja.Http.Get (Req, "x-test") = "a:b:c é ""q"" 12",
             "a value with colons, non-ASCII, quotes, digits: "
             & Soja.Http.Get (Req, "x-test"));
      Check (To_String (Req.Leftover) = "leftover", "bytes after the head");
      Check (Soja.Http.URL_Host ("https://example.com:8080/p?q", Ok)
             = "example.com:8080" and then Ok, "URL host");
      Check (Soja.Http.URL_Host ("https://u:p@h.org/", Ok) = "h.org" and then Ok,
             "URL host without userinfo");
      Check (Soja.Http.URL_Host ("null", Ok) = "" and then Ok, "Origin: null");
      declare
         H : constant String := Soja.Http.URL_Host ("https://a b", Ok);
         pragma Unreferenced (H);
      begin
         Check (not Ok, "a URL with a space");
      end;
   end;

   declare
      procedure Bad (Text, What : String) is
         F   : constant Fake_Access := New_Fake (Text);
         Req : Soja.Http.Request;
      begin
         Soja.Http.Read_Request (F.all, Req);
         Check (False, What & " was accepted");
      exception
         when Soja.Http.Bad_Request => null;
      end Bad;
   begin
      Bad ("GET /x" & CRLF & CRLF, "a request line of two fields");
      Bad ("GET /x HTTP/1.1" & CRLF & CRLF, "HTTP/1.1 without Host");
      Bad ("GET /x HTTP/one" & CRLF & "Host: h" & CRLF & CRLF, "a bad version");
      Bad ("GET /x HTTP/1.1" & CRLF & "Host: h" & CRLF & "Foo : bar" & CRLF
           & CRLF, "a space before the colon");
      Bad ("GET /x HTTP/1.1" & CRLF & "Host: h" & CRLF & "no colon" & CRLF
           & CRLF, "a field without a colon");
      Bad ("GET /x HTTP/1.1" & CRLF & "Host: h" & CRLF, "an unfinished head");
      declare
         F   : constant Fake_Access := New_Fake ("");
         Req : Soja.Http.Request;
      begin
         Soja.Http.Read_Request (F.all, Req);
         Check (False, "an empty connection was a request");
      exception
         when Soja.Http.Closed => null;
      end;
      declare
         F   : constant Fake_Access :=
           New_Fake ("GET /x HTTP/1.0" & ASCII.LF & ASCII.LF);
         Req : Soja.Http.Request;
      begin
         Soja.Http.Read_Request (F.all, Req);
         Check (Req.Minor = 0, "HTTP/1.0 needs no Host; bare LF line ends");
      end;
   end;

   declare
      function Fwd (Fields : String) return String is
         F   : constant Fake_Access := New_Fake
           ("GET / HTTP/1.1" & CRLF & "Host: h" & CRLF & Fields & CRLF);
         Req : Soja.Http.Request;
      begin
         Soja.Http.Read_Request (F.all, Req);
         return Soja.Http.Forwarded_For (Req);
      end Fwd;
   begin
      Check (Fwd ("Forwarded: for=1.2.3.4;proto=https" & CRLF) = "1.2.3.4",
             "Forwarded for");
      Check (Fwd ("Forwarded: proto=https; For=""[2001:db8::1]:4711""" & CRLF)
             = "[2001:db8::1]:4711", "a quoted, upper-case for");
      Check (Fwd ("X-Forwarded-For: 5.6.7.8" & CRLF) = "5.6.7.8",
             "X-Forwarded-For");
      Check (Fwd ("Forwarded: for=1.1.1.1" & CRLF
                  & "X-Forwarded-For: 2.2.2.2" & CRLF) = "1.1.1.1",
             "Forwarded wins");
      Check (Fwd ("Forwarded: for=[::1]" & CRLF) = "",
             "an unparsable Forwarded");
      Check (Fwd ("Forwarded: for=a, for=b" & CRLF) = "", "a list");
      Check (Fwd ("") = "", "none");
   end;

   Check (Soja.Web.Accept_Key ("dGhlIHNhbXBsZSBub25jZQ==")
          = "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=", "the RFC 6455 example key");

   ------------------------------------------------------------------
   --  The WebSocket connection
   ------------------------------------------------------------------
   declare
      function New_Conn (Incoming : String; F : out Fake_Access)
         return Soja.Conn.Ws.Ws_IRC_Conn_Access is
      begin
         F := New_Fake (Incoming);
         return Soja.Conn.Ws.Create (As_Stream (F), "198.51.100.1:99");
      end New_Conn;

      F : Fake_Access;
      C : Soja.Conn.Ws.Ws_IRC_Conn_Access;
   begin
      --  Messages, in a ping, a pong and a fragmented message's company.
      C := New_Conn
        (Client_Frame (1, "PING :one")
         & Client_Frame (9, "p1")
         & Client_Frame (10, "ignored")
         & Client_Frame (1, "PRIVMSG #c :frag", Fin => False)
         & Client_Frame (9, "p2")
         & Client_Frame (0, "ment", Fin => False)
         & Client_Frame (0, "ed", Fin => True)
         & Client_Frame (2, "NOTICE x :binary" & CRLF)
         & Client_Frame (1, "PING :" & (1 .. 1000 => 'z')), F);
      Check (Soja.Conn.Ws.Remote_Addr (C.all) = "198.51.100.1:99", "Remote_Addr");
      Check (Param (Soja.Conn.Ws.Read_Message (C.all), 0) = "one", "a text message");
      declare
         M : constant Message := Soja.Conn.Ws.Read_Message (C.all);
      begin
         Check (To_String (M.Command) = "PRIVMSG"
                and then Param (M, 1) = "fragmented", "a fragmented message");
      end;
      Check (Frames (To_String (F.Sent)) = " 10:p1| 10:p2|",
             "pings are answered with pongs: " & Frames (To_String (F.Sent)));
      Check (To_String (Soja.Conn.Ws.Read_Message (C.all).Command) = "NOTICE",
             "a binary message, its line end trimmed");
      Check (Param (Soja.Conn.Ws.Read_Message (C.all), 0)'Length = 1000,
             "a long message (16-bit length)");
      --  Writing.
      Soja.Conn.Ws.Write_Message (C.all, Parse_Message (":srv PONG srv :one two"));
      Soja.Conn.Ws.Write_Message
        (C.all, Parse_Message ("PRIVMSG #c :" & (1 .. 300 => 'y')));
      Check (Contains (To_String (F.Sent), ":srv PONG srv :one two")
             and then Contains (To_String (F.Sent), (1 .. 300 => 'y')),
             "messages are written, without a line end: "
             & Ada.Strings.Fixed.Head (Frames (To_String (F.Sent)), 120));
      Check (not Contains (To_String (F.Sent), "one two" & CRLF),
             "no line end in a frame");
      --  End of the stream.
      begin
         declare
            M : constant Message := Soja.Conn.Ws.Read_Message (C.all);
            pragma Unreferenced (M);
         begin
            Check (False, "read past the end");
         end;
      exception
         when Ada.IO_Exceptions.End_Error => null;
      end;
   end;

   declare
      F : Fake_Access;
      C : Soja.Conn.Ws.Ws_IRC_Conn_Access;

      function Fresh (Incoming : String) return Soja.Conn.Ws.Ws_IRC_Conn_Access is
      begin
         F := New_Fake (Incoming);
         return Soja.Conn.Ws.Create (As_Stream (F), "x");
      end Fresh;

      function Sent_Close_Code return Natural is
         Fr : constant String := After_Head ("" & CRLF & CRLF & To_String (F.Sent));
      begin
         --  The first frame must be a close frame; its status.
         Check (Character'Pos (Fr (Fr'First)) mod 16 = 8,
                "a close frame was sent");
         return Close_Code (Fr (Fr'First + 2 .. Fr'Last));
      end Sent_Close_Code;
   begin
      --  Close frame from the peer: normal and going away are the end.
      C := Fresh (Client_Frame (8, Character'Val (3) & Character'Val (232)));
      begin
         declare
            M : constant Message := Soja.Conn.Ws.Read_Message (C.all);
            pragma Unreferenced (M);
         begin
            Check (False, "a close frame returned a message");
         end;
      exception
         when Ada.IO_Exceptions.End_Error =>
            Check (Sent_Close_Code = 1000 and then F.Is_Shut,
                   "the close is echoed and the stream shut down");
      end;
      C := Fresh (Client_Frame (8, Character'Val (3) & Character'Val (233)));
      begin
         declare
            M : constant Message := Soja.Conn.Ws.Read_Message (C.all);
            pragma Unreferenced (M);
         begin
            Check (False, "going away returned a message");
         end;
      exception
         when Ada.IO_Exceptions.End_Error => null;
      end;
      C := Fresh (Client_Frame (8, Character'Val (3) & Character'Val (234)));
      Check (Raised_Data_Error (C), "another close status is an error");

      --  Protocol violations: a close frame with the status, and an error.
      C := Fresh (Client_Frame (1, "PING :x", Masked => False));
      Check (Raised_Data_Error (C) and then Sent_Close_Code = 1002,
             "an unmasked frame");
      C := Fresh (Client_Frame (1, "PING :x", Rsv => 4));
      Check (Raised_Data_Error (C) and then Sent_Close_Code = 1002, "RSV bits");
      C := Fresh (Client_Frame (3, "x"));
      Check (Raised_Data_Error (C) and then Sent_Close_Code = 1002, "an unknown opcode");
      C := Fresh (Client_Frame (9, "p", Fin => False));
      Check (Raised_Data_Error (C) and then Sent_Close_Code = 1002,
             "a fragmented control frame");
      C := Fresh (Client_Frame (9, (1 .. 126 => 'p')));
      Check (Raised_Data_Error (C) and then Sent_Close_Code = 1002,
             "a control frame over 125 bytes");
      C := Fresh (Client_Frame (0, "x"));
      Check (Raised_Data_Error (C) and then Sent_Close_Code = 1002,
             "a continuation without a message");
      C := Fresh (Client_Frame (1, "a", Fin => False) & Client_Frame (1, "b"));
      Check (Raised_Data_Error (C) and then Sent_Close_Code = 1002,
             "a new message inside a fragmented one");
      C := Fresh (Client_Frame (1, "PRIVMSG #c :" & Character'Val (16#80#)));
      Check (Raised_Data_Error (C) and then Sent_Close_Code = 1007,
             "a text message that is not UTF-8");
      C := Fresh (Client_Frame (1, (1 .. Soja.Conn.Ws.Read_Limit + 1 => 'a')));
      Check (Raised_Data_Error (C) and then Sent_Close_Code = 1009,
             "a message over the read limit");
      C := Fresh (Client_Frame (1, "a" & (1 .. Soja.Conn.Ws.Read_Limit - 10 => 'a'),
                                Fin => False)
                  & Client_Frame (0, (1 .. 20 => 'b')));
      Check (Raised_Data_Error (C) and then Sent_Close_Code = 1009,
             "fragments that add up to over the limit");
   end;

   ------------------------------------------------------------------
   --  Close, and when the socket is released
   ------------------------------------------------------------------
   declare
      F : constant Fake_Access := New_Fake ("");
      C : constant Soja.Conn.Ws.Ws_IRC_Conn_Access :=
        Soja.Conn.Ws.Create (As_Stream (F), "x");
   begin
      Soja.Conn.Ws.Close (C.all);
      Check (F.Is_Shut and then not F.Released,
             "closed, but the handler is not done: not released yet");
      Check (Frames (To_String (F.Sent)) = " 8:" & Character'Val (3)
             & Character'Val (232) & "|", "Close sends a normal close frame");
      Soja.Conn.Ws.Handler_Done (C);
      Check (F.Released, "released once closed and done");
      --  A write after that fails instead of touching the socket.
      begin
         Soja.Conn.Ws.Write_Message (C.all, Parse_Message ("PING :x"));
         Check (False, "a write after release");
      exception
         when Ada.IO_Exceptions.Use_Error => null;
      end;
      Soja.Conn.Ws.Close (C.all);   --  harmless
   end;
   declare
      F : constant Fake_Access := New_Fake ("");
      C : constant Soja.Conn.Ws.Ws_IRC_Conn_Access :=
        Soja.Conn.Ws.Create (As_Stream (F), "x");
   begin
      Soja.Conn.Ws.Handler_Done (C);
      Check (not F.Released, "done, but not closed: not released yet");
      Soja.Conn.Ws.Close (C.all);
      Check (F.Released, "released by the Close that came last");
   end;

   ------------------------------------------------------------------
   --  The web handlers
   ------------------------------------------------------------------
   declare
      Srv : aliased Soja.Server.Server;
      Cfg : constant Soja.Server.Server_Config_Access :=
        new Soja.Server.Server_Config;

      Seen_Remote : Unbounded_String;
      Seen_Text   : Unbounded_String;

      procedure Echo (IC : not null Soja.Conn.IRC_Conn_Access) is
         M : constant Message := Soja.Conn.Read_Message (IC.all);
      begin
         Seen_Remote := To_Unbounded_String (Soja.Conn.Remote_Addr (IC.all));
         Seen_Text := To_Unbounded_String (Param (M, 0));
         Soja.Conn.Write_Message (IC.all, Parse_Message ("PONG :" & Param (M, 0)));
         Soja.Conn.Close (IC.all);
      end Echo;

      Key_Line : constant String :=
        "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==" & CRLF;

      function Upgrade_Request
        (Path : String := "/socket"; Extra : String := "";
         Method : String := "GET"; Version : String := "13";
         Key : Boolean := True; Host : String := "bouncer.example.org")
         return String is
        (Method & " " & Path & " HTTP/1.1" & CRLF
         & "Host: " & Host & CRLF
         & "Upgrade: websocket" & CRLF & "Connection: keep-alive, Upgrade" & CRLF
         & (if Key then Key_Line else "")
         & "Sec-WebSocket-Version: " & Version & CRLF & Extra & CRLF);

      --  Serves Request; the Fake it was served on.
      function Run
        (Request : String; Http : Boolean := False; Addr : String := "")
         return Fake_Access
      is
         F : constant Fake_Access := New_Fake (Request, Addr);
      begin
         Seen_Remote := Null_Unbounded_String;
         Seen_Text := Null_Unbounded_String;
         if Http then
            Soja.Web.Handle_Http (Srv, As_Stream (F), Echo'Unrestricted_Access);
         else
            Soja.Web.Handle_Ws (Srv, As_Stream (F), Echo'Unrestricted_Access);
         end if;
         return F;
      end Run;

      function Status (F : Fake_Access) return String is
         S : constant String := To_String (F.Sent);
      begin
         return S (S'First .. Ada.Strings.Fixed.Index (S, CRLF) - 1);
      end Status;
   begin
      Soja.Server.Initialize (Srv);
      Cfg.HTTP_Origins.Append (To_Unbounded_String ("*.Allowed.com"));
      Cfg.Accept_Proxy_IPs :=
        Soja.Config.Parse ("accept-proxy-ip 10.0.0.0/8" & ASCII.LF).Accept_Proxy_IPs;
      Soja.Server.Set_Config (Srv, Cfg);

      --  A good upgrade, with the first frame sent with the request.
      declare
         F : constant Fake_Access := Run
           (Upgrade_Request (Extra => "Sec-WebSocket-Protocol: foo, text.ircv3.net"
                                      & CRLF)
            & Client_Frame (1, "PING :hello"));
         S : constant String := To_String (F.Sent);
      begin
         Check (Status (F) = "HTTP/1.1 101 Switching Protocols", "101: " & Status (F));
         Check (Contains (S, "Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=" & CRLF)
                and then Contains (S, "Upgrade: websocket" & CRLF)
                and then Contains (S, "Connection: Upgrade" & CRLF)
                and then Contains (S, "Sec-WebSocket-Protocol: text.ircv3.net" & CRLF),
                "handshake fields: " & S);
         Check (To_String (Seen_Text) = "hello"
                and then To_String (Seen_Remote) = "203.0.113.9:4000",
                "the handler ran on the connection");
         Check (Starts (Frames (After_Head (S)), " 1:PONG hello|"),
                "and wrote a text frame: " & Frames (After_Head (S)));
         Check (F.Released, "the socket was released at the end");
      end;

      --  No offered subprotocol: none is chosen.
      declare
         F : constant Fake_Access :=
           Run (Upgrade_Request & Client_Frame (1, "PING :x"));
      begin
         Check (Status (F) = "HTTP/1.1 101 Switching Protocols"
                and then not Contains (To_String (F.Sent), "Sec-WebSocket-Protocol"),
                "no subprotocol");
      end;

      --  The ws listeners serve any path.
      Check (Status (Run (Upgrade_Request (Path => "/anything")
                          & Client_Frame (1, "PING :x"))) = "HTTP/1.1 101 Switching Protocols",
             "ws: any path");

      --  Refusals (nhooyr's statuses).
      declare
         F : Fake_Access;
      begin
         F := Run ("GET /socket HTTP/1.1" & CRLF & "Host: h" & CRLF & CRLF);
         Check (Starts (Status (F), "HTTP/1.1 426") and then F.Released
                and then Contains (To_String (F.Sent), "Connection header"),
                "no Upgrade headers: " & Status (F));
         F := Run ("GET /socket HTTP/1.1" & CRLF & "Host: h" & CRLF
                   & "Connection: Upgrade" & CRLF & "Upgrade: h2c" & CRLF & CRLF);
         Check (Starts (Status (F), "HTTP/1.1 426")
                and then Contains (To_String (F.Sent), "Upgrade header"),
                "a different Upgrade");
         F := Run (Upgrade_Request (Method => "POST"));
         Check (Starts (Status (F), "HTTP/1.1 405"), "POST");
         F := Run (Upgrade_Request (Version => "12"));
         Check (Starts (Status (F), "HTTP/1.1 400")
                and then Contains (To_String (F.Sent), "Sec-WebSocket-Version: 13"),
                "another version");
         F := Run (Upgrade_Request (Key => False));
         Check (Starts (Status (F), "HTTP/1.1 400"), "no key");
         F := Run ("not http" & CRLF & CRLF);
         Check (Starts (Status (F), "HTTP/1.1 400") and then F.Released,
                "garbage");
         F := Run ("");
         Check (To_String (F.Sent) = "" and then F.Released, "an empty connection");
      end;

      --  Origins: the request's own host, a configured pattern; else 403.
      declare
         function Origin_Status (Origin : String) return String is
           (Status (Run (Upgrade_Request
                           (Extra => "Origin: " & Origin & CRLF)
                         & Client_Frame (1, "PING :x"))));
      begin
         Check (Origin_Status ("https://bouncer.example.org") = "HTTP/1.1 101 Switching Protocols",
                "same host");
         Check (Origin_Status ("https://BOUNCER.example.org") = "HTTP/1.1 101 Switching Protocols",
                "same host, any case");
         Check (Origin_Status ("https://app.allowed.com") = "HTTP/1.1 101 Switching Protocols",
                "a pattern, any case");
         Check (Starts (Origin_Status ("https://evil.org"), "HTTP/1.1 403"),
                "another origin");
         Check (Starts (Origin_Status ("null"), "HTTP/1.1 403"), "Origin: null");
         Check (Starts (Origin_Status ("https://a b"), "HTTP/1.1 403"),
                "an unparsable origin");
      end;

      --  Behind a trusted proxy the client's address is in Forwarded.
      declare
         Fw : constant String := "Forwarded: for=""192.0.2.60:1234""" & CRLF;
         F  : Fake_Access;
      begin
         F := Run (Upgrade_Request (Extra => Fw) & Client_Frame (1, "PING :x"),
                   Addr => "10.1.2.3:5555");
         Check (To_String (Seen_Remote) = "192.0.2.60:1234",
                "a trusted proxy: " & To_String (Seen_Remote));
         F := Run (Upgrade_Request (Extra => Fw) & Client_Frame (1, "PING :x"),
                   Addr => "203.0.113.9:5555");
         Check (To_String (Seen_Remote) = "203.0.113.9:5555",
                "an untrusted peer cannot spoof it");
         F := Run (Upgrade_Request & Client_Frame (1, "PING :x"),
                   Addr => "10.1.2.3:5555");
         Check (To_String (Seen_Remote) = "10.1.2.3:5555",
                "a trusted proxy without Forwarded");
      end;

      --  The mux of the http listeners.
      Check (Status (Run (Upgrade_Request & Client_Frame (1, "PING :x"), Http => True))
             = "HTTP/1.1 101 Switching Protocols", "http: /socket");
      declare
         F : Fake_Access;
      begin
         F := Run (Upgrade_Request (Path => "/"), Http => True);
         Check (Starts (Status (F), "HTTP/1.1 404")
                and then Contains (To_String (F.Sent), "404 page not found")
                and then F.Released, "http: /");
         F := Run (Upgrade_Request (Path => "/uploads/x"), Http => True);
         Check (Starts (Status (F), "HTTP/1.1 404")
                and then Contains (To_String (F.Sent), "Content-Security-Policy: sandbox")
                and then Contains (To_String (F.Sent), "media-src 'self'"),
                "http: uploads without an uploader");
         F := Run (Upgrade_Request (Path => "/uploads",
                                    Extra => "Origin: https://evil.org" & CRLF),
                   Http => True);
         Check (Starts (Status (F), "HTTP/1.1 403"), "http: uploads, a foreign origin");
         F := Run (Upgrade_Request (Path => "/uploadsx"), Http => True);
         Check (Starts (Status (F), "HTTP/1.1 404")
                and then not Contains (To_String (F.Sent), "Content-Security"),
                "http: /uploadsx is not /uploads");

         --  /icon: 404 without an icon file, the file with one.
         F := Run (Upgrade_Request (Path => "/icon"), Http => True);
         Check (Starts (Status (F), "HTTP/1.1 404"), "http: /icon, no icon");
         declare
            Icon : constant String := "/tmp/soja_icon_check.png";
            Out_F : Ada.Streams.Stream_IO.File_Type;
         begin
            Ada.Streams.Stream_IO.Create (Out_F, Ada.Streams.Stream_IO.Out_File,
                                          Icon);
            Ada.Streams.Stream_IO.Write
              (Out_F, [16#89#, 16#50#, 16#4E#, 16#47#, 16#0D#, 16#0A#]);
            Ada.Streams.Stream_IO.Close (Out_F);
            Cfg.Icon_Path := To_Unbounded_String (Icon);
            F := Run (Upgrade_Request (Path => "/icon"), Http => True);
            Check (Starts (Status (F), "HTTP/1.1 200")
                   and then Contains (To_String (F.Sent),
                                      "Content-Type: image/png"),
                   "http: /icon, the file: " & Status (F));
            Cfg.Icon_Path := Null_Unbounded_String;
            Ada.Directories.Delete_File (Icon);
         end;
      end;
   end;

   Ada.Text_IO.Put_Line ("ALL PASS");
exception
   when E : others =>
      Ada.Text_IO.Put_Line
        ("FAILED: " & Ada.Exceptions.Exception_Information (E));
      GNAT.OS_Lib.OS_Exit (1);
end Web_Check;
