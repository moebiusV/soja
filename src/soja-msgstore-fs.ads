--  Soja.Msgstore.Fs -- msgstore/fs.go: a per-user on-disk message store that
--  mimics the layout and format of ZNC's log module:
--
--     <root>/<user>/<network>/<target>/<year>-<month>-<day>.log
--
--  one line per message ("[12:34:56] <nick> text", see Soja.Msgstore.Znclog),
--  days in local time.  A message's ID is the date and the byte offset of its
--  line in the day's file.  It has chat history and search (by scanning
--  files, case-insensitively).
pragma Ada_2022;

private with Ada.Containers.Indefinite_Ordered_Maps;
private with System;
private with Ada.Strings.Unbounded;

with Ada.Calendar;
with Ada.Strings.Unbounded;

with Soja.Database;

package Soja.Msgstore.Fs is

   --  fsMessageStoreMaxFiles: log files kept open.
   Max_Files : constant := 20;
   --  fsMessageStoreMaxTries: empty days in a row before giving up.
   Max_Tries : constant := 100;

   --  EscapeFilename: a name made safe to use as a file name ("." and ".."
   --  and the path separators are replaced).
   function Escape_Filename (Unsafe : String) return String;

   type Fs_Store is new Store with private;

   --  The store of User, under Root (the user gets a directory of their own).
   function New_Fs_Store (Root : String; User : Soja.Database.User)
      return Store_Access;

   function Is_Fs_Store (S : Store'Class) return Boolean;

   --  DeleteMessagesBefore: removes the log files under Root whose day (the
   --  first ten characters of the name, YYYY-MM-DD) is before the day of
   --  Before, then the directories that are left empty (not Root itself).
   --  Store_Error when a file cannot be removed.  A failure only of the
   --  second part is not an error: it is told in Cleanup_Error (empty when
   --  all went well).
   procedure Delete_Messages_Before
     (Root          : String;
      Before        : Ada.Calendar.Time;
      Cleanup_Error : out Ada.Strings.Unbounded.Unbounded_String);

   overriding procedure Close (S : in out Fs_Store);

   overriding function Supports_Chat_History (S : Fs_Store) return Boolean;
   overriding function Supports_Search (S : Fs_Store) return Boolean;
   overriding function Supports_Rename_Network (S : Fs_Store) return Boolean;

   overriding procedure User_Updated
     (S : in out Fs_Store; User : Soja.Database.User);

   overriding function Last_Msg_ID
     (S : in out Fs_Store; Network : Soja.Database.Network;
      Entity : String; T : Ada.Calendar.Time) return String;

   overriding function Load_Latest_ID
     (S : in out Fs_Store; ID : String; Options : Load_Message_Options)
      return Soja.Irc.Messages.Message_Vectors.Vector;

   overriding function Append
     (S : in out Fs_Store; Network : Soja.Database.Network;
      Entity : String; Msg : Soja.Irc.Messages.Message) return String;

   overriding function List_Targets
     (S : in out Fs_Store; Network : Soja.Database.Network;
      Start, End_Time : Ada.Calendar.Time; Limit : Natural; Events : Boolean)
      return Target_Vectors.Vector;

   overriding function Load_Before_Time
     (S : in out Fs_Store; Start, End_Time : Ada.Calendar.Time;
      Options : Load_Message_Options) return Message_Vector;

   overriding function Load_After_Time
     (S : in out Fs_Store; Start, End_Time : Ada.Calendar.Time;
      Options : Load_Message_Options) return Message_Vector;

   overriding function Search
     (S : in out Fs_Store; Network : Soja.Database.Network;
      Options : Search_Options) return Message_Vector;

   --  RenameNetwork: move the network's directory to its new name, so that
   --  the history follows.  Nothing to move (no history yet) is not an
   --  error; an existing destination is, so that nothing is overwritten.
   overriding procedure Rename_Network
     (S : in out Fs_Store; Old_Net, New_Net : Soja.Database.Network);

private

   use Ada.Strings.Unbounded;

   --  A log file open for appending: a C stdio FILE* (null when closed).  The
   --  C library, not Ada's files, so that the store can read a day's log while
   --  it has it open for appending (GNAT forbids mixing modes on one file).
   type Open_File is record
      File     : System.Address := System.Null_Address;
      Path     : Unbounded_String;
      Last_Use : Ada.Calendar.Time;
   end record;

   package File_Maps is new Ada.Containers.Indefinite_Ordered_Maps
     (Key_Type => String, Element_Type => Open_File);

   type Fs_Store is new Store with record
      Root  : Unbounded_String;     --  with the user's directory
      User  : Soja.Database.User;
      Files : File_Maps.Map;        --  by entity
   end record;

end Soja.Msgstore.Fs;
