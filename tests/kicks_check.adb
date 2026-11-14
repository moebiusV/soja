pragma Ada_2022;

with Ada.Calendar;
with Ada.Containers;
with Ada.Containers.Indefinite_Vectors;
with Ada.Exceptions;
with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;
with Ada.Text_IO;
with GNAT.OS_Lib;

with Soja.Conn;
with Soja.Core;
with Soja.Core.Upstream_Dispatch;
with Soja.Database;
with Soja.Database.Sqlite;
with Soja.Irc.Case_Mapping;
with Soja.Irc.Cap_Registry;
with Soja.Irc.Members;
with Soja.Irc.Messages;
with Soja.Logging;
with Soja.Server;

--  Kicks are persisted, ignored after a rejoin, and kept as history.
procedure Kicks_Check is
   package SD renames Soja.Database;
   use Soja.Core;
   use Soja.Irc.Messages;
   use type Ada.Calendar.Time;
   use type Ada.Containers.Count_Type;

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
      function Last return String;
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
      function Last return String is
        (if V.Is_Empty then "" else V (V.Last_Index));
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

   function Wait (R : Recorder; N : Natural) return Boolean is
      Waited : Duration := 0.0;
   begin
      while R.Count < N and then Waited < 3.0 loop
         delay 0.02;
         Waited := Waited + 0.02;
      end loop;
      return R.Count >= N;
   end Wait;

   Log     : aliased Soja.Logging.Standard_Logger;
   Srv     : aliased Soja.Server.Server;
   DB      : SD.Database_Access := Soja.Database.Sqlite.Open_Temp_Sqlite_DB;
   Rec     : SD.User := SD.New_User ("alice");
   NRec    : SD.Network := SD.New_Network ("irc+insecure://irc.example");

   --  One "run" of the bouncer: a network loaded from the database and an
   --  upstream connection registered on it.
   type Run is record
      U    : User_Access;
      Net  : Network_Access;
      UC   : Upstream_Conn_Access;
      Wire : Recorder_Access;
   end record;

   Runs_Wires : array (1 .. 4) of aliased Recorder;
   Runs_Trans : array (1 .. 4) of aliased Fake_Transport;
   N_Runs     : Natural := 0;
   Conns      : array (1 .. 4) of Soja.Conn.Conn_Access;

   function Start return Run is
      R : Run;
   begin
      N_Runs := N_Runs + 1;
      R.U := New_User (Srv'Unchecked_Access, Rec);
      declare
         Chans : constant SD.Channel_Lists.Vector :=
           SD.List_Channels (DB.all, NRec.ID);
      begin
         R.Net := New_Network (R.U, NRec, Chans);
      end;
      Load_Kicks (R.Net);
      R.U.Networks.Append (R.Net);

      Runs_Trans (N_Runs).Log := Runs_Wires (N_Runs)'Unchecked_Access;
      R.UC := new Upstream_Conn;
      R.UC.Network := R.Net;
      R.UC.User := R.U;
      R.UC.Srv := Srv'Unchecked_Access;
      R.UC.Logger := Log'Unchecked_Access;
      R.UC.Nick := To_Unbounded_String ("alice");
      Conns (N_Runs) := Soja.Conn.New_Conn
        (Runs_Trans (N_Runs)'Unchecked_Access,
         (Logger => null, Rate_Limit_Delay => 0.0, Rate_Limit_Burst => 0,
         others => <>));
      R.UC.Conn := Conns (N_Runs);
      R.UC.Channels := Upstream_Channel_Maps.New_Map
        (Soja.Irc.Case_Mapping.Case_RFC1459);
      R.UC.Users := Upstream_User_Maps.New_Map
        (Soja.Irc.Case_Mapping.Case_RFC1459);
      R.UC.Monitored := Flag_Maps.New_Map (Soja.Irc.Case_Mapping.Case_RFC1459);
      R.UC.Join_Retries := Join_Retry_Maps.New_Map
        (Soja.Irc.Case_Mapping.Case_RFC1459);
      R.UC.Caps := Soja.Irc.Cap_Registry.New_Registry;
      R.UC.Server_Prefix :=
        new Prefix'(Name => To_Unbounded_String ("*"), others => <>);
      R.UC.Available_Channel_Types := To_Unbounded_String ("#&+!");
      for M of Soja.Irc.Members.Std_Memberships loop
         R.UC.Available_Memberships.Append (M);
      end loop;
      R.UC.Has_Desired_Nick := True;
      R.Net.Conn := R.UC;
      R.Wire := Runs_Wires (N_Runs)'Unchecked_Access;
      return R;
   end Start;

   function H (R : Run; Line : String)
      return Soja.Core.Handle_Result is
     (Soja.Core.Upstream_Dispatch.Handle_Message (R.UC, Parse_Message (Line)));

   procedure Ok (R : Run; Line : String) is
      Res : constant Handle_Result := H (R, Line);
   begin
      Check (not Res.Failed, Line & " failed: " & To_String (Res.Reason));
   end Ok;

   function Active return SD.Kick_Lists.Vector is
     (SD.List_Kicks (DB.all, NRec.ID, True));
   function History return SD.Kick_Lists.Vector is
     (SD.List_Kicks (DB.all, NRec.ID, False));
begin
   Srv.Initialize (Log'Unchecked_Access);
   Srv.Set_DB (DB);

   --  A user with a network and two saved channels.
   SD.Store_User (DB.all, Rec);
   SD.Store_Network (DB.all, Rec.ID, NRec);
   declare
      A : SD.Channel := (Name => To_Unbounded_String ("#a"), others => <>);
      B : SD.Channel := (Name => To_Unbounded_String ("#b"), others => <>);
   begin
      SD.Store_Channel (DB.all, NRec.ID, A);
      SD.Store_Channel (DB.all, NRec.ID, B);
   end;

   -------------------------------------------------------------------
   --  Run 1: join #a, get kicked.
   -------------------------------------------------------------------
   declare
      R : constant Run := Start;
   begin
      Check (R.Net.Kicked.Length = 0, "no kicks yet");
      Ok (R, ":alice!u@h JOIN #a");
      Ok (R, ":op!o@h KICK #a alice :behave");

      Check (R.Net.Kicked.Has ("#a")
             and then To_String (R.Net.Kicked.Get ("#a").Kicked_By) = "op"
             and then To_String (R.Net.Kicked.Get ("#a").Reason) = "behave"
             and then R.Net.Kicked.Get ("#a").ID /= 0, "kick cached");
      Check (Active.Length = 1 and then History.Length = 1
             and then To_String (Active.Element (1).Channel) = "#a"
             and then To_String (Active.Element (1).Kicked_By) = "op"
             and then To_String (Active.Element (1).Reason) = "behave"
             and then Active.Element (1).Rejoined_At = SD.Null_Time,
             "the kick is stored as active");
   end;

   -------------------------------------------------------------------
   --  Run 2 ("soja restarted"): the kick is loaded, and #a is not joined.
   -------------------------------------------------------------------
   declare
      R : constant Run := Start;
   begin
      Check (R.Net.Kicked.Has ("#a")
             and then To_String (R.Net.Kicked.Get ("#a").Reason) = "behave",
             "the kick survives a restart");
      Ok (R, ":irc 001 alice :Welcome");
      Soja.Core.Upstream_Dispatch.Join_Saved_Channels (R.UC);
      Check (Wait (R.Wire.all, 1) and then R.Wire.Last = "JOIN #b",
             "after a restart only #b is joined: " & R.Wire.Last);
      delay 0.15;
      Check (R.Wire.Count = 1, "exactly one JOIN");

      --  We join #a by hand: the kick is no longer active, but is history.
      Ok (R, ":alice!u@h JOIN #a");
      Check (not R.Net.Kicked.Has ("#a"), "the kick is cleared in memory");
      Check (Active.Is_Empty and then History.Length = 1
             and then History.Element (1).Rejoined_At /= SD.Null_Time,
             "the rejoined kick is kept as history");
      Check (History.Element (1).Rejoined_At >= History.Element (1).Kicked_At,
             "rejoined after the kick");

      --  Kicked again: a new record; the first stays as it was.
      Ok (R, ":op2!o@h KICK #a alice :again");
      Check (Active.Length = 1 and then History.Length = 2
             and then To_String (Active.Element (1).Reason) = "again"
             and then History.Element (1).Rejoined_At /= SD.Null_Time
             and then History.Element (2).Rejoined_At = SD.Null_Time,
             "a new kick is a new record");

      --  Kicked yet again without us seeing the rejoin: the old one is
      --  closed, only the new one is active.
      Ok (R, ":alice!u@h JOIN #a");   --  (clears the second kick)
      Ok (R, ":op3!o@h KICK #a alice :third");
      Ok (R, ":alice!u@h JOIN #b");
      Check (Active.Length = 1 and then History.Length = 3
             and then To_String (Active.Element (1).Reason) = "third",
             "history of three kicks, one active");
   end;

   -------------------------------------------------------------------
   --  Two active records for a channel (a record left over): loading keeps
   --  the newest and closes the older one.
   -------------------------------------------------------------------
   declare
      Extra : SD.Kick_Record;
   begin
      Extra.Channel := To_Unbounded_String ("#a");
      Extra.Kicked_By := To_Unbounded_String ("ghost");
      Extra.Kicked_At := Ada.Calendar.Clock;
      SD.Store_Kick (DB.all, NRec.ID, Extra);
      Check (Active.Length = 2, "two active records");
      declare
         R : constant Run := Start;
      begin
         Check (To_String (R.Net.Kicked.Get ("#a").Kicked_By) = "ghost",
                "the newest record wins");
         Check (Active.Length = 1 and then History.Length = 4,
                "the older record was closed, nothing deleted");
      end;
   end;

   --  Another network's kicks are not loaded.
   declare
      Other : SD.Network := SD.New_Network ("irc+insecure://other.example");
      K     : SD.Kick_Record;
   begin
      SD.Store_Network (DB.all, Rec.ID, Other);
      K.Channel := To_Unbounded_String ("#a");
      K.Kicked_By := To_Unbounded_String ("elsewhere");
      K.Kicked_At := Ada.Calendar.Clock;
      SD.Store_Kick (DB.all, Other.ID, K);
      declare
         U : constant User_Access := New_User (Srv'Unchecked_Access, Rec);
         N : constant Network_Access :=
           New_Network (U, Other, SD.Channel_Lists.Empty_Vector);
      begin
         Load_Kicks (N);
         Check (N.Kicked.Length = 1
                and then To_String (N.Kicked.Get ("#a").Kicked_By)
                         = "elsewhere", "kicks are per network");
      end;
   end;

   --  Without a database nothing breaks.
   declare
      Srv2 : aliased Soja.Server.Server;
      U    : User_Access;
      N    : Network_Access;
   begin
      Srv2.Initialize (Log'Unchecked_Access);
      U := New_User (Srv2'Unchecked_Access, Rec);
      N := New_Network (U, NRec, SD.Channel_Lists.Empty_Vector);
      Load_Kicks (N);
      Record_Kick (N, "#x", "op", "no db");
      Check (N.Kicked.Has ("#x") and then N.Kicked.Get ("#x").ID = 0,
             "kicks work without a database");
      Clear_Kick (N, "#x");
      Check (not N.Kicked.Has ("#x"), "and are cleared");
   end;

   for I in 1 .. N_Runs loop
      Soja.Conn.Close (Conns (I));
   end loop;
   Ada.Text_IO.Put_Line ("ALL PASS");
exception
   when E : others =>
      Ada.Text_IO.Put_Line
        ("FAILED: " & Ada.Exceptions.Exception_Information (E));
      GNAT.OS_Lib.OS_Exit (1);
end Kicks_Check;
