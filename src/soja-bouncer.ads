--  Soja.Bouncer -- the part of server.go that needs the core: the user table
--  (users, getUser, forEachUser, addUserLocked, createUser,
--  getOrCreateUser), the per-user task that runs user.run, the downstream
--  connection handler (Server.Handle) and the orderly shutdown.
--
--  Soja.Server sits below Soja.Core, so this lives above it.  There is one
--  bouncer per process: the connection handler type carries no context, so
--  Handle finds its bouncer through the one Initialize registered.
pragma Ada_2022;

with Ada.Containers.Indefinite_Hashed_Maps;
with Ada.Containers.Vectors;
with Ada.Strings.Hash;

with Soja.Conn;
with Soja.Core;
with Soja.Database;
with Soja.Server;

package Soja.Bouncer is

   type Bouncer is tagged limited private;
   type Bouncer_Access is access all Bouncer;

   Bouncer_Error : exception;   --  Exception_Message says why

   --  Bind to Srv: install Handle as its connection handler and register the
   --  bouncer-wide broadcast.  Srv must outlive the bouncer.
   procedure Initialize
     (B : aliased in out Bouncer; Srv : not null Soja.Server.Server_Access);

   --  Server.Start: load every user from the database and start its task.
   procedure Start (B : in out Bouncer);

   --  Server.getUser: null when there is no such (running) user.
   function Get_User (B : in out Bouncer; Name : String)
      return Soja.Core.User_Access;

   type User_Process is access procedure (U : Soja.Core.User_Access);

   --  Server.forEachUser.  Works on a snapshot of the table.
   procedure For_Each_User
     (B : in out Bouncer; Process : not null User_Process);

   --  Server.createUser: store Rec and start the user.  Bouncer_Error when
   --  the user exists or cannot be stored.
   function Create_User
     (B : in out Bouncer; Rec : in out Soja.Database.User)
      return Soja.Core.User_Access;

   --  Server.getOrCreateUser, for a client that has just authenticated.
   function Get_Or_Create_User (B : in out Bouncer; Username : String)
      return Soja.Core.User_Access;

   --  disableInactiveUsersLoop's period (4 hours); tests shorten it.
   Inactive_Check_Interval : Duration := 4.0 * 3600.0;

   --  Server.disableInactiveUsers: disable the users that have not had a
   --  client for the configured delay (`disable-inactive-user`), unless they
   --  have clients now.  Does nothing when the delay is 0.  Returns how many
   --  users were disabled.
   function Disable_Inactive_Users (B : in out Bouncer) return Natural;

   --  Server.Handle: owns IC until the client goes away.
   procedure Handle (IC : not null Soja.Conn.IRC_Conn_Access);

   --  Server.Shutdown's second half: refuse new clients, stop every user and
   --  wait for them (Timeout bounds each wait), then close the database.
   --  Stop listening first (Soja.Server.Shutdown).
   procedure Shutdown (B : in out Bouncer; Timeout : Duration := 30.0);

private

   package User_Maps is new Ada.Containers.Indefinite_Hashed_Maps
     (String, Soja.Core.User_Access, Ada.Strings.Hash, "=",
      Soja.Core."=");

   package User_Vectors is new Ada.Containers.Vectors
     (Positive, Soja.Core.User_Access, Soja.Core."=");

   protected type Table is
      function Get (Name : String) return Soja.Core.User_Access;
      --  Ok is False when Name is taken.
      procedure Add
        (Name : String; U : Soja.Core.User_Access; Ok : out Boolean);
      procedure Remove (Name : String);
      function All_Users return User_Vectors.Vector;
      procedure Stop_Accepting;
      function Is_Stopping return Boolean;
   private
      Map      : User_Maps.Map;
      Stopping : Boolean := False;
   end Table;

   protected type Id_Source is
      procedure Next (ID : out Long_Long_Integer);
   private
      Last : Long_Long_Integer := 0;
   end Id_Source;

   --  server.go's stopWG: the running user tasks.
   protected type Wait_Group is
      procedure Add;
      procedure Done;
      entry Wait;
   private
      Active : Natural := 0;
   end Wait_Group;

   protected type Stop_Gate is
      procedure Request;
      entry Wait;
   private
      Is_Set : Boolean := False;
   end Stop_Gate;

   type Bouncer is tagged limited record
      Stopped : Stop_Gate;
      Srv   : Soja.Server.Server_Access;
      Users : Table;
      Ids   : Id_Source;
      Tasks : Wait_Group;
   end record;

end Soja.Bouncer;
