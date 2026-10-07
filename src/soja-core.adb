pragma Ada_2022;

with Soja.Backoff;

package body Soja.Core is

   use Soja.Logging;

   ------------
   -- Signal --
   ------------

   protected body Signal is

      procedure Set is
      begin
         Set_Flag := True;
      end Set;

      function Is_Set return Boolean is
        (Set_Flag);

      entry Wait when Set_Flag is
      begin
         null;
      end Wait;

   end Signal;

   ----------------
   -- Event queue --
   ----------------

   protected body Event_Queue is

      entry Enqueue (E : Event_Access) when Count < Event_Capacity is
      begin
         Buf ((Head + Count - 1) mod Event_Capacity + 1) := E;
         Count := Count + 1;
      end Enqueue;

      entry Dequeue (E : out Event_Access; Done : out Boolean)
        when Count > 0 or else Closed
      is
      begin
         if Count > 0 then
            E := Buf (Head);
            Head := Head mod Event_Capacity + 1;
            Count := Count - 1;
            Done := False;
         else
            E := null;
            Done := True;
         end if;
      end Dequeue;

      procedure Close is
      begin
         Closed := True;
      end Close;

      function Is_Closed return Boolean is
        (Closed);

   end Event_Queue;

   ------------------
   --  Constructors --
   ------------------

   --  server.go's prefixLogger: wrap a base logger with a textual prefix.
   function Prefixed (Base : Logger_Access; Text : String)
      return Logger_Access
   is
   begin
      return new Prefix_Logger'
        (Base   => Base,
         Prefix => To_Unbounded_String (Text));
   end Prefixed;

   --  downstream.go's permanentDownstreamCaps: capabilities always advertised
   --  (each with an empty value string).
   type String_Access is access constant String;

   Permanent_Downstream_Caps : constant array (Positive range <>) of
     String_Access :=
     [new String'("batch"), new String'("cap-notify"),
      new String'("echo-message"), new String'("invite-notify"),
      new String'("server-time"), new String'("setname"),
      new String'("draft/pre-away"), new String'("draft/read-marker"),
      new String'("draft/no-implicit-names"),
      new String'("soju.im/account-required"),
      new String'("soju.im/bouncer-networks"),
      new String'("soju.im/bouncer-networks-notify"),
      new String'("soju.im/no-implicit-names"),
      new String'("soju.im/read"), new String'("soju.im/webpush")];

   function New_User
     (Srv : Soja.Server.Server_Access; Rec : Soja.Database.User)
      return User_Access
   is
      U : constant User_Access := new User;
   begin
      U.User_Record := Rec;
      U.Srv := Srv;
      U.Logger := Prefixed
        (Soja.Server.Logger (Srv.all),
         "user " & To_String (Rec.Username) & ": ");
      U.Events := new Event_Queue;
      U.Done := new Signal;
      return U;
   end New_User;

   function New_Network
     (U : User_Access; Rec : Soja.Database.Network;
      Channels : Soja.Database.Channel_Lists.Vector) return Network_Access
   is
      Net : constant Network_Access := new Network;
      CM  : constant Kind := Case_ASCII;   --  maps start on the strictest fold
   begin
      Net.Network_Record := Rec;
      Net.User := U;
      Net.Logger := Prefixed
        (U.Logger, "network " & Soja.Database.Get_Name (Rec) & ": ");
      Net.Stopped := new Signal;
      Net.Channels := Channel_Maps.New_Map (CM);
      for Ch of Channels loop
         Net.Channels.Set (To_String (Ch.Name), new Soja.Database.Channel'(Ch));
      end loop;
      Net.Delivered := Soja.User.New_Delivered_Store (CM);
      Net.Casemap := Case_RFC1459;   --  stdCaseMapping
      return Net;
   end New_Network;

   function New_Downstream_Conn
     (Srv : Soja.Server.Server_Access;
      IC  : not null Soja.Conn.IRC_Conn_Access;
      ID  : Long_Long_Integer) return Downstream_Conn_Access
   is
      Remote : constant String := Soja.Conn.Remote_Addr (IC.all);
      Logger : constant Logger_Access :=
        Prefixed (Soja.Server.Logger (Srv.all),
                  "downstream " & Remote & ": ");
      DC : constant Downstream_Conn_Access := new Downstream_Conn;
   begin
      DC.Conn := Soja.Conn.New_Conn
        (IC, (Logger           => Logger,
              Rate_Limit_Delay => 0.0,
              Rate_Limit_Burst => 0));
      DC.Srv := Srv;
      DC.Logger := Logger;
      DC.ID := ID;
      DC.Nick := To_Unbounded_String ("*");
      DC.Nick_CM := To_Unbounded_String ("*");
      DC.Username := To_Unbounded_String ("~u");
      DC.Hostname := To_Unbounded_String (Remote);
      DC.Caps := Soja.Irc.Cap_Registry.New_Registry;
      DC.Casemap := Case_ASCII;
      DC.Registration := new Downstream_Registration;
      for Cap of Permanent_Downstream_Caps loop
         Soja.Irc.Cap_Registry.Set_Available (DC.Caps, Cap.all, "");
      end loop;
      --  Deferred: the "sasl" cap value (serverSASLMechanisms) and the
      --  message-store caps, both of which need srv.Config().
      return DC;
   end New_Downstream_Conn;

   -----------------
   --  Event loop --
   -----------------

   --  user.go's handleEvent: dispatch on the event variant.  Every handler is
   --  a stub until the connection methods they call are ported.
   procedure Handle (U : not null User_Access; E : Event_Access) is
      pragma Unreferenced (U);
   begin
      if E.all in Upstream_Message_Event then
         null;   --  deferred: handleUpstreamMessage
      elsif E.all in Upstream_Connection_Error_Event then
         null;   --  deferred: handleUpstreamConnectionError
      elsif E.all in Upstream_Connected_Event then
         null;   --  deferred: handleUpstreamConnected
      elsif E.all in Upstream_Disconnected_Event then
         null;   --  deferred: handleUpstreamDisconnected
      elsif E.all in Upstream_Error_Event then
         null;   --  deferred: handleUpstreamError
      elsif E.all in Downstream_Message_Event then
         null;   --  deferred: handleDownstreamMessage
      elsif E.all in Downstream_Connected_Event then
         null;   --  deferred: handleDownstreamConnected
      elsif E.all in Downstream_Disconnected_Event then
         null;   --  deferred: handleDownstreamDisconnected
      elsif E.all in Channel_Detach_Event then
         null;   --  deferred: handleChannelDetach
      elsif E.all in Broadcast_Event then
         null;   --  deferred: handleBroadcast
      elsif E.all in Stop_Event then
         null;   --  deferred: stop the user
      elsif E.all in Try_Regain_Nick_Event then
         null;   --  deferred: handleTryRegainNick
      end if;
   end Handle;

   -----------------------------
   --  network/user helpers  --
   -----------------------------

   procedure For_Each_Downstream
     (Net : not null Network_Access; Process : not null Downstream_Process) is
   begin
      for DC of Net.User.Downstream_Conns loop
         if DC.Network = Net then
            Process (DC);
         end if;
      end loop;
   end For_Each_Downstream;

   function Is_Stopped (Net : not null Network_Access) return Boolean is
   begin
      return Net.Stopped.Is_Set;
   end Is_Stopped;

   procedure Stop_Network (Net : not null Network_Access) is
   begin
      if not Is_Stopped (Net) then
         Net.Stopped.Set;
      end if;
   end Stop_Network;

   function Equal_Casemap (Net : not null Network_Access; A, B : String)
      return Boolean
   is
   begin
      return Soja.Irc.Case_Mapping.Fold (Net.Casemap, A) =
             Soja.Irc.Case_Mapping.Fold (Net.Casemap, B);
   end Equal_Casemap;

   function Get_Network (U : not null User_Access; Name : String)
      return Network_Access
   is
   begin
      for Net of U.Networks loop
         if To_String (Net.Network_Record.Addr) = Name then
            return Net;
         end if;
         if Net.Network_Record.Name /= Null_Unbounded_String
           and then To_String (Net.Network_Record.Name) = Name
         then
            return Net;
         end if;
      end loop;
      return null;
   end Get_Network;

   function Get_Network_By_ID (U : not null User_Access; ID : Long_Long_Integer)
      return Network_Access
   is
   begin
      for Net of U.Networks loop
         if Net.Network_Record.ID = ID then
            return Net;
         end if;
      end loop;
      return null;
   end Get_Network_By_ID;

   --  connectToUpstream is deferred (network.URL, dialTCP, TLS, SASL EXTERNAL
   --  certificate parsing, certfp verification).  The stub reports a temporary
   --  failure so the reconnect loop keeps its shape.
   function Connect_To_Upstream (Net : not null Network_Access)
      return Upstream_Conn_Access
   is
      pragma Unreferenced (Net);
   begin
      return null;
   end Connect_To_Upstream;

   --  One task per network (Go's `go network.run()`).
   task type Network_Task (Net : not null Network_Access);
   task body Network_Task is
   begin
      Run_Network (Net);
   end Network_Task;
   type Network_Task_Access is access Network_Task;

   procedure Spawn_Network (Net : not null Network_Access) is
      T : Network_Task_Access := new Network_Task (Net);
      pragma Unreferenced (T);
   begin
      null;
   end Spawn_Network;

   --  Sort a network slice by ID (Go's sort.Slice over u.srv.db.ListNetworks).
   procedure Sort_By_ID (V : in out Soja.Database.Network_Lists.Vector) is
   begin
      for I in 1 .. Natural (V.Length) loop
         for J in reverse 2 .. I loop
            if V.Element (J - 1).ID > V.Element (J).ID then
               declare
                  Tmp : constant Soja.Database.Network := V.Element (J - 1);
               begin
                  V.Replace_Element (J - 1, V.Element (J));
                  V.Replace_Element (J, Tmp);
               end;
            end if;
         end loop;
      end loop;
   end Sort_By_ID;

   procedure Run_Network (Net : not null Network_Access) is
      use type Ada.Calendar.Time;
      Backoff : Soja.Backoff.Backoffer := Soja.Backoff.New_Backoffer
        (Soja.Server.Retry_Connect_Min_Delay,
         Soja.Server.Retry_Connect_Max_Delay,
         Soja.Server.Retry_Connect_Jitter);
      Last_Try : Ada.Calendar.Time := Ada.Calendar.Clock;
      Delay_Needed : Duration;
   begin
      if not Net.User.User_Record.Enabled
        or else not Net.Network_Record.Enabled
      then
         return;
      end if;

      loop
         exit when Is_Stopped (Net);

         Delay_Needed := Soja.Backoff.Next (Backoff)
           - (Ada.Calendar.Clock - Last_Try);
         if Delay_Needed > 0.0 then
            Net.Logger.Print
              ("waiting " & Duration'Image (Delay_Needed)
               & " before trying to reconnect to "
               & To_String (Net.Network_Record.Addr));
            delay Delay_Needed;
         end if;
         Last_Try := Ada.Calendar.Clock;

         if Connect_To_Upstream (Net) = null then
            Net.Logger.Print
              ("connection error to " & To_String (Net.Network_Record.Addr)
               & ": connectToUpstream not yet ported");
            Net.User.Events.Enqueue
              (new Upstream_Connection_Error_Event'
                 (Net   => Net,
                  Error => To_Unbounded_String
                    ("connection error: connectToUpstream not yet ported")));
         else
            Soja.Backoff.Reset (Backoff);
         end if;
      end loop;
   end Run_Network;

   procedure Load_Networks (U : not null User_Access) is
      DB  : constant Soja.Database.Database_Access :=
        Soja.Server.DB (U.Srv.all);
      Nets : Soja.Database.Network_Lists.Vector;
   begin
      --  Deferred: the user's message store (newUser's msgStore) and the
      --  delivery-receipt loading (needs msgStore).
      Nets := Soja.Database.List_Networks (DB.all, U.User_Record.ID);
      Sort_By_ID (Nets);
      for Rec of Nets loop
         declare
            Chs : constant Soja.Database.Channel_Lists.Vector :=
              Soja.Database.List_Channels (DB.all, Rec.ID);
            Net : constant Network_Access := New_Network (U, Rec, Chs);
         begin
            U.Networks.Append (Net);
            Spawn_Network (Net);
         end;
      end loop;
   end Load_Networks;

   procedure Run (U : not null User_Access) is
   begin
      Load_Networks (U);
      loop
         declare
            E    : Event_Access;
            Done : Boolean;
         begin
            U.Events.Dequeue (E, Done);
            exit when Done;
            Handle (U, E);
         end;
      end loop;
   end Run;

end Soja.Core;
