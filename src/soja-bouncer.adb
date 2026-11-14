pragma Ada_2022;

with Ada.Calendar;
with Ada.Exceptions;
with Ada.IO_Exceptions;
with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;

with Soja.Core;             use Soja.Core;
with Soja.Core.Downstream_Commands;
with Soja.Core.Downstream_Handshake;
with Soja.Core.Service;
with Soja.Core.Downstream_Helpers; use Soja.Core.Downstream_Helpers;
with Soja.Database;
with Soja.Irc.Genmsg;       use Soja.Irc.Genmsg;
with Soja.Irc.Helpers;
with Soja.Irc.Messages;     use Soja.Irc.Messages;
with Soja.Irc.Numerics;     use Soja.Irc.Numerics;
with Soja.Logging;

package body Soja.Bouncer is

   --  The bouncer Handle works for (see the spec).
   Current : Bouncer_Access;

   protected body Table is

      function Get (Name : String) return Soja.Core.User_Access is
         Pos : constant User_Maps.Cursor := Map.Find (Name);
      begin
         return (if User_Maps.Has_Element (Pos)
                 then User_Maps.Element (Pos) else null);
      end Get;

      procedure Add
        (Name : String; U : Soja.Core.User_Access; Ok : out Boolean) is
      begin
         Ok := not Map.Contains (Name);
         if Ok then
            Map.Insert (Name, U);
         end if;
      end Add;

      procedure Remove (Name : String) is
      begin
         Map.Exclude (Name);
      end Remove;

      function All_Users return User_Vectors.Vector is
         V : User_Vectors.Vector;
      begin
         for U of Map loop
            V.Append (U);
         end loop;
         return V;
      end All_Users;

      procedure Stop_Accepting is
      begin
         Stopping := True;
      end Stop_Accepting;

      function Is_Stopping return Boolean is (Stopping);

   end Table;

   protected body Id_Source is
      procedure Next (ID : out Long_Long_Integer) is
      begin
         Last := Last + 1;
         ID := Last;
      end Next;
   end Id_Source;

   protected body Wait_Group is
      procedure Add is
      begin
         Active := Active + 1;
      end Add;

      procedure Done is
      begin
         Active := Active - 1;
      end Done;

      entry Wait when Active = 0 is
      begin
         null;
      end Wait;
   end Wait_Group;

   protected body Stop_Gate is
      procedure Request is
      begin
         Is_Set := True;
      end Request;

      entry Wait when Is_Set is
      begin
         null;
      end Wait;
   end Stop_Gate;

   function Log (B : Bouncer) return Soja.Logging.Logger_Access is
     (Soja.Server.Logger (B.Srv.all));

   ----------------------------------------------------------------------
   --  Users
   ----------------------------------------------------------------------

   --  The task that runs one user (addUserLocked's goroutine): run the
   --  user's loop, then leave the table.
   task type User_Runner (B : Bouncer_Access; U : Soja.Core.User_Access);
   type User_Runner_Access is access User_Runner;

   task body User_Runner is
      Name : constant String := To_String (U.User_Record.Username);
   begin
      begin
         Soja.Core.Run (U);
      exception
         when E : others =>
            Log (B.all).Print
              ("panic serving user " & Soja.Irc.Helpers.Quote (Name) & ": "
               & Ada.Exceptions.Exception_Information (E));
      end;
      B.Users.Remove (Name);
      B.Srv.Add_Users (-1);
      B.Tasks.Done;
   end User_Runner;

   --  addUserLocked: build the user, enter it in the table, start its task.
   function Add_User
     (B : in out Bouncer; Rec : Soja.Database.User)
      return Soja.Core.User_Access
   is
      U  : constant Soja.Core.User_Access := New_User (B.Srv, Rec);
      Ok : Boolean;
      Runner : User_Runner_Access;
      pragma Unreferenced (Runner);
   begin
      Log (B).Print
        ("starting bouncer for user "
         & Soja.Irc.Helpers.Quote (To_String (Rec.Username)));
      B.Users.Add (To_String (Rec.Username), U, Ok);
      if not Ok then
         raise Bouncer_Error with
           "user " & Soja.Irc.Helpers.Quote (To_String (Rec.Username))
           & " already exists";
      end if;
      B.Srv.Add_Users (1);
      B.Tasks.Add;
      Runner := new User_Runner (B'Unchecked_Access, U);
      return U;
   end Add_User;

   function Get_User (B : in out Bouncer; Name : String)
      return Soja.Core.User_Access is (B.Users.Get (Name));

   procedure For_Each_User
     (B : in out Bouncer; Process : not null User_Process) is
   begin
      for U of B.Users.All_Users loop
         Process (U);
      end loop;
   end For_Each_User;

   function Create_User
     (B : in out Bouncer; Rec : in out Soja.Database.User)
      return Soja.Core.User_Access
   is
      DB : constant Soja.Database.Database_Access :=
        Soja.Server.DB (B.Srv.all);
   begin
      if B.Users.Get (To_String (Rec.Username)) /= null then
         raise Bouncer_Error with
           "user " & Soja.Irc.Helpers.Quote (To_String (Rec.Username))
           & " already exists";
      end if;
      begin
         Soja.Database.Store_User (DB.all, Rec);
      exception
         when E : others =>
            raise Bouncer_Error with
              "could not create user in db: "
              & Ada.Exceptions.Exception_Message (E);
      end;
      return Add_User (B, Rec);
   end Create_User;

   function Get_Or_Create_User (B : in out Bouncer; Username : String)
      return Soja.Core.User_Access
   is
      Known : constant Soja.Core.User_Access := B.Users.Get (Username);
      DB    : constant Soja.Database.Database_Access :=
        Soja.Server.DB (B.Srv.all);
      Found : Boolean := True;
   begin
      if Known /= null then
         return Known;
      end if;

      begin
         declare
            Ignored : constant Soja.Database.User :=
              Soja.Database.Get_User (DB.all, Username);
            pragma Unreferenced (Ignored);
         begin
            null;
         end;
      exception
         when others =>   --  (Not_Found: the usual case)
            Found := False;
      end;
      if Found then
         raise Bouncer_Error with
           "user " & Soja.Irc.Helpers.Quote (Username)
           & " exists in the DB but hasn't been loaded by the bouncer -- a "
           & "restart may help";
      end if;

      if not Soja.Server.Config (B.Srv.all).Enable_Users_On_Auth then
         raise Bouncer_Error with
           "cannot find user " & Soja.Irc.Helpers.Quote (Username)
           & " in the DB";
      end if;

      --  Can't find the user in the DB -- try to create it.
      declare
         Rec : Soja.Database.User := Soja.Database.New_User (Username);
      begin
         return Create_User (B, Rec);
      exception
         when E : Bouncer_Error =>
            raise Bouncer_Error with
              "failed to automatically create user "
              & Soja.Irc.Helpers.Quote (Username)
              & " after successful authentication: "
              & Ada.Exceptions.Exception_Message (E);
      end;
   end Get_Or_Create_User;

   ----------------------------------------------------------------------
   --  Disabling inactive users
   ----------------------------------------------------------------------

   function Disable_Inactive_Users (B : in out Bouncer) return Natural is
      Delay_For : constant Duration :=
        Soja.Server.Config (B.Srv.all).Disable_Inactive_Users_Delay;
      DB        : constant Soja.Database.Database_Access :=
        Soja.Server.DB (B.Srv.all);
      Disabled  : Natural := 0;
      Inactive  : User_Vectors.Vector;
   begin
      if Delay_For = 0.0 then
         return 0;
      end if;

      declare
         Names : Soja.Database.Username_Lists.Vector;
      begin
         begin
            Names := Soja.Database.List_Inactive_Usernames
              (DB.all, Ada.Calendar."-" (Ada.Calendar.Clock, Delay_For));
         exception
            when E : others =>
               Log (B).Print ("failed to list inactive users: "
                              & Ada.Exceptions.Exception_Message (E));
               return 0;
         end;

         --  Filter out users with clients.  (Go also asks the users that are
         --  disabled already, every time: SOJU-BUGS.md.)
         for Name of Names loop
            declare
               U : constant User_Access := B.Users.Get (To_String (Name));
            begin
               if U /= null
                 and then U.Num_Downstream_Conns = 0
                 and then U.User_Record.Enabled
               then
                  Inactive.Append (U);
               end if;
            end;
         end loop;
      end;

      if Inactive.Is_Empty then
         return 0;
      end if;

      Log (B).Print ("found" & Natural'Image (Natural (Inactive.Length))
                     & " inactive users");
      for U of Inactive loop
         declare
            Result : constant Update_Result_Access := new Update_Result;
            Error  : Unbounded_String;
            Name   : constant String := To_String (U.User_Record.Username);
         begin
            U.Events.Enqueue
              (new User_Update_Event'
                 (Has_Enabled => True, Enabled => False,
                  Result => Result, others => <>));
            select
               Result.Wait (Error);
               if Length (Error) > 0 then
                  Log (B).Print ("failed to disable inactive user "
                                 & Soja.Irc.Helpers.Quote (Name) & ": "
                                 & To_String (Error));
               else
                  --  (Go says "deleted": the user is only disabled.)
                  Log (B).Print ("disabled inactive user "
                                 & Soja.Irc.Helpers.Quote (Name));
                  Disabled := Disabled + 1;
               end if;
            or
               delay 60.0;
               Log (B).Print ("timeout disabling inactive user "
                              & Soja.Irc.Helpers.Quote (Name));
            end select;
         exception
            when others =>
               null;   --  that user is stopping
         end;
      end loop;
      return Disabled;
   end Disable_Inactive_Users;

   --  disableInactiveUsersLoop.
   task type Inactive_Runner (B : Bouncer_Access);
   type Inactive_Runner_Access is access Inactive_Runner;

   task body Inactive_Runner is
   begin
      loop
         select
            B.Stopped.Wait;
            exit;
         or
            delay Inactive_Check_Interval;
         end select;

         begin
            declare
               Count : constant Natural := Disable_Inactive_Users (B.all);
               pragma Unreferenced (Count);
            begin
               null;
            end;
         exception
            when E : others =>
               Log (B.all).Print ("failed to disable inactive users: "
                                  & Ada.Exceptions.Exception_Message (E));
         end;
      end loop;
      B.Tasks.Done;
   end Inactive_Runner;

   procedure Start (B : in out Bouncer) is
      DB    : constant Soja.Database.Database_Access :=
        Soja.Server.DB (B.Srv.all);
      Users : constant Soja.Database.User_Lists.Vector :=
        Soja.Database.List_Users (DB.all);
   begin
      for Rec of Users loop
         declare
            U : constant Soja.Core.User_Access := Add_User (B, Rec);
            pragma Unreferenced (U);
         begin
            null;
         end;
      end loop;

      declare
         Runner : Inactive_Runner_Access;
         pragma Unreferenced (Runner);
      begin
         B.Tasks.Add;
         Runner := new Inactive_Runner (B'Unchecked_Access);
      end;
   end Start;

   ----------------------------------------------------------------------
   --  Broadcast (a bouncer-wide NOTICE by an administrator)
   ----------------------------------------------------------------------

   procedure Broadcast
     (Srv  : not null Soja.Server.Server_Access;
      From : not null User_Access;
      Msg  : Message)
   is
      pragma Unreferenced (Srv, From);
   begin
      if Current = null then
         return;
      end if;
      for U of Current.Users.All_Users loop
         begin
            U.Events.Enqueue (new Broadcast_Event'(Msg => Copy (Msg)));
         exception
            when others =>
               null;   --  that user is stopping
         end;
      end loop;
   end Broadcast;

   ----------------------------------------------------------------------
   --  What BouncerServ asks of the user table
   ----------------------------------------------------------------------

   type Directory_Impl is new Soja.Core.Service.Directory with record
      B : Bouncer_Access;
   end record;

   overriding function Find (D : Directory_Impl; Name : String)
      return User_Access;
   overriding function Count (D : Directory_Impl) return Natural;
   overriding function Snapshot (D : Directory_Impl; Limit : Natural)
      return Soja.Core.Service.User_Vectors.Vector;
   overriding function Create
     (D : Directory_Impl; Rec : in out Soja.Database.User)
      return User_Access;
   overriding procedure Broadcast
     (D : Directory_Impl; Msg : Message; Sent, Total : out Natural);

   function Find (D : Directory_Impl; Name : String)
      return User_Access is (D.B.Users.Get (Name));

   function Count (D : Directory_Impl) return Natural is
     (Natural (D.B.Users.All_Users.Length));

   function Snapshot (D : Directory_Impl; Limit : Natural)
      return Soja.Core.Service.User_Vectors.Vector
   is
      R : Soja.Core.Service.User_Vectors.Vector;
   begin
      for U of D.B.Users.All_Users loop
         exit when Natural (R.Length) >= Limit;
         R.Append (U);
      end loop;
      return R;
   end Snapshot;

   function Create
     (D : Directory_Impl; Rec : in out Soja.Database.User)
      return User_Access is
   begin
      return Create_User (D.B.all, Rec);
   exception
      when E : Bouncer_Error =>
         raise Soja.Core.Service.Service_Error
           with Ada.Exceptions.Exception_Message (E);
   end Create;

   procedure Broadcast
     (D : Directory_Impl; Msg : Message; Sent, Total : out Natural) is
   begin
      Sent := 0;
      Total := 0;
      for U of D.B.Users.All_Users loop
         Total := Total + 1;
         begin
            U.Events.Enqueue (new Broadcast_Event'(Msg => Copy (Msg)));
            Sent := Sent + 1;
         exception
            when others =>
               null;   --  that user is stopping
         end;
      end loop;
   end Broadcast;

   The_Directory : aliased Directory_Impl;

   ----------------------------------------------------------------------
   --  Initialize, Handle, Shutdown
   ----------------------------------------------------------------------

   procedure Initialize
     (B : aliased in out Bouncer; Srv : not null Soja.Server.Server_Access) is
   begin
      B.Srv := Srv;
      Current := B'Unchecked_Access;
      The_Directory.B := B'Unchecked_Access;
      Soja.Core.Service.Users := The_Directory'Access;
      Soja.Core.Downstream_Commands.Service_Handler :=
        Soja.Core.Service.Handle_Client'Access;
      Srv.Set_Handler (Handle'Access);
      Soja.Core.Downstream_Commands.Broadcast_Hook := Broadcast'Access;
   end Initialize;

   procedure Handle (IC : not null Soja.Conn.IRC_Conn_Access) is
      B  : constant Bouncer_Access := Current;
      ID : Long_Long_Integer;
      DC : Downstream_Conn_Access;

      procedure Send_Error (Text : String) is
      begin
         Send_Message (DC, Make ("ERROR", [Text]));
      end Send_Error;

      --  The client is registered and bound to U: hand its commands to the
      --  user's task until it goes away.
      procedure Serve_Client (U : User_Access) is
      begin
         U.Events.Enqueue (new Downstream_Connected_Event'(DC => DC));
         begin
            loop
               declare
                  M : constant Message := Soja.Conn.Read_Message (DC.Conn);
               begin
                  U.Events.Enqueue
                    (new Downstream_Message_Event'(Msg => M, DC => DC));
               end;
            end loop;
         exception
            when Ada.IO_Exceptions.End_Error =>
               null;
            when E : others =>
               DC.Logger.Print
                 ("failed to read IRC command: "
                  & Ada.Exceptions.Exception_Message (E));
         end;
         U.Events.Enqueue (new Downstream_Disconnected_Event'(DC => DC));
      end Serve_Client;
   begin
      B.Ids.Next (ID);
      DC := New_Downstream_Conn (B.Srv, IC, ID);
      B.Srv.Add_Downstreams (1);

      begin
         if B.Users.Is_Stopping then
            Send_Error ("Server is shutting down");
         elsif Soja.Core.Downstream_Handshake.Run_Until_Registered (DC) then
            declare
               U : User_Access;
            begin
               begin
                  U := Get_Or_Create_User
                    (B.all, To_String (DC.Registration.Auth_Username));
               exception
                  when E : Bouncer_Error =>
                     DC.Logger.Print
                       ("failed to get/create user: "
                        & Ada.Exceptions.Exception_Message (E));
                     Send_Error ("Internal server error");
               end;
               if U /= null then
                  Serve_Client (U);
               end if;
            end;
         end if;
      exception
         when E : others =>
            Log (B.all).Print
              ("panic serving downstream "
               & Soja.Conn.Remote_Addr (DC.Conn) & ": "
               & Ada.Exceptions.Exception_Information (E));
      end;

      B.Srv.Add_Downstreams (-1);
      --  dc.Shutdown: flush what is queued (an ERROR, say), then close.
      Soja.Conn.Shutdown (DC.Conn);
   end Handle;

   --  Where an admin command's output goes: PRIVMSGs to "*" from the server.
   type Admin_Printer
     (C : Soja.Conn.Conn_Access; Srv : Soja.Server.Server_Access)
   is limited new Soja.Core.Service.Printer with null record;

   overriding procedure Print (P : in out Admin_Printer; Text : String) is
      M : Message := Make ("PRIVMSG", ["*", Text]);
   begin
      M.Prefix := Server_Prefix (P.Srv);
      Soja.Conn.Send_Message (P.C, M);
   end Print;

   procedure Handle_Admin (IC : not null Soja.Conn.IRC_Conn_Access) is
      B      : constant Bouncer_Access := Current;
      Remote : constant String := Soja.Conn.Remote_Addr (IC.all);
      Logger : constant Soja.Logging.Logger_Access :=
        new Soja.Logging.Prefix_Logger'
          (Base   => Log (B.all),
           Prefix => To_Unbounded_String
             ("admin " & Soja.Irc.Helpers.Quote (Remote) & ": "));
      C      : constant Soja.Conn.Conn_Access := Soja.Conn.New_Conn
        (IC, (Logger => Logger, Rate_Limit_Delay => 0.0,
              Rate_Limit_Burst => 0, others => <>));
      Printer : aliased Admin_Printer (C, B.Srv);

      procedure Reply (M : Message; With_Prefix : Boolean := True) is
         R : Message := M;
      begin
         if With_Prefix then
            R.Prefix := Server_Prefix (B.Srv);
         end if;
         Soja.Conn.Send_Message (C, R);
      end Reply;
   begin
      begin
         if B.Users.Is_Stopping then
            Soja.Conn.Send_Message
              (C, Make ("ERROR", ["Server is shutting down"]));
         else
            loop
               declare
                  M : Message;
               begin
                  begin
                     M := Soja.Conn.Read_Message (C);
                  exception
                     when Ada.IO_Exceptions.End_Error =>
                        exit;
                     when E : others =>
                        Logger.Print
                          ("failed to read IRC command: "
                           & Ada.Exceptions.Exception_Message (E));
                        exit;
                  end;

                  if To_String (M.Command) in "CAP" | "NICK" | "USER"
                                              | "PASS"
                  then
                     --  Ensure regular IRC clients cannot connect.  This is
                     --  important to e.g. prevent unprivileged users from
                     --  connecting to the admin socket.
                     Soja.Conn.Send_Message
                       (C, Make ("ERROR",
                                 ["This is not a regular IRC server"]));
                     exit;
                  elsif To_String (M.Command) = "BOUNCERSERV" then
                     if M.Params.Is_Empty then
                        Reply (Make (ERR_NEEDMOREPARAMS,
                                     ["*", "BOUNCERSERV",
                                      "Not enough parameters"]), False);
                     else
                        declare
                           Ctx : constant Soja.Core.Service.Service_Context :=
                             (Nick => Null_Unbounded_String, Network => null,
                              User => null, Srv => B.Srv, Admin => True,
                              Output => Printer'Unchecked_Access);
                        begin
                           Soja.Core.Service.Handle_Privmsg
                             (Ctx, Param (M, 0));
                           Reply (Make ("BOUNCERSERV", ["OK"]));
                        exception
                           when E : Soja.Core.Service.Service_Error =>
                              Reply (Make ("FAIL",
                                           ["BOUNCERSERV",
                                            Ada.Exceptions.Exception_Message
                                              (E)]));
                        end;
                     end if;
                  else
                     Reply (Make (ERR_UNKNOWNCOMMAND,
                                  ["*", To_String (M.Command),
                                   "Unknown command"]));
                  end if;
               end;
            end loop;
         end if;
      exception
         when E : others =>
            Logger.Print
              ("panic serving admin client: "
               & Ada.Exceptions.Exception_Information (E));
      end;
      Soja.Conn.Shutdown (C);   --  flush the last replies, then close
   end Handle_Admin;

   procedure Shutdown (B : in out Bouncer; Timeout : Duration := 30.0) is
      DB : constant Soja.Database.Database_Access :=
        Soja.Server.DB (B.Srv.all);
   begin
      Log (B).Print ("shutting down server");
      B.Users.Stop_Accepting;
      B.Stopped.Request;

      for U of B.Users.All_Users loop
         if not Soja.Core.Stop_User (U, Timeout) then
            Log (B).Print
              ("user " & To_String (U.User_Record.Username)
               & " did not stop in time");
         end if;
      end loop;

      Log (B).Print ("waiting for users to finish");
      select
         B.Tasks.Wait;
      or
         delay Timeout;
      end select;

      begin
         Soja.Database.Close (DB.all);
      exception
         when E : others =>
            Log (B).Print
              ("failed to close DB: " & Ada.Exceptions.Exception_Message (E));
      end;
   end Shutdown;

end Soja.Bouncer;
