pragma Ada_2022;

with Ada.Characters.Handling;
with Ada.Strings.Fixed;

with Mime_Media;
with Mime_Media.Parser;

package body Soja.Mime is

   use Ada.Strings.Unbounded;

   function Lower (S : String) return String is
     (Ada.Characters.Handling.To_Lower (S));

   function Starts_With (S, Prefix : String) return Boolean is
     (S'Length >= Prefix'Length
      and then S (S'First .. S'First + Prefix'Length - 1) = Prefix);

   ----------------------------------------------------------------------
   --  Parsing
   ----------------------------------------------------------------------

   --  A quoted string without its quotes, and each backslash taken off with
   --  the character after it kept; a token as it is.
   function Value_Of (Raw : String) return String is
      Result : Unbounded_String;
      I      : Natural := Raw'First + 1;
   begin
      if Raw'Length = 0 or else Raw (Raw'First) /= '"' then
         return Raw;
      end if;
      while I < Raw'Last loop
         if Raw (I) = '\' and then I + 1 < Raw'Last then
            I := I + 1;
         end if;
         Append (Result, Raw (I));
         I := I + 1;
      end loop;
      return To_String (Result);
   end Value_Of;

   function Hex_Digit (C : Character) return Integer is
     (case C is
         when '0' .. '9' => Character'Pos (C) - Character'Pos ('0'),
         when 'a' .. 'f' => Character'Pos (C) - Character'Pos ('a') + 10,
         when 'A' .. 'F' => Character'Pos (C) - Character'Pos ('A') + 10,
         when others     => -1);

   --  RFC 2231: charset'language'percent-encoded text, as UTF-8.  Ok is False
   --  for a charset other than utf-8, us-ascii and iso-8859-1, or bad
   --  escapes.
   procedure Decode_Extended
     (Raw : String; Result : out Unbounded_String; Ok : out Boolean)
   is
      First  : constant Natural := Ada.Strings.Fixed.Index (Raw, "'");
      Second : constant Natural :=
        (if First = 0 then 0
         else Ada.Strings.Fixed.Index (Raw, "'", First + 1));
      Charset : constant String :=
        (if First = 0 then "" else Lower (Raw (Raw'First .. First - 1)));
      I : Natural;
   begin
      Result := Null_Unbounded_String;
      Ok := Second > 0
        and then Charset in "utf-8" | "us-ascii" | "iso-8859-1" | "";
      if not Ok then
         return;
      end if;
      I := Second + 1;
      while I <= Raw'Last loop
         if Raw (I) = '%' then
            if I + 2 > Raw'Last or else Hex_Digit (Raw (I + 1)) < 0
              or else Hex_Digit (Raw (I + 2)) < 0
            then
               Ok := False;
               return;
            end if;
            declare
               B : constant Natural :=
                 Hex_Digit (Raw (I + 1)) * 16 + Hex_Digit (Raw (I + 2));
            begin
               --  Latin-1 bytes above 0x7F are two bytes of UTF-8.
               if Charset = "iso-8859-1" and then B >= 16#80# then
                  Append (Result, Character'Val (16#C0# + B / 64));
                  Append (Result, Character'Val (16#80# + B mod 64));
               else
                  Append (Result, Character'Val (B));
               end if;
            end;
            I := I + 3;
         else
            Append (Result, Raw (I));
            I := I + 1;
         end if;
      end loop;
   end Decode_Extended;

   procedure Parse_Media_Type
     (Value  : String;
      Media  : out Unbounded_String;
      Params : out Param_Maps.Map;
      Ok     : out Boolean)
   is
      Tree     : Mime_Media.Media_Type;
      Extended : Param_Maps.Map;
   begin
      Media := Null_Unbounded_String;
      Params := Param_Maps.Empty_Map;
      Ok := False;
      begin
         Tree := Mime_Media.Parser.Parse_Text (Value);
      exception
         when Mime_Media.Parser.Parse_Error | Constraint_Error =>
            return;
      end;

      Media := To_Unbounded_String (Lower (To_String (Tree.Mtype)));
      Ok := True;
      for Item of Tree.Media_1 loop
         declare
            Name : constant String :=
              Lower (To_String (Item.Param.Param_name));
            Raw  : constant String := To_String (Item.Param.Param_value);
            Star : constant Boolean :=
              Name'Length > 1 and then Name (Name'Last) = '*';
            Key  : constant String :=
              (if Star then Name (Name'First .. Name'Last - 1) else Name);
            Decoded : Unbounded_String;
            Good    : Boolean := True;
         begin
            if Params.Contains (Name)
              or else (Star and then Extended.Contains (Key))
            then
               Ok := False;   --  a name used twice
            elsif Star then
               Decode_Extended (Value_Of (Raw), Decoded, Good);
               if Good then
                  Extended.Include (Key, To_String (Decoded));
               end if;
            else
               Params.Include (Name, Value_Of (Raw));
            end if;
         end;
      end loop;
      Mime_Media.Parser.Free_Media (Tree);

      --  An extended value stands in for the plain one.
      for C in Extended.Iterate loop
         Params.Include (Param_Maps.Key (C), Param_Maps.Element (C));
      end loop;
      if not Ok then
         Params := Param_Maps.Empty_Map;
         Media := Null_Unbounded_String;
      end if;
   end Parse_Media_Type;

   ----------------------------------------------------------------------
   --  Formatting
   ----------------------------------------------------------------------

   --  A token: not empty, printable ASCII, none of tspecials.
   function Is_Token (S : String) return Boolean is
     (S'Length > 0
      and then (for all C of S =>
                  Character'Pos (C) in 33 .. 126
                  and then C not in '(' | ')' | '<' | '>' | '@' | ',' | ';'
                                    | ':' | '\' | '"' | '/' | '[' | ']'
                                    | '?' | '='));

   function Needs_Encoding (S : String) return Boolean is
     (for some C of S =>
        (Character'Pos (C) < 32 or else Character'Pos (C) > 126)
        and then C /= ASCII.HT);

   function Percent (S : String) return String is
      Hex    : constant String := "0123456789ABCDEF";
      Result : Unbounded_String;
   begin
      for C of S loop
         if Character'Pos (C) <= 32 or else Character'Pos (C) >= 127
           or else C in '*' | ''' | '%' | '(' | ')' | '<' | '>' | '@' | ','
                        | ';' | ':' | '\' | '"' | '/' | '[' | ']' | '?' | '='
         then
            Append (Result, '%');
            Append (Result, Hex (Character'Pos (C) / 16 + 1));
            Append (Result, Hex (Character'Pos (C) mod 16 + 1));
         else
            Append (Result, C);
         end if;
      end loop;
      return To_String (Result);
   end Percent;

   function Quote (S : String) return String is
      Result : Unbounded_String := To_Unbounded_String ("""");
   begin
      for C of S loop
         if C in '"' | '\' then
            Append (Result, '\');
         end if;
         Append (Result, C);
      end loop;
      return To_String (Result) & '"';
   end Quote;

   function Param_Text (Name, Value : String) return String is
     ("; " & Name
      & (if Needs_Encoding (Value) then "*=utf-8''" & Percent (Value)
         elsif Is_Token (Value) then "=" & Value
         else "=" & Quote (Value)));

   function Format_Media_Type
     (Media : String; Params : Param_Maps.Map) return String
   is
      Slash : constant Natural := Ada.Strings.Fixed.Index (Media, "/");
      Valid : constant Boolean :=
        (if Slash = 0 then Is_Token (Media)
         else Is_Token (Media (Media'First .. Slash - 1))
              and then Is_Token (Media (Slash + 1 .. Media'Last)));
      Result : Unbounded_String := To_Unbounded_String (Lower (Media));
   begin
      if not Valid then
         return "";
      end if;
      for C in Params.Iterate loop
         Append (Result, Param_Text (Param_Maps.Key (C),
                                     Param_Maps.Element (C)));
      end loop;
      return To_String (Result);
   end Format_Media_Type;

   ----------------------------------------------------------------------
   --  By extension
   ----------------------------------------------------------------------

   function Type_By_Extension (Ext : String) return String is
     (declare
         E : constant String := Lower (Ext);
      begin
         (if E = ".avif" then "image/avif"
          elsif E = ".css" then "text/css; charset=utf-8"
          elsif E = ".gif" then "image/gif"
          elsif E in ".htm" | ".html" then "text/html; charset=utf-8"
          elsif E in ".jpeg" | ".jpg" then "image/jpeg"
          elsif E in ".js" | ".mjs" then "text/javascript; charset=utf-8"
          elsif E = ".json" then "application/json"
          elsif E = ".pdf" then "application/pdf"
          elsif E = ".png" then "image/png"
          elsif E = ".svg" then "image/svg+xml"
          elsif E = ".wasm" then "application/wasm"
          elsif E = ".webp" then "image/webp"
          elsif E = ".xml" then "text/xml; charset=utf-8"
          else ""));

   function Is_Inline (Media : String) return Boolean is
     (Media in "audio/aac" | "audio/mp4" | "audio/mpeg" | "audio/ogg"
             | "audio/webm" | "image/apng" | "image/gif" | "image/jpeg"
             | "image/png" | "image/webp" | "text/plain" | "video/mp4"
             | "video/ogg" | "video/webm");

   function Extension_Of (Media : String) return String is
     (if Media = "audio/aac" then ".aac"
      elsif Media in "audio/mp4" | "video/mp4" then ".mp4"
      elsif Media = "audio/mpeg" then ".mp3"
      elsif Media = "audio/ogg" then ".oga"
      elsif Media = "image/jpeg" then ".jpeg"
      elsif Media = "text/plain" then ".txt"
      elsif Media = "image/avif" then ".avif"
      elsif Media = "text/css" then ".css"
      elsif Media = "image/gif" then ".gif"
      elsif Media = "application/json" then ".json"
      elsif Media = "application/pdf" then ".pdf"
      elsif Media = "image/png" then ".png"
      elsif Media = "image/svg+xml" then ".svg"
      elsif Media = "application/wasm" then ".wasm"
      elsif Media = "image/webp" then ".webp"
      elsif Media = "text/xml" then ".xml"
      else "");

   ----------------------------------------------------------------------
   --  By content
   ----------------------------------------------------------------------

   function Sniffed (Data : String) return String is
     (if Data'Length > 512 then Data (Data'First .. Data'First + 511)
      else Data);

   --  Whether Data begins (after leading white space) with a tag name, in any
   --  case, followed by a space or '>'.
   function Is_Tag (Data, Tag : String) return Boolean is
      Start : Natural := Data'First;
   begin
      while Start <= Data'Last
        and then Data (Start) in ' ' | ASCII.HT | ASCII.LF | ASCII.FF
                                 | ASCII.CR
      loop
         Start := Start + 1;
      end loop;
      return Data'Last - Start + 1 > Tag'Length
        and then Lower (Data (Start .. Start + Tag'Length - 1)) = Lower (Tag)
        and then Data (Start + Tag'Length) in ' ' | '>';
   end Is_Tag;

   function Is_Html (Data : String) return Boolean is
     (Is_Tag (Data, "<!DOCTYPE HTML") or else Is_Tag (Data, "<HTML")
      or else Is_Tag (Data, "<HEAD") or else Is_Tag (Data, "<SCRIPT")
      or else Is_Tag (Data, "<IFRAME") or else Is_Tag (Data, "<H1")
      or else Is_Tag (Data, "<DIV") or else Is_Tag (Data, "<FONT")
      or else Is_Tag (Data, "<TABLE") or else Is_Tag (Data, "<A")
      or else Is_Tag (Data, "<STYLE") or else Is_Tag (Data, "<TITLE")
      or else Is_Tag (Data, "<B") or else Is_Tag (Data, "<BODY")
      or else Is_Tag (Data, "<BR") or else Is_Tag (Data, "<P"));

   --  Bytes that are not text: the control characters but the usual white
   --  space and escape.
   function Is_Binary_Byte (C : Character) return Boolean is
     (Character'Pos (C) in 0 .. 8 | 11 | 14 .. 26 | 28 .. 31);

   function Detect_Content_Type (Data : String) return String is
      D : constant String := Sniffed (Data);

      function Has (Prefix : String) return Boolean is
        (Starts_With (D, Prefix));

      --  RIFF, four bytes of size, then a form name.
      function Riff (Form : String) return Boolean is
        (D'Length >= 12 and then Starts_With (D, "RIFF")
         and then D (D'First + 8 .. D'First + 8 + Form'Length - 1) = Form);

      Mp4 : constant Boolean :=
        D'Length >= 12 and then D (D'First + 4 .. D'First + 7) = "ftyp";
   begin
      return
        (if Is_Html (D) or else Has ("<!--") then "text/html; charset=utf-8"
         elsif Has ("<?xml") then "text/xml; charset=utf-8"
         elsif Has ("%PDF-") then "application/pdf"
         elsif Has ("%!PS-Adobe-") then "application/postscript"
         elsif Has (Character'Val (16#FE#) & Character'Val (16#FF#)) then
            "text/plain; charset=utf-16be"
         elsif Has (Character'Val (16#FF#) & Character'Val (16#FE#)) then
            "text/plain; charset=utf-16le"
         elsif Has (Character'Val (16#EF#) & Character'Val (16#BB#)
                    & Character'Val (16#BF#)) then
            "text/plain; charset=utf-8"
         elsif Has (ASCII.NUL & ASCII.NUL & Character'Val (1) & ASCII.NUL)
           or else Has (ASCII.NUL & ASCII.NUL & Character'Val (2) & ASCII.NUL)
         then "image/x-icon"
         elsif Has ("BM") then "image/bmp"
         elsif Has ("GIF87a") or else Has ("GIF89a") then "image/gif"
         elsif Riff ("WEBPVP") then "image/webp"
         elsif Has (Character'Val (16#89#) & "PNG" & ASCII.CR & ASCII.LF
                    & Character'Val (16#1A#) & ASCII.LF) then "image/png"
         elsif Has (Character'Val (16#FF#) & Character'Val (16#D8#)
                    & Character'Val (16#FF#)) then "image/jpeg"
         elsif Has ("ID3") then "audio/mpeg"
         elsif Has ("OggS" & ASCII.NUL) then "application/ogg"
         elsif Has ("MThd" & ASCII.NUL & ASCII.NUL & ASCII.NUL
                    & Character'Val (6)) then "audio/midi"
         elsif Riff ("AVI ") then "video/avi"
         elsif Riff ("WAVE") then "audio/wave"
         elsif Has (Character'Val (16#1A#) & Character'Val (16#45#)
                    & Character'Val (16#DF#) & Character'Val (16#A3#)) then
            "video/webm"
         elsif Mp4 then "video/mp4"
         elsif Has (Character'Val (16#1F#) & Character'Val (16#8B#)
                    & Character'Val (8)) then "application/x-gzip"
         elsif Has ("PK" & Character'Val (3) & Character'Val (4)) then
            "application/zip"
         elsif Has ("Rar!" & Character'Val (16#1A#) & Character'Val (7)
                    & ASCII.NUL) then "application/x-rar-compressed"
         elsif Has (ASCII.NUL & "asm") then "application/wasm"
         elsif (for some C of D => Is_Binary_Byte (C)) then
            "application/octet-stream"
         else "text/plain; charset=utf-8");
   end Detect_Content_Type;

end Soja.Mime;
