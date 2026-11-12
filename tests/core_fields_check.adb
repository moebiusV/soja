pragma Ada_2022;

with Ada.Strings.Unbounded;
with Ada.Text_IO;

with Soja.Conn;
with Soja.Core;
with Soja.Database;
with Soja.Irc.Cap_Registry;
with Soja.Irc.Case_Mapping;
with Soja.Irc.Members;
with Soja.Irc.Messages;
with Soja.Irc.Modes;
with Soja.Logging;
with Soja.Server;
with Soja.Timers;

procedure Core_Fields_Check is
   use Ada.Strings.Unbounded;
   use Soja.Core;
   use Soja.Conn;
   use type Soja.Timers.Timer_Access;
   use type Soja.Irc.Members.Membership_Set_Access;

   procedure Check (Cond : Boolean; What : String) is
   begin
      if not Cond then
         raise Program_Error with What;
      end if;
   end Check;

   --  A transport that records what is written to it.
   protected Wire is
      procedure Add (Line : String);
      function Count return Natural;
      function Last return String;
   private
      N : Natural := 0;
      L : Unbounded_String;
   end Wire;

   protected body Wire is
      procedure Add (Line : String) is
      begin
         N := N + 1;
         L := To_Unbounded_String (Line);
      end Add;
      function Count return Natural is (N);
      function Last return String is (To_String (L));
   end Wire;

   Addr : Unbounded_String := To_Unbounded_String ("1.2.3.4:6667");

   type Fake_Transport is new IRC_Conn with null record;
   overriding function Read_Message
     (C : in out Fake_Transport) return Soja.Irc.Messages.Message is
     (others => <>);
   overriding procedure Write_Message
     (C : in out Fake_Transport; M : Soja.Irc.Messages.Message);
   overriding procedure Close (C : in out Fake_Transport) is null;
   overriding function Remote_Addr (C : Fake_Transport) return String is
     (To_String (Addr));

   overriding procedure Write_Message
     (C : in out Fake_Transport; M : Soja.Irc.Messages.Message) is
   begin
      Wire.Add (Soja.Irc.Messages.Image (M));
   end Write_Message;

   --  Wait (up to Secs) for Wire.Count to reach N.
   function Wait_Wire (N : Natural; Secs : Duration := 3.0) return Boolean is
      Waited : Duration := 0.0;
   begin
      while Wire.Count < N and then Waited < Secs loop
         delay 0.02;
         Waited := Waited + 0.02;
      end loop;
      return Wire.Count >= N;
   end Wait_Wire;

   Log : aliased Soja.Logging.Standard_Logger;
   S   : aliased Soja.Server.Server;
   F   : aliased Fake_Transport;

   --  Every connection's writer task must be closed or the program cannot
   --  exit; Make_DC remembers each one for the end of the test.
   Made : array (1 .. 16) of Downstream_Conn_Access;
   N_Made : Natural := 0;

   function Make_DC (ID : Long_Long_Integer) return Downstream_Conn_Access is
      DC : constant Downstream_Conn_Access :=
        New_Downstream_Conn (S'Unchecked_Access, F'Unchecked_Access, ID);
   begin
      N_Made := N_Made + 1;
      Made (N_Made) := DC;
      return DC;
   end Make_DC;
