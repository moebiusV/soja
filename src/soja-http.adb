pragma Ada_2022;

with Ada.Characters.Handling;
with Ada.Strings.Fixed;
with Ada.Streams;

with Http_Head;
with Http_Head.Parser;

package body Soja.Http is

   use Ada.Streams;
   use type Http_Head.Request_line_Access;
   use type Http_Head.Field_Access;

   CRLF : constant String := ASCII.CR & ASCII.LF;

   function Lower (S : String) return String is
     (Ada.Characters.Handling.To_Lower (S));

   function To_Bytes (S : String) return Stream_Element_Array is
      R : Stream_Element_Array (1 .. Stream_Element_Offset (S'Length));
   begin
      for I in S'Range loop
         R (Stream_Element_Offset (I - S'First + 1)) :=
           Stream_Element (Character'Pos (S (I)));
      end loop;
      return R;
   end To_Bytes;

   function Trim_Blanks (S : String) return String is
      First : Natural := S'First;
      Last  : Natural := S'Last;
   begin
      while First <= Last
        and then (S (First) = ' ' or else S (First) = ASCII.HT)
      loop
         First := First + 1;
      end loop;
      while Last >= First
        and then (S (Last) = ' ' or else S (Last) = ASCII.HT)
      loop
         Last := Last - 1;
      end loop;
      return S (First .. Last);
   end Trim_Blanks;

   ----------------------------------------------------------------------
   --  Reading a request
   ----------------------------------------------------------------------

   --  One line of the head, read by the generated parser
   --  (grammars/http-head.hbnf): a request line or a header field.
   function Parse_Line (Line : String) return Http_Head.Head_line_Type is
   begin
      return Http_Head.Parser.Parse_Text (Line);
   exception
      when Http_Head.Parser.Parse_Error | Constraint_Error =>
         raise Bad_Request with "malformed HTTP request";
   end Parse_Line;

   --  A version number is one digit, as in HTTP/1.1.
   function Valid_Version (Major, Minor : Long_Long_Integer) return Boolean is
     (Major in 0 .. 9 and then Minor in 0 .. 9);

   procedure Read_Request
     (S : in out Soja.Byte_Stream.Stream'Class; R : out Request)
   is
      Chunk    : Stream_Element_Array (1 .. 4096);
      Last     : Stream_Element_Offset;
      Data     : Unbounded_String;      --  received, not yet split into lines
      Total    : Natural := 0;
      Got_Line : Boolean := False;      --  the request line is read
      Done     : Boolean := False;

      procedure Handle_Line (Line : String) is
      begin
         if Got_Line and then Line'Length = 0 then
            Done := True;
            return;
         end if;
         declare
            Parsed : Http_Head.Head_line_Type := Parse_Line (Line);
         begin
            if not Got_Line then
               --  METHOD SP target SP HTTP/x.y
               if Parsed.Request_line = null then
                  Http_Head.Parser.Free_Head_line (Parsed);
                  raise Bad_Request with "malformed HTTP request";
               end if;
               declare
                  RL : Http_Head.Request_line_Type renames
                    Parsed.Request_line.all;
                  V  : Http_Head.Version_Type renames RL.Version.all;
               begin
                  if not Valid_Version (V.Major, V.Minor) then
                     Http_Head.Parser.Free_Head_line (Parsed);
                     raise Bad_Request with "malformed HTTP version";
                  end if;
                  R := (Method => RL.Method, Target => RL.Target,
                        Major  => Natural (V.Major),
                        Minor  => Natural (V.Minor), others => <>);
               end;
               Got_Line := True;
            else
               if Parsed.Field = null then
                  Http_Head.Parser.Free_Head_line (Parsed);
                  raise Bad_Request with "malformed MIME header line";
               end if;
               R.Headers.Append
                 (Header'
                    (Name  => To_Unbounded_String
                                (Lower (To_String (Parsed.Field.Field_name))),
                     Value => To_Unbounded_String
                                (Trim_Blanks
                                   (To_String (Parsed.Field.Field_value)))));
            end if;
            Http_Head.Parser.Free_Head_line (Parsed);
         end;
      end Handle_Line;
   begin
      R := (others => <>);
      while not Done loop
         --  The complete lines we have.
         loop
            declare
               S_Data : constant String := To_String (Data);
               NL     : constant Natural :=
                 Ada.Strings.Fixed.Index (S_Data, "" & ASCII.LF);
            begin
               exit when NL = 0;
               declare
                  Stop : constant Natural :=
                    (if NL > 1 and then S_Data (NL - 1) = ASCII.CR
                     then NL - 2 else NL - 1);
                  --  (A request may start with blank lines; net/http skips
                  --  them, as RFC 7230 asks.)
                  Line : constant String := S_Data (1 .. Stop);
               begin
                  Data := To_Unbounded_String (S_Data (NL + 1 .. S_Data'Last));
                  if Got_Line or else Line'Length > 0 then
                     Handle_Line (Line);
                  end if;
                  exit when Done;
               end;
            end;
         end loop;
         exit when Done;

         if Total > Max_Head_Bytes then
            raise Bad_Request with "request header too large";
         end if;
         S.Receive (Chunk, Last);
         if Last < Chunk'First then
            if Total = 0 then
               raise Closed;
            end if;
            raise Bad_Request with "unexpected EOF";
         end if;
         for I in Chunk'First .. Last loop
            Append (Data, Character'Val (Chunk (I)));
         end loop;
         Total := Total + Natural (Last - Chunk'First + 1);
      end loop;
      R.Leftover := Data;
      if R.Major = 1 and then R.Minor >= 1 and then Get (R, "host") = "" then
         raise Bad_Request with "missing required Host header";
      end if;
   end Read_Request;

   ----------------------------------------------------------------------
   --  Request fields
   ----------------------------------------------------------------------

   function Get (R : Request; Name : String) return String is
      N : constant String := Lower (Name);
   begin
      for H of R.Headers loop
         if To_String (H.Name) = N then
            return To_String (H.Value);
         end if;
      end loop;
      return "";
   end Get;

   function Has_Token (R : Request; Name, Token : String) return Boolean is
      N : constant String := Lower (Name);
      T : constant String := Lower (Token);
   begin
      for H of R.Headers loop
         if To_String (H.Name) = N then
            declare
               V     : constant String := To_String (H.Value);
               Start : Natural := V'First;
            begin
               for I in V'First .. V'Last + 1 loop
                  if I > V'Last or else V (I) = ',' then
                     if Lower (Trim_Blanks (V (Start .. I - 1))) = T then
                        return True;
                     end if;
                     Start := I + 1;
                  end if;
               end loop;
            end;
         end if;
      end loop;
      return False;
   end Has_Token;

   function Host (R : Request) return String is (Get (R, "host"));

   function Path (R : Request) return String is
      T : constant String := To_String (R.Target);
      Q : constant Natural := Ada.Strings.Fixed.Index (T, "?");
   begin
      return (if Q > 0 then T (T'First .. Q - 1) else T);
   end Path;

   ----------------------------------------------------------------------
   --  Responses
   ----------------------------------------------------------------------

   function Reason (Status : Positive) return String is
     (case Status is
         when 101 => "Switching Protocols",
         when 200 => "OK",
         when 400 => "Bad Request",
         when 403 => "Forbidden",
         when 404 => "Not Found",
         when 405 => "Method Not Allowed",
         when 426 => "Upgrade Required",
         when others => "Status");

   procedure Write_Response
     (S       : in out Soja.Byte_Stream.Stream'Class;
      Status  : Positive;
      Fields  : String := "";
      Content : String := "")
   is
      Code : constant String :=
        Ada.Strings.Fixed.Trim (Positive'Image (Status), Ada.Strings.Left);
      Len  : constant String :=
        Ada.Strings.Fixed.Trim
          (Natural'Image (Content'Length), Ada.Strings.Left);
   begin
      if Status = 101 then
         S.Send (To_Bytes
           ("HTTP/1.1 101 " & Reason (Status) & CRLF & Fields & CRLF));
      else
         S.Send (To_Bytes
           ("HTTP/1.1 " & Code & " " & Reason (Status) & CRLF & Fields
            & "Content-Length: " & Len & CRLF & "Connection: close" & CRLF
            & CRLF & Content));
      end if;
   end Write_Response;

   procedure Write_Error
     (S : in out Soja.Byte_Stream.Stream'Class;
      Status : Positive; Message : String; Fields : String := "")
   is
   begin
      Write_Response
        (S, Status,
         "Content-Type: text/plain; charset=utf-8" & CRLF
         & "X-Content-Type-Options: nosniff" & CRLF & Fields,
         Message & ASCII.LF);
   end Write_Error;

   ----------------------------------------------------------------------
   --  Origin and Forwarded
   ----------------------------------------------------------------------

   function URL_Host (URL : String; Ok : out Boolean) return String is
      Sep : constant Natural := Ada.Strings.Fixed.Index (URL, "://");
   begin
      Ok := True;
      for C of URL loop
         if Character'Pos (C) <= 32 or else Character'Pos (C) = 127 then
            Ok := False;
            return "";
         end if;
      end loop;
      if Sep = 0 then
         return "";   --  no authority: "null", a bare name, ...
      end if;
      declare
         Rest : constant String := URL (Sep + 3 .. URL'Last);
         Stop : Natural := Rest'Last + 1;
      begin
         for I in Rest'Range loop
            if Rest (I) = '/' or else Rest (I) = '?' or else Rest (I) = '#'
            then
               Stop := I;
               exit;
            end if;
         end loop;
         declare
            Auth : constant String := Rest (Rest'First .. Stop - 1);
            At_Sign : Natural := Auth'First - 1;
         begin
            for I in reverse Auth'Range loop
               if Auth (I) = '@' then
                  At_Sign := I;
                  exit;
               end if;
            end loop;
            return Auth (At_Sign + 1 .. Auth'Last);
         end;
      end;
   end URL_Host;

   --  mime.ParseMediaType ("hack; " & Text): the value of parameter "for",
   --  "" when there is none or Text does not parse.
   function Forwarded_Param (Text : String) return String is
      I : Natural := Text'First;
      Result : Unbounded_String;
      Seen   : Unbounded_String;   --  the names seen, "|"-delimited

      function Is_Token (C : Character) return Boolean is
        (C in 'a' .. 'z' or else C in 'A' .. 'Z' or else C in '0' .. '9'
         or else C in '!' | '#' | '$' | '%' | '&' | ''' | '*' | '+' | '-'
                    | '.' | '^' | '_' | '`' | '|' | '~');

      procedure Skip_Blanks is
      begin
         while I <= Text'Last
           and then (Text (I) = ' ' or else Text (I) = ASCII.HT)
         loop
            I := I + 1;
         end loop;
      end Skip_Blanks;

      Bad : exception;
   begin
      while True loop
         Skip_Blanks;
         if I > Text'Last then
            exit;
         end if;
         declare
            Start : constant Natural := I;
         begin
            while I <= Text'Last and then Is_Token (Text (I)) loop
               I := I + 1;
            end loop;
            if I = Start or else I > Text'Last or else Text (I) /= '=' then
               raise Bad;
            end if;
            declare
               Key : constant String := Lower (Text (Start .. I - 1));
               Val : Unbounded_String;
            begin
               I := I + 1;
               if I <= Text'Last and then Text (I) = '"' then
                  I := I + 1;
                  loop
                     if I > Text'Last then
                        raise Bad;
                     end if;
                     exit when Text (I) = '"';
                     if Text (I) = '\' and then I < Text'Last then
                        I := I + 1;
                     end if;
                     Append (Val, Text (I));
                     I := I + 1;
                  end loop;
                  I := I + 1;
               else
                  declare
                     VStart : constant Natural := I;
                  begin
                     while I <= Text'Last and then Is_Token (Text (I)) loop
                        I := I + 1;
                     end loop;
                     if I = VStart then
                        raise Bad;
                     end if;
                     Val := To_Unbounded_String (Text (VStart .. I - 1));
                  end;
               end if;
               if Ada.Strings.Fixed.Index (To_String (Seen), "|" & Key & "|")
                  > 0
               then
                  raise Bad;   --  duplicate parameter name
               end if;
               Append (Seen, "|" & Key & "|");
               if Key = "for" then
                  Result := Val;
               end if;
            end;
         end;
         Skip_Blanks;
         if I > Text'Last then
            exit;
         elsif Text (I) /= ';' then
            raise Bad;
         end if;
         I := I + 1;
      end loop;
      return To_String (Result);
   exception
      when Bad =>
         return "";
   end Forwarded_Param;

   function Forwarded_For (R : Request) return String is
      F : constant String := Get (R, "forwarded");
   begin
      return (if F = "" then Get (R, "x-forwarded-for")
              else Forwarded_Param (F));
   end Forwarded_For;

end Soja.Http;
