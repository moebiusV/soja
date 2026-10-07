pragma Ada_2022;

with Ada.Text_IO;
with Ada.Strings.Unbounded;

with AWS.Net;
with AWS.Net.Std;

with Soja.Conn;
with Soja.Core;
with Soja.Database;
with Soja.Irc.Members;
with Soja.Irc.Messages;
with Soja.Logging;
with Soja.Server;

procedure Upstream_Connect_Check is
   use Ada.Strings.Unbounded;
   use Soja.Core;
   use type Soja.Conn.Conn_Access;
   use type Soja.Irc.Messages.Prefix_Access;

   ---------
   -- URL --
   ---------

   procedure Check_URL (Addr, Scheme, Host, Path : String) is
      N : Soja.Database.Network := Soja.Database.New_Network (Addr);
      U : constant Soja.Database.Network_URL := Soja.Database.URL (N);
   begin
      if To_String (U.Scheme) /= Scheme
        or else To_String (U.Host) /= Host
        or else To_String (U.Path) /= Path
      then
         raise Program_Error with
           "URL " & Addr & " parsed as [" & To_String (U.Scheme) & "] ["
           & To_String (U.Host) & "] [" & To_String (U.Path) & "]";
      end if;
   end Check_URL;

   Log  : aliased Soja.Logging.Standard_Logger;
   Srv  : aliased Soja.Server.Server;
   Rec  : Soja.Database.User := Soja.Database.New_User ("alice");
   U    : User_Access;

begin

   --  network.URL parsing.
   Check_URL ("irc.example", "ircs", "irc.example", "");
   Check_URL ("ircs://irc.example:6697", "ircs", "irc.example:6697", "");
   Check_URL ("irc+insecure://irc.example:6667", "irc+insecure",
              "irc.example:6667", "");
   Check_URL ("irc+unix:///run/ircd.sock", "irc+unix", "", "/run/ircd.sock");

   Soja.Server.Initialize (Srv, Log'Unchecked_Access);
   U := New_User (Srv'Unchecked_Access, Rec);

   --  connectToUpstream over a plain TCP listener (irc+insecure).
   declare
      Listener : AWS.Net.Socket_Access := AWS.Net.Socket (False);
      Port     : Positive;

      task Accept_Task;
      task body Accept_Task is
         New_Sock : AWS.Net.Socket_Access := AWS.Net.Socket (False);
      begin
         AWS.Net.Accept_Socket (Listener.all, New_Sock.all);
         delay 1.0;   --  hold the connection open for the check
         AWS.Net.Free (New_Sock);
      end Accept_Task;

      NetRec : Soja.Database.Network :=
        Soja.Database.New_Network ("irc+insecure://127.0.0.1:0");
      Net : Network_Access;
      UC  : Upstream_Conn_Access;
   begin
      AWS.Net.Std.Socket_Type (Listener.all).Bind (0, "127.0.0.1");
      AWS.Net.Std.Socket_Type (Listener.all).Listen (1);
      Port := AWS.Net.Std.Socket_Type (Listener.all).Get_Port;
      NetRec.Addr := To_Unbounded_String
        ("irc+insecure://127.0.0.1:" & Positive'Image (Port));

      Net := New_Network
        (U, NetRec, Soja.Database.Channel_Lists.Empty_Vector);
      UC := Connect_To_Upstream (Net);

      if UC = null then
         raise Program_Error with "connectToUpstream returned null";
      end if;
      if UC.Network /= Net or else UC.User /= U then
         raise Program_Error with "upstream network/user not stored";
      end if;
      if UC.Conn = null then
         raise Program_Error with "upstream conn not allocated";
      end if;
      if UC.Server_Prefix = null
        or else To_String (UC.Server_Prefix.Name) /= "*"
      then
         raise Program_Error with "server prefix not initialized";
      end if;
      if To_String (UC.Available_Channel_Types) /=
        Soja.Irc.Members.Std_Channel_Types
      then
         raise Program_Error with "channel types not initialized";
      end if;
      if Natural (UC.Available_Memberships.Length) /=
        Soja.Irc.Members.Std_Memberships'Length
      then
         raise Program_Error with "memberships not initialized";
      end if;
      if not UC.Has_Desired_Nick then
         raise Program_Error with "hasDesiredNick not set";
      end if;

      Soja.Conn.Close (UC.Conn);   --  stop the writer task
      AWS.Net.Free (Listener);
   end;

   Ada.Text_IO.Put_Line ("ALL PASS");
end Upstream_Connect_Check;
