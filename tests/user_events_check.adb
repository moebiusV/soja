pragma Ada_2022;

with Ada.Calendar;
with Ada.Containers;
with Ada.Containers.Indefinite_Vectors;
with Ada.Exceptions;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;
with Ada.Text_IO;
with GNAT.OS_Lib;

with Soja.Conn;
with Soja.Core;                use Soja.Core;
with Soja.Core.Upstream_Dispatch;
with Soja.Core.User_Events;
with Soja.Core.User_Ops;
with Soja.Database;
with Soja.Database.Sqlite;
with Soja.Irc.Case_Mapping;
with Soja.Irc.Cap_Registry;
with Soja.Irc.Members;
with Soja.Irc.Messages;        use Soja.Irc.Messages;
with Soja.Logging;
with Soja.Msgstore;
with Soja.Msgstore.Memory;
with Soja.Server;
with Soja.User;

--  user.go's event loop and network/user operations.
procedure User_Events_Check is
   package SD renames Soja.Database;
   use type Ada.Containers.Count_Type;
   use type Ada.Calendar.Time;
   use type Soja.Msgstore.Store_Access;

   procedure Check (Cond : Boolean; What : String) is
   begin
      if not Cond then
         raise Program_Error with What;
      end if;
   end Check;

   package String_Vectors is new Ada.Containers.Indefinite_Vectors
     (Positive, String);

   protected type Recorder is
      procedure Add (Line : String);
      function Count return Natural;
      function Line (I : Positive) return String;
      function Has (Needle : String) return Boolean;
   private
      V : String_Vectors.Vector;
   end Recorder;
   type Recorder_Access is access all Recorder;

   protected body Recorder is
      procedure Add (Line : String) is
      begin
         V.Append (Line);
      end Add;
      function Count return Natural is (Natural (V.Length));
      function Line (I : Positive) return String is (V (I));
      function Has (Needle : String) return Boolean is
      begin
         for L of V loop
            if Ada.Strings.Fixed.Index (L, Needle) > 0 then
               return True;
            end if;
         end loop;
         return False;
      end Has;
   end Recorder;

   type Fake_Transport is new Soja.Conn.IRC_Conn with record
      Log : Recorder_Access;
   end record;
   overriding function Read_Message
     (C : in out Fake_Transport) return Message is (others => <>);
   overriding procedure Write_Message
     (C : in out Fake_Transport; M : Message);
   overriding procedure Close (C : in out Fake_Transport) is null;
   overriding function Remote_Addr (C : Fake_Transport) return String is
     ("1.2.3.4:6667");
   overriding procedure Write_Message
     (C : in out Fake_Transport; M : Message) is
   begin
      C.Log.Add (Image (M));
   end Write_Message;

   type Fake_Transport_Access is access all Fake_Transport;

   function Wait (R : Recorder_Access; N : Natural) return Boolean is
      Waited : Duration := 0.0;
   begin
      while R.Count < N and then Waited < 3.0 loop
         delay 0.02;
         Waited := Waited + 0.02;
      end loop;
      return R.Count >= N;
   end Wait;

   --  Wait for the writer to have caught up, then expect K more lines than
   --  Before.
   procedure Expect_Lines
     (R : Recorder_Access; Before, K : Natural; What : String) is
   begin
      Check (Wait (R, Before + K), What & ": expected" & Natural'Image (K)
             & " lines");
      delay 0.1;
      Check (R.Count = Before + K, What & ": exactly" & Natural'Image (K)
             & " lines, got" & Natural'Image (R.Count - Before));
   end Expect_Lines;

   Log : aliased Soja.Logging.Standard_Logger;
   Srv : aliased Soja.Server.Server;
   DB  : SD.Database_Access := Soja.Database.Sqlite.Open_Temp_Sqlite_DB;
   Rec : SD.User := SD.New_User ("alice");

   Conns : array (1 .. 64) of Soja.Conn.Conn_Access;
   N_Conns : Natural := 0;

   --  A downstream connection on Net (or on the bouncer, when Net is null).
   function New_DC
     (U : User_Access; Net : Network_Access; ID : Long_Long_Integer;
      Log_Out : out Recorder_Access) return Downstream_Conn_Access
   is
      R : constant Recorder_Access := new Recorder;
      T : constant Fake_Transport_Access := new Fake_Transport'
        (Soja.Conn.IRC_Conn with Log => R);
      DC : Downstream_Conn_Access;
   begin
      DC := New_Downstream_Conn
        (Srv'Unchecked_Access, T.all'Unchecked_Access, ID);
      DC.User := U;
      DC.Network := Net;
      DC.Nick := To_Unbounded_String ("bob");
      DC.Registered := True;
      N_Conns := N_Conns + 1;
      Conns (N_Conns) := DC.Conn;
      Log_Out := R;
      return DC;
   end New_DC;

   --  An upstream connection on Net.
   function New_UC
     (U : User_Access; Net : Network_Access; Log_Out : out Recorder_Access)
      return Upstream_Conn_Access
   is
      R : constant Recorder_Access := new Recorder;
      T : constant Fake_Transport_Access := new Fake_Transport'
        (Soja.Conn.IRC_Conn with Log => R);
      UC : constant Upstream_Conn_Access := new Upstream_Conn;
      CM : constant Soja.Irc.Case_Mapping.Kind :=
        Soja.Irc.Case_Mapping.Case_RFC1459;
   begin
      UC.Network := Net;
      UC.User := U;
      UC.Srv := Srv'Unchecked_Access;
      UC.Logger := Log'Unchecked_Access;
      UC.Nick := To_Unbounded_String ("alice");
      UC.Conn := Soja.Conn.New_Conn
        (T.all'Unchecked_Access,
         (Logger => null, Rate_Limit_Delay => 0.0, Rate_Limit_Burst => 0,
         others => <>));
      N_Conns := N_Conns + 1;
      Conns (N_Conns) := UC.Conn;
      UC.Channels := Upstream_Channel_Maps.New_Map (CM);
      UC.Users := Upstream_User_Maps.New_Map (CM);
      UC.Monitored := Flag_Maps.New_Map (CM);
      UC.Join_Retries := Join_Retry_Maps.New_Map (CM);
      UC.Caps := Soja.Irc.Cap_Registry.New_Registry;
      UC.Server_Prefix :=
        new Prefix'(Name => To_Unbounded_String ("irc"), others => <>);
      UC.Available_Channel_Types := To_Unbounded_String ("#&+!");
      for M of Soja.Irc.Members.Std_Memberships loop
         UC.Available_Memberships.Append (M);
      end loop;
      UC.Has_Desired_Nick := True;
      Log_Out := R;
      return UC;
   end New_UC;

   --  A network that never connects (disabled), registered with U.
   function Add_Net
     (U : User_Access; Addr : String; Name : String := "")
      return Network_Access
   is
      NRec : SD.Network := SD.New_Network (Addr);
   begin
      NRec.Enabled := False;
      NRec.Auto_Away := False;
      NRec.Name := To_Unbounded_String (Name);
      return Soja.Core.User_Ops.Create_Network (U, NRec);
   end Add_Net;

   function Event_Of (E : Event_Access) return Event_Access is (E);

   procedure Send
     (U : User_Access; E : Event_Access; Expect_Stop : Boolean := False)
   is
      Stop : Boolean;
   begin
      Soja.Core.User_Events.Handle_Event (U, E, Stop);
      Check (Stop = Expect_Stop, "stop flag");
   end Send;

   function DB_User return SD.User is (SD.Get_User (DB.all, "alice"));

   procedure Raises_Operation_Error
     (U : User_Access; NRec : SD.Network; Text : String)
   is
   begin
      Soja.Core.User_Ops.Check_Network (U, NRec);
      Check (False, "expected an error: " & Text);
   exception
      when E : Soja.Core.User_Ops.Operation_Error =>
         Check (Ada.Exceptions.Exception_Message (E) = Text,
                "wrong error for " & Text & ": "
                & Ada.Exceptions.Exception_Message (E));
   end Raises_Operation_Error;

   U : User_Access;
begin
   Srv.Initialize (Log'Unchecked_Access);
   Srv.Set_DB (DB);
   SD.Store_User (DB.all, Rec);
   Rec.Enabled := True;
   SD.Store_User (DB.all, Rec);
   U := New_User (Srv'Unchecked_Access, Rec);
   U.Msg_Store := Soja.Msgstore.Memory.New_Memory_Store;

   -------------------------------------------------------------------
   --  Check_Network
   -------------------------------------------------------------------
   declare
      function R (Addr : String; Name : String := "") return SD.Network is
         N : SD.Network := SD.New_Network (Addr);
      begin
         N.Name := To_Unbounded_String (Name);
         return N;
      end R;
   begin
      Soja.Core.User_Ops.Check_Network (U, R ("irc.example"));
      Soja.Core.User_Ops.Check_Network (U, R ("ircs://irc.example:6697"));
      Soja.Core.User_Ops.Check_Network (U, R ("irc+insecure://h:6667"));
      Soja.Core.User_Ops.Check_Network (U, R ("irc+unix:///run/ircd.sock", "local"));
      Soja.Core.User_Ops.Check_Network (U, R ("unix:///run/ircd.sock", "local2"));
      Raises_Operation_Error
        (U, R ("ircs://user:pw@irc.example"),
         "ircs:// URL must not have username and password information");
      Raises_Operation_Error
        (U, R ("ircs://irc.example?a=b"),
         "ircs:// URL must not have query values");
      Raises_Operation_Error
        (U, R ("ircs://irc.example#frag"),
         "ircs:// URL must not have a fragment");
      Raises_Operation_Error
        (U, R ("ircs://irc.example/path"), "ircs:// URL must not have a path");
      Raises_Operation_Error (U, R ("ircs://"), "ircs:// URL must have a host");
      Raises_Operation_Error
        (U, R ("irc+unix://host/path"),
         "irc+unix:// URL must not have a host");
      Raises_Operation_Error
        (U, R ("unix://"), "unix:// URL must have a path");
      Raises_Operation_Error
        (U, R ("http://irc.example"), "unknown URL scheme ""http""");
      Raises_Operation_Error
        (U, R ("irc.example", "-dash"),
         "network name cannot start with a dash character");
   end;

   -------------------------------------------------------------------
   --  Create_Network / Update_Network / Delete_Network
   -------------------------------------------------------------------
   declare
      Net, Net2, Updated : Network_Access;
      DC_Log, Other_Log : Recorder_Access;
      DC, Other_DC : Downstream_Conn_Access;
      Count : Natural;
   begin
      Net := Add_Net (U, "irc.example", "libera");
      Check (Net.Network_Record.ID /= 0 and then U.Networks.Length = 1
             and then U.Networks (1) = Net, "network created and listed");
      Check (SD.List_Networks (DB.all, U.User_Record.ID).Length = 1,
             "network stored");

      --  A duplicate name is refused.
      declare
         D : SD.Network := SD.New_Network ("other.example");
      begin
         D.Name := To_Unbounded_String ("libera");
         D.Enabled := False;
         begin
            declare
               X : constant Network_Access :=
                 Soja.Core.User_Ops.Create_Network (U, D);
               pragma Unreferenced (X);
            begin
               Check (False, "duplicate name must be refused");
            end;
         exception
            when Soja.Core.User_Ops.Operation_Error => null;
         end;
      end;

      --  A client that wants BOUNCER NETWORK notifications.
      DC := New_DC (U, null, 1, DC_Log);
      Soja.Irc.Cap_Registry.Set_Enabled
        (DC.Caps, "soju.im/bouncer-networks-notify", True);
      Soja.Irc.Cap_Registry.Set_Enabled (DC.Caps, "message-tags", True);
      U.Downstream_Conns.Append (DC);

      Count := DC_Log.Count;
      Net2 := Add_Net (U, "ircs://second.example:6697", "second");
      Check (U.Networks.Length = 2
             and then U.Networks (2) = Net2, "networks stay sorted by id");
      Expect_Lines (DC_Log, Count, 1, "create notification");
      Check (DC_Log.Has ("BOUNCER NETWORK")
             and then DC_Log.Has ("name=second")
             and then DC_Log.Has ("host=second.example")
             and then DC_Log.Has ("port=6697")
             and then DC_Log.Has ("tls=1")
             and then DC_Log.Has ("state=disconnected"),
             "attributes of the new network");

      --  Limits.
      declare
         Cfg : constant Soja.Server.Server_Config_Access :=
           new Soja.Server.Server_Config;
      begin
         Cfg.Max_User_Networks := 2;
         Srv.Set_Config (Cfg);
         declare
            X : Network_Access;
            pragma Unreferenced (X);
         begin
            X := Add_Net (U, "third.example", "third");
            Check (False, "the network limit must apply");
         exception
            when E : Soja.Core.User_Ops.Operation_Error =>
               Check (Ada.Exceptions.Exception_Message (E)
                      = "maximum number of networks reached", "limit text");
         end;
         Cfg.Max_User_Networks := -1;
      end;

      --  Update: a fresh network replaces the old one, keeping its channels
      --  and the clients that were on it.
      Net.Channels.Set
        ("#a", new SD.Channel'(Name => To_Unbounded_String ("#a"),
                               Key => To_Unbounded_String ("k"), others => <>));
      Other_DC := New_DC (U, Net, 2, Other_Log);
      U.Downstream_Conns.Append (Other_DC);
      Net.Has_Last_Error := True;
      Net.Last_Error := To_Unbounded_String ("connection refused");
      Net.Push_Targets.Set ("#a", Ada.Calendar.Clock);
      declare
         NRec : SD.Network := Net.Network_Record;
      begin
         NRec.Nick := To_Unbounded_String ("alice-on-libera");
         NRec.Username := To_Unbounded_String ("lib");
         NRec.Enabled := True;
         Count := DC_Log.Count;
         Updated := Soja.Core.User_Ops.Update_Network (U, NRec);
      end;
      Check (Updated /= Net and then U.Networks.Length = 2
             and then U.Networks (1) = Updated
             and then Updated.Network_Record.ID = Net.Network_Record.ID,
             "the network was replaced, in the same place");
      Check (To_String (Updated.Network_Record.Nick) = "alice-on-libera"
             and then Updated.Channels.Has ("#a"), "new settings, same channels");
      Check (Updated.Has_Last_Error
             and then To_String (Updated.Last_Error) = "connection refused",
             "the last error is carried over");
      Check (Updated.Push_Targets.Has ("#a"),
             "the push targets are carried over");
      Check (Other_DC.Network = Updated, "clients are patched to the new one");
      Check (not Soja.Conn.Is_Closed (Other_DC.Conn),
             "and are not disconnected");
      Check (Is_Stopped (Net) and then not Is_Stopped (Updated),
             "the old one is stopped");
      Check (SD.List_Networks (DB.all, U.User_Record.ID) (1).Nick
             = To_Unbounded_String ("alice-on-libera"), "update stored");
      Expect_Lines (DC_Log, Count, 1, "update notification");

      --  A nick equal to the user's default is reset.
      declare
         NRec : SD.Network := Updated.Network_Record;
      begin
         NRec.Nick := U.User_Record.Nick;
         Updated := Soja.Core.User_Ops.Update_Network (U, NRec);
         Check (Length (Updated.Network_Record.Nick) = 0, "default nick wiped");
      end;
      delay 0.2;   --  let its notification reach the client

      --  Disabling a network drops its error; it stays enabled afterwards.
      Updated.Has_Last_Error := True;
      declare
         NRec : SD.Network := Updated.Network_Record;
      begin
         NRec.Enabled := False;
         Updated := Soja.Core.User_Ops.Update_Network (U, NRec);
         Check (not Updated.Has_Last_Error,
                "the error of a network that was disabled is dropped");
         NRec.Enabled := True;
         Updated := Soja.Core.User_Ops.Update_Network (U, NRec);
      end;
      delay 0.2;

      --  Delete: stored rows go, the clients on it are closed, others are told.
      Count := DC_Log.Count;
      Soja.Core.User_Ops.Delete_Network (U, Net2.Network_Record.ID);
      Check (U.Networks.Length = 1 and then Is_Stopped (Net2), "deleted");
      Check (SD.List_Networks (DB.all, U.User_Record.ID).Length = 1,
             "deleted from the database");
      Expect_Lines (DC_Log, Count, 1, "delete notification");
      Check (DC_Log.Has (" * ") or else DC_Log.Has ("NETWORK"), "notified");

      Soja.Core.User_Ops.Delete_Network (U, Updated.Network_Record.ID);
      Check (Soja.Conn.Is_Closed (Other_DC.Conn),
             "deleting a network closes the clients on it");
      Check (not Soja.Conn.Is_Closed (DC.Conn), "but not the others");
      U.Downstream_Conns.Clear;
      Check (U.Networks.Is_Empty, "no networks left");
   end;

   -------------------------------------------------------------------
   --  Upstream events
   -------------------------------------------------------------------
   declare
      Net : constant Network_Access := Add_Net (U, "irc.example", "net");
      UC_Log, DC_Log, Notify_Log : Recorder_Access;
      UC : constant Upstream_Conn_Access := New_UC (U, Net, UC_Log);
      DC : constant Downstream_Conn_Access := New_DC (U, Net, 10, DC_Log);
      Notify : constant Downstream_Conn_Access := New_DC (U, null, 11, Notify_Log);
      Count : Natural;
   begin
      Soja.Irc.Cap_Registry.Set_Enabled
        (Notify.Caps, "soju.im/bouncer-networks-notify", True);
      U.Downstream_Conns.Append (DC);
      U.Downstream_Conns.Append (Notify);

      --  Connected.
      Net.Network_Record.Auto_Away := True;
      Count := DC_Log.Count;
      Send (U, new Upstream_Connected_Event'(UC => UC));
      Check (Net.Conn = UC, "the user's loop sets the network's connection");
      --  The notice, and the NICK that makes the client use our nick.
      Expect_Lines (DC_Log, Count, 2, "connected");
      Check (DC_Log.Has ("connected to net") and then DC_Log.Has (" NICK alice"),
             "connection notice and nick update");
      Check (Notify_Log.Has ("state=connected"), "state notification");
      --  Auto-away: a client is connected and not away, so we are not.
      Check (not UC_Log.Has ("AWAY"), "no auto-away while a client is here");

      --  A connection error is reported once per distinct error.
      Net.Has_Last_Error := False;
      Count := DC_Log.Count;
      Send (U, new Upstream_Connection_Error_Event'
              (Net => Net, Error => To_Unbounded_String ("connection error: boom")));
      Expect_Lines (DC_Log, Count, 1, "error notice");
      Check (DC_Log.Has ("failed connecting/registering to net: connection error: boom"),
             "error text");
      Check (Net.Has_Last_Error, "error remembered");
      Send (U, new Upstream_Connection_Error_Event'
              (Net => Net, Error => To_Unbounded_String ("connection error: boom")));
      delay 0.15;
      Check (DC_Log.Count = Count + 1, "the same error is not repeated");
      Send (U, new Upstream_Connection_Error_Event'
              (Net => Net, Error => To_Unbounded_String ("connection error: other")));
      Expect_Lines (DC_Log, Count, 2, "another error");
      delay 0.15;
      Check (Notify_Log.Has ("error=connection\serror:\sother"),
             "error state (tag values are escaped)");

      --  A stopped network does not announce errors.
      declare
         Stopped_Net : constant Network_Access :=
           Add_Net (U, "stopped.example", "stopped");
         Stopped_Log : Recorder_Access;
         Stopped_DC  : constant Downstream_Conn_Access :=
           New_DC (U, Stopped_Net, 12, Stopped_Log);
      begin
         U.Downstream_Conns.Append (Stopped_DC);
         Stop_Network (Stopped_Net);
         Send (U, new Upstream_Connection_Error_Event'
                 (Net => Stopped_Net, Error => To_Unbounded_String ("late")));
         delay 0.15;
         Check (Stopped_Log.Count = 0, "no notice for a stopped network");
         Check (Stopped_Net.Has_Last_Error, "but the error is recorded");
      end;

      Count := DC_Log.Count;
      Send (U, new Upstream_Error_Event'
              (UC => UC, Error => To_Unbounded_String ("ping timeout")));
      Expect_Lines (DC_Log, Count, 1, "upstream error");
      Check (DC_Log.Has ("disconnected from net: ping timeout"), "text");

      --  Messages go through the dispatch; closed connections are ignored.
      Count := UC_Log.Count;
      Send (U, new Upstream_Message_Event'
              (Msg => Parse_Message ("PING :t1"), UC => UC));
      Check (Wait (UC_Log, Count + 1), "PONG sent");
      Send (U, new Upstream_Message_Event'
              (Msg => Parse_Message ("NOT-A-REAL-COMMAND"), UC => UC));
      Send (U, new Upstream_Message_Event'
              (Msg => Parse_Message (":x JOIN"), UC => UC));   --  fails: logged
      declare
         Closed_UC : constant Upstream_Conn_Access := New_UC (U, Net, UC_Log);
      begin
         Soja.Conn.Close (Closed_UC.Conn);
         Count := UC_Log.Count;
         Send (U, new Upstream_Message_Event'
                 (Msg => Parse_Message ("PING :late"), UC => Closed_UC));
         delay 0.15;
         Check (UC_Log.Count = Count, "closed connections are ignored");
      end;

      --  Idle channels detach (and the change is stored).
      Net.Channels.Set
        ("#idle", new SD.Channel'(Name => To_Unbounded_String ("#idle"),
                                  others => <>));
      declare
         Saved : SD.Channel := (Name => To_Unbounded_String ("#idle"),
                                others => <>);
      begin
         SD.Store_Channel (DB.all, Net.Network_Record.ID, Saved);
         Net.Channels.Get ("#idle").ID := Saved.ID;
      end;
      Count := DC_Log.Count;
      Send (U, new Channel_Detach_Event'
              (UC => UC, Name => To_Unbounded_String ("#idle")));
      Check (Net.Channels.Get ("#idle").Detached, "channel detached");
      Check (SD.List_Channels (DB.all, Net.Network_Record.ID) (1).Detached,
             "and stored");
      Expect_Lines (DC_Log, Count, 1, "PART Detach");
      Send (U, new Channel_Detach_Event'
              (UC => UC, Name => To_Unbounded_String ("#idle")));   --  no-op
      Send (U, new Channel_Detach_Event'
              (UC => UC, Name => To_Unbounded_String ("#unknown")));  --  no-op
      delay 0.15;
      Check (DC_Log.Count = Count + 1, "detaching twice does nothing");

      --  Disconnected.
      Net.Has_Last_Error := False;
      Net.Last_Error := Null_Unbounded_String;
      Count := DC_Log.Count;
      Send (U, new Upstream_Disconnected_Event'(UC => UC));
      Check (Net.Conn = null, "no connection any more");
      Check (Wait (DC_Log, Count + 1)
             and then DC_Log.Has ("disconnected from net"), "disconnect notice");
      Check (Notify_Log.Has ("state=disconnected"), "disconnect state");

      Send (U, new Try_Regain_Nick_Event'
              (UC => UC, Nick => To_Unbounded_String ("alice")));   --  no timer
      Send (U, new Retry_Join_Event'
              (UC => UC, Name => To_Unbounded_String ("#nope")));   --  none
      U.Downstream_Conns.Clear;
   end;

   -------------------------------------------------------------------
   --  Downstream events
   -------------------------------------------------------------------
   declare
      Net : Network_Access := Add_Net (U, "d.example", "d");
      UC_Log, DC_Log, DC2_Log : Recorder_Access;
      UC : constant Upstream_Conn_Access := New_UC (U, Net, UC_Log);
      DC : constant Downstream_Conn_Access := New_DC (U, Net, 20, DC_Log);
      DC2 : constant Downstream_Conn_Access := New_DC (U, Net, 21, DC2_Log);
      Count : Natural;
   begin
      Net.Conn := UC;
      Net.Network_Record.Auto_Away := True;

      --  A registered client is added to the user, and sees past errors.
      Net.Has_Last_Error := True;
      Net.Last_Error := To_Unbounded_String ("it broke");
      DC.Monitored := Flag_Maps.New_Map (Soja.Irc.Case_Mapping.Case_ASCII);
      Send (U, new Downstream_Connected_Event'(DC => DC));
      Check (U.Downstream_Conns.Length = 1 and then U.Num_Downstream_Conns = 1,
             "client added");
      Check (Wait (DC_Log, 1) and then DC_Log.Has ("disconnected from d: it broke"),
             "told about the network's error");
      Check (DB_User.Downstream_Interacted_At /= SD.Null_Time,
             "the interaction time is bumped and stored");
      Net.Has_Last_Error := False;

      --  A disabled account is refused ...
      declare
         procedure Disable (R : in out SD.User) is
         begin
            R.Enabled := False;
         end Disable;
      begin
         Soja.Core.User_Ops.Update_User (U, Disable'Access);
      end;
      Count := DC2_Log.Count;
      Send (U, new Downstream_Connected_Event'(DC => DC2));
      Check (Wait (DC2_Log, Count + 1) and then DC2_Log.Has ("This bouncer account is disabled"),
             "disabled account");
      Check (U.Downstream_Conns.Length = 0 or else U.Downstream_Conns.Length = 1,
             "(the first client was closed by the disabling)");
      Check (Soja.Conn.Is_Closed (DC.Conn), "disabling closes the clients");
      U.Downstream_Conns.Clear;
      U.Num_Downstream_Conns := 0;

      --  ... unless the server enables users on authentication.
      declare
         Cfg : constant Soja.Server.Server_Config_Access :=
           new Soja.Server.Server_Config;
      begin
         Cfg.Enable_Users_On_Auth := True;
         Srv.Set_Config (Cfg);
      end;
      Send (U, new Downstream_Connected_Event'(DC => DC2));
      Check (U.User_Record.Enabled and then DB_User.Enabled,
             "enabled on authentication, and stored");
      Check (U.Downstream_Conns.Length = 1, "client accepted");
      Srv.Set_Config (new Soja.Server.Server_Config);

      --  (Enabling the user reconnected its networks, as in Go: refetch.)
      Net := Get_Network_By_ID (U, Net.Network_Record.ID);
      Net.Conn := UC;
      Net.Network_Record.Auto_Away := True;
      UC.Network := Net;
      DC.Network := Net;
      DC2.Network := Net;

      --  Messages: dispatched; IRC errors go back to the client.
      Count := UC_Log.Count;
      Send (U, new Downstream_Message_Event'
              (Msg => Parse_Message ("FROBNICATE x"), DC => DC2));
      Check (Wait (UC_Log, Count + 1) and then UC_Log.Has ("FROBNICATE x"),
             "unknown commands are relayed upstream on a network");
      Count := DC2_Log.Count;
      Net.Conn := null;
      Send (U, new Downstream_Message_Event'
              (Msg => Parse_Message ("FROBNICATE y"), DC => DC2));
      Check (Wait (DC2_Log, Count + 1) and then DC2_Log.Has (" 421 "),
             "unknown commands are answered with 421 while disconnected");
      Net.Conn := UC;
      Count := DC2_Log.Count;
      Soja.Conn.Close (DC.Conn);
      Send (U, new Downstream_Message_Event'
              (Msg => Parse_Message ("FROBNICATE x"), DC => DC));
      delay 0.1;
      Check (DC_Log.Count < 100, "closed connections are ignored");

      --  Broadcast.
      Count := DC2_Log.Count;
      Send (U, new Broadcast_Event'(Msg => Parse_Message (":srv NOTICE * :hello all")));
      Check (Wait (DC2_Log, Count + 1) and then DC2_Log.Has ("hello all"),
             "broadcast");

      --  Disconnected: removed, pending commands cancelled.
      UC.Network := Net;
      Soja.Core.Upstream_Dispatch.Enqueue_Command
        (UC, DC2, Parse_Message ("WHOIS first"));
      Soja.Core.Upstream_Dispatch.Enqueue_Command
        (UC, DC2, Parse_Message ("WHOIS second"));
      Check (UC.Pending_Cmds ("WHOIS").Length = 2, "two pending");
      Send (U, new Downstream_Disconnected_Event'(DC => DC2));
      Check (U.Downstream_Conns.Length = 0 and then U.Num_Downstream_Conns = 0,
             "client removed");
      Check (UC.Pending_Cmds ("WHOIS").Length = 1,
             "its queued commands are cancelled (the running one stays)");
      --  No client left: auto-away.
      Check (UC.Away, "no clients: away");
      Net.Conn := null;
   end;

   -------------------------------------------------------------------
   --  Delivery receipts of a persistent store are saved on disconnect
   -------------------------------------------------------------------
   declare
      type Persistent_Store is new Soja.Msgstore.Store with null record;
      overriding procedure Close (S : in out Persistent_Store) is null;
      overriding function Last_Msg_ID
        (S : in out Persistent_Store; Network : SD.Network; Entity : String;
         T : Ada.Calendar.Time) return String is ("id");
      overriding function Load_Latest_ID
        (S : in out Persistent_Store; ID : String;
         Options : Soja.Msgstore.Load_Message_Options)
         return Soja.Irc.Messages.Message_Vectors.Vector is
        (Soja.Irc.Messages.Message_Vectors.Empty_Vector);
      overriding function Append
        (S : in out Persistent_Store; Network : SD.Network; Entity : String;
         Msg : Message) return String is ("");

      Store : aliased Persistent_Store;
      Net : constant Network_Access := Add_Net (U, "r.example", "receipts");
      DC_Log : Recorder_Access;
      DC : constant Downstream_Conn_Access := New_DC (U, Net, 30, DC_Log);
      Saved_Store : constant Soja.Msgstore.Store_Access := U.Msg_Store;
   begin
      Check (not Has_Persistent_Msg_Store (U), "the memory store is not persistent");
      U.Msg_Store := Store'Unchecked_Access;
      Check (Has_Persistent_Msg_Store (U), "a persistent store");
      DC.Client_Name := To_Unbounded_String ("phone");
      U.Downstream_Conns.Append (DC);
      Soja.User.Store_ID (Net.Delivered, "#chan", "phone", "msgid-1");
      Soja.User.Store_ID (Net.Delivered, "#other", "laptop", "msgid-2");
      Send (U, new Downstream_Disconnected_Event'(DC => DC));
      declare
         R : constant SD.Delivery_Receipt_Lists.Vector :=
           SD.List_Delivery_Receipts (DB.all, Net.Network_Record.ID);
      begin
         Check (R.Length = 1 and then To_String (R (1).Client) = "phone"
                and then To_String (R (1).Target) = "#chan"
                and then To_String (R (1).Internal_Msg_ID) = "msgid-1",
                "only the disconnecting client's receipts are stored");
      end;
      U.Msg_Store := Saved_Store;
   end;

   -------------------------------------------------------------------
   --  User updates
   -------------------------------------------------------------------
   declare
      Net : constant Network_Access := Add_Net (U, "u.example", "upd");
      UC_Log, DC_Log : Recorder_Access;
      UC : constant Upstream_Conn_Access := New_UC (U, Net, UC_Log);
      DC : constant Downstream_Conn_Access := New_DC (U, Net, 40, DC_Log);
      Result : aliased Update_Result;
      Error  : Unbounded_String;
      Count  : Natural;
   begin
      Net.Conn := UC;
      Soja.Irc.Cap_Registry.Set_Enabled (UC.Caps, "setname", True);
      U.Downstream_Conns.Append (DC);

      --  A password change closes the clients (they must re-authenticate).
      Send (U, new User_Update_Event'
              (Has_Password => True, Password => To_Unbounded_String ("new pw"),
               Has_Admin => True, Admin => True, Result => Result'Unchecked_Access,
               others => <>));
      Result.Wait (Error);
      Check (Length (Error) = 0, "update worked: " & To_String (Error));
      declare
         Fresh    : SD.User := DB_User;
         Upgraded : Boolean;
         pragma Unreferenced (Upgraded);
      begin
         Check (Fresh.Admin, "admin stored");
         --  (Raises Database_Error when the password is wrong.)
         Upgraded := SD.Check_Password (Fresh, "new pw");
         begin
            Upgraded := SD.Check_Password (Fresh, "old pw");
            Check (False, "the old password must not work");
         exception
            when SD.Database_Error => null;
         end;
      end;
      Check (U.User_Record.Admin, "in memory too");
      Check (Soja.Conn.Is_Closed (DC.Conn), "clients closed after a password change");
      U.Downstream_Conns.Clear;

      --  A new default nick is sent upstream (networks without their own).
      declare
         procedure New_Nick (R : in out SD.User) is
         begin
            R.Nick := To_Unbounded_String ("aly");
         end New_Nick;
      begin
         Count := UC_Log.Count;
         Soja.Core.User_Ops.Update_User (U, New_Nick'Access);
         Check (Wait (UC_Log, Count + 1) and then UC_Log.Has ("NICK aly"),
                "NICK sent to connected networks");
      end;

      --  A new default realname goes out as SETNAME when the server can.
      declare
         procedure New_Realname (R : in out SD.User) is
         begin
            R.Realname := To_Unbounded_String ("Alice A.");
         end New_Realname;
      begin
         Count := UC_Log.Count;
         Soja.Core.User_Ops.Update_User (U, New_Realname'Access);
         Check (Wait (UC_Log, Count + 1) and then UC_Log.Has ("SETNAME :Alice A."),
                "SETNAME sent");
         Check (U.Networks (U.Networks.Last_Index) = Net,
                "no reconnect was needed");
      end;

      --  A failing update changes nothing.
      declare
         procedure Boom (R : in out SD.User) is
         begin
            R.Nick := To_Unbounded_String ("changed");
            raise Soja.Core.User_Ops.Operation_Error with "no way";
         end Boom;
      begin
         Soja.Core.User_Ops.Update_User (U, Boom'Access);
         Check (False, "an update that fails must raise");
      exception
         when Soja.Core.User_Ops.Operation_Error =>
            Check (To_String (U.User_Record.Nick) = "aly", "unchanged");
      end;
      Net.Conn := null;
   end;

   -------------------------------------------------------------------
   --  The loop itself: start, handle events, stop.
   -------------------------------------------------------------------
   declare
      U2 : constant User_Access := New_User (Srv'Unchecked_Access, DB_User);
      DC_Log : Recorder_Access;
      Store : constant Soja.Msgstore.Store_Access :=
        Soja.Msgstore.Memory.New_Memory_Store;

      task Runner;
      task body Runner is
      begin
         Run (U2);
      end Runner;
   begin
      U2.Msg_Store := Store;
      declare
         DC : constant Downstream_Conn_Access := New_DC (U2, null, 50, DC_Log);
      begin
         U2.Events.Enqueue (new Downstream_Connected_Event'(DC => DC));
         U2.Events.Enqueue
           (new Broadcast_Event'(Msg => Parse_Message (":srv NOTICE * :via the loop")));
         Check (Wait (DC_Log, 1) and then DC_Log.Has ("via the loop"),
                "the loop handles events");
         Check (Stop_User (U2, 5.0), "the user stops");
         Check (U2.Done.Is_Set, "done");
         Check (Soja.Conn.Is_Closed (DC.Conn), "stopping closes the clients");
         Check (Stop_User (U2, 1.0), "stopping twice is fine");
      end;
   end;

   for I in 1 .. N_Conns loop
      Soja.Conn.Close (Conns (I));
   end loop;
   Ada.Text_IO.Put_Line ("ALL PASS");
exception
   when E : others =>
      Ada.Text_IO.Put_Line
        ("FAILED: " & Ada.Exceptions.Exception_Information (E));
      GNAT.OS_Lib.OS_Exit (1);
end User_Events_Check;
