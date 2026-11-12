pragma Ada_2022;

with Soja.Core.Upstream_Dispatch;
with Soja.Irc.Cap_Registry;
with Soja.Irc.Genmsg;
with Soja.Irc.Numerics;
with Soja.Msgstore;

package body Soja.Core.Downstream_Helpers is

   use Soja.Irc.Cap_Registry;
   use Soja.Irc.Genmsg;
   use Soja.Irc.Messages;
   use type Soja.Msgstore.Store_Access;

   --  database.GetNick(&user, nil) and friends: no network record.
   No_Network : constant Soja.Database.Network := (others => <>);

   ---------------
   -- Prefix_Of --
   ---------------

   function Prefix_Of (DC : not null Downstream_Conn_Access) return Prefix is
   begin
      return (Name => DC.Nick, User => DC.Username, Host => DC.Hostname);
   end Prefix_Of;

   -----------------
   -- Upstream_Of --
   -----------------

   function Upstream_Of (DC : not null Downstream_Conn_Access)
      return Upstream_Conn_Access
   is
   begin
      if DC.Network = null then
         return null;
      end if;
      return DC.Network.Conn;
   end Upstream_Of;

   -----------------------
   -- Set_Supported_Cap --
   -----------------------

   procedure Set_Supported_Cap
     (DC : not null Downstream_Conn_Access; Name, Value : String)
   is
      Has_Prev : constant Boolean := Is_Available (DC.Caps, Name);
      Changed  : constant Boolean :=
        not Has_Prev
        or else Soja.Irc.Cap_Registry.Value (DC.Caps, Name) /= Value;
   begin
      Set_Available (DC.Caps, Name, Value);

      if not Is_Enabled (DC.Caps, "cap-notify") or else not Changed then
         return;
      end if;

      declare
         Cap : constant String :=
           (if Value /= "" and then DC.Cap_Version >= 302
            then Name & "=" & Value else Name);
         M   : Message := Make ("CAP", [To_String (DC.Nick), "NEW", Cap]);
      begin
         M.Prefix := Server_Prefix (DC.Srv);
         Send_Message (DC, M);
      end;
   end Set_Supported_Cap;

   -------------------------
   -- Unset_Supported_Cap --
   -------------------------

   procedure Unset_Supported_Cap
     (DC : not null Downstream_Conn_Access; Name : String)
   is
      Has_Prev : constant Boolean := Is_Available (DC.Caps, Name);
   begin
      Delete (DC.Caps, Name);

      if not Is_Enabled (DC.Caps, "cap-notify") or else not Has_Prev then
         return;
      end if;

      declare
         M : Message := Make ("CAP", [To_String (DC.Nick), "DEL", Name]);
      begin
         M.Prefix := Server_Prefix (DC.Srv);
         Send_Message (DC, M);
      end;
   end Unset_Supported_Cap;

   ---------------------------
   -- Update_Supported_Caps --
   ---------------------------

   --  needAllDownstreamCaps: capabilities that require support from every
   --  upstream to be enabled (each with an empty value).
   Need_All_Downstream_Caps : constant array (1 .. 9) of access constant String
     := [new String'("account-notify"), new String'("account-tag"),
         new String'("away-notify"), new String'("chghost"),
         new String'("extended-join"), new String'("extended-monitor"),
         new String'("message-tags"), new String'("multi-prefix"),
         new String'("draft/extended-monitor")];

   procedure Update_Supported_Caps (DC : not null Downstream_Conn_Access) is
      UC : constant Upstream_Conn_Access := Upstream_Of (DC);
   begin
      --  (dc.forEachUpstream visits at most the network's one connection.)
      for Cap of Need_All_Downstream_Caps loop
         if UC = null or else Is_Enabled (UC.Caps, Cap.all) then
            Set_Supported_Cap (DC, Cap.all, "");
         else
            Unset_Supported_Cap (DC, Cap.all);
         end if;
      end loop;

      if UC /= null
        and then Soja.Core.Upstream_Dispatch.Supports_SASL (UC, "PLAIN")
      then
         Set_Supported_Cap (DC, "sasl", "PLAIN,ANONYMOUS");
      elsif DC.Network /= null then
         Unset_Supported_Cap (DC, "sasl");
      end if;

      if UC /= null
        and then Is_Enabled (UC.Caps, "draft/account-registration")
      then
         --  Strip "before-connect", because we require downstreams to be
         --  fully connected before attempting account registration.
         declare
            Values : constant String :=
              Soja.Irc.Cap_Registry.Value
                (UC.Caps, "draft/account-registration");
            Result : Unbounded_String;
            First  : Positive := Values'First;
            Seen   : Boolean := False;   --  stripped once, like Go
            Emitted : Boolean := False;

            procedure Add (Item : String) is
            begin
               if not Seen and then Item = "before-connect" then
                  Seen := True;
                  return;
               end if;
               if Emitted then
                  Append (Result, ",");
               end if;
               Append (Result, Item);
               Emitted := True;
            end Add;
         begin
            for I in Values'Range loop
               if Values (I) = ',' then
                  Add (Values (First .. I - 1));
                  First := I + 1;
               end if;
            end loop;
            Add (Values (First .. Values'Last));
            Set_Supported_Cap
              (DC, "draft/account-registration", To_String (Result));
         end;
      else
         Unset_Supported_Cap (DC, "draft/account-registration");
      end if;

      if DC.User.Msg_Store /= null
        and then DC.User.Msg_Store.Supports_Chat_History
        and then DC.Network /= null
      then
         Set_Supported_Cap (DC, "draft/event-playback", "");
      else
         Unset_Supported_Cap (DC, "draft/event-playback");
      end if;
   end Update_Supported_Caps;

   -----------------
   -- Update_Nick --
   -----------------

   procedure Update_Nick (DC : not null Downstream_Conn_Access) is
      UC   : constant Upstream_Conn_Access := Upstream_Of (DC);
      Nick : constant String :=
        (if UC /= null then To_String (UC.Nick)
         elsif DC.Network /= null then
           Soja.Database.Get_Nick
             (DC.User.User_Record, DC.Network.Network_Record)
         else Soja.Database.Get_Nick (DC.User.User_Record, No_Network));
      M    : Message;
   begin
      if Nick = To_String (DC.Nick) then
         return;
      end if;

      M := Make ("NICK", [Nick]);
      M.Prefix := new Prefix'(Prefix_Of (DC));
      Send_Message (DC, M);
      DC.Nick := To_Unbounded_String (Nick);
      DC.Nick_CM := To_Unbounded_String
        (Soja.Irc.Case_Mapping.Fold (DC.Casemap, Nick));
   end Update_Nick;

   -----------------
   -- Update_Host --
   -----------------

   procedure Update_Host (DC : not null Downstream_Conn_Access) is
      UC : constant Upstream_Conn_Access := Upstream_Of (DC);
   begin
      if UC = null or else Length (UC.Hostname) = 0 then
         return;
      end if;
      if UC.Hostname = DC.Hostname and then UC.Username = DC.Username then
         return;
      end if;

      if Is_Enabled (DC.Caps, "chghost") then
         declare
            M : Message := Make
              ("CHGHOST", [To_String (UC.Username), To_String (UC.Hostname)]);
         begin
            M.Prefix := new Prefix'(Prefix_Of (DC));
            Send_Message (DC, M);
         end;
      elsif UC.Hostname /= DC.Hostname then
         declare
            M : Message := Make
              (Soja.Irc.Numerics.RPL_VISIBLEHOST,
               [To_String (DC.Nick), To_String (UC.Hostname),
                "is now your visible host"]);
         begin
            M.Prefix := new Prefix'(Prefix_Of (DC));
            Send_Message (DC, M);
         end;
      end if;

      DC.Hostname := UC.Hostname;
      DC.Username := UC.Username;
   end Update_Host;

   ---------------------
   -- Update_Realname --
   ---------------------

   procedure Update_Realname (DC : not null Downstream_Conn_Access) is
      UC : constant Upstream_Conn_Access := Upstream_Of (DC);
   begin
      if not Is_Enabled (DC.Caps, "setname") then
         return;
      end if;

      declare
         Realname : constant String :=
           (if UC /= null then To_String (UC.Realname)
            elsif DC.Network /= null then
              Soja.Database.Get_Realname
                (DC.User.User_Record, DC.Network.Network_Record)
            else Soja.Database.Get_Realname
                   (DC.User.User_Record, No_Network));
      begin
         if Realname /= To_String (DC.Realname) then
            declare
               M : Message := Make ("SETNAME", [Realname]);
            begin
               M.Prefix := new Prefix'(Prefix_Of (DC));
               Send_Message (DC, M);
            end;
            DC.Realname := To_Unbounded_String (Realname);
         end if;
      end;
   end Update_Realname;

   --------------------
   -- Update_Account --
   --------------------

   procedure Update_Account (DC : not null Downstream_Conn_Access) is
      UC      : constant Upstream_Conn_Access := Upstream_Of (DC);
      Account : Unbounded_String;
   begin
      if DC.Network = null then
         Account := DC.User.User_Record.Username;
      elsif UC /= null then
         Account := UC.Account;
      else
         return;
      end if;

      if DC.Account = Account or else not Is_Enabled (DC.Caps, "sasl") then
         return;
      end if;

      if Length (Account) > 0 then
         Send_Message
           (DC, Make (Soja.Irc.Numerics.RPL_LOGGEDIN,
                      [To_String (DC.Nick), Image (Prefix_Of (DC)),
                       To_String (Account),
                       "You are logged in as " & To_String (Account)]));
      else
         Send_Message
           (DC, Make (Soja.Irc.Numerics.RPL_LOGGEDOUT,
                      [To_String (DC.Nick), Image (Prefix_Of (DC)),
                       "You are logged out"]));
      end if;

      DC.Account := Account;
   end Update_Account;

   --------------
   -- End_SASL --
   --------------

   procedure End_SASL
     (DC : not null Downstream_Conn_Access; M : Message) is
   begin
      if DC.Sasl = null then
         return;
      end if;
      DC.Sasl := null;
      Send_Message (DC, M);
   end End_SASL;

   procedure End_SASL (DC : not null Downstream_Conn_Access) is
   begin
      End_SASL
        (DC, Make (Soja.Irc.Numerics.RPL_SASLSUCCESS,
                   [To_String (DC.Nick), "SASL authentication successful"]));
   end End_SASL;

end Soja.Core.Downstream_Helpers;
