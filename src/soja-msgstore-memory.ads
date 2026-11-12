pragma Ada_2022;

with Ada.Containers.Indefinite_Ordered_Maps;
with Interfaces;

--  Soja.Msgstore.Memory — msgstore/memory.go: a volatile store keeping the
--  last 4096 PRIVMSG/NOTICE per (network, entity) in a ring buffer.  Like
--  Go's, it is not synchronised: it is used only from its user's event loop.
--  Stored and returned messages are copies (Go shares the pointers).
package Soja.Msgstore.Memory is

   Message_Ring_Buffer_Cap : constant := 4096;

   type Memory_Store is new Store with private;

   function New_Memory_Store return Store_Access;

   --  IsMemoryStore.
   function Is_Memory_Store (S : Store'Class) return Boolean;

   overriding procedure Close (S : in out Memory_Store);

   overriding function Last_Msg_ID
     (S : in out Memory_Store; Network : Soja.Database.Network;
      Entity : String; T : Ada.Calendar.Time) return String;

   --  Events are unsupported (Store_Error).
   overriding function Load_Latest_ID
     (S : in out Memory_Store; ID : String; Options : Load_Message_Options)
      return Soja.Irc.Messages.Message_Vectors.Vector;

   --  Only PRIVMSG and NOTICE are stored (LoadLatestID must not return other
   --  kinds); anything else returns "".
   overriding function Append
     (S : in out Memory_Store; Network : Soja.Database.Network;
      Entity : String; Msg : Soja.Irc.Messages.Message) return String;

private

   use Interfaces;

   type Message_Access is access Soja.Irc.Messages.Message;
   type Message_Array is array (0 .. Message_Ring_Buffer_Cap - 1)
     of Message_Access;

   --  messageRingBuffer: Cur is the next sequence number (starting at 1).
   type Message_Ring is record
      Buf : Message_Array := [others => null];
      Cur : Unsigned_64 := 1;
   end record;

   type Ring_Access is access Message_Ring;

   --  Keyed by "<network id>/<entity>" (an id's image has no '/', so the key
   --  is unambiguous).
   package Buffer_Maps is new Ada.Containers.Indefinite_Ordered_Maps
     (Key_Type => String, Element_Type => Ring_Access);

   type Memory_Store is new Store with record
      Buffers : Buffer_Maps.Map;
   end record;

end Soja.Msgstore.Memory;
