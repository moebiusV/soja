--  The HAProxy PROXY protocol, versions 1 (text) and 2 (binary): what a
--  trusted load balancer puts in front of a connection to tell us the real
--  client address.  soju uses go-proxyproto with the USE policy for peers in
--  `accept-proxy-ip`: a header, if one comes, sets the remote address;
--  without one the connection goes on as it is.
pragma Ada_2022;

with Ada.Strings.Unbounded;

with AWS.Net;

with Soja.Config;

package Soja.Proxy_Protocol is

   --  A malformed header, a connection that closed in the middle of one, or
   --  no complete header within the timeout.  The connection must be dropped.
   Proxy_Error : exception;

   --  What a header said.  Local is True when it carries no address (v1
   --  UNKNOWN, v2 LOCAL or an unspecified family): the connection's own
   --  address stays.
   type Info is record
      Local       : Boolean := True;
      Source_Host : Ada.Strings.Unbounded.Unbounded_String;
      Source_Port : Natural := 0;
      Dest_Host   : Ada.Strings.Unbounded.Unbounded_String;
      Dest_Port   : Natural := 0;
   end record;

   type Status is
     (Need_More,    --  the bytes so far could still be (the start of) a header
      No_Header,    --  this is not a header: plain data
      Header);      --  Consumed bytes are a complete header

   --  Look at the first bytes of a connection.  Proxy_Error when they start a
   --  header but it is malformed.
   procedure Examine
     (Data : String; State : out Status; Consumed : out Natural;
      Result : out Info);

   --  Read from Sock, after what is already in Buffer, until the start of the
   --  stream is known to be a header (consumed from Buffer, Result says what
   --  it held) or plain data (Buffer untouched, Result.Local).  Gives up with
   --  Proxy_Error after Timeout (go-proxyproto's ReadHeaderTimeout).
   procedure Read_Header
     (Sock    : in out AWS.Net.Socket_Type'Class;
      Buffer  : in out Ada.Strings.Unbounded.Unbounded_String;
      Timeout : Duration;
      Result  : out Info);

   --  net.ParseIP: dotted-quad IPv4 or colon-hex IPv6 (with "::").  An IPv4
   --  address is stored v4-mapped, as in Soja.Config.
   function Parse_IP
     (Text : String; Addr : out Soja.Config.IP_Addr) return Boolean;

   --  net.IP.String.
   function Image (Addr : Soja.Config.IP_Addr) return String;

   --  config.IPSet.Contains.
   function Contains
     (Set : Soja.Config.IPSet; Addr : Soja.Config.IP_Addr) return Boolean;

end Soja.Proxy_Protocol;
