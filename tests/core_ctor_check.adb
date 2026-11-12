pragma Ada_2022;

with Ada.Text_IO;
with Ada.Strings.Unbounded;

with Soja.Core;
with Soja.Conn;
with Soja.Database;
with Soja.Irc.Cap_Registry;
with Soja.Irc.Case_Mapping;
with Soja.Irc.Messages;
with Soja.Server;

procedure Core_Ctor_Check is
   use Ada.Strings.Unbounded;
   use Soja.Core;
   use Soja.Conn;
   use Soja.Irc.Case_Mapping;
   use type Soja.Server.Server_Access;

begin

   ------------
   --  Queue --
   ------------

   declare
      Q  : Event_Queue;
      E1 : Event_Access := new Upstream_Connected_Event;
      E2 : Event_Access := new Downstream_Disconnected_Event;
      E  : Event_Access;
      Done : Boolean;
   begin
      if Q.Is_Closed then
         raise Program_Error with "fresh queue must be open";
      end if;
      Q.Enqueue (E1);
      Q.Enqueue (E2);
      Q.Dequeue (E, Done);
      if Done or else E /= E1 then
         raise Program_Error with "queue order broken (1)";
      end if;
      Q.Dequeue (E, Done);
      if Done or else E /= E2 then
         raise Program_Error with "queue order broken (2)";
      end if;
      Q.Close;
      if not Q.Is_Closed then
         raise Program_Error with "queue must be closed after Close";
      end if;
      Q.Dequeue (E, Done);
      if not Done then
         raise Program_Error with "empty closed queue must report Done";
      end if;
   end;

   ---------------
   --  New_User --
   ---------------

   declare
      S    : aliased Soja.Server.Server;
      Rec  : Soja.Database.User := Soja.Database.New_User ("alice");
      U    : User_Access;
   begin
      S.Initialize (null);
      U := New_User (S'Unchecked_Access, Rec);
      if U.Srv /= S'Unchecked_Access then
         raise Program_Error with "user srv not stored";
      end if;
      if U.Events = null or else U.Done = null then
         raise Program_Error with "user queue/done not allocated";
      end if;
      if U.User_Record.Username /= To_Unbounded_String ("alice") then
         raise Program_Error with "user record not stored";
      end if;
   end;

   ------------------
   --  New_Network --
   ------------------

   declare
      Rec  : Soja.Database.Network := Soja.Database.New_Network ("irc.example");
      U    : User_Access := new User;
      Chs  : Soja.Database.Channel_Lists.Vector;
      Net  : Network_Access;
   begin
      Chs.Append (Soja.Database.Channel'
        (Name => To_Unbounded_String ("#chan"), others => <>));
      Net := New_Network (U, Rec, Chs);
      if Net.User /= U then
         raise Program_Error with "network user not stored";
      end if;
      if not Net.Channels.Has ("#chan")
        or else not Net.Channels.Has ("#CHAN")
      then
         raise Program_Error with "channel map not seeded/casemapped";
      end if;
      if Net.Casemap /= Case_RFC1459 then
         raise Program_Error with "network casemap should be rfc1459";
      end if;
   end;

   --------------------------
   --  New_Downstream_Conn --
   --------------------------

   declare
      --  A fake transport; the writer only calls Write_Message/Close.
      type Fake_Transport is new IRC_Conn with null record;
      overriding function Read_Message
        (C : in out Fake_Transport) return Soja.Irc.Messages.Message is
        (others => <>);
      overriding procedure Write_Message
        (C : in out Fake_Transport; M : Soja.Irc.Messages.Message) is null;
      overriding procedure Close (C : in out Fake_Transport) is null;
      overriding function Remote_Addr (C : Fake_Transport) return String is
        ("1.2.3.4:6667");

      S  : aliased Soja.Server.Server;
      F  : aliased Fake_Transport;
      DC : Downstream_Conn_Access;
   begin
      S.Initialize (null);
      DC := New_Downstream_Conn (S'Unchecked_Access, F'Unchecked_Access, 7);
      if DC.ID /= 7 then
         raise Program_Error with "downstream id not stored";
      end if;
      if DC.Nick /= To_Unbounded_String ("*") then
         raise Program_Error with "downstream default nick wrong";
      end if;
      if DC.Username /= To_Unbounded_String ("~u") then
         raise Program_Error with "downstream default username wrong";
      end if;
      if DC.Hostname /= To_Unbounded_String ("1.2.3.4") then
         raise Program_Error with "downstream hostname wrong";
      end if;
      if not Soja.Irc.Cap_Registry.Is_Available (DC.Caps, "batch")
        or else not Soja.Irc.Cap_Registry.Is_Available
          (DC.Caps, "soju.im/webpush")
      then
         raise Program_Error with "permanent caps not advertised";
      end if;
      if DC.Registration = null then
         raise Program_Error with "registration not allocated";
      end if;
      Soja.Conn.Close (DC.Conn);   --  stop the writer task
   end;

   Ada.Text_IO.Put_Line ("ALL PASS");
end Core_Ctor_Check;
