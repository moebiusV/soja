pragma Ada_2022;

with Ada.Exceptions;
with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;
with Ada.Text_IO;
with GNAT.OS_Lib;

with Soja.Mime; use Soja.Mime;

--  Media types with parameters, extensions and content sniffing.
procedure Mime_Check is

   procedure Check (Cond : Boolean; What : String) is
   begin
      if not Cond then
         raise Program_Error with What;
      end if;
   end Check;

   --  "type|name=value,name=value" or "!" when it is refused.
   function Parsed (Value : String) return String is
      Media  : Unbounded_String;
      Params : Param_Maps.Map;
      Ok     : Boolean;
      Result : Unbounded_String;
   begin
      Parse_Media_Type (Value, Media, Params, Ok);
      if not Ok then
         return "!";
      end if;
      for C in Params.Iterate loop
         Append (Result, (if Length (Result) > 0 then "," else "")
                 & Param_Maps.Key (C) & "=" & Param_Maps.Element (C));
      end loop;
      return To_String (Media) & "|" & To_String (Result);
   end Parsed;

   function Formatted (Media, Name, Value : String) return String is
      Params : Param_Maps.Map;
   begin
      Params.Include (Name, Value);
      return Format_Media_Type (Media, Params);
   end Formatted;

   function Bytes (S : String) return String is (S);
   NUL : constant Character := ASCII.NUL;
begin
   Check (Parsed ("text/plain; charset=utf-8") = "text/plain|charset=utf-8",
          "a media type with a parameter: " & Parsed ("text/plain; charset=utf-8"));
   Check (Parsed ("TEXT/Plain; CHARSET=UTF-8") = "text/plain|charset=UTF-8",
          "names lower-cased, values kept");
   Check (Parsed ("attachment; filename=""my file.png""")
          = "attachment|filename=my file.png", "a quoted value");
   Check (Parsed ("attachment") = "attachment|", "a type without a slash");
   Check (Parsed ("a/b; x=""q\""uote""; y=""back\\slash""")
          = "a/b|x=q""uote,y=back\slash", "backslashes in a quoted value");
   Check (Parsed ("text/plain ; charset=x ") = "text/plain|charset=x",
          "blanks around the semicolon");
   Check (Parsed ("text/plain;") = "text/plain|", "a trailing semicolon");
   Check (Parsed ("attachment; filename*=utf-8''my%20f%C3%A9.png")
          = "attachment|filename=my fé.png", "an extended value");
   Check (Parsed ("attachment; filename=plain; filename*=utf-8''ext.png")
          = "attachment|filename=ext.png", "the extended value wins");
   Check (Parsed ("attachment; filename*=iso-8859-1''caf%E9")
          = "attachment|filename=café", "Latin-1 as UTF-8");
   Check (Parsed ("form-data; name=x; name=y") = "!", "a name used twice");
   Check (Parsed ("") = "!" and then Parsed ("text/") = "!"
          and then Parsed ("a b") = "!" and then Parsed ("text/plain; x") = "!"
          and then Parsed ("text/plain; =x") = "!"
          and then Parsed ("text/plain; x=""open") = "!",
          "malformed values");

   Check (Formatted ("attachment", "filename", "x.png")
          = "attachment; filename=x.png", "a token");
   Check (Formatted ("attachment", "filename", "my file.png")
          = "attachment; filename=""my file.png""", "a value to quote");
   Check (Formatted ("attachment", "filename", "a""b\c")
          = "attachment; filename=""a\""b\\c""", "quotes escaped");
   Check (Formatted ("attachment", "filename", "h" & Character'Val (16#C3#)
                     & Character'Val (16#A9#) & ".png")
          = "attachment; filename*=utf-8''h%C3%A9.png", "non-ASCII text");
   Check (Formatted ("Attachment", "filename", "x") = "attachment; filename=x",
          "the type is lower-cased");
   Check (Formatted ("bad type", "a", "b") = "", "an invalid type");

   Check (Type_By_Extension (".png") = "image/png"
          and then Type_By_Extension (".PNG") = "image/png"
          and then Type_By_Extension (".html") = "text/html; charset=utf-8"
          and then Type_By_Extension (".xyz") = ""
          and then Type_By_Extension ("") = "", "by extension");
   Check (Is_Inline ("application/pdf"), "PDFs are shown in the browser");
   Check (Is_Inline ("image/png") and then not Is_Inline ("image/svg+xml")
          and then not Is_Inline ("text/html"), "inline types");
   Check (Extension_Of ("image/jpeg") = ".jpeg"
          and then Extension_Of ("text/plain") = ".txt"
          and then Extension_Of ("application/x-unknown") = "", "extensions");

   Check (Detect_Content_Type ("hello world" & ASCII.LF)
          = "text/plain; charset=utf-8", "text");
   Check (Detect_Content_Type ("" & NUL & Character'Val (1)) = "application/octet-stream",
          "binary");
   Check (Detect_Content_Type ("") = "text/plain; charset=utf-8", "empty");
   Check (Detect_Content_Type (Bytes ("GIF89a....")) = "image/gif", "gif");
   Check (Detect_Content_Type (Character'Val (16#89#) & "PNG" & ASCII.CR
                               & ASCII.LF & Character'Val (16#1A#) & ASCII.LF
                               & "rest") = "image/png", "png");
   Check (Detect_Content_Type (Character'Val (16#FF#) & Character'Val (16#D8#)
                               & Character'Val (16#FF#) & "x")
          = "image/jpeg", "jpeg");
   Check (Detect_Content_Type ("%PDF-1.4") = "application/pdf", "pdf");
   Check (Detect_Content_Type ("  <HTML><body>") = "text/html; charset=utf-8"
          and then Detect_Content_Type ("<!-- c -->") = "text/html; charset=utf-8"
          and then Detect_Content_Type ("<p>hi") = "text/html; charset=utf-8",
          "html");
   Check (Detect_Content_Type ("<?xml version=""1.0""?>") = "text/xml; charset=utf-8",
          "xml");
   Check (Detect_Content_Type ("RIFF" & NUL & NUL & NUL & NUL & "WEBPVP8 ")
          = "image/webp", "webp");
   Check (Detect_Content_Type ("RIFF" & NUL & NUL & NUL & NUL & "WAVEfmt ")
          = "audio/wave", "wav");
   Check (Detect_Content_Type (NUL & NUL & NUL & Character'Val (24) & "ftypmp42"
                               & NUL & NUL & NUL & NUL) = "video/mp4", "mp4");
   Check (Detect_Content_Type ("PK" & Character'Val (3) & Character'Val (4) & "x")
          = "application/zip", "zip");
   Ada.Text_IO.Put_Line ("ALL PASS");
exception
   when E : others =>
      Ada.Text_IO.Put_Line
        ("FAILED: " & Ada.Exceptions.Exception_Information (E));
      GNAT.OS_Lib.OS_Exit (1);
end Mime_Check;
