pragma Ada_2022;

with Ada.Calendar.Arithmetic;
with Ada.Calendar.Formatting;
with Ada.Characters.Handling;
with Ada.Directories;
with Ada.Exceptions;
with Ada.Strings.Fixed;
with System;
with Ada.Wide_Wide_Characters.Handling;
with Ada.Strings.UTF_Encoding.Wide_Wide_Strings;
with Interfaces;
with Interfaces.C;

with Soja.Bare;
with Soja.Irc.Helpers;
with Soja.Irc.Messages;      use Soja.Irc.Messages;
with Soja.Msgstore.Znclog;

package body Soja.Msgstore.Fs is

   use type Ada.Calendar.Time;
   use type Soja.Database.Time;

   Zero : Ada.Calendar.Time renames Soja.Database.Null_Time;

   ----------------------------------------------------------------------
   --  Names and times
   ----------------------------------------------------------------------

   function Escape_Filename (Unsafe : String) return String is
      R : Unbounded_String;
   begin
      if Unsafe = "." then
         return "-";
      elsif Unsafe = ".." then
         return "--";
      end if;
      for C of Unsafe loop
         Append (R, (if C = '/' or else C = '\' then '-' else C));
      end loop;
      return To_String (R);
   end Escape_Filename;

   function Img (N : Integer; Width : Positive) return String is
      S : constant String :=
        Ada.Strings.Fixed.Trim (Integer'Image (N), Ada.Strings.Left);
   begin
      return (if S'Length >= Width then S
              else (1 .. Width - S'Length => '0') & S);
   end Img;

   --  The start of T's day (local time), the start of the next day, and a
   --  time truncated to the second.
   function Truncate_Day (T : Ada.Calendar.Time) return Ada.Calendar.Time is
      Y : Ada.Calendar.Year_Number;
      M : Ada.Calendar.Month_Number;
      D : Ada.Calendar.Day_Number;
      Secs : Ada.Calendar.Day_Duration;
   begin
      Ada.Calendar.Split (T, Y, M, D, Secs);
      return Ada.Calendar.Time_Of (Y, M, D);
   end Truncate_Day;

   function Next_Day (T : Ada.Calendar.Time) return Ada.Calendar.Time is
     (Ada.Calendar.Arithmetic."+" (Truncate_Day (T), 1));

   function Day_Before (T : Ada.Calendar.Time) return Ada.Calendar.Time is
     (Truncate_Day (T) - 1.0);

   function Truncate_Second (T : Ada.Calendar.Time) return Ada.Calendar.Time is
      Y  : Ada.Calendar.Year_Number;
      M  : Ada.Calendar.Month_Number;
      D  : Ada.Calendar.Day_Number;
      H  : Ada.Calendar.Formatting.Hour_Number;
      Mi : Ada.Calendar.Formatting.Minute_Number;
      S  : Ada.Calendar.Formatting.Second_Number;
      Sub : Ada.Calendar.Formatting.Second_Duration;
   begin
      Ada.Calendar.Formatting.Split (T, Y, M, D, H, Mi, S, Sub);
      return Ada.Calendar.Formatting.Time_Of (Y, M, D, H, Mi, S);
   end Truncate_Second;

   function Is_Time_Between (T, Start, End_T : Ada.Calendar.Time)
      return Boolean is
     (if End_T < Start then End_T < T and then T < Start
      else Start < T and then T < End_T);

   ----------------------------------------------------------------------
   --  Message IDs: the date and the offset in the day's file
   ----------------------------------------------------------------------

   function Format_FS_Msg_ID
     (Net_ID : Long_Long_Integer; Entity : String; T : Ada.Calendar.Time;
      Offset : Long_Long_Integer) return String
   is
      Y : Ada.Calendar.Year_Number;
      M : Ada.Calendar.Month_Number;
      D : Ada.Calendar.Day_Number;
      Secs : Ada.Calendar.Day_Duration;
      Buf  : Unbounded_String;
   begin
      Ada.Calendar.Split (T, Y, M, D, Secs);
      Soja.Bare.Write_Int (Buf, Interfaces.Integer_64 (Y));
      Soja.Bare.Write_Int (Buf, Interfaces.Integer_64 (M));
      Soja.Bare.Write_Int (Buf, Interfaces.Integer_64 (D));
      Soja.Bare.Write_Int (Buf, Interfaces.Integer_64 (Offset));
      return Format_Msg_ID (Net_ID, Entity, Msg_ID_FS, To_String (Buf));
   end Format_FS_Msg_ID;

   procedure Parse_FS_Msg_ID
     (S      : String; Net_ID : out Long_Long_Integer;
      Entity : out Unbounded_String; T : out Ada.Calendar.Time;
      Offset : out Long_Long_Integer)
   is
      Bytes : Unbounded_String;
   begin
      Parse_Msg_ID (S, Net_ID, Entity, Bytes, Expected => Msg_ID_FS);
      declare
         R : Soja.Bare.Reader := Soja.Bare.New_Reader (To_String (Bytes));
         Y : constant Interfaces.Integer_64 := Soja.Bare.Read_Int (R);
         M : constant Interfaces.Integer_64 := Soja.Bare.Read_Int (R);
         D : constant Interfaces.Integer_64 := Soja.Bare.Read_Int (R);
         O : constant Interfaces.Integer_64 := Soja.Bare.Read_Int (R);
      begin
         T := Ada.Calendar.Time_Of
           (Ada.Calendar.Year_Number (Y), Ada.Calendar.Month_Number (M),
            Ada.Calendar.Day_Number (D));
         Offset := Long_Long_Integer (O);
      exception
         when Constraint_Error =>
            raise Store_Error with "invalid internal message ID: bad date";
      end;
   exception
      when E : Soja.Bare.Bare_Error =>
         raise Store_Error with
           "invalid internal message ID: "
           & Ada.Exceptions.Exception_Message (E);
   end Parse_FS_Msg_ID;

   ----------------------------------------------------------------------
   --  Files
   ----------------------------------------------------------------------

   function C_Mkdir
     (Path : Interfaces.C.char_array; Mode : Interfaces.C.unsigned)
      return Interfaces.C.int
     with Import, Convention => C, External_Name => "mkdir";
   function C_Creat
     (Path : Interfaces.C.char_array; Mode : Interfaces.C.unsigned)
      return Interfaces.C.int
     with Import, Convention => C, External_Name => "creat";
   function C_Close (FD : Interfaces.C.int) return Interfaces.C.int
     with Import, Convention => C, External_Name => "close";

   --  stdio, for reading and appending the logs.
   use type System.Address;
   use type Interfaces.C.size_t;
   use type Interfaces.C.int;
   function C_Fopen (Path, Mode : Interfaces.C.char_array)
      return System.Address
     with Import, Convention => C, External_Name => "fopen";
   function C_Fclose (File : System.Address) return Interfaces.C.int
     with Import, Convention => C, External_Name => "fclose";
   function C_Fread
     (Buf : System.Address; Size, Count : Interfaces.C.size_t;
      File : System.Address) return Interfaces.C.size_t
     with Import, Convention => C, External_Name => "fread";
   function C_Fwrite
     (Buf : System.Address; Size, Count : Interfaces.C.size_t;
      File : System.Address) return Interfaces.C.size_t
     with Import, Convention => C, External_Name => "fwrite";
   function C_Fflush (File : System.Address) return Interfaces.C.int
     with Import, Convention => C, External_Name => "fflush";
   function C_Fseek
     (File : System.Address; Offset : Interfaces.C.long;
      Whence : Interfaces.C.int) return Interfaces.C.int
     with Import, Convention => C, External_Name => "fseek";
   function C_Ftell (File : System.Address) return Interfaces.C.long
     with Import, Convention => C, External_Name => "ftell";

   --  MkdirAll (path, 0750): created with that mode (less the umask), not
   --  fixed afterwards, so the logs are never readable by others.
   procedure Make_All (Dir : String) is
      Dummy : Interfaces.C.int;
      pragma Unreferenced (Dummy);
   begin
      for I in Dir'Range loop
         if (Dir (I) = '/' and then I > Dir'First) or else I = Dir'Last then
            declare
               Prefix : constant String :=
                 (if Dir (I) = '/' then Dir (Dir'First .. I - 1)
                  else Dir (Dir'First .. I));
            begin
               if not Ada.Directories.Exists (Prefix) then
                  Dummy := C_Mkdir (Interfaces.C.To_C (Prefix), 8#750#);
                  if not Ada.Directories.Exists (Prefix) then
                     raise Store_Error with
                       "failed to create message logs directory "
                       & Soja.Irc.Helpers.Quote (Prefix);
                  end if;
               end if;
            end;
         end if;
      end loop;
   end Make_All;

   --  Create the file (0640) if it does not exist yet.
   procedure Ensure_File (Path : String) is
      FD : Interfaces.C.int;
      Dummy : Interfaces.C.int;
      pragma Unreferenced (Dummy);
   begin
      if not Ada.Directories.Exists (Path) then
         FD := C_Creat (Interfaces.C.To_C (Path), 8#640#);
         if Interfaces.C."<" (FD, 0) then
            raise Store_Error with
              "failed to open message log file "
              & Soja.Irc.Helpers.Quote (Path);
         end if;
         Dummy := C_Close (FD);
      end if;
   end Ensure_File;

   --  The whole file; Exists is False when there is none.
   procedure Read_File
     (Path : String; Data : out Unbounded_String; Exists : out Boolean)
   is
      F     : System.Address;
      Chunk : String (1 .. 65_536);
      Count : Interfaces.C.size_t;
      Dummy : Interfaces.C.int;
      pragma Unreferenced (Dummy);
   begin
      Data := Null_Unbounded_String;
      Exists := Ada.Directories.Exists (Path);
      if not Exists then
         return;
      end if;
      F := C_Fopen (Interfaces.C.To_C (Path), Interfaces.C.To_C ("rb"));
      if F = System.Null_Address then
         raise Store_Error with
           "failed to read " & Soja.Irc.Helpers.Quote (Path);
      end if;
      loop
         Count := C_Fread (Chunk'Address, 1, Chunk'Length, F);
         exit when Count = 0;
         Append (Data, Chunk (1 .. Natural (Count)));
      end loop;
      Dummy := C_Fclose (F);
   end Read_File;

   function Log_Path
     (S : Fs_Store; Network : Soja.Database.Network; Entity : String;
      T : Ada.Calendar.Time) return String
   is
      Y : Ada.Calendar.Year_Number;
      M : Ada.Calendar.Month_Number;
      D : Ada.Calendar.Day_Number;
      Secs : Ada.Calendar.Day_Duration;
   begin
      Ada.Calendar.Split (T, Y, M, D, Secs);
      return Ada.Directories.Compose
        (Ada.Directories.Compose
           (Ada.Directories.Compose
              (To_String (S.Root),
               Escape_Filename (Soja.Database.Get_Name (Network))),
            Escape_Filename (Entity)),
         Img (Y, 4) & "-" & Img (M, 2) & "-" & Img (D, 2) & ".log");
   end Log_Path;

   procedure Close_File (E : in out Open_File) is
      Dummy : Interfaces.C.int;
      pragma Unreferenced (Dummy);
   begin
      if E.File /= System.Null_Address then
         Dummy := C_Fclose (E.File);
         E.File := System.Null_Address;
      end if;
   end Close_File;

   ----------------------------------------------------------------------
   --  The Store operations
   ----------------------------------------------------------------------

   function New_Fs_Store (Root : String; User : Soja.Database.User)
      return Store_Access is
   begin
      return new Fs_Store'
        (Store with
           Root  => To_Unbounded_String
             (Ada.Directories.Compose
                (Root, Escape_Filename (To_String (User.Username)))),
           User  => User,
           Files => File_Maps.Empty_Map);
   end New_Fs_Store;

   function Is_Fs_Store (S : Store'Class) return Boolean is (S in Fs_Store);

   overriding procedure Close (S : in out Fs_Store) is
   begin
      for C in S.Files.Iterate loop
         declare
            E : Open_File := File_Maps.Element (C);
         begin
            Close_File (E);
         end;
      end loop;
      S.Files.Clear;
   end Close;

   overriding function Supports_Chat_History (S : Fs_Store) return Boolean is
      pragma Unreferenced (S);
   begin
      return True;
   end Supports_Chat_History;

   overriding function Supports_Search (S : Fs_Store) return Boolean is
      pragma Unreferenced (S);
   begin
      return True;
   end Supports_Search;

   overriding function Supports_Rename_Network (S : Fs_Store) return Boolean is
      pragma Unreferenced (S);
   begin
      return True;
   end Supports_Rename_Network;

   overriding procedure User_Updated
     (S : in out Fs_Store; User : Soja.Database.User) is
   begin
      S.User := User;
   end User_Updated;

   overriding function Last_Msg_ID
     (S : in out Fs_Store; Network : Soja.Database.Network;
      Entity : String; T : Ada.Calendar.Time) return String
   is
      Path : constant String := Log_Path (S, Network, Entity, T);
   begin
      if not Ada.Directories.Exists (Path) then
         return Format_FS_Msg_ID (Network.ID, Entity, T, -1);
      end if;
      return Format_FS_Msg_ID
        (Network.ID, Entity, T,
         Long_Long_Integer (Ada.Directories.Size (Path)) - 1);
   exception
      when E : Ada.Directories.Use_Error | Ada.Directories.Name_Error =>
         raise Store_Error with
           "failed to query last FS message ID: "
           & Ada.Exceptions.Exception_Message (E);
   end Last_Msg_ID;

   overriding function Append
     (S : in out Fs_Store; Network : Soja.Database.Network;
      Entity : String; Msg : Soja.Irc.Messages.Message) return String
   is
      Stamp : Ada.Calendar.Time := Ada.Calendar.Clock;
   begin
      if Has_Tag (Msg.Tags, "time") then
         declare
            Valid : Boolean;
            T     : constant Ada.Calendar.Time :=
              Soja.Irc.Helpers.Parse_Server_Time
                (Get_Tag (Msg.Tags, "time"), Valid);
         begin
            if not Valid then
               raise Store_Error with "failed to parse message time tag";
            end if;
            Stamp := T;
         end;
      end if;

      declare
         Line : constant String := Znclog.Marshal_Line (Msg, Stamp);
      begin
         if Line = "" then
            return "";
         end if;

         declare
            Path : constant String := Log_Path (S, Network, Entity, Stamp);
            Pos  : File_Maps.Cursor := S.Files.Find (Entity);
            Ent  : Open_File;
         begin
            --  TODO (Go): handle non-monotonic clock behaviour.
            if File_Maps.Has_Element (Pos) then
               Ent := File_Maps.Element (Pos);
            end if;
            if Ent.File = System.Null_Address
              or else To_String (Ent.Path) /= Path
            then
               Make_All (Ada.Directories.Containing_Directory (Path));
               Ensure_File (Path);
               declare
                  F : constant System.Address := C_Fopen
                    (Interfaces.C.To_C (Path), Interfaces.C.To_C ("a"));
               begin
                  if F = System.Null_Address then
                     raise Store_Error with
                       "failed to open message log file "
                       & Soja.Irc.Helpers.Quote (Path);
                  end if;
                  Close_File (Ent);   --  (the previous day's)
                  Ent := (File => F, Path => To_Unbounded_String (Path),
                          Last_Use => Ada.Calendar.Clock);
               end;
            end if;
            Ent.Last_Use := Ada.Calendar.Clock;
            S.Files.Include (Entity, Ent);

            --  Keep at most Max_Files open: close the least recently used.
            while Natural (S.Files.Length) > Max_Files loop
               declare
                  Oldest : File_Maps.Cursor := S.Files.First;
               begin
                  for C in S.Files.Iterate loop
                     if File_Maps.Element (C).Last_Use
                        < File_Maps.Element (Oldest).Last_Use
                     then
                        Oldest := C;
                     end if;
                  end loop;
                  declare
                     Victim : Open_File := File_Maps.Element (Oldest);
                  begin
                     Close_File (Victim);
                  end;
                  S.Files.Delete (Oldest);
               end;
            end loop;

            --  Write the line, the offset of which is the message's ID.
            declare
               Text : constant String := Line & ASCII.LF;
               F    : constant System.Address :=
                 File_Maps.Element (S.Files.Find (Entity)).File;
               Offset : Long_Long_Integer;
               Dummy  : Interfaces.C.int;
               pragma Unreferenced (Dummy);
            begin
               Dummy := C_Fseek (F, 0, 2);   --  SEEK_END
               Offset := Long_Long_Integer (C_Ftell (F));
               if C_Fwrite (Text'Address, 1, Text'Length, F)
                    /= Interfaces.C.size_t (Text'Length)
                 or else C_Fflush (F) /= 0
               then
                  raise Store_Error with
                    "failed to log message to "
                    & Soja.Irc.Helpers.Quote (Path);
               end if;
               return Format_FS_Msg_ID (Network.ID, Entity, Stamp, Offset);
            end;
         end;
      end;
   end Append;

   ----------------------------------------------------------------------
   --  Reading the logs
   ----------------------------------------------------------------------

   type Selector is access function (M : Message) return Boolean;

   --  The lines of Data from Pos on (a trailing CR dropped), as bufio's
   --  ScanLines gives them.
   procedure Next_Line
     (Data : String; Pos : in out Positive;
      Line_First, Line_Last : out Natural; Found : out Boolean)
   is
      LF : Natural := 0;
   begin
      if Pos > Data'Last then
         Found := False;
         Line_First := 1;
         Line_Last := 0;
         return;
      end if;
      for I in Pos .. Data'Last loop
         if Data (I) = ASCII.LF then
            LF := I;
            exit;
         end if;
      end loop;
      Found := True;
      Line_First := Pos;
      if LF = 0 then
         Line_Last := Data'Last;
         Pos := Data'Last + 1;
      else
         Line_Last := LF - 1;
         Pos := LF + 1;
      end if;
      if Line_Last >= Line_First and then Data (Line_Last) = ASCII.CR then
         Line_Last := Line_Last - 1;
      end if;
   end Next_Line;

   --  parseMessagesBefore: the last Options.Limit messages of the day of Ref
   --  that are after End_T and before Ref (after the line at After_Offset,
   --  when that is not negative).
   function Parse_Before
     (S : Fs_Store; Ref, End_T : Ada.Calendar.Time;
      Options : Load_Message_Options; After_Offset : Long_Long_Integer;
      Filter : Selector) return Message_Vector
   is
      Path   : constant String :=
        Log_Path (S, Options.Network, To_String (Options.Entity), Ref);
      Data   : Unbounded_String;
      Exists : Boolean;
      Result : Message_Vector;
   begin
      Read_File (Path, Data, Exists);
      if not Exists then
         return Result;
      end if;

      declare
         Text : constant String := To_String (Data);
         Pos  : Positive := Text'First;
         First_Pos, Last_Pos : Natural;
         Found : Boolean;
      begin
         if After_Offset >= 0 then
            if After_Offset >= Long_Long_Integer (Text'Length) then
               return Result;
            end if;
            Pos := Text'First + Natural (After_Offset);
            Next_Line (Text, Pos, First_Pos, Last_Pos, Found);   --  skip it
         end if;

         loop
            Next_Line (Text, Pos, First_Pos, Last_Pos, Found);
            exit when not Found;
            declare
               Msg : Message;
               T   : Ada.Calendar.Time;
               Ok  : Boolean;
            begin
               Znclog.Unmarshal_Line
                 (Text (First_Pos .. Last_Pos), S.User,
                  Options.Network, To_String (Options.Entity), Ref,
                  Options.Events, Msg, T, Ok);
               if Ok and then T > End_T then
                  exit when not (T < Ref);
                  if Filter = null or else Filter (Msg) then
                     Result.Append (Msg);
                     if Natural (Result.Length) > Options.Limit then
                        Result.Delete_First;   --  keep the last ones
                     end if;
                  end if;
               end if;
            end;
         end loop;
      end;
      return Result;
   end Parse_Before;

   --  parseMessagesAfter.
   function Parse_After
     (S : Fs_Store; Ref, End_T : Ada.Calendar.Time;
      Options : Load_Message_Options; Filter : Selector) return Message_Vector
   is
      Path   : constant String :=
        Log_Path (S, Options.Network, To_String (Options.Entity), Ref);
      Data   : Unbounded_String;
      Exists : Boolean;
      Result : Message_Vector;
   begin
      Read_File (Path, Data, Exists);
      if not Exists then
         return Result;
      end if;

      declare
         Text : constant String := To_String (Data);
         Pos  : Positive := Text'First;
         First_Pos, Last_Pos : Natural;
         Found : Boolean;
      begin
         while Natural (Result.Length) < Options.Limit loop
            Next_Line (Text, Pos, First_Pos, Last_Pos, Found);
            exit when not Found;
            declare
               Msg : Message;
               T   : Ada.Calendar.Time;
               Ok  : Boolean;
            begin
               Znclog.Unmarshal_Line
                 (Text (First_Pos .. Last_Pos), S.User,
                  Options.Network, To_String (Options.Entity), Ref,
                  Options.Events, Msg, T, Ok);
               if Ok and then T > Ref then
                  exit when not (T < End_T);
                  if Filter = null or else Filter (Msg) then
                     Result.Append (Msg);
                  end if;
               end if;
            end;
         end loop;
      end;
      return Result;
   end Parse_After;

   --  getBeforeTime: walk back a day at a time.
   function Get_Before_Time
     (S : Fs_Store; Start, End_Time : Ada.Calendar.Time;
      Options : Load_Message_Options; Filter : Selector) return Message_Vector
   is
      Cur       : Ada.Calendar.Time :=
        (if Start = Zero then Ada.Calendar.Clock else Start);
      Remaining : Natural := Options.Limit;
      Tries     : Natural := 0;
      Result    : Message_Vector;
   begin
      while Remaining > 0 and then Tries < Max_Tries and then End_Time < Cur
      loop
         declare
            Opts : Load_Message_Options := Options;
            Buf  : Message_Vector;
         begin
            Opts.Limit := Remaining;
            Buf := Parse_Before (S, Cur, End_Time, Opts, -1, Filter);
            if Buf.Is_Empty then
               Tries := Tries + 1;
            else
               Tries := 0;
            end if;
            Result.Prepend (Buf);   --  older days come first
            Remaining := Remaining - Natural (Buf.Length);
         end;
         Cur := Day_Before (Cur);
      end loop;
      return Result;
   end Get_Before_Time;

   --  getAfterTime: walk forward a day at a time.
   function Get_After_Time
     (S : Fs_Store; Start, End_Time : Ada.Calendar.Time;
      Options : Load_Message_Options; Filter : Selector) return Message_Vector
   is
      Cur       : Ada.Calendar.Time := Start;
      Stop      : constant Ada.Calendar.Time :=
        (if End_Time = Zero then Ada.Calendar.Clock else End_Time);
      Remaining : Natural := Options.Limit;
      Tries     : Natural := 0;
      Result    : Message_Vector;
   begin
      while Remaining > 0 and then Tries < Max_Tries and then Cur < Stop loop
         declare
            Opts : Load_Message_Options := Options;
            Buf  : Message_Vector;
         begin
            Opts.Limit := Remaining;
            Buf := Parse_After (S, Cur, Stop, Opts, Filter);
            if Buf.Is_Empty then
               Tries := Tries + 1;
            else
               Tries := 0;
            end if;
            Result.Append_Vector (Buf);
            Remaining := Remaining - Natural (Buf.Length);
         end;
         Cur := Next_Day (Cur);
      end loop;
      return Result;
   end Get_After_Time;

   overriding function Load_Before_Time
     (S : in out Fs_Store; Start, End_Time : Ada.Calendar.Time;
      Options : Load_Message_Options) return Message_Vector is
   begin
      return Get_Before_Time (S, Start, End_Time, Options, null);
   end Load_Before_Time;

   overriding function Load_After_Time
     (S : in out Fs_Store; Start, End_Time : Ada.Calendar.Time;
      Options : Load_Message_Options) return Message_Vector is
   begin
      return Get_After_Time (S, Start, End_Time, Options, null);
   end Load_After_Time;

   overriding function Load_Latest_ID
     (S : in out Fs_Store; ID : String; Options : Load_Message_Options)
      return Soja.Irc.Messages.Message_Vectors.Vector
   is
      After_Time   : Ada.Calendar.Time := Zero;
      After_Offset : Long_Long_Integer := 0;
      Cur          : Ada.Calendar.Time := Ada.Calendar.Clock;
      Remaining    : Natural := Options.Limit;
      Tries        : Natural := 0;
      Result       : Message_Vector;
   begin
      if ID /= "" then
         declare
            Id_Net    : Long_Long_Integer;
            Id_Entity : Unbounded_String;
         begin
            Parse_FS_Msg_ID
              (ID, Id_Net, Id_Entity, After_Time, After_Offset);
            if Id_Net /= Options.Network.ID
              or else Id_Entity /= Options.Entity
            then
               raise Store_Error with
                 "cannot find message ID: message ID doesn't match "
                 & "network/entity";
            end if;
         end;
      end if;

      while Remaining > 0 and then Tries < Max_Tries
        and then not (Truncate_Day (Cur) < After_Time)
      loop
         declare
            Offset : Long_Long_Integer := -1;
            Opts   : Load_Message_Options := Options;
            Buf    : Message_Vector;
         begin
            if After_Offset >= 0 and then Truncate_Day (Cur) = After_Time then
               Offset := After_Offset;
            end if;
            Opts.Limit := Remaining;
            Buf := Parse_Before (S, Cur, Zero, Opts, Offset, null);
            if Buf.Is_Empty then
               Tries := Tries + 1;
            else
               Tries := 0;
            end if;
            Result.Prepend (Buf);
            Remaining := Remaining - Natural (Buf.Length);
         end;
         Cur := Day_Before (Cur);
      end loop;
      return Result;
   end Load_Latest_ID;

   overriding function List_Targets
     (S : in out Fs_Store; Network : Soja.Database.Network;
      Start, End_Time : Ada.Calendar.Time; Limit : Natural; Events : Boolean)
      return Target_Vectors.Vector
   is
      pragma Unreferenced (Events);
      Root_Path : constant String := Ada.Directories.Compose
        (To_String (S.Root),
         Escape_Filename (Soja.Database.Get_Name (Network)));
      Targets   : Target_Vectors.Vector;

      function Before (A, B : Chat_History_Target) return Boolean is
        (A.Latest_Message < B.Latest_Message);
      package Sorting is new Target_Vectors.Generic_Sorting (Before);
   begin
      if not Ada.Directories.Exists (Root_Path) then
         return Targets;
      end if;

      declare
         Search : Ada.Directories.Search_Type;
         Item   : Ada.Directories.Directory_Entry_Type;
      begin
         Ada.Directories.Start_Search
           (Search, Root_Path, "",
            [Ada.Directories.Directory => True, others => False]);
         while Ada.Directories.More_Entries (Search) loop
            Ada.Directories.Get_Next_Entry (Search, Item);
            declare
               Name : constant String := Ada.Directories.Simple_Name (Item);
               Latest : Ada.Calendar.Time := Zero;
            begin
               if Name /= "." and then Name /= ".." then
                  --  We use the mtime here, which may be imprecise.
                  declare
                     Inner : Ada.Directories.Search_Type;
                     File  : Ada.Directories.Directory_Entry_Type;
                  begin
                     Ada.Directories.Start_Search
                       (Inner, Ada.Directories.Full_Name (Item), "",
                        [others => True]);
                     while Ada.Directories.More_Entries (Inner) loop
                        Ada.Directories.Get_Next_Entry (Inner, File);
                        declare
                           N : constant String :=
                             Ada.Directories.Simple_Name (File);
                           M : constant Ada.Calendar.Time :=
                             Ada.Directories.Modification_Time (File);
                        begin
                           if N /= "." and then N /= ".."
                             and then M > Latest
                           then
                              Latest := M;
                           end if;
                        end;
                     end loop;
                     Ada.Directories.End_Search (Inner);
                  end;

                  --  The times in the logs have a granularity of a second.
                  if Latest /= Zero then
                     Latest := Truncate_Second (Latest);
                  end if;

                  if Is_Time_Between (Latest, Start, End_Time) then
                     Targets.Append
                       (Chat_History_Target'
                          (Name => To_Unbounded_String (Name),
                           Latest_Message => Latest));
                  end if;
               end if;
            end;
         end loop;
         Ada.Directories.End_Search (Search);
      end;

      --  Latest first or last, by the order of the bounds.
      Sorting.Sort (Targets);
      if not (Start < End_Time) then
         Targets.Reverse_Elements;
      end if;
      while Natural (Targets.Length) > Limit loop
         Targets.Delete_Last;
      end loop;
      return Targets;
   exception
      when E : Ada.Directories.Use_Error | Ada.Directories.Name_Error =>
         raise Store_Error with
           "failed to list targets: " & Ada.Exceptions.Exception_Message (E);
   end List_Targets;

   overriding function Search
     (S : in out Fs_Store; Network : Soja.Database.Network;
      Options : Search_Options) return Message_Vector
   is
      use Ada.Wide_Wide_Characters.Handling;
      use Ada.Strings.UTF_Encoding.Wide_Wide_Strings;

      Wanted : constant Wide_Wide_String :=
        To_Lower (Decode (To_String (Options.Text)));
      From   : constant String := To_String (Options.From);

      function Matches (M : Message) return Boolean is
      begin
         if From /= "" and then
           (M.Prefix = null or else To_String (M.Prefix.Name) /= From)
         then
            return False;
         end if;
         if Wanted'Length > 0 then
            declare
               Text : constant Wide_Wide_String :=
                 To_Lower (Decode (Param (M, 1)));
            begin
               --  strings.Contains
               if Text'Length < Wanted'Length then
                  return False;
               end if;
               for I in Text'First .. Text'Last - Wanted'Length + 1 loop
                  if Text (I .. I + Wanted'Length - 1) = Wanted then
                     return True;
                  end if;
               end loop;
               return False;
            end;
         end if;
         return True;
      end Matches;

      Load : constant Load_Message_Options :=
        (Network => Network, Entity => Options.In_Target,
         Limit => Options.Limit, Events => False);
   begin
      if Options.Start /= Zero then
         return Get_After_Time
           (S, Options.Start, Options.End_Time, Load,
            Matches'Unrestricted_Access);
      end if;
      return Get_Before_Time
        (S, Options.End_Time, Options.Start, Load,
         Matches'Unrestricted_Access);
   end Search;

   overriding procedure Rename_Network
     (S : in out Fs_Store; Old_Net, New_Net : Soja.Database.Network)
   is
      Old_Dir : constant String := Ada.Directories.Compose
        (To_String (S.Root),
         Escape_Filename (Soja.Database.Get_Name (Old_Net)));
      New_Dir : constant String := Ada.Directories.Compose
        (To_String (S.Root),
         Escape_Filename (Soja.Database.Get_Name (New_Net)));
   begin
      --  A network that has no history yet has no directory to move (soju
      --  reports that as an error every time, SOJU-BUGS.md).
      if not Ada.Directories.Exists (Old_Dir) then
         return;
      end if;
      --  Avoid losing data by overwriting an existing directory.
      if Ada.Directories.Exists (New_Dir) then
         raise Store_Error with
           "destination " & Soja.Irc.Helpers.Quote (New_Dir)
           & " already exists";
      end if;
      --  Open files point into the old directory.
      Close (S);
      Ada.Directories.Rename (Old_Dir, New_Dir);
   exception
      when E : Ada.Directories.Use_Error | Ada.Directories.Name_Error =>
         raise Store_Error with Ada.Exceptions.Exception_Message (E);
   end Rename_Network;

end Soja.Msgstore.Fs;
