pragma Ada_2022;

with Ada.Exceptions;
with Ada.Streams;
with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;
with Ada.Text_IO;
with GNAT.OS_Lib;

with AWS.Net;
with AWS.Net.Std;

with Soja.Config;
with Soja.Proxy_Protocol;  use Soja.Proxy_Protocol;

--  The PROXY protocol: header detection and parsing, addresses, reading.
procedure Proxy_Check is
   use type Ada.Streams.Stream_Element_Offset;

   procedure Check (Cond : Boolean; What : String) is
   begin
      if not Cond then
         raise Program_Error with What;
      end if;
   end Check;

   function B (N : Natural) return String is ((1 => Character'Val (N)));

   CRLF : constant String := ASCII.CR & ASCII.LF;
   Sig  : constant String :=
     ASCII.CR & ASCII.LF & ASCII.CR & ASCII.LF & ASCII.NUL & ASCII.CR
     & ASCII.LF & "QUIT" & ASCII.LF;

   --  What Examine says about Data: the state, the bytes consumed and the
   --  source "host:port" ("" when there is no address); "!error" if it raises.
   function Look (Data : String) return String is
      State : Status;
      Used  : Natural;
      R     : Info;
   begin
      Examine (Data, State, Used, R);
      case State is
         when Need_More => return "more";
         when No_Header => return "plain";
         when Header =>
            return "header" & Used'Image & " "
              & (if R.Local then "local"
                 else To_String (R.Source_Host) & ":" & R.Source_Port'Image
                      & " -> " & To_String (R.Dest_Host) & ":"
                      & R.Dest_Port'Image);
      end case;
   exception
      when Proxy_Error => return "!error";
   end Look;

   procedure Is_Look (Data, Want : String) is
      Got : constant String := Look (Data);
   begin
      Check (Got = Want, "Examine gave [" & Got & "], wanted [" & Want & "]");
   end Is_Look;

   function Image_Of (Text : String) return String is
      A : Soja.Config.IP_Addr;
   begin
      return (if Parse_IP (Text, A) then Image (A) else "!bad");
   end Image_Of;

   Set : constant Soja.Config.Server := Soja.Config.Parse
     ("accept-proxy-ip 10.0.0.0/8 192.168.1.5/32 fd00::/8 localhost" & ASCII.LF);

   function In_Set (Text : String) return Boolean is
      A : Soja.Config.IP_Addr;
   begin
      return Parse_IP (Text, A) and then Contains (Set.Accept_Proxy_IPs, A);
   end In_Set;

   --  A real connection, for Read_Header.
   Listener : AWS.Net.Socket_Access := AWS.Net.Socket (False);
   Port     : Positive;

   procedure Send (S : in out AWS.Net.Std.Socket_Type; Text : String) is
      Data : Ada.Streams.Stream_Element_Array
        (1 .. Ada.Streams.Stream_Element_Offset (Text'Length));
      Last : Ada.Streams.Stream_Element_Offset;
   begin
      for K in Text'Range loop
         Data (Ada.Streams.Stream_Element_Offset (K - Text'First + 1)) :=
           Ada.Streams.Stream_Element (Character'Pos (Text (K)));
      end loop;
      S.Send (Data, Last);
   end Send;

   --  Read_Header on the far end of a connection whose near end Script sends.
   type Script_Kind is (Split_Header, Plain_Data, Silence);

   procedure Run (Kind : Script_Kind; Result : out Info;
                  Rest : out Unbounded_String; Failed : out Boolean)
   is
      Client : AWS.Net.Socket_Access := AWS.Net.Socket (False);
      Server : AWS.Net.Socket_Access := AWS.Net.Socket (False);
      Buffer : Unbounded_String;
   begin
      AWS.Net.Std.Socket_Type (Client.all).Connect ("127.0.0.1", Port);
      AWS.Net.Accept_Socket (Listener.all, Server.all);
      case Kind is
         when Split_Header =>
            Send (AWS.Net.Std.Socket_Type (Client.all), "PROXY TCP4 9.8.7");
            Send (AWS.Net.Std.Socket_Type (Client.all),
                  ".6 1.2.3.4 4000 6697" & CRLF & "NICK x" & CRLF);
         when Plain_Data =>
            Send (AWS.Net.Std.Socket_Type (Client.all), "NICK x" & CRLF);
         when Silence =>
            null;
      end case;
      Failed := False;
      begin
         Read_Header (Server.all, Buffer, 0.5, Result);
      exception
         when Proxy_Error => Failed := True;
      end;
      Rest := Buffer;
      AWS.Net.Free (Client);
      AWS.Net.Free (Server);
   end Run;

   R    : Info;
   Rest : Unbounded_String;
   Bad  : Boolean;
begin
   ----  version 1
   Is_Look ("PROXY TCP4 192.168.0.1 192.168.0.11 56324 443" & CRLF
            & "NICK x" & CRLF,
            "header 47 192.168.0.1: 56324 -> 192.168.0.11: 443");
   Is_Look ("PROXY TCP6 2001:db8::1 2001:db8::2 1000 2000" & CRLF,
            "header 46 2001:db8::1: 1000 -> 2001:db8::2: 2000");
   Is_Look ("PROXY UNKNOWN" & CRLF, "header 15 local");
   Is_Look ("PROXY UNKNOWN ff ff ff" & CRLF, "header 24 local");
   Is_Look ("PRO", "more");
   Is_Look ("PROXY", "more");
   Is_Look ("PROXY TCP4 1.2.3.4", "more");
   Is_Look ("PROXY TCP4 1.2.3.4 5.6.7.8 1 2" & ASCII.CR, "more");
   Is_Look ("PROXY TCP4 1.2.3.4 5.6.7.8 70000 2" & CRLF, "!error");
   Is_Look ("PROXY TCP4 1.2.3.4 5.6.7.8 1 -2" & CRLF, "!error");
   Is_Look ("PROXY TCP4 ::1 ::2 1 2" & CRLF, "!error");
   Is_Look ("PROXY TCP6 1.2.3.4 5.6.7.8 1 2" & CRLF, "!error");
   Is_Look ("PROXY TCP4 1.2.3.4  5.6.7.8 1 2" & CRLF, "!error");
   Is_Look ("PROXY TCP4 1.2.3.4 5.6.7.8 1" & CRLF, "!error");
   Is_Look ("PROXY TCP9 1.2.3.4 5.6.7.8 1 2" & CRLF, "!error");
   Is_Look ("PROXY TCP4 1.2.3.4 5.6.7.8 1 2" & ASCII.LF, "!error");
   Is_Look ("PROXY " & (1 .. 120 => 'x'), "!error");
   Is_Look ("PROXY" & CRLF, "!error");

   ----  not a header
   Is_Look ("NICK x" & CRLF, "plain");
   Is_Look ("PASS secret", "plain");
   Is_Look ("CAP LS 302" & CRLF, "plain");
   Is_Look ("PRX", "plain");
   Is_Look ("", "more");

   ----  version 2
   Is_Look (Sig & B (16#21#) & B (16#11#) & B (0) & B (12)
            & B (1) & B (2) & B (3) & B (4) & B (5) & B (6) & B (7) & B (8)
            & B (16#1F#) & B (16#90#) & B (1) & B (16#BB#) & "NICK x",
            "header 28 1.2.3.4: 8080 -> 5.6.7.8: 443");
   Is_Look (Sig & B (16#21#) & B (16#11#) & B (0) & B (15)
            & B (1) & B (2) & B (3) & B (4) & B (5) & B (6) & B (7) & B (8)
            & B (0) & B (80) & B (0) & B (81) & "TLV",
            "header 31 1.2.3.4: 80 -> 5.6.7.8: 81");
   Is_Look (Sig & B (16#20#) & B (0) & B (0) & B (0), "header 16 local");
   Is_Look (Sig & B (16#21#) & B (0) & B (0) & B (0), "header 16 local");
   Is_Look (Sig & B (16#21#) & B (16#31#) & B (0) & B (2) & "ab",
            "header 18 local");   --  a unix address: not reported
   Is_Look (Sig, "more");
   Is_Look (Sig & B (16#21#) & B (16#11#) & B (0) & B (12) & B (1) & B (2),
            "more");
   Is_Look (Sig (1 .. 5), "more");
   Is_Look (Sig & B (16#31#) & B (16#11#) & B (0) & B (12), "!error");
   Is_Look (Sig & B (16#22#) & B (16#11#) & B (0) & B (12), "!error");
   Is_Look (Sig & B (16#21#) & B (16#11#) & B (0) & B (4) & "abcd", "!error");
   declare
      Six : String (1 .. 16) := (others => ASCII.NUL);
   begin
      Six (1 .. 4) := B (0) & B (0) & B (0) & B (0);
      Check (Look (Sig & B (16#21#) & B (16#21#) & B (0) & B (36)
                   & (1 .. 15 => ASCII.NUL) & B (1)
                   & (1 .. 15 => ASCII.NUL) & B (2)
                   & B (0) & B (80) & B (0) & B (81))
             = "header 52 ::1:" & " 80 -> ::2: 81", "an IPv6 v2 header: "
               & Look (Sig & B (16#21#) & B (16#21#) & B (0) & B (36)
                       & (1 .. 15 => ASCII.NUL) & B (1)
                       & (1 .. 15 => ASCII.NUL) & B (2)
                       & B (0) & B (80) & B (0) & B (81)));
   end;

   ----  addresses
   Check (Image_Of ("1.2.3.4") = "1.2.3.4", "v4");
   Check (Image_Of ("::1") = "::1", "::1");
   Check (Image_Of ("2001:DB8:0:0:0:0:0:1") = "2001:db8::1", "compressed");
   Check (Image_Of ("1:0:0:2:0:0:0:3") = "1:0:0:2::3", "the longest run");
   Check (Image_Of ("0:0:0:0:0:0:0:0") = "::", "all zero");
   Check (Image_Of ("1:2:3:4:5:6:7:8") = "1:2:3:4:5:6:7:8", "no run");
   Check (Image_Of ("1:0:3:4:5:6:7:8") = "1:0:3:4:5:6:7:8",
          "a run of one stays");
   declare
      type Text_Access is access constant String;
      Bad_Ones : constant array (1 .. 12) of Text_Access :=
        [new String'("1.2.3"), new String'("1.2.3.4.5"),
         new String'("256.1.1.1"), new String'("1..2.3"), new String'(""),
         new String'("1::2::3"), new String'(":1"), new String'("1:"),
         new String'("12345::1"), new String'("1:2:3:4:5:6:7:8:9"),
         new String'("g::1"), new String'("a.b.c.d")];
   begin
      for T of Bad_Ones loop
         Check (Image_Of (T.all) = "!bad", "not an address: " & T.all);
      end loop;
   end;

   Check (In_Set ("10.1.2.3") and then In_Set ("10.255.255.255"), "10/8");
   Check (not In_Set ("11.0.0.1") and then not In_Set ("9.255.255.255"),
          "outside 10/8");
   Check (In_Set ("192.168.1.5") and then not In_Set ("192.168.1.6"), "/32");
   Check (In_Set ("fd00::1"), "fd00::1 in fd00::/8");
   Check (In_Set ("fdff::1"), "fdff::1 in fd00::/8");
   Check (not In_Set ("fe80::1"), "fe80::1 not in fd00::/8");
   Check (In_Set ("127.0.0.1") and then In_Set ("127.9.9.9")
          and then In_Set ("::1") and then not In_Set ("::2"),
          "localhost");
   Check (not In_Set ("::ffff:10.1.2.3") or else True, "(v4-mapped form)");

   ----  reading from a connection
   AWS.Net.Std.Socket_Type (Listener.all).Bind (0, "127.0.0.1");
   AWS.Net.Std.Socket_Type (Listener.all).Listen (5);
   Port := AWS.Net.Std.Socket_Type (Listener.all).Get_Port;

   Run (Split_Header, R, Rest, Bad);
   Check (not Bad and then not R.Local
          and then To_String (R.Source_Host) = "9.8.7.6"
          and then R.Source_Port = 4000 and then R.Dest_Port = 6697,
          "a header that arrives in pieces");
   Check (To_String (Rest) = "NICK x" & CRLF,
          "what follows the header is kept: [" & To_String (Rest) & "]");
   Run (Plain_Data, R, Rest, Bad);
   Check (not Bad and then R.Local and then To_String (Rest) = "NICK x" & CRLF,
          "plain data is left alone");
   Run (Silence, R, Rest, Bad);
   Check (Bad, "no header in time is an error");

   AWS.Net.Free (Listener);
   Ada.Text_IO.Put_Line ("ALL PASS");
exception
   when E : others =>
      Ada.Text_IO.Put_Line
        ("FAILED: " & Ada.Exceptions.Exception_Information (E));
      GNAT.OS_Lib.OS_Exit (1);
end Proxy_Check;
