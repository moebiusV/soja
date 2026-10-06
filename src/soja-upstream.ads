pragma Ada_2022;

with Ada.Calendar;
with Ada.Strings.Unbounded;

with Soja.Irc.Messages;

--  Soja.Upstream — the upstream (IRC-server-facing) connection, translated
--  from upstream.go.  This first slice carries the standalone record types;
--  the upstreamConn struct and its message logic follow once the shared
--  user/network/downstream types are ported.
package Soja.Upstream is

   use Ada.Strings.Unbounded;

   --  upstreamUser: cached WHO information for one user on the upstream
   --  network.
   type Upstream_User is record
      Nickname : Unbounded_String;
      Username : Unbounded_String;
      Hostname : Unbounded_String;
      Server   : Unbounded_String;
      Flags    : Unbounded_String;
      Account  : Unbounded_String;
      Realname : Unbounded_String;
   end record;

   --  hasWHOXFields: whether every WHOX field letter in Fields is available
   --  for this user.
   function Has_WHOX_Fields (UU : Upstream_User; Fields : String)
      return Boolean;

   --  updateFrom: copy the non-empty fields of Update over UU.
   procedure Update_From (UU : in out Upstream_User; Update : Upstream_User);

   --  upstreamBatch: an IRCv3 batch in progress (Outer is the enclosing
   --  batch, null for a top-level batch).
   type Upstream_Batch;
   type Upstream_Batch_Access is access Upstream_Batch;
   type Upstream_Batch is record
      Batch_Type : Unbounded_String;   -- Go "Type"
      Params     : Soja.Irc.Messages.Param_Vectors.Vector;
      Outer      : Upstream_Batch_Access;
      Label      : Unbounded_String;
   end record;

   --  pendingUpstreamCommand: a queued upstream command awaiting a reply.
   type Pending_Upstream_Command is record
      Downstream_ID : Long_Long_Integer;   -- uint64
      Msg           : Soja.Irc.Messages.Message;
      Sent_At       : Ada.Calendar.Time;
   end record;

end Soja.Upstream;
