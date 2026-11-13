pragma Ada_2022;

with Ada.Exceptions;
with Ada.IO_Exceptions;
with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;

with Soja.Core;             use Soja.Core;
with Soja.Core.Downstream_Commands;
with Soja.Core.Downstream_Handshake;
with Soja.Core.Downstream_Helpers; use Soja.Core.Downstream_Helpers;
with Soja.Database;
with Soja.Irc.Genmsg;       use Soja.Irc.Genmsg;
with Soja.Irc.Helpers;
with Soja.Irc.Messages;     use Soja.Irc.Messages;
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
   --  Initialize, Handle, Shutdown
   ----------------------------------------------------------------------

   procedure Initialize
     (B : aliased in out Bouncer; Srv : not null Soja.Server.Server_Access) is
   begin
      B.Srv := Srv;
      Current := B'Unchecked_Access;
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

      --  dc.Shutdown: flush what is queued (an ERROR, say), then close.
      Soja.Conn.Shutdown (DC.Conn);
   end Handle;

   procedure Shutdown (B : in out Bouncer; Timeout : Duration := 30.0) is
      DB : constant Soja.Database.Database_Access :=
        Soja.Server.DB (B.Srv.all);
   begin
      Log (B).Print ("shutting down server");
      B.Users.Stop_Accepting;

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
