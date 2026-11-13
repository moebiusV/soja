pragma Ada_2022;

with Ada.Calendar;
with Ada.Containers;
with Ada.Exceptions;

with Soja.Core.Downstream_Helpers;
with Soja.Core.Upstream_Dispatch;
with Soja.Irc.Case_Mapping;
with Soja.Irc.Genmsg;
with Soja.Irc.Helpers;
with Soja.Msgstore;

package body Soja.Core.Network_Ops is

   use Soja.Irc.Messages;
   use type Soja.Msgstore.Store_Access;
   use type Ada.Containers.Count_Type;
   use type Soja.Database.Message_Filter;

   ------------------
   -- Is_Highlight --
   ------------------

   function Is_Highlight
     (Net : not null Network_Access; Msg : Message) return Boolean
   is
      Cmd : constant String := To_String (Msg.Command);
   begin
      if (Cmd /= "PRIVMSG" and then Cmd /= "NOTICE")
        or else Msg.Params.Length < 2
      then
         return False;
      end if;

      declare
         Text : constant String := Param (Msg, 1);
         Nick : constant String :=
           (if Net.Conn /= null then To_String (Net.Conn.Nick)
            else Soja.Database.Get_Nick
                   (Net.User.User_Record, Net.Network_Record));
      begin
         --  TODO (Go): use a case-mapping aware comparison here.
         return Nick /= "" and then To_String (Msg.Prefix.Name) /= Nick
           and then Soja.Irc.Helpers.Is_Highlight (Text, Nick);
      end;
   end Is_Highlight;

   ----------------------------------
   -- Detached_Message_Needs_Relay --
   ----------------------------------

   function Detached_Message_Needs_Relay
     (Net : not null Network_Access;
      Ch  : not null Channel_Access;
      Msg : Message) return Boolean
   is
      use Soja.Database;
      Highlight : constant Boolean := Is_Highlight (Net, Msg);
   begin
      return Ch.Relay_Detached = Filter_Message
        or else ((Ch.Relay_Detached = Filter_Highlight
                  or else Ch.Relay_Detached = Filter_Default)
                 and then Highlight);
   end Detached_Message_Needs_Relay;

   ------------
   -- Detach --
   ------------

   procedure Detach
     (Net : not null Network_Access; Ch : not null Channel_Access)
   is
      use Soja.Core.Downstream_Helpers;
      Name : constant String := To_String (Ch.Name);
   begin
      if Ch.Detached then
         return;
      end if;

      Net.Logger.Print ("detaching channel " & Soja.Irc.Helpers.Quote (Name));
      Ch.Detached := True;

      if Net.User.Msg_Store /= null then
         begin
            Ch.Detached_Internal_Msg_ID := To_Unbounded_String
              (Net.User.Msg_Store.Last_Msg_ID
                 (Net.Network_Record,
                  Soja.Irc.Case_Mapping.Fold (Net.Casemap, Name),
                  Ada.Calendar.Clock));
         exception
            when E : Soja.Msgstore.Store_Error =>
               Net.Logger.Print
                 ("failed to get last message ID for channel "
                  & Soja.Irc.Helpers.Quote (Name) & ": "
                  & Ada.Exceptions.Exception_Message (E));
               Ch.Detached_Internal_Msg_ID := Null_Unbounded_String;
         end;
      end if;

      if Net.Conn /= null then
         declare
            Uch : constant Upstream_Channel_Access :=
              Net.Conn.Channels.Get (Name);
         begin
            if Uch /= null then
               Update_Auto_Detach (Uch, 0.0);
            end if;
         end;
      end if;

      for DC of Downstreams (Net) loop
         declare
            M : Message := Soja.Irc.Genmsg.Make ("PART", [Name, "Detach"]);
         begin
            M.Prefix := new Prefix'(Prefix_Of (DC));
            Send_Message (DC, M);
         end;
      end loop;
   end Detach;

   ------------
   -- Attach --
   ------------

   procedure Attach
     (Net : not null Network_Access; Ch : not null Channel_Access)
   is
      use Soja.Core.Downstream_Helpers;
      Name : constant String := To_String (Ch.Name);
   begin
      if not Ch.Detached then
         return;
      end if;

      Net.Logger.Print ("attaching channel " & Soja.Irc.Helpers.Quote (Name));

      declare
         Detached_Msg_ID : constant String :=
           To_String (Ch.Detached_Internal_Msg_ID);
         Uch : Upstream_Channel_Access;
      begin
         Ch.Detached := False;
         Ch.Detached_Internal_Msg_ID := Null_Unbounded_String;

         if Net.Conn /= null then
            Uch := Net.Conn.Channels.Get (Name);
            Soja.Core.Upstream_Dispatch.Update_Channel_Auto_Detach
              (Net.Conn, Name);
         end if;

         for DC of Downstreams (Net) loop
            declare
               M : Message := Soja.Irc.Genmsg.Make ("JOIN", [Name]);
            begin
               M.Prefix := new Prefix'(Prefix_Of (DC));
               Send_Message (DC, M);
            end;

            --  (Go panics when the channel's NAMES are still incomplete;
            --  it is replayed when they end instead.)
            if Uch /= null and then Uch.Complete then
               Forward_Channel (DC, Uch);
            end if;

            if Detached_Msg_ID /= "" then
               Send_Target_Backlog (DC, Net, Name, Detached_Msg_ID);
            end if;
         end loop;
      end;
   end Attach;

end Soja.Core.Network_Ops;
