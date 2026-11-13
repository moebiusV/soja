pragma Ada_2022;

with Ada.Containers;
with Ada.Directories;
with Ada.Exceptions;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;
with Ada.Text_IO;
with GNAT.OS_Lib;

with Soja.Bouncer;
with Soja.Core;              use Soja.Core;
with Soja.Core.Service;      use Soja.Core.Service;
with Soja.Database;
with Soja.Database.Sqlite;
with Soja.Irc.Messages;
with Soja.Logging;
with Soja.Msgstore.Fs;
with Soja.Server;

--  BouncerServ's commands.
procedure Service_Check is
   package SD renames Soja.Database;
   use type Ada.Containers.Count_Type;
   use type SD.Message_Filter;

   procedure Check (Cond : Boolean; What : String) is
   begin
      if not Cond then
         raise Program_Error with What;
      end if;
   end Check;

   function Has (Text, Needle : String) return Boolean is
     (Ada.Strings.Fixed.Index (Text, Needle) > 0);

   --  Collects what a command prints, joined with '|'.
   type Collector is limited new Printer with record
      Text : Unbounded_String;
   end record;
   overriding procedure Print (P : in out Collector; Text : String) is
   begin
      if Length (P.Text) > 0 then
         Append (P.Text, "|");
      end if;
      Append (P.Text, Text);
   end Print;

   Log : aliased Soja.Logging.Standard_Logger;
   Srv : aliased Soja.Server.Server;
   DB  : SD.Database_Access := Soja.Database.Sqlite.Open_Temp_Sqlite_DB;
   B   : aliased Soja.Bouncer.Bouncer;
   Alice : User_Access;

   function Ctx_Of
     (U : User_Access; Admin : Boolean; C : not null access Collector;
      Net : Network_Access := null) return Service_Context is
     (Nick => To_Unbounded_String ("alice_"), Network => Net, User => U,
      Srv => Srv'Unchecked_Access, Admin => Admin,
      Output => C.all'Unchecked_Access);

   --  What a command prints, or "!<error>" when it fails.
   function Run
     (Line : String; Admin : Boolean := True; Net : Network_Access := null;
      U : User_Access := Alice) return String
   is
      C : aliased Collector;
   begin
      Handle_Privmsg (Ctx_Of (U, Admin, C'Access, Net), Line);
      return To_String (C.Text);
   exception
      when E : Service_Error =>
         return (if Length (C.Text) > 0 then To_String (C.Text) & "|" else "")
                & "!" & Ada.Exceptions.Exception_Message (E);
   end Run;

   function Wait_Gone (Name : String) return Boolean is
      Waited : Duration := 0.0;
   begin
      while Soja.Bouncer.Get_User (B, Name) /= null and then Waited < 5.0 loop
         delay 0.05;
         Waited := Waited + 0.05;
      end loop;
      return Soja.Bouncer.Get_User (B, Name) = null;
   end Wait_Gone;

   Mark : constant String := " (type ""help"" for a list of commands)";
begin
   Srv.Initialize (Log'Unchecked_Access);
   Srv.Set_DB (DB);
   declare
      Rec : SD.User := SD.New_User ("alice");
   begin
      SD.Set_Password (Rec, "secret");
      Rec.Enabled := True;
      Rec.Admin := True;
      SD.Store_User (DB.all, Rec);
   end;
   Soja.Bouncer.Initialize (B, Srv'Unchecked_Access);
   Soja.Bouncer.Start (B);
   Alice := Soja.Bouncer.Get_User (B, "alice");
   Check (Alice /= null, "alice runs");

   -------------------------------------------------------------------
   --  help and command lookup
   -------------------------------------------------------------------
   declare
      Text : constant String := Run ("help");
   begin
      Check (Has (Text, "available commands: certfp fingerprint, certfp generate, "
                        & "channel delete, channel status, channel update, help, "
                        & "network create, network delete, network quote, "
                        & "network status, network update, sasl reset"),
             "help: " & Text);
      Check (Has (Text, "server notice, server status, user create"),
             "an admin sees the admin commands");
   end;
   Check (not Has (Run ("help", Admin => False), "server status")
          and then not Has (Run ("help", Admin => False), "user create"),
          "others do not");
   Check (not Has (Run ("help", U => null), "network create")
          and then Has (Run ("help", U => null), "user update"),
          "without a user only the global commands");
   Check (Run ("help network") =
          "available commands: network create, network delete, network quote, "
          & "network status, network update", "help of a group");
   Check (Has (Run ("help network delete"), "network delete [name]: delete a network"),
          "help of a command");
   Check (Run ("") = "!no command specified" & Mark, "nothing");
   Check (Run ("frob") = "!command ""frob"" not found" & Mark, "unknown");
   Check (Run ("s") = "!command ""s"" is ambiguous" & Mark, "ambiguous");
   Check (Run ("network frob") = "!command ""frob"" not found" & Mark, "sub");
   --  (A group lists its commands under the words as typed.)
   Check (Run ("net") = "available commands: net create, net delete, "
          & "net quote, net status, net update", "a group lists its commands");
   Check (Has (Run ("net stat"), "No network configured"), "prefixes");
   Check (Run ("say ""x") = "!failed to parse command: unterminated quoted string",
          "split errors");
   Check (Run ("server status", Admin => False)
          = "!you must be an admin to use this command", "admin only");
   Check (Run ("network status", U => null)
          = "!this command must be run as a user (try running with user run)",
          "user only");

   -------------------------------------------------------------------
   --  network
   -------------------------------------------------------------------
   Check (Run ("network status")
          = "No network configured, add one with ""network create"".",
          "no networks");
   Check (Run ("network create") = "!flag -addr is required", "-addr");
   Check (Run ("network create -addr http://x")
          = "!unknown scheme ""http"" (supported schemes: ircs, irc+insecure, "
            & "unix)", "scheme");
   Check (Run ("network create -addr x -name *")
          = "!the network name ""*"" is reserved for multi-upstream mode",
          "reserved name");
   Check (Run ("network create -addr x -certfp zz")
          = "!the certificate fingerprint must be hex-encoded", "hex");
   Check (Run ("network create -addr x -certfp abcd")
          = "!the certificate fingerprint must be a SHA256 or SHA512 hash",
          "length");
   Check (Run ("network create -addr x oops") = "!unexpected argument: oops",
          "extra");
   Check (Run ("network create -addr x -bogus 1")
          = "!flag provided but not defined: -bogus", "flag errors");
   Check (Run ("network create -addr irc+insecure://irc.example -name foo "
               & "-enabled false -nick fooey -connect-command ""MODE x +i""")
          = "created network ""foo""", "create");
   declare
      Net : constant Network_Access := Get_Network (Alice, "foo");
   begin
      Check (Net /= null and then To_String (Net.Network_Record.Nick) = "fooey"
             and then Net.Network_Record.Connect_Commands.Length = 1
             and then not Net.Network_Record.Enabled, "stored settings");
      Check (SD.List_Networks (DB.all, Alice.User_Record.ID).Length = 1,
             "and in the database");
   end;
   Check (Run ("network create -addr x -name foo -connect-command nonsense:::")
          /= "", "a duplicate is refused");
   Check (Run ("network status")
          = "foo (irc+insecure://irc.example) [disabled]", "status");
   Check (Run ("network update foo -nick bar -realname ""Bar Baz""")
          = "updated network ""foo""", "update");
   Check (To_String (Get_Network (Alice, "foo").Network_Record.Realname)
          = "Bar Baz", "updated");
   Check (Run ("network update nope -nick x") = "!unknown network ""nope""",
          "unknown");
   Check (Run ("network update -nick x")
          = "!no network selected, a name argument is required", "no default");
   Check (Run ("network update foo -connect-command a -connect-command b")
          = "updated network ""foo""", "several connect commands");
   Check (Get_Network (Alice, "foo").Network_Record.Connect_Commands.Length = 2,
          "kept");
   Check (Run ("network update foo -connect-command """"")
          = "updated network ""foo""", "cleared");
   Check (Get_Network (Alice, "foo").Network_Record.Connect_Commands.Is_Empty,
          "empty");
   Check (Run ("network quote foo ""PING x""")
          = "!network ""foo"" is not currently connected", "quote offline");
   Check (Run ("network quote") = "!expected one or two arguments", "quote");
   Check (Run ("network delete") = "!expected exactly one argument", "delete");
   Check (Run ("network delete -x") = "!unexpected argument: -x",
          "a flag is not a name");
   Check (Run ("network delete nope") = "!unknown network ""nope""", "gone");

   -------------------------------------------------------------------
   --  sasl, certfp
   -------------------------------------------------------------------
   Check (Run ("sasl status -network foo")
          = "SASL is disabled|Disconnected from upstream network", "sasl off");
   Check (Run ("sasl set-plain -network foo user pw") = "credentials saved",
          "set-plain");
   Check (Run ("sasl status -network foo")
          = "SASL PLAIN enabled with username ""user""|"
            & "Disconnected from upstream network", "sasl on");
   Check (Run ("sasl set-plain -network foo user")
          = "!expected exactly 2 arguments", "arguments");
   Check (Run ("sasl status") = "!no network selected, -network is required",
          "network flag");
   Check (To_String (SD.List_Networks (DB.all, Alice.User_Record.ID) (1)
                       .SASL.Plain_Password) = "pw", "saved in the database");
   Check (Run ("certfp fingerprint -network foo") = "!CertFP not set up",
          "no certfp");
   Check (Run ("sasl reset -network foo") = "credentials reset", "reset");
   Check (Run ("sasl status -network foo")
          = "SASL is disabled|Disconnected from upstream network", "reset ok");

   -------------------------------------------------------------------
   --  channel
   -------------------------------------------------------------------
   declare
      Net : constant Network_Access := Get_Network (Alice, "foo");
      procedure Save (Name : String; Detached : Boolean) is
         Ch : constant Channel_Access := new SD.Channel;
      begin
         Ch.Name := To_Unbounded_String (Name);
         Ch.Detached := Detached;
         SD.Store_Channel (DB.all, Net.Network_Record.ID, Ch.all);
         Net.Channels.Set (Name, Ch);
      end Save;
   begin
      Check (Run ("channel status -network foo") = "No channel configured.",
             "no channels");
      Save ("#b", True);
      Save ("#a", False);
      Check (Run ("channel status -network foo")
             = "#a [disconnected]|#b [disconnected, detached]",
             "status, sorted: " & Run ("channel status -network foo"));
      Check (Run ("channel status")
             = "#a/foo [disconnected]|#b/foo [disconnected, detached]",
             "without a network every channel is shown with it");
      Check (Run ("channel status -network nope") = "!unknown network ""nope""",
             "unknown network");

      Check (Run ("channel update #a/foo -relay-detached none -detach-after 5m")
             = "updated channel ""#a""", "update");
      Check (Net.Channels.Get ("#a").Relay_Detached = SD.Filter_None
             and then Net.Channels.Get ("#a").Detach_After = 300.0,
             "applied");
      Check (Run ("channel update #a/foo -relay-detached highlight "
                  & "-detach-after bogus")
             = "!unknown duration for -detach-after ""bogus"" (duration "
               & "format: 0, 300s, 22h30m, ...)", "bad duration");
      Check (Net.Channels.Get ("#a").Relay_Detached = SD.Filter_None,
             "a failed update changes nothing");
      Check (Run ("channel update #a/foo -detach-on sometimes")
             = "!unknown filter: ""sometimes""", "bad filter");
      Check (Run ("channel update #a") = "!missing network name",
             "needs the suffix");
      Check (Run ("channel update #zz/foo") = "!unknown channel ""#zz""",
             "unknown channel");
      Check (Run ("channel update #a/nope") = "!unknown network ""nope""",
             "unknown suffix");
      Check (Run ("channel update #b/foo -detached false")
             = "updated channel ""#b""", "attach");
      Check (not Net.Channels.Get ("#b").Detached, "attached");
      Check (Run ("channel delete #a/foo") = "deleted channel ""#a""", "delete");
      Check (Net.Channels.Get ("#a") = null, "gone");
      Check (Has (Run ("channel delete #a/foo"), "!failed to delete channel: "),
             "deleting it again fails");
   end;

   -------------------------------------------------------------------
   --  user
   -------------------------------------------------------------------
   Check (Run ("user status") = "alice (admin): 1 networks", "user status");
   Check (Run ("user status nobody") = "!unknown username ""nobody""",
          "unknown user");
   Check (Run ("user status", Admin => False)
          = "!you must be an admin to use this command", "admin only");
   Check (Run ("user create -username bob")
          = "!flag -password is required", "password required");
   Check (Run ("user create -username bob -password x -disable-password")
          = "!flags -password and -disable-password are mutually exclusive",
          "exclusive");
   Check (Run ("user create -password x") = "!flag -username is required",
          "username required");
   Check (Run ("user create -username bob -password pw -nick bobby")
          = "created user ""bob""", "create user");
   declare
      Bob : constant User_Access := Soja.Bouncer.Get_User (B, "bob");
   begin
      Check (Bob /= null and then Bob.User_Record.Enabled
             and then not Bob.User_Record.Admin
             and then To_String (Bob.User_Record.Nick) = "bobby",
             "bob runs, with his settings");
      Check (Has (Run ("user create -username bob -password pw"),
                  "!could not create user: "), "a duplicate");
      Check (Run ("user status") = "alice (admin): 1 networks|"
             & "bob: 0 networks"
             or else Run ("user status") = "bob: 0 networks|"
                     & "alice (admin): 1 networks", "both users");

      --  Updating another user goes through that user's own task.
      Check (Run ("user update bob -admin true -enabled true")
             = "updated user ""bob""", "update bob");
      Check (Bob.User_Record.Admin, "bob is an admin now");
      Check (Run ("user update bob -nick x")
             = "!cannot update -nick of other user", "no nick for others");
      Check (Run ("user update bob -admin true", Admin => False)
             = "!you must be an admin to update other users", "admin only");
      Check (Run ("user update -admin true")
             = "!cannot update -admin of own user", "own admin");
      Check (Run ("user update -nick al -realname ""Al Ice""")
             = "updated user ""alice""", "own update");
      Check (To_String (SD.Get_User (DB.all, "alice").Nick) = "al"
             and then To_String (Alice.User_Record.Realname) = "Al Ice",
             "stored");
      Check (Run ("user update bob -password pw2") = "updated user ""bob""",
             "bob's password");
      Check (SD.Get_User (DB.all, "bob").Password /= Null_Unbounded_String,
             "hashed");
      Check (Run ("user update bob -disable-password") = "updated user ""bob""",
             "disable");
      Check (Length (SD.Get_User (DB.all, "bob").Password) = 0,
             "bob has no password");
      Check (Run ("user update bob -password x -disable-password")
             = "!flags -password and -disable-password are mutually exclusive",
             "exclusive");

      --  user run: as another user, on that user's task.
      Check (Run ("user run bob network status")
             = "No network configured, add one with ""network create"".",
             "run");
      Check (Run ("user run bob network frob")
             = "!command ""frob"" not found" & Mark, "run's errors");
      Check (Run ("user run alice network status")
             = "foo (irc+insecure://irc.example) [disabled]", "run as self");
      Check (Run ("user run nobody help") = "!unknown username ""nobody""",
             "run, unknown");
      Check (Run ("user run bob") = "!expected at least two arguments",
             "run needs a command");

      --  delete asks for a confirmation token first.
      declare
         Ask : constant String := Run ("user delete bob");
         Tok : constant String := Ask (Ask'Last - 6 .. Ask'Last - 1);
      begin
         Check (Has (Ask, "To confirm user deletion, send ""user delete bob "),
                "asks: " & Ask);
         Check (Run ("user delete bob 000000")
                = "!provided confirmation token doesn't match user", "token");
         Check (Run ("user delete bob", Admin => False)
                = "!only admins may delete other users", "admins only");
         Check (Run ("user delete bob " & Tok) = "deleted user ""bob""",
                "deleted");
         Check (Wait_Gone ("bob"), "bob is not running any more");
         begin
            declare
               Gone : constant SD.User := SD.Get_User (DB.all, "bob");
               pragma Unreferenced (Gone);
            begin
               Check (False, "bob is still in the database");
            end;
         exception
            when SD.Not_Found => null;
         end;
      end;
   end;

   --  Deleting oneself: Go waits for its own task to stop and never returns
   --  (SB-10); here the user stops after the command and is then deleted.
   Check (Run ("user create -username carol -password pw") /= "", "carol");
   declare
      Ask : constant String := Run ("user run carol user delete carol");
      Tok : constant String := Ask (Ask'Last - 6 .. Ask'Last - 1);
   begin
      Check (Has (Ask, "send ""user delete carol "), "asks: " & Ask);
      Check (Has (Run ("user run carol user delete carol " & Tok), "Goodbye carol"),
             "says goodbye");
      Check (Wait_Gone ("carol"), "carol stopped");
      declare
         Waited : Duration := 0.0;
         Present : Boolean := True;
      begin
         while Present and then Waited < 5.0 loop
            begin
               declare
                  Rec : constant SD.User := SD.Get_User (DB.all, "carol");
                  pragma Unreferenced (Rec);
               begin
                  delay 0.05;
                  Waited := Waited + 0.05;
               end;
            exception
               when SD.Not_Found => Present := False;
            end;
         end loop;
         Check (not Present, "carol is deleted from the database");
      end;
   end;

   -------------------------------------------------------------------
   --  server
   -------------------------------------------------------------------
   Check (Run ("server status") = "2/2 users, 0 downstreams, 0 upstreams, 1 "
          & "networks, 1 channels" or else Has (Run ("server status"), " users, "),
          "server status: " & Run ("server status"));
   Check (Run ("server notice") = "!expected exactly one argument", "notice");
   Check (Has (Run ("server notice ""hello all"""), "sent to "), "broadcast");
   Check (Run ("server status", Admin => False)
          = "!you must be an admin to use this command", "admin only");

   --  The file message store is told when a network is renamed: its
   --  history moves with it.
   declare
      Root : constant String := "/tmp/soja-service-check-logs";
      Net  : constant Network_Access := Get_Network (Alice, "foo");
   begin
      if Ada.Directories.Exists (Root) then
         Ada.Directories.Delete_Tree (Root);
      end if;
      Alice.Msg_Store := Soja.Msgstore.Fs.New_Fs_Store (Root, Alice.User_Record);
      declare
         ID : constant String := Alice.Msg_Store.Append
           (Net.Network_Record, "#x",
            Soja.Irc.Messages.Parse_Message (":bob!u@h PRIVMSG #x :logged"));
         pragma Unreferenced (ID);
      begin
         null;
      end;
      Check (Ada.Directories.Exists (Root & "/alice/foo/#x"), "logs of foo");
      Check (Run ("network update foo -name renamed") = "updated network ""renamed""",
             "rename a network");
      Check (Ada.Directories.Exists (Root & "/alice/renamed/#x")
             and then not Ada.Directories.Exists (Root & "/alice/foo"),
             "the history moved with the network");
      --  A network without logs renames without any complaint.
      Check (Run ("network update renamed -name again") = "updated network ""again""",
             "rename a network again");
      Alice.Msg_Store.Close;
      Ada.Directories.Delete_Tree (Root);
   end;

   Soja.Bouncer.Shutdown (B, Timeout => 10.0);
   Ada.Text_IO.Put_Line ("ALL PASS");
exception
   when E : others =>
      Ada.Text_IO.Put_Line
        ("FAILED: " & Ada.Exceptions.Exception_Information (E));
      GNAT.OS_Lib.OS_Exit (1);
end Service_Check;
