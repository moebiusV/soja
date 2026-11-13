pragma Ada_2022;

with Ada.Containers;
with Ada.Exceptions;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;

with Soja.Core.Downstream_Handshake;
with Soja.Core.Downstream_Helpers;
with Soja.Core.Network_Ops;
with Soja.Core.Upstream_Dispatch;
with Soja.Core.User_Ops;
with Soja.Database;
with Soja.Downstream;
with Soja.Irc.Case_Mapping;
with Soja.Irc.Cap_Registry;
with Soja.Irc.Genmsg;
with Soja.Irc.Helpers;
with Soja.Irc.Modes;
with Soja.Irc.Members;
with Soja.Irc.Numerics;
with Soja.Irc.Whox;
with Soja.Server;

package body Soja.Core.Downstream_Commands is

   use Ada.Strings.Unbounded;
   use Soja.Core.Downstream_Helpers;
   use Soja.Irc.Genmsg;
   use Soja.Irc.Helpers;
   use Soja.Irc.Messages;
   use Soja.Irc.Numerics;
   use type Soja.Database.Database_Access;
   use type Ada.Containers.Count_Type;
   use type Soja.Irc.Members.Membership_Set_Access;

   ----------------------------------------------------------------------
   --  Results and small helpers
   ----------------------------------------------------------------------

   Success : constant Irc_Error_Result := (Failed => False);

   function IRC_Fail
     (Command : String; Params : String_Vectors.Vector)
      return Irc_Error_Result is
     (Failed => True, Is_IRC => True,
      Err    => (Message => Make (Command, Params)),
      Text   => Null_Unbounded_String);

   function From_Error (E : Soja.Downstream.Irc_Error) return Irc_Error_Result
   is (Failed => True, Is_IRC => True, Err => E,
       Text   => Null_Unbounded_String);

   function Need_More (R : Params_Result) return Irc_Error_Result is
     (From_Error (R.Err));

   function Nick_Of (DC : not null Downstream_Conn_Access) return String is
     (To_String (DC.Nick));

   function Fold (DC : not null Downstream_Conn_Access; S : String)
      return String is (Soja.Irc.Case_Mapping.Fold (DC.Casemap, S));

   function DB_Of (DC : not null Downstream_Conn_Access)
      return Soja.Database.Database_Access
   is (Soja.Server.DB (DC.Srv.all));

   --  illegalNickChars and illegalChanChars.
   function Has_Illegal_Nick_Char (S : String) return Boolean is
     (for some C of S => Ada.Strings.Fixed.Index (" :@!*?$,.", [1 => C]) > 0);
   function Has_Illegal_Chan_Char (S : String) return Boolean is
     (for some C of S =>
        C = ' ' or else C = ',' or else C = ASCII.BEL);

   --  dc.upstreamForCommand.
   function Upstream_For_Command
     (DC  : not null Downstream_Conn_Access;
      Cmd : String;
      UC  : out Upstream_Conn_Access) return Irc_Error_Result
   is
   begin
      UC := null;
      if DC.Network = null then
         return From_Error
           (Soja.Downstream.New_Unknown_Irc_Error
              (Cmd, "Cannot interact with channels and users on the bouncer "
                    & "connection. Did you mean to use a specific network?"));
      end if;
      if DC.Network.Conn = null then
         return From_Error
           (Soja.Downstream.New_Unknown_Irc_Error
              (Cmd, "Disconnected from upstream network"));
      end if;
      UC := DC.Network.Conn;
      return Success;
   end Upstream_For_Command;

   --  uc.SendMessageLabeled(ctx, dc.id, msg)
   procedure Relay
     (UC : not null Upstream_Conn_Access;
      DC : not null Downstream_Conn_Access;
      M  : Message) is
   begin
      Soja.Core.Upstream_Dispatch.Send_Message_Labeled (UC, DC.ID, M);
   end Relay;

   procedure Store_Channel_Quietly
     (DC   : not null Downstream_Conn_Access;
      Net  : not null Network_Access;
      Ch   : not null Channel_Access;
      Name : String)
   is
      DB : constant Soja.Database.Database_Access := DB_Of (DC);
   begin
      if DB /= null then
         Soja.Database.Store_Channel (DB.all, Net.Network_Record.ID, Ch.all);
      end if;
   exception
      when E : Soja.Database.Database_Error =>
         DC.Logger.Print
           ("failed to create or update channel " & Quote (Name) & ": "
            & Ada.Exceptions.Exception_Message (E));
   end Store_Channel_Quietly;

   ----------------------------------------------------------------------
   --  PING, PONG, USER, NICK, SETNAME
   ----------------------------------------------------------------------

   function Cmd_Ping
     (DC : not null Downstream_Conn_Access; M : Message)
      return Irc_Error_Result
   is
      PR : constant Params_Result := Parse_Message_Params (M, 1);
   begin
      if not PR.Ok then
         return Need_More (PR);
      end if;
      declare
         Host        : constant String :=
           To_String (Soja.Server.Config (DC.Srv.all).Hostname);
         Destination : constant String :=
           (if M.Params.Length > 1 then Param (M, 1) else "");
         Reply       : Message;
      begin
         if Destination /= "" and then Destination /= Host then
            return IRC_Fail
              (ERR_NOSUCHSERVER, [Nick_Of (DC), Destination, "No such server"]);
         end if;
         Reply := Make ("PONG", [Host, Param (M, 0)]);
         Reply.Prefix := Server_Prefix (DC.Srv);
         Send_Message (DC, Reply);
      end;
      return Success;
   end Cmd_Ping;

   function Cmd_Pong
     (DC : not null Downstream_Conn_Access; M : Message)
      return Irc_Error_Result is
   begin
      if M.Params.Is_Empty then
         return From_Error
           (Soja.Downstream.New_Need_More_Params_Error
              (To_String (M.Command)));
      end if;
      Handle_Pong (DC, Trailing (M));
      return Success;
   end Cmd_Pong;

   function Cmd_Nick
     (DC : not null Downstream_Conn_Access; M : Message)
      return Irc_Error_Result
   is
      PR : constant Params_Result := Parse_Message_Params (M, 1);
   begin
      if not PR.Ok then
         return Need_More (PR);
      end if;

      declare
         Nick : constant String := Param (M, 0);
         DB   : constant Soja.Database.Database_Access := DB_Of (DC);
         Failed : Boolean := False;

         procedure Set_Nick (Rec : in out Soja.Database.User) is
         begin
            Rec.Nick := To_Unbounded_String (Nick);
         end Set_Nick;
      begin
         if Nick = "" or else Has_Illegal_Nick_Char (Nick) then
            return IRC_Fail
              (ERR_ERRONEUSNICKNAME,
               [Nick_Of (DC), Nick, "Nickname contains illegal characters"]);
         end if;
         if Fold (DC, Nick) = Service_Nick_CM then
            return IRC_Fail
              (ERR_NICKNAMEINUSE,
               [Nick_Of (DC), Nick, "Nickname reserved for bouncer service"]);
         end if;

         begin
            if DC.Network /= null then
               declare
                  Rec : Soja.Database.Network := DC.Network.Network_Record;
               begin
                  Rec.Nick := To_Unbounded_String (Nick);
                  if DB /= null then
                     Soja.Database.Store_Network
                       (DB.all, DC.User.User_Record.ID, Rec);
                  end if;
               end;
            else
               Soja.Core.User_Ops.Update_User (DC.User, Set_Nick'Access);
            end if;
         exception
            when E : Soja.Database.Database_Error
                   | Soja.Core.User_Ops.Operation_Error =>
               DC.Logger.Print
                 ("failed to update nick: "
                  & Ada.Exceptions.Exception_Message (E));
               Failed := True;
         end;
         if Failed then
            return IRC_Fail
              (ERR_UNKNOWNERROR,
               [Nick_Of (DC), "NICK", "Failed to update nick"]);
         end if;

         if DC.Network /= null then
            DC.Network.Network_Record.Nick := To_Unbounded_String (Nick);
            declare
               UC : constant Upstream_Conn_Access := Upstream_Of (DC);
            begin
               if UC /= null then
                  Relay (UC, DC, Make ("NICK", [Nick]));
               else
                  Update_Nick (DC);
               end if;
            end;
         else
            for C of DC.User.Downstream_Conns loop
               if C.Network = null then
                  Update_Nick (C);
               end if;
            end loop;
         end if;
      end;
      return Success;
   end Cmd_Nick;

   function Cmd_Setname
     (DC : not null Downstream_Conn_Access; M : Message)
      return Irc_Error_Result
   is
      PR : constant Params_Result := Parse_Message_Params (M, 1);
   begin
      if not PR.Ok then
         return Need_More (PR);
      end if;

      declare
         Realname : constant String := Param (M, 0);
         DB       : constant Soja.Database.Database_Access := DB_Of (DC);
         Failed   : Boolean := False;

         procedure Set_Realname (Rec : in out Soja.Database.User) is
         begin
            Rec.Realname := To_Unbounded_String (Realname);
         end Set_Realname;
      begin
         if To_String (DC.Realname) = Realname then
            declare
               Reply : Message := Make ("SETNAME", [Realname]);
            begin
               Reply.Prefix := new Prefix'(Prefix_Of (DC));
               Send_Message (DC, Reply);
            end;
            return Success;
         end if;

         begin
            if DC.Network /= null then
               --  If the client just resets to the default, wipe the
               --  per-network preference.
               declare
                  Rec : Soja.Database.Network := DC.Network.Network_Record;
                  UC  : constant Upstream_Conn_Access := Upstream_Of (DC);
               begin
                  Rec.Realname := To_Unbounded_String (Realname);
                  if Rec.Realname = DC.User.User_Record.Realname then
                     Rec.Realname := Null_Unbounded_String;
                  end if;

                  if UC /= null
                    and then Soja.Irc.Cap_Registry.Is_Enabled
                               (UC.Caps, "setname")
                  then
                     --  Upstream will reply with a SETNAME on success.
                     Relay (UC, DC, Make ("SETNAME", [Realname]));
                     if DB /= null then
                        Soja.Database.Store_Network
                          (DB.all, DC.User.User_Record.ID, Rec);
                     end if;
                  else
                     --  This disconnects then re-connects the upstream.
                     declare
                        Ignored : constant Network_Access :=
                          Soja.Core.User_Ops.Update_Network (DC.User, Rec);
                        pragma Unreferenced (Ignored);
                     begin
                        null;
                     end;
                  end if;
               end;
            else
               Soja.Core.User_Ops.Update_User (DC.User, Set_Realname'Access);
            end if;
         exception
            when E : Soja.Database.Database_Error
                   | Soja.Core.User_Ops.Operation_Error =>
               DC.Logger.Print
                 ("failed to update realname: "
                  & Ada.Exceptions.Exception_Message (E));
               Failed := True;
         end;
         if Failed then
            return IRC_Fail
              ("FAIL", ["SETNAME", "CANNOT_CHANGE_REALNAME",
                        "Failed to update realname"]);
         end if;

         if DC.Network = null then
            for C of DC.User.Downstream_Conns loop
               if C.Network = null then
                  Update_Realname (C);
               end if;
            end loop;
         end if;
      end;
      return Success;
   end Cmd_Setname;

   ----------------------------------------------------------------------
   --  JOIN, PART, KICK
   ----------------------------------------------------------------------

   function Cmd_Join
     (DC : not null Downstream_Conn_Access; M : Message)
      return Irc_Error_Result
   is
      UC : Upstream_Conn_Access;
      R  : Irc_Error_Result := Upstream_For_Command (DC, "JOIN", UC);
      PR : Params_Result;
   begin
      if R.Failed then
         return R;
      end if;
      PR := Parse_Message_Params (M, 1);
      if not PR.Ok then
         return Need_More (PR);
      end if;

      declare
         Names : constant String_Vectors.Vector := Split_Commas (Param (M, 0));
         Keys  : constant String_Vectors.Vector :=
           (if M.Params.Length > 1 then Split_Commas (Param (M, 1))
            else String_Vectors.Empty_Vector);
         Net   : constant Network_Access := UC.Network;
      begin
         for I in 1 .. Natural (Names.Length) loop
            declare
               Name : constant String := Names (I);
               Key  : constant String :=
                 (if Natural (Keys.Length) >= I then Keys (I) else "");
            begin
               if Name = "" or else Has_Illegal_Chan_Char (Name) then
                  Send_Message
                    (DC, Make (ERR_BADCHANMASK, [Name, "Invalid channel name"]));
               elsif not Soja.Core.Upstream_Dispatch.Is_Channel (UC, Name) then
                  Send_Message
                    (DC, Make (ERR_NOSUCHCHANNEL, [Name, "Not a channel name"]));
               else
                  --  Most servers ignore duplicate JOIN messages.  We ignore
                  --  them here because some clients send JOINs in bulk when
                  --  reconnecting to the bouncer, and we don't want to flood
                  --  the upstream connection with these.
                  if not UC.Channels.Has (Name) then
                     Relay (UC, DC,
                            (if Key /= "" then Make ("JOIN", [Name, Key])
                             else Make ("JOIN", [Name])));
                  end if;

                  declare
                     Ch : Channel_Access := Net.Channels.Get (Name);
                  begin
                     if Ch /= null then
                        --  Don't clear the channel key if there's one set.
                        --  TODO (Go): add a way to unset the channel key.
                        if Key /= "" then
                           Ch.Key := To_Unbounded_String (Key);
                        end if;
                        Soja.Core.Network_Ops.Attach (Net, Ch);
                     else
                        Ch := new Soja.Database.Channel'
                          (Name => To_Unbounded_String (Name),
                           Key  => To_Unbounded_String (Key),
                           others => <>);
                        Net.Channels.Set (Name, Ch);
                     end if;
                     Store_Channel_Quietly (DC, Net, Ch, Name);
                  end;
               end if;
            end;
         end loop;
      end;
      return Success;
   end Cmd_Join;

   function Cmd_Part
     (DC : not null Downstream_Conn_Access; M : Message)
      return Irc_Error_Result
   is
      UC : Upstream_Conn_Access;
      R  : Irc_Error_Result := Upstream_For_Command (DC, "PART", UC);
      PR : Params_Result;
   begin
      if R.Failed then
         return R;
      end if;
      PR := Parse_Message_Params (M, 1);
      if not PR.Ok then
         return Need_More (PR);
      end if;

      declare
         Reason : constant String :=
           (if M.Params.Length > 1 then Param (M, 1) else "");
         Net    : constant Network_Access := UC.Network;
      begin
         for Name of Split_Commas (Param (M, 0)) loop
            if Lower (Reason) = "detach" then
               declare
                  Ch : Channel_Access := Net.Channels.Get (Name);
               begin
                  if Ch /= null then
                     Soja.Core.Network_Ops.Detach (Net, Ch);
                  else
                     Ch := new Soja.Database.Channel'
                       (Name => To_Unbounded_String (Name), Detached => True,
                        others => <>);
                     Net.Channels.Set (Name, Ch);
                  end if;
                  Store_Channel_Quietly (DC, Net, Ch, Name);
               end;
            else
               Relay (UC, DC,
                      (if Reason /= "" then Make ("PART", [Name, Reason])
                       else Make ("PART", [Name])));

               begin
                  Soja.Core.Network_Ops.Delete_Channel (Net, Name);
               exception
                  when E : Soja.Core.User_Ops.Operation_Error =>
                     DC.Logger.Print
                       ("failed to delete channel " & Quote (Name) & ": "
                        & Ada.Exceptions.Exception_Message (E));
               end;

               --  The channel is gone for good: nothing to retry, and a kick
               --  we were staying out of no longer matters.
               Soja.Core.Upstream_Dispatch.Cancel_Join_Retry (UC, Name);
               Clear_Kick (Net, Name);
               Net.Push_Targets.Del (Name);
            end if;
         end loop;
      end;
      return Success;
   end Cmd_Part;

   function Cmd_Kick
     (DC : not null Downstream_Conn_Access; M : Message)
      return Irc_Error_Result
   is
      UC : Upstream_Conn_Access;
      R  : constant Irc_Error_Result := Upstream_For_Command (DC, "KICK", UC);
   begin
      if R.Failed then
         return R;
      end if;
      Relay (UC, DC, M);
      return Success;
   end Cmd_Kick;

   ----------------------------------------------------------------------
   --  MODE, TOPIC, LIST, NAMES
   ----------------------------------------------------------------------

   function Cmd_Mode
     (DC : not null Downstream_Conn_Access; M : Message)
      return Irc_Error_Result
   is
      PR : constant Params_Result := Parse_Message_Params (M, 1);
   begin
      if not PR.Ok then
         return Need_More (PR);
      end if;

      declare
         Name     : constant String := Param (M, 0);
         Mode_Str : constant String :=
           (if M.Params.Length > 1 then Param (M, 1) else "");
         UC       : Upstream_Conn_Access;
         R        : Irc_Error_Result;
      begin
         if Fold (DC, Name) = To_String (DC.Nick_CM) then
            --  A query or change of our own user modes.
            if Mode_Str /= "" then
               R := Upstream_For_Command (DC, "MODE", UC);
               if R.Failed then
                  return R;
               end if;
               Relay (UC, DC, M);
            else
               declare
                  Up : constant Upstream_Conn_Access := Upstream_Of (DC);
               begin
                  Send_Message
                    (DC, Make (RPL_UMODEIS,
                               [Nick_Of (DC),
                                "+" & (if Up /= null
                                       then To_String (Up.Modes.Value)
                                       else "")]));
               end;
            end if;
            return Success;
         end if;

         R := Upstream_For_Command (DC, "MODE", UC);
         if R.Failed then
            return R;
         end if;

         if not Soja.Core.Upstream_Dispatch.Is_Channel (UC, Name) then
            return IRC_Fail
              (ERR_USERSDONTMATCH,
               [Nick_Of (DC), "Cannot change mode for other users"]);
         end if;

         if Mode_Str /= "" then
            declare
               P : String_Vectors.Vector;
            begin
               P.Append (Name);
               P.Append (Mode_Str);
               for I in 3 .. Natural (M.Params.Length) loop
                  P.Append (To_String (M.Params (I)));
               end loop;
               Relay (UC, DC, Make ("MODE", P));
            end;
         else
            declare
               Ch : constant Upstream_Channel_Access := UC.Channels.Get (Name);
            begin
               if Ch = null then
                  --  We're not on that channel: pass the command upstream.
                  Relay (UC, DC, M);
                  return Success;
               end if;

               if not Ch.Modes.Known then
                  --  We haven't received the initial RPL_CHANNELMODEIS yet:
                  --  ignore the request; the modes are broadcast when it
                  --  arrives.
                  return Success;
               end if;

               declare
                  Mode_String : Unbounded_String;
                  Mode_Params : Param_Vectors.Vector;
                  P           : String_Vectors.Vector;
               begin
                  Soja.Irc.Modes.Format (Ch.Modes, Mode_String, Mode_Params);
                  P.Append (Nick_Of (DC));
                  P.Append (Name);
                  P.Append (To_String (Mode_String));
                  for Item of Mode_Params loop
                     P.Append (To_String (Item));
                  end loop;
                  Send_Message (DC, Make (RPL_CHANNELMODEIS, P));
               end;
               if Length (Ch.Creation_Time) > 0 then
                  Send_Message
                    (DC, Make (RPL_CREATIONTIME,
                               [Nick_Of (DC), Name,
                                To_String (Ch.Creation_Time)]));
               end if;
            end;
         end if;
      end;
      return Success;
   end Cmd_Mode;

   function Cmd_Topic
     (DC : not null Downstream_Conn_Access; M : Message)
      return Irc_Error_Result
   is
      PR : constant Params_Result := Parse_Message_Params (M, 1);
      UC : Upstream_Conn_Access;
      R  : Irc_Error_Result;
   begin
      if not PR.Ok then
         return Need_More (PR);
      end if;
      R := Upstream_For_Command (DC, "TOPIC", UC);
      if R.Failed then
         return R;
      end if;

      declare
         Name : constant String := Param (M, 0);
      begin
         if M.Params.Length > 1 then   --  setting the topic
            Relay (UC, DC, Make ("TOPIC", [Name, Param (M, 1)]));
         else                          --  getting it
            declare
               Ch : constant Upstream_Channel_Access := UC.Channels.Get (Name);
            begin
               if Ch = null then
                  --  We're not on that channel: pass the command upstream.
                  Relay (UC, DC, M);
               else
                  Send_Topic (DC, Ch);
               end if;
            end;
         end if;
      end;
      return Success;
   end Cmd_Topic;

   function Cmd_List
     (DC : not null Downstream_Conn_Access; M : Message)
      return Irc_Error_Result
   is
      UC : Upstream_Conn_Access;
      R  : constant Irc_Error_Result := Upstream_For_Command (DC, "LIST", UC);
   begin
      if R.Failed then
         return R;
      end if;
      Soja.Core.Upstream_Dispatch.Enqueue_Command (UC, DC, M);
      return Success;
   end Cmd_List;

   function Cmd_Names
     (DC : not null Downstream_Conn_Access; M : Message)
      return Irc_Error_Result
   is
      UC : Upstream_Conn_Access;
      R  : constant Irc_Error_Result := Upstream_For_Command (DC, "NAMES", UC);
   begin
      if R.Failed then
         return R;
      end if;

      if M.Params.Is_Empty then
         Send_Message
           (DC, Make (RPL_ENDOFNAMES, [Nick_Of (DC), "*", "End of /NAMES list"]));
         return Success;
      end if;

      for Name of Split_Commas (Param (M, 0)) loop
         declare
            Ch : constant Upstream_Channel_Access := UC.Channels.Get (Name);
         begin
            if Ch /= null then
               Send_Names (DC, Ch);
            else
               --  NAMES on a channel we have not joined: ask the upstream.
               Relay (UC, DC, Make ("NAMES", [Name]));
            end if;
         end;
      end loop;
      return Success;
   end Cmd_Names;

   ----------------------------------------------------------------------
   --  WHO, WHOIS
   ----------------------------------------------------------------------

   function Cmd_Who
     (DC : not null Downstream_Conn_Access; M : Message)
      return Irc_Error_Result
   is
      function End_Of_Who (Token : String) return Message is
        (Make (RPL_ENDOFWHO, ["*", Token, "End of /WHO list"]));
   begin
      if M.Params.Is_Empty then
         Send_Message (DC, End_Of_Who ("*"));
         return Success;
      end if;

      declare
         --  Clients use the first mask to match RPL_ENDOFWHO.
         Mask    : constant String := Param (M, 0);
         Options : constant String :=
           (if M.Params.Length > 1 then Param (M, 1) else "");
         Fields_U, Token_U : Unbounded_String;
      begin
         --  TODO (Go): add support for WHOX mask2.
         Soja.Irc.Whox.Parse_Whox_Options (Options, Fields_U, Token_U);

         declare
            Fields  : constant String := To_String (Fields_U);
            Mask_CM : constant String := Fold (DC, Mask);
            Info    : Soja.Irc.Whox.Whox_Info;
            Cfg     : constant Soja.Server.Server_Config_Access :=
              Soja.Server.Config (DC.Srv.all);
         begin
            --  TODO (Go): support mixed bouncer/upstream WHO queries.
            if DC.Network = null and then Mask_CM = To_String (DC.Nick_CM) then
               --  TODO (Go): support AWAY (H/G) in the self WHO reply.
               Info.Token := Token_U;
               Info.Username := DC.User.User_Record.Username;
               Info.Hostname := DC.Hostname;
               Info.Server := Cfg.Hostname;
               Info.Nickname := DC.Nick;
               Info.Flags := To_Unbounded_String
                 (if DC.User.User_Record.Admin then "H*" else "H");
               Info.Account := DC.User.User_Record.Username;
               Info.Realname := DC.Realname;
               Send_Message
                 (DC, Soja.Irc.Whox.Generate_Whox_Reply (Fields, Info));
               Send_Message (DC, End_Of_Who (Mask));
               return Success;
            end if;

            if Mask_CM = Service_Nick_CM then
               declare
                  Flags : Unbounded_String := To_Unbounded_String ("H*");
                  Up    : constant Upstream_Conn_Access := Upstream_Of (DC);
               begin
                  if DC.Network = null then
                     Append (Flags, "B");
                  elsif Up /= null and then Up.Isupport.Contains ("BOT")
                    and then Up.Isupport ("BOT").Has_Value
                    and then Length (Up.Isupport ("BOT").Value) = 1
                  then
                     Append (Flags, Up.Isupport ("BOT").Value);
                  end if;
                  Info.Token := Token_U;
                  Info.Username := To_Unbounded_String (Service_Nick);
                  Info.Hostname := To_Unbounded_String (Service_Nick);
                  Info.Server := Cfg.Hostname;
                  Info.Nickname := To_Unbounded_String (Service_Nick);
                  Info.Flags := Flags;
                  Info.Account := To_Unbounded_String (Service_Nick);
                  Info.Realname := To_Unbounded_String (Service_Realname);
               end;
               Send_Message
                 (DC, Soja.Irc.Whox.Generate_Whox_Reply (Fields, Info));
               Send_Message (DC, End_Of_Who (Mask));
               return Success;
            end if;

            if DC.Network = null then
               Send_Message (DC, End_Of_Who (Mask));
               return Success;
            end if;

            declare
               UC : Upstream_Conn_Access;
               R  : constant Irc_Error_Result :=
                 Upstream_For_Command (DC, "WHO", UC);
            begin
               if R.Failed then
                  return R;
               end if;

               --  Check if we have the reply cached.
               declare
                  Cached : constant Soja.Core.Upstream_Dispatch.Cached_Who :=
                    Soja.Core.Upstream_Dispatch.Get_Cached_Who
                      (UC, Mask, Fields);
               begin
                  if Cached.Found then
                     for Uu of Cached.Users loop
                        declare
                           W : Soja.Irc.Whox.Whox_Info;
                        begin
                           W.Token := Token_U;
                           W.Username := Uu.Username;
                           W.Hostname := Uu.Hostname;
                           W.Server := Uu.Server;
                           W.Nickname := Uu.Nickname;
                           W.Flags := Uu.Flags;
                           W.Account := Uu.Account;
                           W.Realname := Uu.Realname;

                           if Soja.Core.Upstream_Dispatch.Is_Channel
                                (UC, Mask)
                           then
                              W.Channel := To_Unbounded_String (Mask);

                              --  Channel membership prefixes from the cached
                              --  NAMES reply, listed after the away status
                              --  ('G'/'H') and the operator indicator ('*').
                              declare
                                 Ch : constant Upstream_Channel_Access :=
                                   UC.Channels.Get (Mask);
                                 Set : constant
                                   Soja.Irc.Members.Membership_Set_Access :=
                                   (if Ch = null then null
                                    else Ch.Members.Get
                                           (To_String (W.Nickname)));
                                 Prefixes : constant String :=
                                   (if Set = null then ""
                                    else Format_Member_Prefix
                                           (Set.all,
                                            Soja.Irc.Cap_Registry.Is_Enabled
                                              (DC.Caps, "multi-prefix")));
                                 Flags : constant String :=
                                   To_String (W.Flags);
                                 I : Natural := 0;
                              begin
                                 for K in Flags'Range loop
                                    if Flags (K) /= 'G'
                                      and then Flags (K) /= 'H'
                                      and then Flags (K) /= '*'
                                    then
                                       I := K;
                                       exit;
                                    end if;
                                 end loop;
                                 if I = 0 then
                                    W.Flags := To_Unbounded_String
                                      (Flags & Prefixes);
                                 else
                                    W.Flags := To_Unbounded_String
                                      (Flags (Flags'First .. I - 1) & Prefixes
                                       & Flags (I .. Flags'Last));
                                 end if;
                              end;
                           end if;
                           Send_Message
                             (DC, Soja.Irc.Whox.Generate_Whox_Reply
                                    (Fields, W));
                        end;
                     end loop;
                     Send_Message (DC, End_Of_Who (Mask));
                     return Success;
                  end if;
               end;

               Soja.Core.Upstream_Dispatch.Enqueue_Command (UC, DC, M);
            end;
         end;
      end;
      return Success;
   end Cmd_Who;

   function Cmd_Whois
     (DC : not null Downstream_Conn_Access; M : Message)
      return Irc_Error_Result
   is
      Nick : constant String := Nick_Of (DC);
      Cfg  : constant Soja.Server.Server_Config_Access :=
        Soja.Server.Config (DC.Srv.all);
   begin
      if M.Params.Is_Empty then
         return IRC_Fail (ERR_NONICKNAMEGIVEN, [Nick, "No nickname given"]);
      end if;

      declare
         Raw  : constant String :=
           (if M.Params.Length = 1 then Param (M, 0) else Param (M, 1));
         Comma : constant Natural := Ada.Strings.Fixed.Index (Raw, ",");
         --  TODO (Go): support multiple WHOIS users.
         Mask : constant String :=
           (if Comma > 0 then Raw (Raw'First .. Comma - 1) else Raw);
         Host : constant String := To_String (Cfg.Hostname);
      begin
         if DC.Network = null
           and then Fold (DC, Mask) = To_String (DC.Nick_CM)
         then
            Send_Message
              (DC, Make (RPL_WHOISUSER,
                         [Nick, Nick, To_String (DC.User.User_Record.Username),
                          To_String (DC.Hostname), "*",
                          To_String (DC.Realname)]));
            Send_Message
              (DC, Make (RPL_WHOISSERVER, [Nick, Nick, Host, "soju"]));
            if DC.User.User_Record.Admin then
               Send_Message
                 (DC, Make (RPL_WHOISOPERATOR,
                            [Nick, Nick, "is a bouncer administrator"]));
            end if;
            Send_Message
              (DC, Make (RPL_WHOISACCOUNT,
                         [Nick, Nick,
                          To_String (DC.User.User_Record.Username),
                          "is logged in as"]));
            Send_Message
              (DC, Make (RPL_ENDOFWHOIS, [Nick, Nick, "End of /WHOIS list"]));
            return Success;
         end if;

         if Fold (DC, Mask) = Service_Nick_CM then
            Send_Message
              (DC, Make (RPL_WHOISUSER,
                         [Nick, Service_Nick, Service_Nick, Service_Nick, "*",
                          Service_Realname]));
            Send_Message
              (DC, Make (RPL_WHOISSERVER,
                         [Nick, Service_Nick, Host, "soju"]));
            Send_Message
              (DC, Make (RPL_WHOISOPERATOR,
                         [Nick, Service_Nick, "is the bouncer service"]));
            Send_Message
              (DC, Make (RPL_WHOISACCOUNT,
                         [Nick, Service_Nick, Service_Nick, "is logged in as"]));
            Send_Message
              (DC, Make (RPL_WHOISBOT, [Nick, Service_Nick, "is a bot"]));
            Send_Message
              (DC, Make (RPL_ENDOFWHOIS,
                         [Nick, Service_Nick, "End of /WHOIS list"]));
            return Success;
         end if;
      end;

      declare
         UC : Upstream_Conn_Access;
         R  : constant Irc_Error_Result :=
           Upstream_For_Command (DC, "WHOIS", UC);
      begin
         if R.Failed then
            return R;
         end if;
         Soja.Core.Upstream_Dispatch.Enqueue_Command (UC, DC, M);
      end;
      return Success;
   end Cmd_Whois;

   ----------------------------------------------------------------------
   --  The dispatch
   ----------------------------------------------------------------------

   function Handle_Message_Registered
     (DC : not null Downstream_Conn_Access; M : Message)
      return Irc_Error_Result
   is
      Cmd : constant String := To_String (M.Command);
   begin
      if Cmd = "CAP" then
         return Soja.Core.Downstream_Handshake.Handle_Cap (DC, M);
      elsif Cmd = "PING" then
         return Cmd_Ping (DC, M);
      elsif Cmd = "PONG" then
         return Cmd_Pong (DC, M);
      elsif Cmd = "USER" then
         return IRC_Fail
           (ERR_ALREADYREGISTERED, [Nick_Of (DC), "You may not reregister"]);
      elsif Cmd = "NICK" then
         return Cmd_Nick (DC, M);
      elsif Cmd = "SETNAME" then
         return Cmd_Setname (DC, M);
      elsif Cmd = "JOIN" then
         return Cmd_Join (DC, M);
      elsif Cmd = "PART" then
         return Cmd_Part (DC, M);
      elsif Cmd = "KICK" then
         return Cmd_Kick (DC, M);
      elsif Cmd = "MODE" then
         return Cmd_Mode (DC, M);
      elsif Cmd = "TOPIC" then
         return Cmd_Topic (DC, M);
      elsif Cmd = "LIST" then
         return Cmd_List (DC, M);
      elsif Cmd = "NAMES" then
         return Cmd_Names (DC, M);
      elsif Cmd = "WHO" then
         return Cmd_Who (DC, M);
      elsif Cmd = "WHOIS" then
         return Cmd_Whois (DC, M);
      end if;

      DC.Logger.Debug ("unhandled message: " & Image (M));

      --  Only forward unknown commands in single-upstream mode.
      if DC.Network = null then
         return From_Error (Soja.Downstream.New_Unknown_Command_Error (Cmd));
      end if;

      declare
         UC : constant Upstream_Conn_Access := Upstream_Of (DC);
      begin
         if UC = null then
            return IRC_Fail
              (ERR_UNKNOWNCOMMAND,
               ["*", Cmd, "Disconnected from upstream network"]);
         end if;
         Relay (UC, DC, M);
      end;
      return Success;
   end Handle_Message_Registered;

end Soja.Core.Downstream_Commands;
