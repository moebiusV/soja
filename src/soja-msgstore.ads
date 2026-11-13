pragma Ada_2022;

with Ada.Calendar;
with Ada.Containers.Vectors;
with Ada.Strings.Unbounded;

with Soja.Database;
with Soja.Irc.Messages;

--  Soja.Msgstore — msgstore/msgstore.go: the per-user store of IRC messages
--  and the internal message-ID codec shared by its implementations.
--
--  Go's optional interfaces (ChatHistoryStore, SearchStore), which Go finds by
--  type assertion, are operations of Store here with Supports_* functions that
--  say whether a store has them; a store that does not raises Store_Error if
--  they are called anyway (likewise RenameNetworkStore).  Go's `error`
--  returns are Store_Error exceptions here.
package Soja.Msgstore is

   Store_Error : exception;

   type Load_Message_Options is record
      Network : Soja.Database.Network;
      Entity  : Ada.Strings.Unbounded.Unbounded_String;
      Limit   : Integer := 0;
      Events  : Boolean := False;
   end record;

   --  Store: a per-user store for IRC messages.
   type Store is abstract tagged limited null record;
   type Store_Access is access all Store'Class;

   procedure Close (S : in out Store) is abstract;

   --  Whether the store implements Go's ChatHistoryStore (a type assertion in
   --  Go): ListTargets, LoadBeforeTime and LoadAfterTime below.
   function Supports_Chat_History (S : Store) return Boolean is (False);

   --  Whether it implements SearchStore: Search below.
   function Supports_Search (S : Store) return Boolean is (False);

   --  Whether it implements RenameNetworkStore: it must be told when a
   --  network is renamed (the file store names a directory after it).
   function Supports_Rename_Network (S : Store) return Boolean is (False);
   procedure Rename_Network
     (S : in out Store; Old_Net, New_Net : Soja.Database.Network);

   --  The user's settings changed (soja-specific: the file store takes the
   --  nick of messages sent to us from them).
   procedure User_Updated (S : in out Store; User : Soja.Database.User)
     is null;

   --  LastMsgID: the last message ID for the given network, entity and date.
   --  It may not refer to a valid message, but can be used in history
   --  queries.
   function Last_Msg_ID
     (S : in out Store; Network : Soja.Database.Network; Entity : String;
      T : Ada.Calendar.Time) return String is abstract;

   --  LoadLatestID: the latest non-event messages after the message ID
   --  (excluded), up to Options.Limit, sorted from oldest to newest.
   function Load_Latest_ID
     (S : in out Store; ID : String; Options : Load_Message_Options)
      return Soja.Irc.Messages.Message_Vectors.Vector is abstract;

   --  Append: returns the new message's ID ("" when the message is not
   --  stored).
   function Append
     (S : in out Store; Network : Soja.Database.Network; Entity : String;
      Msg : Soja.Irc.Messages.Message) return String is abstract;

   ----------------------------
   --  Chat history and search --
   ----------------------------

   type Chat_History_Target is record
      Name           : Ada.Strings.Unbounded.Unbounded_String;
      Latest_Message : Ada.Calendar.Time;
   end record;
   package Target_Vectors is
     new Ada.Containers.Vectors (Positive, Chat_History_Target);

   subtype Message_Vector is Soja.Irc.Messages.Message_Vectors.Vector;

   --  ListTargets: channels and nicknames by time of the latest message, up
   --  to Limit of them, between Start and End_Time, both excluded; End_Time
   --  may be before or after Start.  If Events is False only PRIVMSG/NOTICE
   --  count.
   function List_Targets
     (S : in out Store; Network : Soja.Database.Network;
      Start, End_Time : Ada.Calendar.Time; Limit : Natural; Events : Boolean)
      return Target_Vectors.Vector;

   --  LoadBeforeTime: up to Options.Limit messages before Start down to
   --  End_Time (which is before Start), both excluded, oldest first.  The
   --  zero time (Soja.Database.Null_Time) is no bound.
   function Load_Before_Time
     (S : in out Store; Start, End_Time : Ada.Calendar.Time;
      Options : Load_Message_Options) return Message_Vector;

   --  LoadAfterTime: up to Options.Limit messages after Start up to
   --  End_Time (which is after Start), both excluded, oldest first.
   function Load_After_Time
     (S : in out Store; Start, End_Time : Ada.Calendar.Time;
      Options : Load_Message_Options) return Message_Vector;

   --  SearchMessageOptions.  A zero field is no such filter.
   type Search_Options is record
      Start     : Ada.Calendar.Time := Soja.Database.Null_Time;
      End_Time  : Ada.Calendar.Time := Soja.Database.Null_Time;
      Limit     : Natural := 0;
      From      : Ada.Strings.Unbounded.Unbounded_String;
      In_Target : Ada.Strings.Unbounded.Unbounded_String;
      Text      : Ada.Strings.Unbounded.Unbounded_String;
   end record;

   --  Search: the newest Options.Limit messages matching, oldest first.
   function Search
     (S : in out Store; Network : Soja.Database.Network;
      Options : Search_Options) return Message_Vector;

   ----------------
   --  Message IDs --

   --  msgIDType (iota: none, memory, fs, db).  A plain number so that an ID
   --  carrying an unknown type still parses (and is rejected only when a
   --  specific type is expected), as in Go.
   subtype Msg_ID_Type is Natural;
   Msg_ID_None   : constant Msg_ID_Type := 0;
   Msg_ID_Memory : constant Msg_ID_Type := 1;
   Msg_ID_FS     : constant Msg_ID_Type := 2;
   Msg_ID_DB     : constant Msg_ID_Type := 3;

   Msg_ID_Version : constant := 0;

   --  formatMsgID: the BARE header (version, network, target, type) followed
   --  by Body_Bytes (the type-specific body, already BARE-encoded), as raw
   --  URL-safe base64.
   function Format_Msg_ID
     (Net_ID : Long_Long_Integer; Target : String; Typ : Msg_ID_Type;
      Body_Bytes : String) return String;

   --  ParseMsgID: Body_Bytes receives the bytes after the header.  When
   --  Expected is not Msg_ID_None the ID's type must match it.  Raises
   --  Store_Error ("invalid internal message ID: ...") otherwise.
   procedure Parse_Msg_ID
     (S          : String;
      Net_ID     : out Long_Long_Integer;
      Target     : out Ada.Strings.Unbounded.Unbounded_String;
      Body_Bytes : out Ada.Strings.Unbounded.Unbounded_String;
      Expected   : Msg_ID_Type := Msg_ID_None);

end Soja.Msgstore;
