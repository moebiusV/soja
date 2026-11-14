pragma Ada_2022;

with Ada.Characters.Handling;
with Ada.Directories;
with Ada.Exceptions;
with Ada.Streams;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;
with Interfaces.C;
with System;

with AWS.Messages;

with Http_Range;
with Http_Range.Parser;
with Soja.Auth;
with Soja.Base64;
with Soja.Logging;
with Soja.Mime;

package body Soja.Fileupload is

   use Ada.Streams;
   use type Interfaces.C.int;
   use type Interfaces.C.long;
   use type Ada.Directories.File_Kind;
   use type Soja.Logging.Logger_Access;
   use type Interfaces.C.size_t;
   use type System.Address;

   CRLF : constant String := ASCII.CR & ASCII.LF;

   function Lower (S : String) return String is
     (Ada.Characters.Handling.To_Lower (S));

   function Starts_With (S, Prefix : String) return Boolean is
     (S'Length >= Prefix'Length
      and then S (S'First .. S'First + Prefix'Length - 1) = Prefix);

   function Img (N : Long_Long_Integer) return String is
     (Ada.Strings.Fixed.Trim (Long_Long_Integer'Image (N), Ada.Strings.Left));

   ----------------------------------------------------------------------
   --  Paths and names
   ----------------------------------------------------------------------

   function Shown_Name (Stored : String) return String is
      Name : constant String :=
        Stored (Ada.Strings.Fixed.Index (Stored, "/", Ada.Strings.Backward) + 1
                .. Stored'Last);
      Dash : constant Natural := Ada.Strings.Fixed.Index (Name, "-");
   begin
      return (if Dash > 0 then Name (Dash + 1 .. Name'Last) else Name);
   end Shown_Name;

   --  filepath.Ext: from the last dot of the last element ("" if none).
   function Extension (Name : String) return String is
      Base : constant String := (if Name = "" then "" else Path_Base (Name));
      Dot  : constant Natural :=
        Ada.Strings.Fixed.Index (Base, ".", Ada.Strings.Backward);
   begin
      return (if Dot > 0 then Base (Dot .. Base'Last) else "");
   end Extension;

   ----------------------------------------------------------------------
   --  Request headers
   ----------------------------------------------------------------------

   procedure Basic_Credentials
     (Header   : String;
      Scheme   : out Unbounded_String;
      Username : out Unbounded_String;
      Password : out Unbounded_String;
      Ok       : out Boolean)
   is
      Space : constant Natural := Ada.Strings.Fixed.Index (Header, " ");
      Param : constant String :=
        (if Space > 0 then Header (Space + 1 .. Header'Last) else "");
      Valid : Boolean;
   begin
      Scheme := To_Unbounded_String
        (Lower ((if Space > 0 then Header (Header'First .. Space - 1)
                 else Header)));
      Username := Null_Unbounded_String;
      Password := Null_Unbounded_String;
      Ok := False;
      if To_String (Scheme) /= "basic" then
         return;
      end if;
      declare
         Decoded : constant String := Soja.Base64.Decode (Param, Valid);
         Colon   : constant Natural :=
           (if Valid then Ada.Strings.Fixed.Index (Decoded, ":") else 0);
      begin
         if Colon > 0 then
            Username := To_Unbounded_String
              (Decoded (Decoded'First .. Colon - 1));
            Password := To_Unbounded_String
              (Decoded (Colon + 1 .. Decoded'Last));
            Ok := True;
         end if;
      end;
   end Basic_Credentials;

   procedure Parse_Range
     (Header : String; Size : Long_Long_Integer;
      Kind   : out Range_Kind; First, Last : out Long_Long_Integer)
   is
      use type Http_Range.Range_spec_1_Access;
      use type Http_Range.From_to_Access;
      use type Http_Range.Suffix_Access;

      Count : Natural := 0;
      Bad   : Boolean := False;

      --  One range of the header, as net/http's parseRange reads it.
      procedure Take_From_To (Start : Long_Long_Integer;
                              Has_End : Boolean; Stop : Long_Long_Integer) is
      begin
         if Start >= Size then
            return;                     --  no overlap: skipped
         elsif Has_End and then Start > Stop then
            Bad := True;
         else
            Count := Count + 1;
            First := Start;
            Last := (if Has_End then Long_Long_Integer'Min (Stop, Size - 1)
                     else Size - 1);
         end if;
      end Take_From_To;

      procedure Take_Suffix (Amount : Long_Long_Integer) is
         Bytes : constant Long_Long_Integer :=
           Long_Long_Integer'Min (Amount, Size);
      begin
         if Bytes > 0 then
            Count := Count + 1;
            First := Size - Bytes;
            Last := Size - 1;
         end if;
      end Take_Suffix;

      procedure Take (Spec : Http_Range.Range_spec_Type) is
      begin
         if Spec.Range_spec_1 = null then
            Bad := True;
         elsif Spec.Range_spec_1.From_to /= null then
            declare
               R : Http_Range.From_to_Type renames
                 Spec.Range_spec_1.From_to.all;
            begin
               Take_From_To
                 (R.First, not R.From_to_1.Is_Empty,
                  (if R.From_to_1.Is_Empty then 0
                   else R.From_to_1.First_Element));
            end;
         elsif Spec.Range_spec_1.Suffix /= null then
            Take_Suffix (Spec.Range_spec_1.Suffix.Amount);
         end if;
      end Take;

   begin
      Kind := Whole;
      First := 0;
      Last := Size - 1;
      if Header = "" then
         return;
      end if;
      declare
         Tree : Http_Range.Byte_ranges_Type;
      begin
         Tree := Http_Range.Parser.Parse_Text (Header);
         Take (Tree.Range_spec.all);
         for Item of Tree.Byte_ranges_1 loop
            Take (Item.Range_spec.all);
         end loop;
         Http_Range.Parser.Free_Byte_ranges (Tree);
      exception
         when Http_Range.Parser.Parse_Error | Constraint_Error =>
            Bad := True;
      end;
      Kind := (if Bad or else Count = 0 then Unsatisfiable
               elsif Count = 1 then Partial
               else Whole);   --  (several ranges: the whole file)
      if Kind /= Partial then
         First := 0;
         Last := Size - 1;
      end if;
   end Parse_Range;

   ----------------------------------------------------------------------
   --  Files (C library: exclusive creation with a mode, no race)
   ----------------------------------------------------------------------

   function C_Mkdir
     (Path : Interfaces.C.char_array; Mode : Interfaces.C.unsigned)
      return Interfaces.C.int
     with Import, Convention => C, External_Name => "mkdir";
   function C_Open
     (Path : Interfaces.C.char_array; Flags : Interfaces.C.int;
      Mode : Interfaces.C.unsigned) return Interfaces.C.int
     with Import, Convention => C, External_Name => "open";
   function C_Write
     (FD : Interfaces.C.int; Buf : System.Address; N : Interfaces.C.size_t)
      return Interfaces.C.long
     with Import, Convention => C, External_Name => "write";
   function C_Read
     (FD : Interfaces.C.int; Buf : System.Address; N : Interfaces.C.size_t)
      return Interfaces.C.long
     with Import, Convention => C, External_Name => "read";
   function C_Close (FD : Interfaces.C.int) return Interfaces.C.int
     with Import, Convention => C, External_Name => "close";
   function C_Fopen (Path, Mode : Interfaces.C.char_array)
      return System.Address
     with Import, Convention => C, External_Name => "fopen";
   function C_Fclose (File : System.Address) return Interfaces.C.int
     with Import, Convention => C, External_Name => "fclose";
   function C_Fread
     (Buf : System.Address; Size, Count : Interfaces.C.size_t;
      File : System.Address) return Interfaces.C.size_t
     with Import, Convention => C, External_Name => "fread";
   function C_Fseek
     (File : System.Address; Offset : Interfaces.C.long;
      Whence : Interfaces.C.int) return Interfaces.C.int
     with Import, Convention => C, External_Name => "fseek";

   O_RDONLY : constant := 0;
   O_WRONLY : constant := 1;
   O_CREAT  : constant := 8#100#;
   O_EXCL   : constant := 8#200#;

   Upload_Error : exception;   --  the file could not be stored

   --  os.MkdirAll with mode 0700.
   procedure Make_All (Path : String) is
      Dummy : Interfaces.C.int;
      pragma Unreferenced (Dummy);
   begin
      for I in Path'First + 1 .. Path'Last + 1 loop
         if I > Path'Last or else Path (I) = '/' then
            Dummy := C_Mkdir
              (Interfaces.C.To_C (Path (Path'First .. I - 1)), 8#700#);
         end if;
      end loop;
   end Make_All;

   --  The hex text of N random bytes (generateToken).
   function Random_Token (N : Positive) return String is
      Hex  : constant String := "0123456789abcdef";
      FD   : constant Interfaces.C.int :=
        C_Open (Interfaces.C.To_C ("/dev/urandom"), O_RDONLY, 0);
      Buf  : array (1 .. N) of aliased Interfaces.Unsigned_8;
      Got  : Interfaces.C.long;
      Dummy : Interfaces.C.int;
      pragma Unreferenced (Dummy);
      Result : Unbounded_String;
   begin
      if FD < 0 then
         raise Upload_Error with "no random source";
      end if;
      Got := C_Read (FD, Buf'Address, Interfaces.C.size_t (N));
      Dummy := C_Close (FD);
      if Got /= Interfaces.C.long (N) then
         raise Upload_Error with "no random bytes";
      end if;
      for B of Buf loop
         Append (Result, Hex (Natural (B) / 16 + 1));
         Append (Result, Hex (Natural (B) mod 16 + 1));
      end loop;
      return To_String (Result);
   end Random_Token;

   --  fs.store, the creating half: <Dir>/<Username>/<token>-<name>, the file
   --  open for writing.  Name is what the address of the file is.
   procedure Create_File
     (Dir, Username, Mime_Type, Orig_Name : String;
      FD   : out Interfaces.C.int;
      Path : out Unbounded_String;
      Name : out Unbounded_String)
   is
      --  (Go takes the base of an empty name for ".", and names the file
      --  "<token>-.<ext>"; an empty name stays empty here.)
      Orig   : constant String :=
        (if Orig_Name = "" then "" else Path_Base (Orig_Name));
      Suffix : constant String :=
        (if Extension (Orig) = "" and then Mime_Type /= ""
         then Soja.Mime.Extension_Of (Mime_Type) else "");
      Owner  : constant String := Dir & "/" & Username;
   begin
      if Username = "" or else Username = "." or else Username = ".."
        or else Ada.Strings.Fixed.Index (Username, "/") > 0
      then
         raise Upload_Error with "invalid user name";
      end if;
      Make_All (Owner);
      for Attempt in 0 .. 99 loop
         declare
            Token : constant String :=
              Random_Token ((if Orig /= "" and then Attempt = 0 then 4
                             else 8));
            Base  : constant String :=
              Token & (if Orig /= "" then "-" & Orig else "") & Suffix;
         begin
            FD := C_Open
              (Interfaces.C.To_C (Owner & "/" & Base),
               O_WRONLY + O_CREAT + O_EXCL, 8#600#);
            if FD >= 0 then
               Path := To_Unbounded_String (Owner & "/" & Base);
               Name := To_Unbounded_String
                 (Path_Escape (Username) & "/" & Path_Escape (Base));
               return;
            end if;
         end;
      end loop;
      raise Upload_Error with "failed to pick filename";
   end Create_File;

   ----------------------------------------------------------------------
   --  Answering
   ----------------------------------------------------------------------

   procedure Fail
     (Stream : in out Soja.Byte_Stream.Stream'Class;
      Common : String; Status : Positive; Message : String) is
   begin
      Soja.Http.Write_Error (Stream, Status, Message, Common);
   end Fail;

   function Bytes (S : String) return Stream_Element_Array is
      R : Stream_Element_Array (1 .. Stream_Element_Offset (S'Length));
   begin
      for I in S'Range loop
         R (Stream_Element_Offset (I - S'First + 1)) :=
           Stream_Element (Character'Pos (S (I)));
      end loop;
      return R;
   end Bytes;

   --  The first bytes of a file, to tell its type from them.
   function Head_Of_File (Path : String) return String is
      F    : constant System.Address :=
        C_Fopen (Interfaces.C.To_C (Path), Interfaces.C.To_C ("rb"));
      Buf  : String (1 .. 512);
      N    : Interfaces.C.size_t;
      Dummy : Interfaces.C.int;
      pragma Unreferenced (Dummy);
   begin
      if F = System.Null_Address then
         return "";
      end if;
      N := C_Fread (Buf'Address, 1, Buf'Length, F);
      Dummy := C_Fclose (F);
      return Buf (1 .. Natural (N));
   end Head_Of_File;

   --  Sends Count bytes of the file from First.
   procedure Send_File
     (Stream : in out Soja.Byte_Stream.Stream'Class;
      Path : String; First, Count : Long_Long_Integer)
   is
      F : constant System.Address :=
        C_Fopen (Interfaces.C.To_C (Path), Interfaces.C.To_C ("rb"));
      Chunk : String (1 .. 65_536);
      Left  : Long_Long_Integer := Count;
      Dummy : Interfaces.C.int;
      pragma Unreferenced (Dummy);
   begin
      if F = System.Null_Address then
         return;
      end if;
      Dummy := C_Fseek (F, Interfaces.C.long (First), 0);
      while Left > 0 loop
         declare
            N : constant Interfaces.C.size_t := C_Fread
              (Chunk'Address, 1,
               Interfaces.C.size_t'Min
                 (Chunk'Length, Interfaces.C.size_t (Left)), F);
         begin
            exit when N = 0;
            Stream.Send (Bytes (Chunk (1 .. Natural (N))));
            Left := Left - Long_Long_Integer (N);
         end;
      end loop;
      Dummy := C_Fclose (F);
   exception
      when others =>
         Dummy := C_Fclose (F);
         raise;
   end Send_File;

   ----------------------------------------------------------------------
   --  GET and HEAD
   ----------------------------------------------------------------------

   procedure Fetch
     (Dir    : String;
      Stream : in out Soja.Byte_Stream.Stream'Class;
      Req    : Soja.Http.Request;
      Common : String)
   is
      Decoded_Ok : Boolean;
      Path : constant String :=
        Path_Unescape (Soja.Http.Path (Req), Decoded_Ok);
      Prefix : constant String := "/uploads/";
   begin
      if not Decoded_Ok or else not Starts_With (Path, Prefix) then
         Fail (Stream, Common, 404, "invalid path");
         return;
      end if;
      declare
         Name : constant String :=
           Clean_Path (Path (Path'First + Prefix'Length .. Path'Last));
         Full : constant String := Dir & "/" & Name;
      begin
         if Name = "" then
            Fail (Stream, Common, 404, "invalid path");
            return;
         elsif not Ada.Directories.Exists (Full)
           or else Ada.Directories.Kind (Full) /= Ada.Directories.Ordinary_File
         then
            Fail (Stream, Common, 404, "failed to open file");
            return;
         end if;

         declare
            Shown : constant String := Shown_Name (Name);
            By_Ext : constant String :=
              Soja.Mime.Type_By_Extension (Extension (Shown));
            Content_Type : constant String :=
              (if By_Ext /= "" then By_Ext
               else Soja.Mime.Detect_Content_Type (Head_Of_File (Full)));
            Media  : Unbounded_String;
            Params : Soja.Mime.Param_Maps.Map;
            Ok     : Boolean;
            Size   : constant Long_Long_Integer :=
              Long_Long_Integer (Ada.Directories.Size (Full));
            Kind   : Range_Kind;
            First, Last : Long_Long_Integer;
         begin
            Soja.Mime.Parse_Media_Type (Content_Type, Media, Params, Ok);
            Params.Clear;
            Params.Include ("filename", Shown);
            declare
               Mode : constant String :=
                 (if Ok and then Soja.Mime.Is_Inline (To_String (Media))
                  then "inline" else "attachment");
               Disposition : constant String :=
                 Soja.Mime.Format_Media_Type (Mode, Params);
               Modified : constant String := AWS.Messages.To_HTTP_Date
                 (Ada.Directories.Modification_Time (Full));
            begin
               Parse_Range (Soja.Http.Get (Req, "range"), Size,
                            Kind, First, Last);
               if Kind = Unsatisfiable then
                  Soja.Http.Write_Error
                    (Stream, 416, "invalid range: failed to overlap",
                     Common & "Content-Range: bytes */" & Img (Size) & CRLF);
                  return;
               end if;
               Soja.Http.Write_Head
                 (Stream, (if Kind = Partial then 206 else 200),
                  "Content-Type: " & Content_Type & CRLF
                  & "Content-Disposition: " & Disposition & CRLF
                  & "Accept-Ranges: bytes" & CRLF
                  & "Last-Modified: " & Modified & CRLF
                  & (if Kind = Partial
                     then "Content-Range: bytes " & Img (First) & "-"
                          & Img (Last) & "/" & Img (Size) & CRLF
                     else "")
                  & "Content-Length: "
                  & Img (if Size = 0 then 0 else Last - First + 1) & CRLF
                  & "Connection: close" & CRLF & Common);
               if To_String (Req.Method) /= "HEAD" and then Size > 0 then
                  Send_File (Stream, Full, First, Last - First + 1);
               end if;
            end;
         end;
      end;
   end Fetch;

   ----------------------------------------------------------------------
   --  POST
   ----------------------------------------------------------------------

   procedure Store
     (S      : in out Soja.Server.Server;
      Dir    : String;
      Stream : in out Soja.Byte_Stream.Stream'Class;
      Req    : Soja.Http.Request;
      Common : String)
   is
      Cfg   : constant Soja.Server.Server_Config_Access :=
        Soja.Server.Config (S);
      Driver : constant String := To_String (Cfg.Auth_Driver);
      Authz  : constant String := Soja.Http.Get (Req, "authorization");
      Scheme, Username, Password : Unbounded_String;
      Valid  : Boolean;
      Decoded_Ok : Boolean;
      Path : constant String :=
        Path_Unescape (Soja.Http.Path (Req), Decoded_Ok);
   begin
      if not Decoded_Ok or else Path /= "/uploads" then
         Fail (Stream, Common, 404, "invalid path");
         return;
      elsif Authz = "" then
         Fail (Stream, Common, 401, "missing Authorization header");
         return;
      end if;

      Basic_Credentials (Authz, Scheme, Username, Password, Valid);
      if To_String (Scheme) = "basic" then
         if not Soja.Auth.Supports_Plain (Driver) then
            Fail (Stream, Common, 400,
                  "Basic scheme in Authorization header not supported");
            return;
         elsif not Valid then
            Fail (Stream, Common, 400, "invalid Authorization header");
            return;
         end if;
         declare
            Result : constant Soja.Auth.Result := Soja.Auth.Auth_Plain
              (Driver, Soja.Server.DB (S), To_String (Username),
               To_String (Password));
         begin
            if not Result.Ok then
               Fail (Stream, Common, 403, To_String (Result.External));
               return;
            end if;
         end;
      elsif To_String (Scheme) = "bearer" then
         if not Soja.Auth.Supports_Bearer (Driver) then
            Fail (Stream, Common, 400,
                  "Bearer scheme in Authorization header not supported");
            return;
         end if;
         declare
            Space  : constant Natural := Ada.Strings.Fixed.Index (Authz, " ");
            Result : constant Soja.Auth.Result := Soja.Auth.Auth_Bearer
              (Driver, Authz (Space + 1 .. Authz'Last), Username);
         begin
            if not Result.Ok then
               Fail (Stream, Common, 403, To_String (Result.External));
               return;
            end if;
         end;
      else
         Fail (Stream, Common, 400,
               "unsupported Authorization header scheme");
         return;
      end if;

      --  What the client says the file is.
      declare
         Type_Header : constant String := Soja.Http.Get (Req, "content-type");
         Disp_Header : constant String :=
           Soja.Http.Get (Req, "content-disposition");
         Media : Unbounded_String;
         Params, Disp_Params : Soja.Mime.Param_Maps.Map;
         Ok : Boolean := True;
      begin
         if Type_Header /= "" then
            Soja.Mime.Parse_Media_Type (Type_Header, Media, Params, Ok);
            if not Ok then
               Fail (Stream, Common, 400, "failed to parse Content-Type");
               return;
            end if;
            if To_String (Media) = "application/octet-stream" then
               Media := Null_Unbounded_String;
            end if;
            declare
               Charset : constant String :=
                 (if Params.Contains ("charset")
                  then Lower (Params ("charset")) else "");
            begin
               if Charset not in "" | "utf-8" | "us-ascii" then
                  Fail (Stream, Common, 415, "unsupported charset");
                  return;
               end if;
            end;
         end if;
         if Disp_Header /= "" then
            declare
               Ignored : Unbounded_String;
            begin
               Soja.Mime.Parse_Media_Type (Disp_Header, Ignored,
                                           Disp_Params, Ok);
            end;
            if not Ok then
               Fail (Stream, Common, 400,
                     "failed to parse Content-Disposition");
               return;
            end if;
         end if;

         declare
            Orig : constant String :=
              (if Disp_Params.Contains ("filename")
               then Disp_Params ("filename") else "");
            Cursor : Soja.Http.Body_Cursor := Soja.Http.Open_Body (Req);
            FD     : Interfaces.C.int;
            File_Path, Out_Name : Unbounded_String;
            Chunk  : Stream_Element_Array (1 .. 65_536);
            Last   : Stream_Element_Offset;
            Failed : Boolean := False;
            Dummy  : Interfaces.C.int;
            pragma Unreferenced (Dummy);
         begin
            if Cursor.Chunked then
               Fail (Stream, Common, 411,
                     "chunked request bodies are not supported");
               return;
            elsif not Cursor.Valid then
               Fail (Stream, Common, 400, "invalid Content-Length");
               return;
            elsif Cursor.Length > Max_Size then
               Fail (Stream, Common, 500, "failed to write file");
               return;
            end if;
            if Lower (Soja.Http.Get (Req, "expect")) = "100-continue" then
               Soja.Http.Write_Head (Stream, 100);
            end if;

            begin
               Create_File (Dir, To_String (Username), To_String (Media),
                            Orig, FD, File_Path, Out_Name);
            exception
               when E : Upload_Error =>
                  if S.Logger /= null then
                     S.Logger.Print
                       ("file upload: "
                        & Ada.Exceptions.Exception_Message (E));
                  end if;
                  Fail (Stream, Common, 500, "failed to write file");
                  return;
            end;

            begin
               loop
                  Soja.Http.Read_Body (Stream, Cursor, Chunk, Last);
                  exit when Last < Chunk'First;
                  declare
                     Count : constant Natural :=
                       Natural (Last - Chunk'First + 1);
                     Data : String (1 .. Count);
                  begin
                     for I in Data'Range loop
                        Data (I) := Character'Val
                          (Chunk
                             (Chunk'First + Stream_Element_Offset (I - 1)));
                     end loop;
                     if C_Write (FD, Data'Address,
                                 Interfaces.C.size_t (Count))
                       /= Interfaces.C.long (Count)
                     then
                        Failed := True;
                        exit;
                     end if;
                  end;
               end loop;
            exception
               when others => Failed := True;
            end;
            Dummy := C_Close (FD);
            if Failed then
               --  (soju leaves what it had written; it is removed here.)
               Ada.Directories.Delete_File (To_String (File_Path));
               Fail (Stream, Common, 500, "failed to write file");
               return;
            end if;
            Soja.Http.Write_Head
              (Stream, 201,
               "Location: /uploads/" & To_String (Out_Name) & CRLF
               & "Content-Length: 0" & CRLF & "Connection: close" & CRLF
               & Common);
         end;
      end;
   end Store;

   ----------------------------------------------------------------------
   --  Serve
   ----------------------------------------------------------------------

   procedure Serve
     (S      : in out Soja.Server.Server;
      Stream : not null Soja.Byte_Stream.Stream_Access;
      Req    : Soja.Http.Request;
      Common : String)
   is
      Dir    : constant String :=
        To_String (Soja.Server.Config (S).File_Upload_Dir);
      Method : constant String := To_String (Req.Method);
   begin
      if Dir = "" then
         Fail (Stream.all, Common, 404, "404 page not found");
      elsif Method = "OPTIONS" then
         Soja.Http.Write_Head
           (Stream.all, 204, Common & "Connection: close" & CRLF);
      elsif Method in "HEAD" | "GET" then
         Fetch (Dir, Stream.all, Req, Common);
      elsif Method = "POST" then
         Store (S, Dir, Stream.all, Req, Common);
      else
         Fail (Stream.all, Common, 405,
               "only OPTIONS, HEAD, GET and POST are allowed");
      end if;
   end Serve;

end Soja.Fileupload;
