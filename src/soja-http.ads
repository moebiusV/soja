--  Soja.Http -- the little of HTTP/1.x that the WebSocket and web listeners
--  need: reading a request head, answering with a short response, and the
--  helpers net/http and nhooyr.io/websocket provide (the Origin host, the
--  Forwarded header).  Each connection serves one request and is then closed
--  (Go keeps it alive; nothing here needs that).
--
--  The request line and header fields are tokenised by the hbnf grammar
--  grammars/http-head.hbnf; the line framing is done here.
pragma Ada_2022;

with Ada.Containers.Vectors;
with Ada.Streams;
with Ada.Strings.Unbounded;

with Soja.Byte_Stream;

package Soja.Http is

   use Ada.Strings.Unbounded;

   --  Exception_Message is why, and is the body of the 400 response.
   Bad_Request : exception;
   --  The peer closed before it sent a request.
   Closed      : exception;

   --  http.DefaultMaxHeaderBytes.
   Max_Head_Bytes : constant := 1_048_576;

   type Header is record
      Name  : Unbounded_String;   --  lower-cased
      Value : Unbounded_String;
   end record;
   package Header_Vectors is new Ada.Containers.Vectors (Positive, Header);

   type Request is record
      Method   : Unbounded_String;
      Target   : Unbounded_String;
      Major    : Natural := 1;
      Minor    : Natural := 1;
      Headers  : Header_Vectors.Vector;
      --  Bytes the peer sent after the head.
      Leftover : Unbounded_String;
   end record;

   --  http.ReadRequest.  Bad_Request: malformed request line or fields, a
   --  head over Max_Head_Bytes, or an HTTP/1.1 request without Host.
   procedure Read_Request
     (S : in out Soja.Byte_Stream.Stream'Class; R : out Request);

   --  Header.Get: the first value of the field (any case), "" if none.
   function Get (R : Request; Name : String) return String;

   --  headerContainsTokenIgnoreCase: some value of the field, as a comma
   --  separated list, has Token (any case).
   function Has_Token (R : Request; Name, Token : String) return Boolean;

   --  req.Host.
   function Host (R : Request) return String;

   --  The request target without its query.
   function Path (R : Request) return String;

   --  A response: Status line, the extra header fields (each "Name: value"
   --  plus CRLF), Content-Length and Connection: close.
   procedure Write_Response
     (S       : in out Soja.Byte_Stream.Stream'Class;
      Status  : Positive;
      Fields  : String := "";
      Content : String := "");

   --  The status line and the header fields, then the empty line: for a
   --  response whose body is sent after, in pieces.  Fields has its own
   --  Content-Length (and Connection: close).
   procedure Write_Head
     (S      : in out Soja.Byte_Stream.Stream'Class;
      Status : Positive;
      Fields : String := "");

   --  The body of a request: its Content-Length (a request without one has no
   --  body).  A chunked body is not read (Chunked is True: the caller refuses
   --  it); a bad Content-Length is Valid = False.
   type Body_Cursor is record
      Pending   : Unbounded_String;     --  bytes read with the head, not used
      Remaining : Long_Long_Integer := 0;
      Length    : Long_Long_Integer := 0;
      Valid     : Boolean := True;
      Chunked   : Boolean := False;
   end record;

   function Open_Body (R : Request) return Body_Cursor;

   --  The next bytes of the body (Last < Buf'First at its end).
   procedure Read_Body
     (S    : in out Soja.Byte_Stream.Stream'Class;
      C    : in out Body_Cursor;
      Buf  : out Ada.Streams.Stream_Element_Array;
      Last : out Ada.Streams.Stream_Element_Offset);

   --  http.Error: a plain-text response, Message and a line feed.
   procedure Write_Error
     (S : in out Soja.Byte_Stream.Stream'Class;
      Status : Positive; Message : String; Fields : String := "");

   --  url.Parse (Origin).Host: "" when there is none; Ok is False when the
   --  URL is malformed (a control character or a space).
   function URL_Host (URL : String; Ok : out Boolean) return String;

   --  parseForwarded (h)["for"]: the Forwarded header's `for` parameter, or
   --  the X-Forwarded-For field when there is no Forwarded.  "" when there is
   --  none (or the Forwarded field does not parse, as mime.ParseMediaType).
   function Forwarded_For (R : Request) return String;

end Soja.Http;
