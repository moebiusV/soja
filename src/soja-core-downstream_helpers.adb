pragma Ada_2022;

with Ada.Calendar.Conversions;
with Ada.Containers;
with Ada.Exceptions;
with Ada.Strings.Fixed;

with Soja.Core.Network_Ops;
with Soja.Core.Upstream_Dispatch;
with Soja.Irc.Case_Mapping;
with Soja.Irc.Helpers;
with Soja.Irc.Members;
with Soja.Irc.Xirc;
with Soja.User;
with Soja.Irc.Cap_Registry;
with Soja.Irc.Genmsg;
with Soja.Irc.Numerics;
with Soja.Msgstore;

package body Soja.Core.Downstream_Helpers is

   use Soja.Irc.Cap_Registry;
   use Soja.Irc.Genmsg;
   use Soja.Irc.Messages;
   use type Soja.Msgstore.Store_Access;
   use type Soja.Database.Database_Access;
   use type Ada.Containers.Count_Type;
   use type Soja.Database.Read_Receipt_Access;

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


   ------------------------------------------------------------------
   --  Message IDs (delivery receipts) and channel replay
   ------------------------------------------------------------------

   function Message_Supports_Backlog (M : Message) return Boolean is
      Cmd : constant String := To_String (M.Command);
   begin
      --  Don't replay all messages, because that would mess up client
      --  state.  For instance we just sent the list of users, sending PART
      --  messages for one of these users would be incorrect.
      return Cmd = "PRIVMSG" or else Cmd = "NOTICE";
   end Message_Supports_Backlog;

   procedure Send_Ping (DC : not null Downstream_Conn_Access; Msg_ID : String)
   is
   begin
      Send_Message (DC, Make ("PING", ["soju-msgid-" & Msg_ID]));
   end Send_Ping;

   procedure Send_Message_With_ID
     (DC : not null Downstream_Conn_Access; M : Message; ID : String) is
   begin
      Send_Message (DC, M);

      if ID = "" or else not Message_Supports_Backlog (M)
        or else Is_Enabled (DC.Caps, "draft/chathistory")
      then
         return;
      end if;
      Send_Ping (DC, ID);
   end Send_Message_With_ID;

   procedure Advance_Message_With_ID
     (DC : not null Downstream_Conn_Access; M : Message; ID : String) is
   begin
      if ID = "" or else not Message_Supports_Backlog (M)
        or else Is_Enabled (DC.Caps, "draft/chathistory")
      then
         return;
      end if;
      Send_Ping (DC, ID);
   end Advance_Message_With_ID;

   procedure Ack_Msg_ID (DC : not null Downstream_Conn_Access; ID : String) is
      Net_ID : Long_Long_Integer;
      Entity, Rest : Unbounded_String;
   begin
      Soja.Msgstore.Parse_Msg_ID (ID, Net_ID, Entity, Rest);
      declare
         Network : constant Network_Access :=
           Get_Network_By_ID (DC.User, Net_ID);
      begin
         if Network = null then
            return;
         end if;
         Soja.User.Store_ID
           (Network.Delivered, To_String (Entity),
            To_String (DC.Client_Name), ID);
      end;
   exception
      when E : Soja.Msgstore.Store_Error =>
         DC.Logger.Print
           ("failed to ACK message ID " & Soja.Irc.Helpers.Quote (ID) & ": "
            & Ada.Exceptions.Exception_Message (E));
   end Ack_Msg_ID;

   procedure Handle_Pong
     (DC : not null Downstream_Conn_Access; Token : String)
   is
      Tag : constant String := "soju-msgid-";
   begin
      if Token'Length < Tag'Length
        or else Token (Token'First .. Token'First + Tag'Length - 1) /= Tag
      then
         DC.Logger.Print
           ("received unrecognized PONG token "
            & Soja.Irc.Helpers.Quote (Token));
         return;
      end if;
      Ack_Msg_ID (DC, Token (Token'First + Tag'Length .. Token'Last));
   end Handle_Pong;

   function Unix_Seconds (T : Ada.Calendar.Time) return String is
      N : constant Long_Long_Integer := Long_Long_Integer
        (Ada.Calendar.Conversions.To_Unix_Time_64 (T));
   begin
      return Ada.Strings.Fixed.Trim
        (Long_Long_Integer'Image (N), Ada.Strings.Left);
   end Unix_Seconds;

   procedure Send_Topic
     (DC : not null Downstream_Conn_Access;
      Ch : not null Upstream_Channel_Access)
   is
   begin
      if Length (Ch.Topic) > 0 then
         Send_Message
           (DC, Make (Soja.Irc.Numerics.RPL_TOPIC,
                      [To_String (DC.Nick), To_String (Ch.Name),
                       To_String (Ch.Topic)]));
         if Ch.Topic_Who /= null then
            Send_Message
              (DC, Make (Soja.Irc.Numerics.RPL_TOPICWHOTIME,
                         [To_String (DC.Nick), To_String (Ch.Name),
                          Image (Ch.Topic_Who.all),
                          Unix_Seconds (Ch.Topic_Time)]));
         end if;
      else
         Send_Message
           (DC, Make (Soja.Irc.Numerics.RPL_NOTOPIC,
                      [To_String (DC.Nick), To_String (Ch.Name),
                       "No topic is set"]));
      end if;
   end Send_Topic;

   procedure Send_Names
     (DC : not null Downstream_Conn_Access;
      Ch : not null Upstream_Channel_Access)
   is
      Members : String_Vectors.Vector;
      Multi   : constant Boolean := Is_Enabled (DC.Caps, "multi-prefix");

      procedure Add (Nick : String; Set : Soja.Irc.Members.Membership_Set_Access)
      is
      begin
         Members.Append
           (Soja.Irc.Helpers.Format_Member_Prefix (Set.all, Multi) & Nick);
      end Add;
   begin
      Ch.Members.For_Each (Add'Access);
      for M of Generate_Names_Reply
                 (To_String (Ch.Name), Ch.Status, Members)
      loop
         Send_Message (DC, M);
      end loop;
   end Send_Names;

   procedure Forward_Channel
     (DC : not null Downstream_Conn_Access;
      Ch : not null Upstream_Channel_Access)
   is
      Mark_Read_Cmd : Unbounded_String;
   begin
      if not Ch.Complete then
         raise Program_Error with "Tried to forward a partial channel";
      end if;

      --  RPL_NOTOPIC shouldn't be sent on JOIN.
      if Length (Ch.Topic) > 0 then
         Send_Topic (DC, Ch);
      end if;

      if Is_Enabled (DC.Caps, "draft/read-marker") then
         Mark_Read_Cmd := To_Unbounded_String ("MARKREAD");
      elsif Is_Enabled (DC.Caps, "soju.im/read") then
         Mark_Read_Cmd := To_Unbounded_String ("READ");
      end if;
      if Length (Mark_Read_Cmd) > 0 then
         declare
            Net : constant Network_Access := Ch.Conn.Network;
            DB  : constant Soja.Database.Database_Access :=
              Soja.Server.DB (DC.Srv.all);
            Channel_CM : constant String :=
              Soja.Irc.Case_Mapping.Fold (Net.Casemap, To_String (Ch.Name));
         begin
            if DB /= null then
               declare
                  R : constant Soja.Database.Read_Receipt_Access :=
                    Soja.Database.Get_Read_Receipt
                      (DB.all, Net.Network_Record.ID, Channel_CM);
                  Timestamp : constant String :=
                    (if R = null then "*"
                     else "timestamp="
                          & Soja.Irc.Xirc.Format_Server_Time (R.Timestamp));
                  M : Message := Make
                    (To_String (Mark_Read_Cmd),
                     [To_String (Ch.Name), Timestamp]);
               begin
                  M.Prefix := new Prefix'(Prefix_Of (DC));
                  Send_Message (DC, M);
               end;
            end if;
         exception
            when E : others =>
               DC.Logger.Print
                 ("failed to get the read receipt for "
                  & Soja.Irc.Helpers.Quote (To_String (Ch.Name)) & ": "
                  & Ada.Exceptions.Exception_Message (E));
         end;
      end if;

      if not Is_Enabled (DC.Caps, "soju.im/no-implicit-names")
        and then not Is_Enabled (DC.Caps, "draft/no-implicit-names")
      then
         Send_Names (DC, Ch);
      end if;
   end Forward_Channel;


   ------------------------------------------------------------------
   --  Service notices, batches, backlog
   ------------------------------------------------------------------

   function Service_Prefix return Prefix_Access is
     (new Prefix'(Name => To_Unbounded_String (Service_Nick),
                  User => To_Unbounded_String (Service_Nick),
                  Host => To_Unbounded_String (Service_Nick)));

   procedure Send_Service_Notice
     (DC : not null Downstream_Conn_Access; Text : String)
   is
      M : Message := Make ("NOTICE", [To_String (DC.Nick), Text]);
   begin
      M.Prefix := Service_Prefix;
      Send_Message (DC, M);
   end Send_Service_Notice;

   procedure Send_Service_Privmsg
     (DC : not null Downstream_Conn_Access; Text : String)
   is
      M : Message := Make ("PRIVMSG", [To_String (DC.Nick), Text]);
   begin
      M.Prefix := Service_Prefix;
      Send_Message (DC, M);
   end Send_Service_Privmsg;

   procedure Send_Kicked_Notices (DC : not null Downstream_Conn_Access) is
      procedure Notice (Name : String; Kick : Kick_Info_Access) is
         Reason : constant String := To_String (Kick.Reason);
      begin
         Send_Service_Notice
           (DC,
            "you were kicked from " & Name & " by "
            & To_String (Kick.Kicked_By)
            & (if Reason /= "" then " (" & Reason & ")" else "") & " at "
            & Soja.Irc.Xirc.Format_Server_Time (Kick.At_Time)
            & "; soju does not rejoin automatically, send JOIN " & Name
            & " to rejoin");
      end Notice;
   begin
      if DC.Network /= null then
         DC.Network.Kicked.For_Each (Notice'Access);
      end if;
   end Send_Kicked_Notices;

   procedure Relay_Detached_Message
     (DC  : not null Downstream_Conn_Access;
      Net : not null Network_Access;
      M   : Message)
   is
      Cmd : constant String := To_String (M.Command);
   begin
      if (Cmd /= "PRIVMSG" and then Cmd /= "NOTICE")
        or else M.Params.Length < 2
      then
         return;
      end if;

      declare
         Sender : constant String := To_String (M.Prefix.Name);
         Target : constant String := Param (M, 0);
         Text   : constant String := Param (M, 1);
      begin
         if Soja.Core.Network_Ops.Is_Highlight (Net, M) then
            Send_Service_Notice
              (DC, "highlight in " & Target & ": <" & Sender & "> " & Text);
         else
            Send_Service_Notice
              (DC, "message in " & Target & ": <" & Sender & "> " & Text);
         end if;
      end;
   end Relay_Detached_Message;

   procedure Send_Batch
     (DC      : not null Downstream_Conn_Access;
      Typ     : String;
      Params  : String_Vectors.Vector;
      Process : not null access procedure (Batch_Ref : String);
      Tags    : Tag_Map := (others => <>))
   is
      Ref : Unbounded_String;
   begin
      DC.Last_Batch_Ref := DC.Last_Batch_Ref + 1;
      Ref := To_Unbounded_String
        (Ada.Strings.Fixed.Trim
           (Long_Long_Integer'Image (DC.Last_Batch_Ref), Ada.Strings.Left));

      if Is_Enabled (DC.Caps, "batch") then
         declare
            P : String_Vectors.Vector;
            M : Message;
         begin
            P.Append ("+" & To_String (Ref));
            P.Append (Typ);
            for Item of Params loop
               P.Append (Item);
            end loop;
            M := Make ("BATCH", P);
            M.Tags := Tags;
            Send_Message (DC, M);
         end;
      end if;

      Process (To_String (Ref));

      if Is_Enabled (DC.Caps, "batch") then
         Send_Message (DC, Make ("BATCH", ["-" & To_String (Ref)]));
      end if;
   end Send_Batch;

   procedure Send_Target_Backlog
     (DC     : not null Downstream_Conn_Access;
      Net    : not null Network_Access;
      Target : String;
      Msg_ID : String)
   is
      Ch      : constant Channel_Access := Net.Channels.Get (Target);
      History : Message_Vectors.Vector;
      Options : Soja.Msgstore.Load_Message_Options;

      procedure Replay (Batch_Ref : String) is
      begin
         for M of History loop
            if Ch /= null and then Ch.Detached then
               if Soja.Core.Network_Ops.Detached_Message_Needs_Relay
                    (Net, Ch, M)
               then
                  Relay_Detached_Message (DC, Net, M);
               end if;
            else
               declare
                  Msg : Message := M;
               begin
                  Set_Tag (Msg.Tags, "batch", Batch_Ref);
                  Send_Message (DC, Msg);
               end;
            end if;
         end loop;
      end Replay;
   begin
      if Is_Enabled (DC.Caps, "draft/chathistory")
        or else DC.User.Msg_Store = null
      then
         return;
      end if;

      Options.Network := Net.Network_Record;
      Options.Entity := To_Unbounded_String
        (Soja.Irc.Case_Mapping.Fold (Net.Casemap, Target));
      Options.Limit := Soja.Server.Backlog_Limit;
      begin
         History := DC.User.Msg_Store.Load_Latest_ID (Msg_ID, Options);
      exception
         when E : Soja.Msgstore.Store_Error =>
            DC.Logger.Print
              ("failed to send backlog for "
               & Soja.Irc.Helpers.Quote (Target) & ": "
               & Ada.Exceptions.Exception_Message (E));
            return;
      end;

      Send_Batch (DC, "chathistory", [Target], Replay'Access);
   end Send_Target_Backlog;

end Soja.Core.Downstream_Helpers;
