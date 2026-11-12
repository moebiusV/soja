pragma Ada_2022;

with Ada.Calendar;
with Ada.Strings.Unbounded;

with Soja.Database;
with Soja.Irc.Messages;

--  Soja.Msgstore — msgstore/msgstore.go: the per-user store of IRC messages
--  and the internal message-ID codec shared by its implementations.
--
--  Go's optional interfaces (ChatHistoryStore, SearchStore,
--  RenameNetworkStore, discovered by type assertion) arrive with the stores
--  that implement them (the filesystem and database stores).  Go's `error`
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
   --  Go).  None of the stores ported so far does.
   function Supports_Chat_History (S : Store) return Boolean is (False);

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

   ----------------
   --  Message IDs --
   ----------------

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
