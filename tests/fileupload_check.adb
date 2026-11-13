pragma Ada_2022;

with Ada.Directories;
with Ada.Exceptions;
with Ada.Streams;           use Ada.Streams;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;
with Ada.Text_IO;
with GNAT.OS_Lib;

with Soja.Base64;
with Soja.Byte_Stream;
with Soja.Database;
with Soja.Database.Sqlite;
with Soja.Fileupload;       use Soja.Fileupload;
with Soja.Http;
with Soja.Server;

--  The upload handler: its pure parts, then POST, GET, HEAD, Range and OPTIONS
--  over a scripted stream, with a real database and directory.
procedure Fileupload_Check is
   use type Ada.Directories.File_Kind;

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

   function New_Fake (Incoming : String) return Fake_Access is
      F : constant Fake_Access := new Fake;
   begin
      F.Incoming := To_Unbounded_String (Incoming);
      return F;
   end New_Fake;

   function As_Stream (F : Fake_Access) return Soja.Byte_Stream.Stream_Access
   is (F.all'Unchecked_Access);

   Root : constant String := "/tmp/soja-fileupload-check";
   DB   : constant Soja.Database.Database_Access :=
     Soja.Database.Sqlite.Open_Temp_Sqlite_DB;
   Srv  : aliased Soja.Server.Server;
   Cfg  : constant Soja.Server.Server_Config_Access :=
     new Soja.Server.Server_Config;

   Basic : constant String :=
     "Basic " & Soja.Base64.Encode ("alice:secret");

   --  One request through the handler; what was sent back.
   function Run (Request : String) return String is
      F   : constant Fake_Access := New_Fake (Request);
      Req : Soja.Http.Request;
   begin
      Soja.Http.Read_Request (F.all, Req);
      F.Sent := Null_Unbounded_String;
      Serve (Srv, As_Stream (F), Req, "X-Common: 1" & CRLF);
      return To_String (F.Sent);
   end Run;

   function Status (Response : String) return String is
     (Response (Response'First .. Ada.Strings.Fixed.Index (Response, CRLF) - 1));

   function Body_Of (Response : String) return String is
      I : constant Natural := Ada.Strings.Fixed.Index (Response, CRLF & CRLF);
   begin
      return (if I = 0 then "" else Response (I + 4 .. Response'Last));
   end Body_Of;

   function Field (Response, Name : String) return String is
      I : constant Natural :=
        Ada.Strings.Fixed.Index (Response, CRLF & Name & ": ");
      J : Natural;
   begin
      if I = 0 then
         return "";
      end if;
      J := Ada.Strings.Fixed.Index
        (Response, CRLF, I + 2 + Name'Length + 2);
      return Response (I + 2 + Name'Length + 2 .. J - 1);
   end Field;

   function Post
     (Content : String; Auth : String := Basic; Extra : String := "";
      Path : String := "/uploads") return String is
     ("POST " & Path & " HTTP/1.1" & CRLF & "Host: h" & CRLF
      & (if Auth /= "" then "Authorization: " & Auth & CRLF else "")
      & Extra & "Content-Length:" & Natural'Image (Content'Length) & CRLF
      & CRLF & Content);

   function Get (Path : String; Extra : String := "";
                 Method : String := "GET") return String is
     (Method & " " & Path & " HTTP/1.1" & CRLF & "Host: h" & CRLF & Extra
      & CRLF);

   --  The file's address in the Location of a 201.
   function Location (Response : String) return String is
      L : constant String := Field (Response, "Location");
   begin
      return L;
   end Location;

   Data : constant String := "hello, upload" & ASCII.LF;
begin
   ------------------------------------------------------------------
   --  Names, paths, headers
   ------------------------------------------------------------------
   Check (Clean_Path ("a/b") = "a/b" and then Clean_Path ("/a//b/") = "a/b"
          and then Clean_Path ("a/./b") = "a/b"
          and then Clean_Path ("a/../b") = "b"
          and then Clean_Path ("../../etc/passwd") = "etc/passwd"
          and then Clean_Path ("..") = "" and then Clean_Path ("") = "",
          "Clean_Path never leaves the root");
   Check (Path_Base ("a/b.txt") = "b.txt" and then Path_Base ("b") = "b"
          and then Path_Base ("") = "." and then Path_Base ("a/b/") = "b"
          and then Path_Base ("///") = "/", "Path_Base");
   Check (Path_Escape ("a b/c?d;e,f") = "a%20b%2Fc%3Fd%3Be%2Cf"
          and then Path_Escape ("x@y:z+1=2$&-_.~") = "x@y:z+1=2$&-_.~",
          "Path_Escape");
   declare
      Ok : Boolean;
   begin
      Check (Path_Unescape ("/a%20b%2Fc", Ok) = "/a b/c" and then Ok,
             "Path_Unescape");
      declare
         Ignore : constant String := Path_Unescape ("/a%2", Ok);
         pragma Unreferenced (Ignore);
      begin
         Check (not Ok, "a bad escape");
      end;
   end;
   Check (Shown_Name ("alice/deadbeef-my-file.png") = "my-file.png"
          and then Shown_Name ("alice/deadbeef") = "deadbeef"
          and then Shown_Name ("deadbeef-.png") = ".png", "Shown_Name");

   declare
      Scheme, User, Pass : Unbounded_String;
      Ok : Boolean;
   begin
      Basic_Credentials ("Basic " & Soja.Base64.Encode ("al:se:cret"),
                         Scheme, User, Pass, Ok);
      Check (Ok and then To_String (Scheme) = "basic"
             and then To_String (User) = "al"
             and then To_String (Pass) = "se:cret", "Basic credentials");
      Basic_Credentials ("bAsIc " & Soja.Base64.Encode ("a:b"),
                         Scheme, User, Pass, Ok);
      Check (Ok, "the scheme in any case");
      Basic_Credentials ("Basic !!!", Scheme, User, Pass, Ok);
      Check (not Ok and then To_String (Scheme) = "basic", "bad base64");
      Basic_Credentials ("Basic " & Soja.Base64.Encode ("nocolon"),
                         Scheme, User, Pass, Ok);
      Check (not Ok, "no colon");
      Basic_Credentials ("Bearer abc", Scheme, User, Pass, Ok);
      Check (not Ok and then To_String (Scheme) = "bearer", "Bearer");
   end;

   declare
      Kind : Range_Kind;
      First, Last : Long_Long_Integer;
      procedure R (Header : String; Size : Long_Long_Integer) is
      begin
         Parse_Range (Header, Size, Kind, First, Last);
      end R;
   begin
      R ("", 100);
      Check (Kind = Whole, "no Range");
      R ("bytes=0-9", 100);
      Check (Kind = Partial and then First = 0 and then Last = 9, "0-9");
      R ("bytes=90-", 100);
      Check (Kind = Partial and then First = 90 and then Last = 99, "90-");
      R ("bytes=-10", 100);
      Check (Kind = Partial and then First = 90 and then Last = 99, "-10");
      R ("bytes=-500", 100);
      Check (Kind = Partial and then First = 0 and then Last = 99,
             "a suffix longer than the file");
      R ("bytes=50-5000", 100);
      Check (Kind = Partial and then First = 50 and then Last = 99,
             "an end past the file");
      R ("bytes=100-", 100);
      Check (Kind = Unsatisfiable, "a start past the end");
      R ("bytes=9-5", 100);
      Check (Kind = Unsatisfiable, "end before start");
      R ("bytes=0-1, 5-6", 100);
      Check (Kind = Whole, "several ranges: the whole file");
      R ("bytes=0-1, 500-600", 100);
      Check (Kind = Partial and then Last = 1, "one of two overlaps");
      R ("items=0-1", 100);
      Check (Kind = Unsatisfiable, "another unit");
      R ("bytes=a-b", 100);
      Check (Kind = Unsatisfiable, "not numbers");
      R ("bytes= 0-4 ", 100);
      Check (Kind = Partial and then Last = 4, "blanks");
   end;

   ------------------------------------------------------------------
   --  The handler
   ------------------------------------------------------------------
   if Ada.Directories.Exists (Root) then
      Ada.Directories.Delete_Tree (Root);
   end if;
   declare
      Rec : Soja.Database.User := Soja.Database.New_User ("alice");
   begin
      Soja.Database.Set_Password (Rec, "secret");
      Rec.Enabled := True;
      Soja.Database.Store_User (DB.all, Rec);
   end;
   Soja.Server.Initialize (Srv);
   Soja.Server.Set_DB (Srv, DB);
   Cfg.File_Upload_Dir := To_Unbounded_String (Root);
   Cfg.Has_File_Uploader := True;
   Soja.Server.Set_Config (Srv, Cfg);

   --  OPTIONS and the refusals.
   Check (Starts (Run (Get ("/uploads", Method => "OPTIONS")),
                  "HTTP/1.1 204"), "OPTIONS");
   Check (Starts (Run (Get ("/uploads", Method => "PUT")), "HTTP/1.1 405"),
          "PUT");
   Check (Starts (Run (Post (Data, Auth => "")), "HTTP/1.1 401"),
          "no Authorization");
   Check (Starts (Run (Post (Data, Auth => "Basic " & Soja.Base64.Encode ("alice:wrong"))),
                  "HTTP/1.1 403"), "a wrong password");
   Check (Starts (Run (Post (Data, Auth => "Basic " & Soja.Base64.Encode ("bob:secret"))),
                  "HTTP/1.1 403"), "an unknown user");
   Check (Starts (Run (Post (Data, Auth => "Bearer abc")), "HTTP/1.1 400"),
          "Bearer");
   Check (Starts (Run (Post (Data, Auth => "Digest x")), "HTTP/1.1 400"),
          "another scheme");
   Check (Starts (Run (Post (Data, Auth => "Basic !!")), "HTTP/1.1 400"),
          "a bad Basic header");
   Check (Starts (Run (Post (Data, Path => "/uploads/x")), "HTTP/1.1 404"),
          "POST to a file");
   Check (Starts (Run (Post (Data, Extra => "Content-Type: text/plain; charset=latin1" & CRLF)),
                  "HTTP/1.1 415"), "an unsupported charset");
   Check (Starts (Run (Post (Data, Extra => "Content-Type: text/" & CRLF)),
                  "HTTP/1.1 400"), "a bad Content-Type");
   Check (Starts (Run (Post (Data, Extra => "Content-Disposition: attachment; a=1; a=2" & CRLF)),
                  "HTTP/1.1 400"), "a bad Content-Disposition");
   Check (Starts (Run ("POST /uploads HTTP/1.1" & CRLF & "Host: h" & CRLF
                       & "Authorization: " & Basic & CRLF
                       & "Transfer-Encoding: chunked" & CRLF & CRLF
                       & "5" & CRLF & "hello" & CRLF & "0" & CRLF & CRLF),
                  "HTTP/1.1 411"), "chunked");
   Check (not Ada.Directories.Exists (Root & "/alice"),
          "nothing was stored by the refusals");

   --  A good upload, a name and a type given.
   declare
      R   : constant String := Run
        (Post (Data, Extra => "Content-Type: text/plain" & CRLF
               & "Content-Disposition: attachment; filename=""my notes.txt""" & CRLF));
      Loc : constant String := Location (R);
   begin
      Check (Starts (R, "HTTP/1.1 201"), "201: " & Status (R));
      Check (Starts (Loc, "/uploads/alice/") and then Contains (Loc, "-my%20notes.txt"),
             "Location: " & Loc);
      Check (Contains (R, "X-Common: 1"), "the common fields");

      --  Back by GET: bytes, type, shown name, Range, HEAD.
      declare
         G : constant String := Run (Get (Loc));
      begin
         Check (Starts (G, "HTTP/1.1 200") and then Body_Of (G) = Data,
                "GET: " & Status (G));
         Check (Field (G, "Content-Type") = "text/plain; charset=utf-8",
                "type from the sniffing of text: " & Field (G, "Content-Type"));
         Check (Field (G, "Content-Disposition")
                = "inline; filename=""my notes.txt""",
                "inline text: " & Field (G, "Content-Disposition"));
         Check (Field (G, "Content-Length") = Ada.Strings.Fixed.Trim
                  (Natural'Image (Data'Length), Ada.Strings.Left)
                and then Field (G, "Accept-Ranges") = "bytes"
                and then Field (G, "Last-Modified") /= ""
                and then Contains (G, "X-Common: 1"), "GET fields");
      end;
      declare
         H : constant String := Run (Get (Loc, Method => "HEAD"));
      begin
         Check (Starts (H, "HTTP/1.1 200") and then Body_Of (H) = ""
                and then Field (H, "Content-Length") /= "0", "HEAD");
      end;
      declare
         P : constant String := Run (Get (Loc, "Range: bytes=7-12" & CRLF));
      begin
         Check (Starts (P, "HTTP/1.1 206") and then Body_Of (P) = "upload"
                and then Field (P, "Content-Range")
                         = "bytes 7-12/" & Ada.Strings.Fixed.Trim
                             (Natural'Image (Data'Length), Ada.Strings.Left),
                "a range: " & Status (P) & Body_Of (P));
      end;
      Check (Starts (Run (Get (Loc, "Range: bytes=500-" & CRLF)),
                     "HTTP/1.1 416"), "an unsatisfiable range");
      --  A path with .. cannot leave the directory.
      Check (Starts (Run (Get ("/uploads/../../etc/passwd")),
                     "HTTP/1.1 404"), "traversal");
      Check (Starts (Run (Get ("/uploads/alice")), "HTTP/1.1 404"),
             "a directory");
      Check (Starts (Run (Get ("/uploads/alice/nope")), "HTTP/1.1 404"),
             "a missing file");
      Check (Starts (Run (Get ("/uploads/")), "HTTP/1.1 404"), "no name");
   end;

   --  No name and no type: a token, and what the content says.
   declare
      R   : constant String := Run (Post ("<html><body>x</body></html>"));
      Loc : constant String := Location (R);
      G   : constant String := Run (Get (Loc));
   begin
      Check (Starts (R, "HTTP/1.1 201") and then Starts (Loc, "/uploads/alice/"),
             "unnamed upload");
      Check (not Contains (Loc, "-"), "no '-' without a name: " & Loc);
      Check (Field (G, "Content-Type") = "text/html; charset=utf-8"
             and then Starts (Field (G, "Content-Disposition"), "attachment"),
             "html is sniffed and never shown inline: "
             & Field (G, "Content-Disposition"));
   end;

   --  A type but no name: the extension comes from the type; a PNG is shown.
   declare
      Png : constant String :=
        Character'Val (16#89#) & "PNG" & ASCII.CR & ASCII.LF
        & Character'Val (16#1A#) & ASCII.LF & "xxxx";
      R   : constant String := Run (Post (Png, Extra => "Content-Type: image/png" & CRLF));
      Loc : constant String := Location (R);
      G   : constant String := Run (Get (Loc));
   begin
      Check (Ada.Strings.Fixed.Index (Loc, ".png", Ada.Strings.Backward)
             = Loc'Last - 3, "the extension of the type: " & Loc);
      Check (Field (G, "Content-Type") = "image/png"
             and then Starts (Field (G, "Content-Disposition"), "inline"),
             "a PNG is shown inline");
      Check (Body_Of (G) = Png, "binary bytes survive");
   end;

   --  A traversal in the sent name stays in the user's directory.
   declare
      R   : constant String := Run
        (Post (Data, Extra => "Content-Disposition: attachment; filename=""../../evil.txt""" & CRLF));
      Loc : constant String := Location (R);
   begin
      Check (Starts (R, "HTTP/1.1 201") and then Contains (Loc, "-evil.txt")
             and then not Contains (Loc, ".."), "the name is a base name: " & Loc);
   end;

   --  Too large.
   Check (Starts (Run ("POST /uploads HTTP/1.1" & CRLF & "Host: h" & CRLF
                       & "Authorization: " & Basic & CRLF
                       & "Content-Length: 60000000" & CRLF & CRLF),
                  "HTTP/1.1 500"), "over the size limit");
   --  The body ends early: nothing is kept.
   declare
      Before : Natural := 0;
      After  : Natural := 0;
      procedure Count (N : out Natural) is
         S : Ada.Directories.Search_Type;
         E : Ada.Directories.Directory_Entry_Type;
      begin
         N := 0;
         Ada.Directories.Start_Search (S, Root & "/alice", "");
         while Ada.Directories.More_Entries (S) loop
            Ada.Directories.Get_Next_Entry (S, E);
            if Ada.Directories.Kind (E) = Ada.Directories.Ordinary_File then
               N := N + 1;
            end if;
         end loop;
         Ada.Directories.End_Search (S);
      end Count;
   begin
      Count (Before);
      declare
         R : constant String := Run
           ("POST /uploads HTTP/1.1" & CRLF & "Host: h" & CRLF
            & "Authorization: " & Basic & CRLF
            & "Content-Length: 100" & CRLF & CRLF & "only ten b");
      begin
         Check (Starts (R, "HTTP/1.1 500"), "a short body: " & Status (R));
      end;
      Count (After);
      Check (Before = After, "a failed upload leaves no file");
   end;

   --  No file-upload: 404.
   Cfg.File_Upload_Dir := Null_Unbounded_String;
   Check (Starts (Run (Get ("/uploads/x")), "HTTP/1.1 404"),
          "without an uploader");

   Ada.Directories.Delete_Tree (Root);
   Ada.Text_IO.Put_Line ("ALL PASS");
exception
   when E : others =>
      Ada.Text_IO.Put_Line
        ("FAILED: " & Ada.Exceptions.Exception_Information (E));
      GNAT.OS_Lib.OS_Exit (1);
end Fileupload_Check;
