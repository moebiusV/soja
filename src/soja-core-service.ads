--  BouncerServ (service.go): the bouncer's own command interface, reached by
--  messaging the nick BouncerServ.  A command is a path through a tree
--  ("network create", "user update", ...) whose leaves take flags in Go's
--  `flag` syntax (see Soja.Flags).
pragma Ada_2022;

with Ada.Containers.Vectors;

with Soja.Database;
with Soja.Irc.Genmsg;
with Soja.Irc.Messages;

package Soja.Core.Service is

   subtype String_Vector is Soja.Irc.Genmsg.String_Vectors.Vector;

   --  A command failed; Exception_Message is what the user is told.
   Service_Error : exception;

   --  Where a command's output goes (serviceContext.print).
   type Printer is limited interface;
   procedure Print (P : in out Printer; Text : String) is abstract;
   type Printer_Access is access all Printer'Class;

   --  What the commands need to know about the other users: the bouncer's
   --  user table, which lives above Soja.Core (Soja.Bouncer implements it).
   package User_Vectors is new Ada.Containers.Vectors (Positive, User_Access);

   type Directory is limited interface;
   function Find (D : Directory; Name : String) return User_Access
      is abstract;
   --  Running users, and (at most Limit of) them.
   function Count (D : Directory) return Natural is abstract;
   function Snapshot (D : Directory; Limit : Natural) return User_Vectors.Vector
      is abstract;
   --  Server.createUser; Service_Error carries the reason on failure.
   function Create (D : Directory; Rec : in out Soja.Database.User)
      return User_Access is abstract;
   --  A bouncer-wide message to every user's clients; Sent of Total users
   --  could be reached.
   procedure Broadcast
     (D : Directory; Msg : Soja.Irc.Messages.Message;
      Sent, Total : out Natural) is abstract;
   type Directory_Access is access all Directory'Class;

   --  Set by Soja.Bouncer.Initialize.
   Users : Directory_Access;

   --  serviceContext.
   type Service_Context is record
      Nick    : Unbounded_String;      --  the client's nick; optional
      Network : Network_Access;        --  the client's network; optional
      User    : User_Access;           --  optional
      Srv     : Soja.Server.Server_Access;
      Admin   : Boolean := False;
      Output  : Printer_Access;
   end record;

   --  handleServicePRIVMSG: split a command line and run it.  Service_Error
   --  carries what went wrong (including a line that does not split).
   procedure Handle_Privmsg (Ctx : Service_Context; Text : String);

   --  handleServiceCommand.
   procedure Handle_Command (Ctx : Service_Context; Words : String_Vector);

   --  The client hook (Downstream_Commands.Service_Handler): run Text as a
   --  command for DC and answer it with BouncerServ PRIVMSGs, errors as
   --  "error: ...".
   procedure Handle_Client
     (DC : not null Downstream_Conn_Access; Text : String);

   --  The eventUserRun handler, on the user's task.
   procedure Run_Event
     (U : not null User_Access; Params : String_Vector;
      Output : not null Run_Output_Access);

end Soja.Core.Service;