begin
   S.Initialize (Log'Unchecked_Access);

   -------------------------------------------------------------------
   --  Event_Queue.Try_Enqueue: non-blocking, refuses when full.
   -------------------------------------------------------------------
   declare
      Q  : Event_Queue;
      Ok : Boolean;
      E  : Event_Access;
      Done : Boolean;
   begin
      for I in 1 .. Event_Capacity loop
         Q.Try_Enqueue (new Stop_Event, Ok);
         Check (Ok, "Try_Enqueue below capacity");
      end loop;
      Q.Try_Enqueue (new Stop_Event, Ok);
      Check (not Ok, "Try_Enqueue on a full queue must refuse");
      Q.Dequeue (E, Done);
      Check (not Done, "dequeue after full");
      Q.Try_Enqueue (new Stop_Event, Ok);
      Check (Ok, "Try_Enqueue after making room");
   end;

   -------------------------------------------------------------------
   --  Server config and the downstream caps derived from it.
   -------------------------------------------------------------------
   Check (To_String (Soja.Server.Config (S).Hostname) = "localhost"
          and then Soja.Server.Config (S).Max_User_Networks = -1
          and then To_String (Soja.Server.Config (S).Auth_Driver)
                   = "internal", "NewServer config defaults");
   Check (Server_SASL_Mechanisms (S'Unchecked_Access) = "PLAIN",
          "internal auth offers PLAIN");

   declare
      DC : Downstream_Conn_Access;
      use Soja.Irc.Cap_Registry;
   begin
      DC := Make_DC (1);
      Check (Value (DC.Caps, "sasl") = "PLAIN", "sasl cap value");
      Check (not Is_Available (DC.Caps, "draft/chathistory")
             and then not Is_Available (DC.Caps, "soju.im/search"),
             "no chathistory without a persistent store");
      Check (DC.Hostname = To_Unbounded_String ("1.2.3.4"),
             "hostname is the host part of host:port");
      Check (DC.Monitored.Length = 0 and then DC.Sasl = null,
             "monitored/sasl start empty");

      Addr := To_Unbounded_String ("[::1]:6667");
      DC := Make_DC (2);
      Check (DC.Hostname = To_Unbounded_String ("::1"),
             "bracketed IPv6 host");
      Addr := To_Unbounded_String ("/run/soju/admin.sock");
      DC := Make_DC (3);
      Check (DC.Hostname = To_Unbounded_String ("/run/soju/admin.sock"),
             "no port: whole address");
   end;

   declare
      Cfg : constant Soja.Server.Server_Config_Access :=
        new Soja.Server.Server_Config;
      DC  : Downstream_Conn_Access;
      use Soja.Irc.Cap_Registry;
   begin
      Cfg.Msg_Store_Driver := To_Unbounded_String ("fs");
      Cfg.Auth_Driver := To_Unbounded_String ("oauth2");
      S.Set_Config (Cfg);
      Check (Server_SASL_Mechanisms (S'Unchecked_Access)
             = "PLAIN,OAUTHBEARER", "oauth2 offers both");
      DC := Make_DC (4);
      Check (Is_Available (DC.Caps, "draft/chathistory")
             and then Is_Available (DC.Caps, "soju.im/search"),
             "fs store enables chathistory and search");
      Check (Value (DC.Caps, "sasl") = "PLAIN,OAUTHBEARER",
             "sasl cap value (oauth2)");

      Cfg.Msg_Store_Driver := To_Unbounded_String ("memory");
      Cfg.Auth_Driver := To_Unbounded_String ("pam");
      Check (Server_SASL_Mechanisms (S'Unchecked_Access) = "PLAIN",
             "pam offers PLAIN");
      DC := Make_DC (5);
      Check (not Is_Available (DC.Caps, "draft/chathistory"),
             "memory store: no chathistory");
      Cfg.Auth_Driver := To_Unbounded_String ("bogus");
      Check (Server_SASL_Mechanisms (S'Unchecked_Access) = "",
             "unknown driver offers nothing");
      Cfg.Auth_Driver := To_Unbounded_String ("internal");
   end;

   -------------------------------------------------------------------
   --  A hand-built upstream: fields, channel constructor, timers.
   -------------------------------------------------------------------
   declare
      Rec : Soja.Database.User := Soja.Database.New_User ("alice");
      U   : constant User_Access := New_User (S'Unchecked_Access, Rec);
      NR  : constant Soja.Database.Network :=
        Soja.Database.New_Network ("irc+insecure://irc.example");
      Net : constant Network_Access :=
        New_Network (U, NR, Soja.Database.Channel_Lists.Empty_Vector);
      UC  : constant Upstream_Conn_Access := new Upstream_Conn;
      Fake : aliased Fake_Transport;
      E    : Event_Access;
      Done : Boolean;
   begin
      Check (Net.Push_Targets.Length = 0 and then not Net.Has_Last_Error,
             "network pushTargets/lastError start empty");

      UC.Network := Net;
      UC.User := U;
      UC.Logger := Log'Unchecked_Access;
      UC.Nick := To_Unbounded_String ("alice_");
      UC.Conn := Soja.Conn.New_Conn
        (Fake'Unchecked_Access,
         (Logger => null, Rate_Limit_Delay => 0.0, Rate_Limit_Burst => 0));

      --  New_Upstream_Channel: name, back-pointer, member map on the
      --  network's case-mapping.
      declare
         Ch : constant Upstream_Channel_Access :=
           New_Upstream_Channel (UC, "#Chan");
         Alice : constant Soja.Irc.Members.Membership_Set_Access :=
           new Soja.Irc.Members.Membership_Vectors.Vector;
      begin
         Check (To_String (Ch.Name) = "#Chan" and then Ch.Conn = UC,
                "channel name/conn");
         Check (not Ch.Modes.Known and then Ch.Detach_Timer = null,
                "channel modes unknown, no timer");
         Ch.Members.Set ("Nick[x]", Alice);
         --  Network.Casemap is rfc1459: [ and { are the same letter.
         Check (Ch.Members.Get ("nick{x}") = Alice,
                "members use the network case-mapping");

         --  Auto-detach: fires once, posts Channel_Detach_Event.
         Update_Auto_Detach (Ch, 0.05);
         Check (Ch.Detach_Timer /= null, "detach timer armed");
         select
            U.Events.Dequeue (E, Done);
            Check (not Done and then E.all in Channel_Detach_Event,
                   "detach event type");
            Check (To_String (Channel_Detach_Event (E.all).Name) = "#Chan"
                   and then Channel_Detach_Event (E.all).UC = UC,
                   "detach event contents");
         or
            delay 2.0;
            Check (False, "detach timer never fired");
         end select;

         --  Re-arming replaces the old timer; zero only cancels.
         Update_Auto_Detach (Ch, 0.3);
         Update_Auto_Detach (Ch, 0.0);
         Check (Ch.Detach_Timer = null, "zero duration cancels");
         select
            U.Events.Dequeue (E, Done);
            Check (False, "cancelled detach timer fired");
         or
            delay 0.6;
         end select;
      end;

      --  Regain nick: alice_ wants "alice".
      Check (not Is_Our_Nick (UC, "alice") and then Is_Our_Nick (UC, "ALICE_"),
             "Is_Our_Nick (case-insensitive)");
      Start_Regain_Nick_Timer (UC);
      Check (UC.Regain_Nick_Timer /= null
             and then UC.Regain_Nick_Backoff /= null, "regain timer armed");
      begin
         Start_Regain_Nick_Timer (UC);
         Check (False, "starting twice must raise");
      exception
         when Program_Error => null;
      end;

      --  A stale nick (user changed their desired nick) stops the timer.
      Try_Regain_Nick (UC, "something-else");
      Check (UC.Regain_Nick_Timer = null and then UC.Regain_Nick_Backoff = null,
             "stale regain attempt stops the timer");

      Start_Regain_Nick_Timer (UC);
      Check (Wire.Count = 0, "nothing sent yet");
      Try_Regain_Nick (UC, "alice");
      Check (Wait_Wire (1) and then Wire.Last = "NICK alice",
             "regain sends NICK: " & Wire.Last);
      Check (To_String (UC.Pending_Regain_Nick) = "alice", "pending nick");
      Try_Regain_Nick (UC, "alice");   --  still pending: no second NICK
      delay 0.2;
      Check (Wire.Count = 1, "no NICK while one is pending");
      Stop_Regain_Nick_Timer (UC);
      Check (UC.Regain_Nick_Timer = null, "regain timer stopped");
      Try_Regain_Nick (UC, "alice");   --  no timer: no-op
      delay 0.2;
      Check (Wire.Count = 1, "no NICK without a timer");

      --  Already our nick: no timer.
      UC.Nick := To_Unbounded_String ("alice");
      Start_Regain_Nick_Timer (UC);
      Check (UC.Regain_Nick_Timer = null, "no timer when nick is ours");

      Soja.Conn.Close (UC.Conn);
   end;

   for I in 1 .. N_Made loop
      Soja.Conn.Close (Made (I).Conn);   --  stop the writer tasks
   end loop;

   Ada.Text_IO.Put_Line ("ALL PASS");
end Core_Fields_Check;
