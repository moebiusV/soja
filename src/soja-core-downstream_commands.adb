pragma Ada_2022;

with Ada.Calendar;
with Ada.Containers;
with Ada.Exceptions;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;

with Soja.Core.Downstream_Handshake;
with Soja.Core.Downstream_Helpers;
with Soja.Core.Network_Ops;
with Soja.Core.Push;
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
with Soja.Irc.Xirc;
with Soja.Msgstore;
with Soja.Server;
with Soja.Webpush;

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
   use type Soja.Msgstore.Store_Access;

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
              (ERR_NOSUCHSERVER, [Nick_Of (DC), Destination,
                "No such server"]);
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
                    (DC, Make (ERR_BADCHANMASK, [Nick_Of (DC), Name,
                      "Invalid channel name"]));
               elsif not Soja.Core.Upstream_Dispatch.Is_Channel (UC, Name) then
                  Send_Message
                    (DC, Make (ERR_NOSUCHCHANNEL, [Nick_Of (DC), Name,
                      "Not a channel name"]));
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
           (DC, Make (RPL_ENDOFNAMES, [Nick_Of (DC), "*",
             "End of /NAMES list"]));
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
               Info.Token := Token_U;
               Info.Username := DC.User.User_Record.Username;
               Info.Hostname := DC.Hostname;
               Info.Server := Cfg.Hostname;
               Info.Nickname := DC.Nick;
               Info.Flags := To_Unbounded_String
                 ((if Length (DC.Away) > 0 then "G" else "H")
                  & (if DC.User.User_Record.Admin then "*" else ""));
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
                         [Nick, Service_Nick, Service_Nick,
                           "is logged in as"]));
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

   procedure Default_Service_Handler
     (DC : not null Downstream_Conn_Access; Text : String)
   is
      pragma Unreferenced (Text);
   begin
      Send_Service_Privmsg
        (DC, "error: the bouncer service commands are not available yet");
   end Default_Service_Handler;

   procedure Broadcast_To_All_Users
     (Srv  : not null Soja.Server.Server_Access;
      From : not null User_Access;
      Msg  : Message) is
   begin
      if Broadcast_Hook /= null then
         Broadcast_Hook (Srv, From, Msg);
      else
         From.Events.Enqueue (new Broadcast_Event'(Msg => Copy (Msg)));
      end if;
   end Broadcast_To_All_Users;

   ----------------------------------------------------------------------
   --  PRIVMSG, NOTICE, TAGMSG
   ----------------------------------------------------------------------

   --  parseNickServCredentials
   procedure Parse_NickServ_Credentials
     (Text, Nick : String;
      Username, Password : out Unbounded_String;
      Ok : out Boolean)
   is
      Words : constant String_Vectors.Vector := Fields (Text);
   begin
      Username := Null_Unbounded_String;
      Password := Null_Unbounded_String;
      Ok := False;
      if Words.Length < 2 then
         return;
      end if;

      declare
         Command : constant String := Upper (Words (1));
         Count   : constant Natural := Natural (Words.Length) - 1;   --  params
      begin
         if Command = "REGISTER" then
            Username := To_Unbounded_String (Nick);
            Password := To_Unbounded_String (Words (2));
            Ok := True;
         elsif Command = "IDENTIFY" then
            if Count = 1 then
               Username := To_Unbounded_String (Nick);
               Password := To_Unbounded_String (Words (2));
            else
               Username := To_Unbounded_String (Words (2));
               Password := To_Unbounded_String (Words (3));
            end if;
            Ok := True;
         elsif Command = "SET" then
            --  Only "SET PASSWORD <pw>" is credentials: another SET (EMAIL,
            --  ...) must not blank the saved password (de8690c).
            if Count = 2 and then Upper (Words (2)) = "PASSWORD" then
               Username := To_Unbounded_String (Nick);
               Password := To_Unbounded_String (Words (3));
               Ok := True;
            end if;
         end if;
      end;
   end Parse_NickServ_Credentials;

   function Cmd_Chat
     (DC : not null Downstream_Conn_Access; M : Message)
      return Irc_Error_Result
   is
      Cmd : constant String := To_String (M.Command);
      PR  : constant Params_Result :=
        Parse_Message_Params (M, (if Cmd /= "TAGMSG" then 2 else 1));
   begin
      if not PR.Ok then
         return Need_More (PR);
      end if;

      declare
         Targets : constant String := Param (M, 0);
         Text    : constant String :=
           (if Cmd /= "TAGMSG" then Param (M, 1) else "");
         Tags    : constant Tag_Map := Copy_Client_Tags (M.Tags);
         Cfg     : constant Soja.Server.Server_Config_Access :=
           Soja.Server.Config (DC.Srv.all);

         function Params_For (Name : String) return String_Vectors.Vector is
         begin
            return (if Cmd /= "TAGMSG" then [Name, Text] else [Name]);
         end Params_For;

         function Now_Tag return String is
           (Soja.Irc.Xirc.Format_Server_Time (Ada.Calendar.Clock));

         --  strings.TrimLeft (name, cutset).
         function Without_Sigils (S, Cutset : String) return String is
         begin
            for I in S'Range loop
               if Ada.Strings.Fixed.Index (Cutset, [1 => S (I)]) = 0 then
                  return S (I .. S'Last);
               end if;
            end loop;
            return "";
         end Without_Sigils;
      begin
         for Name of Split_Commas (Targets) loop
            if Name = "$" & To_String (Cfg.Hostname)
              or else (Name = "$*" and then DC.Network = null)
            then
               --  "$" means a server mask follows.  If it is the bouncer's
               --  hostname, broadcast the message to all bouncer users.
               if not DC.User.User_Record.Admin then
                  return IRC_Fail
                    (ERR_BADMASK,
                     [Nick_Of (DC), Name,
                      "Permission denied to broadcast message to all "
                      & "bouncer users"]);
               end if;

               DC.Logger.Print
                 ("broadcasting bouncer-wide " & Cmd & ": " & Text);
               declare
                  B : Message := Make (Cmd, Params_For (Name));
               begin
                  B.Tags := Copy (Tags);
                  Set_Tag (B.Tags, "time", Now_Tag);
                  B.Prefix := Service_Prefix;
                  Broadcast_To_All_Users (DC.Srv, DC.User, B);
               end;

            elsif DC.Network = null
              and then Fold (DC, Name) = To_String (DC.Nick_CM)
            then
               declare
                  Echo : Message := Make (Cmd, Params_For (Name));
               begin
                  Echo.Tags := Copy (M.Tags);
                  Echo.Prefix := new Prefix'(Prefix_Of (DC));
                  Send_Message (DC, Echo);
               end;

            elsif Fold (DC, Name) = Service_Nick_CM then
               if Soja.Irc.Cap_Registry.Is_Enabled (DC.Caps, "echo-message")
               then
                  declare
                     Echo : Message := Make (Cmd, Params_For (Name));
                  begin
                     Echo.Tags := Copy (Tags);
                     Set_Tag (Echo.Tags, "time", Now_Tag);
                     Echo.Prefix := new Prefix'(Prefix_Of (DC));
                     Send_Message (DC, Echo);
                  end;
               end if;
               if Cmd = "PRIVMSG" then
                  Service_Handler (DC, Text);
               end if;

            else
               declare
                  UC : Upstream_Conn_Access;
                  R  : constant Irc_Error_Result :=
                    Upstream_For_Command (DC, Cmd, UC);
                  --  The name without the STATUSMSG sigils ("+#chan" is
                  --  logged with "#chan").  The message itself goes upstream
                  --  as it came.
                  Target : constant String :=
                    (if UC /= null
                     then Without_Sigils
                            (Name, To_String (UC.Available_Status_Msg))
                     else Name);
               begin
                  if R.Failed then
                     return R;
                  end if;

                  if Cmd = "PRIVMSG"
                    and then Soja.Irc.Case_Mapping.Fold
                               (UC.Network.Casemap, Target) = "nickserv"
                  then
                     declare
                        User, Pass : Unbounded_String;
                        Found      : Boolean;
                     begin
                        Parse_NickServ_Credentials
                          (Text, To_String (UC.Nick), User, Pass, Found);
                        if Found and then Length (Pass) > 0 then
                           Auto_Save_SASL_Plain
                             (UC.Network, To_String (User), To_String (Pass));
                        end if;
                     end;
                  end if;

                  declare
                     Out_Msg : Message := Make (Cmd, Params_For (Name));
                  begin
                     Out_Msg.Tags := Copy (Tags);
                     Relay (UC, DC, Out_Msg);
                  end;

                  --  If the upstream supports echo-message, we produce the
                  --  message when it is echoed back.  Otherwise, produce and
                  --  log it here because it's the last time we'll see it.
                  if not Soja.Irc.Cap_Registry.Is_Enabled
                           (UC.Caps, "echo-message")
                  then
                     declare
                        Echo : Message := Make (Cmd, Params_For (Name));
                     begin
                        Echo.Tags := Copy (Tags);
                        Set_Tag (Echo.Tags, "time", Now_Tag);
                        if Length (UC.Account) > 0 then
                           Set_Tag (Echo.Tags, "account",
                                    To_String (UC.Account));
                        end if;
                        Echo.Prefix := new Prefix'
                          (Name => UC.Nick, User => UC.Username,
                           Host => UC.Hostname);
                        Soja.Core.Upstream_Dispatch.Produce
                          (UC, Target, Echo, DC.ID);
                     end;
                  end if;

                  Soja.Core.Upstream_Dispatch.Update_Channel_Auto_Detach
                    (UC, Target);
               end;
            end if;
         end loop;
      end;
      return Success;
   end Cmd_Chat;

   ----------------------------------------------------------------------
   --  INVITE, AUTHENTICATE, REGISTER/VERIFY, AWAY, INFO
   ----------------------------------------------------------------------

   function Cmd_Invite
     (DC : not null Downstream_Conn_Access; M : Message)
      return Irc_Error_Result
   is
      UC : Upstream_Conn_Access;
      R  : constant Irc_Error_Result := Upstream_For_Command (DC, "INVITE",
        UC);
   begin
      if R.Failed then
         return R;
      end if;
      Relay (UC, DC, M);
      return Success;
   end Cmd_Invite;

   function Cmd_Authenticate
     (DC : not null Downstream_Conn_Access; M : Message)
      return Irc_Error_Result
   is
      --  Post-registration AUTHENTICATE is only supported if an upstream is
      --  bound and supports SASL.
      UC : constant Upstream_Conn_Access := Upstream_Of (DC);
   begin
      if UC = null or else not Soja.Irc.Cap_Registry.Is_Enabled (UC.Caps,
        "sasl")
      then
         return IRC_Fail
           (ERR_SASLFAIL,
            [Nick_Of (DC), "Upstream network authentication not supported"]);
      end if;

      declare
         Step : constant Soja.Core.Downstream_Handshake.Authenticate_Step :=
           Soja.Core.Downstream_Handshake.Handle_Authenticate (DC, M);
      begin
         if Step.Result.Failed then
            return Step.Result;
         elsif not Step.Done then
            return Success;
         end if;
      end;

      if UC.Sasl_Mech /= Sasl_None then
         End_SASL
           (DC, Make (ERR_SASLFAIL,
                      [Nick_Of (DC),
                       "Another authentication attempt is already in "
                       & "progress"]));
         return Success;
      end if;

      declare
         Mech : constant String := To_String (DC.Sasl.Mechanism);
      begin
         if Mech = "PLAIN" then
            UC.Logger.Print
              ("starting post-registration SASL PLAIN authentication with "
               & "username " & Quote (To_String (DC.Sasl.Plain_Username)));
            UC.Sasl_Mech := Sasl_Plain;
            UC.Sasl_Username := DC.Sasl.Plain_Username;
            UC.Sasl_Password := DC.Sasl.Plain_Password;
            Soja.Core.Upstream_Dispatch.Enqueue_Command
              (UC, DC, Make ("AUTHENTICATE", ["PLAIN"]));

         elsif Mech = "ANONYMOUS" then
            if Length (UC.Network.Network_Record.SASL.Mechanism) > 0 then
               --  Clear the stored credentials (on a copy of the record).
               declare
                  Rec : Soja.Database.Network := UC.Network.Network_Record;
               begin
                  Rec.SASL.Plain_Username := Null_Unbounded_String;
                  Rec.SASL.Plain_Password := Null_Unbounded_String;
                  Rec.SASL.External_Cert := Null_Unbounded_String;
                  Rec.SASL.External_Key := Null_Unbounded_String;
                  Rec.SASL.Mechanism := Null_Unbounded_String;
                  declare
                     Ignored : constant Network_Access :=
                       Soja.Core.User_Ops.Update_Network (DC.User, Rec);
                     pragma Unreferenced (Ignored);
                  begin
                     null;
                  exception
                     when Soja.Core.User_Ops.Operation_Error =>
                        null;
                  end;
               exception
                  when Soja.Core.User_Ops.Operation_Error =>
                     DC.Logger.Print ("failed to clear SASL credentials");
                     End_SASL
                       (DC, Make (ERR_SASLFAIL,
                                  [Nick_Of (DC), "Internal server error"]));
                     return Success;
               end;
            end if;
            End_SASL (DC);

         else
            End_SASL
              (DC, Make (ERR_SASLFAIL,
                         [Nick_Of (DC),
                          "Unsupported SASL authentication mechanism"]));
         end if;
      end;
      return Success;
   end Cmd_Authenticate;

   function Cmd_Register
     (DC : not null Downstream_Conn_Access; M : Message)
      return Irc_Error_Result
   is
      Cmd : constant String := To_String (M.Command);
   begin
      --  Check the number of parameters here: it is what saves the
      --  credentials when the command succeeds.
      if (Cmd = "REGISTER" and then M.Params.Length < 3)
        or else (Cmd = "VERIFY" and then M.Params.Length < 2)
      then
         return From_Error
           (Soja.Downstream.New_Need_More_Params_Error (Cmd));
      end if;

      declare
         UC : constant Upstream_Conn_Access := Upstream_Of (DC);
      begin
         if UC = null
           or else not Soja.Irc.Cap_Registry.Is_Enabled
                         (UC.Caps, "draft/account-registration")
         then
            return IRC_Fail
              ("FAIL",
               [Cmd, "TEMPORARILY_UNAVAILABLE", "*",
                "Upstream network account registration not supported"]);
         end if;
         UC.Logger.Print
           ("starting " & Cmd & " with account name " & Param (M, 0));
         Soja.Core.Upstream_Dispatch.Enqueue_Command (UC, DC, M);
      end;
      return Success;
   end Cmd_Register;

   function Cmd_Away
     (DC : not null Downstream_Conn_Access; M : Message)
      return Irc_Error_Result is
   begin
      if not M.Params.Is_Empty then
         DC.Away := M.Params (1);
      else
         DC.Away := Null_Unbounded_String;
      end if;
      Send_Message (DC, Generate_Away_Reply (Length (DC.Away) > 0));

      declare
         UC : constant Upstream_Conn_Access := Upstream_Of (DC);
      begin
         if UC /= null then
            Soja.Core.Upstream_Dispatch.Update_Away (UC);
         end if;
      end;
      return Success;
   end Cmd_Away;

   function Cmd_Info
     (DC : not null Downstream_Conn_Access; M : Message)
      return Irc_Error_Result is
   begin
      if DC.Network = null then
         Send_Message
           (DC, Make (RPL_INFO, [Nick_Of (DC), "soju <https://soju.im>"]));
         Send_Message
           (DC, Make (RPL_ENDOFINFO, [Nick_Of (DC), "End of INFO"]));
         return Success;
      end if;

      declare
         UC : constant Upstream_Conn_Access := Upstream_Of (DC);
      begin
         if UC = null then
            return IRC_Fail
              (ERR_UNKNOWNCOMMAND,
               [Nick_Of (DC), To_String (M.Command),
                "Disconnected from upstream network"]);
         end if;
         Relay (UC, DC, M);
      end;
      return Success;
   end Cmd_Info;

   ----------------------------------------------------------------------
   --  MONITOR
   ----------------------------------------------------------------------

   function Cmd_Monitor
     (DC : not null Downstream_Conn_Access; M : Message)
      return Irc_Error_Result
   is
      UC  : constant Upstream_Conn_Access := Upstream_Of (DC);
      Cmd : constant String := To_String (M.Command);
      PR  : Params_Result;
   begin
      if UC = null or else not UC.Isupport.Contains ("MONITOR") then
         return From_Error (Soja.Downstream.New_Unknown_Command_Error (Cmd));
      end if;

      PR := Parse_Message_Params (M, 1);
      if not PR.Ok then
         return Need_More (PR);
      end if;

      declare
         Sub  : constant String := Param (M, 0);
         Nick : constant String := Nick_Of (DC);
      begin
         if Sub = "+" or else Sub = "-" then
            PR := Parse_Message_Params (M, 2);
            if not PR.Ok then
               return Need_More (PR);
            end if;

            for Target of Split_Commas (Param (M, 1)) loop
               if Sub = "+" then
                  --  A hard limit, just to avoid having clients fill our map.
                  if DC.Monitored.Length >= 1000 then
                     Send_Message
                       (DC, Make (ERR_MONLISTFULL,
                                  [Nick, "1000", Target,
                                   "Bouncer monitor list is full"]));
                  else
                     DC.Monitored.Set (Target, True);

                     if Soja.Irc.Case_Mapping.Fold
                          (UC.Network.Casemap, Target) = Service_Nick_CM
                     then
                        --  BouncerServ is never tired.
                        Send_Message
                          (DC, Make (RPL_MONONLINE, [Nick, Target]));
                     elsif UC.Monitored.Has (Target) then
                        Send_Message
                          (DC, Make
                                 ((if UC.Monitored.Get (Target)
                                   then RPL_MONONLINE else RPL_MONOFFLINE),
                                  [Nick, Target]));
                     end if;
                  end if;
               else
                  DC.Monitored.Del (Target);
               end if;
            end loop;
            Soja.Core.Upstream_Dispatch.Update_Monitor (UC);

         elsif Upper (Sub) = "C" then   --  clear
            DC.Monitored := Flag_Maps.New_Map (UC.Network.Casemap);
            Soja.Core.Upstream_Dispatch.Update_Monitor (UC);

         elsif Upper (Sub) = "L" then   --  list
            --  TODO (Go): be less lazy and pack the list.
            declare
               procedure Show (Name : String; Present : Boolean) is
                  pragma Unreferenced (Present);
               begin
                  Send_Message (DC, Make (RPL_MONLIST, [Nick, Name]));
               end Show;
            begin
               DC.Monitored.For_Each (Show'Access);
            end;
            Send_Message
              (DC, Make (RPL_ENDOFMONLIST, [Nick, "End of MONITOR list"]));

         elsif Upper (Sub) = "S" then   --  status
            declare
               procedure Show (Target : String; Present : Boolean) is
                  pragma Unreferenced (Present);
                  Online : constant Boolean :=
                    UC.Monitored.Get (Target)
                    or else Soja.Irc.Case_Mapping.Fold
                              (UC.Network.Casemap, Target) = Service_Nick_CM;
               begin
                  Send_Message
                    (DC, Make ((if Online then RPL_MONONLINE
                                else RPL_MONOFFLINE), [Nick, Target]));
               end Show;
            begin
               DC.Monitored.For_Each (Show'Access);
            end;
         end if;
      end;
      return Success;
   end Cmd_Monitor;

   ----------------------------------------------------------------------
   --  BOUNCER (soju.im/bouncer-networks)
   ----------------------------------------------------------------------

   function Text_Fail (Text : String) return Irc_Error_Result is
     (Failed => True, Is_IRC => False,
      Err    => (Message => (others => <>)),
      Text   => To_Unbounded_String (Text));

   function Img (N : Long_Long_Integer) return String is
     (Ada.Strings.Fixed.Trim (Long_Long_Integer'Image (N), Ada.Strings.Left));

   --  fillNetworkAddrAttrs, for a record that is not a running network.
   procedure Fill_Addr_Attrs
     (Attrs : in out Tag_Map; Rec : Soja.Database.Network)
   is
      U      : constant Soja.Database.Network_URL := Soja.Database.URL (Rec);
      Scheme : constant String := To_String (U.Scheme);
      HP     : constant String := To_String (U.Host);
      Colon  : Natural := 0;
   begin
      if Scheme = "ircs" then
         Set_Tag (Attrs, "tls", "1");
      elsif Scheme = "irc+insecure" then
         Set_Tag (Attrs, "tls", "0");
      else
         return;   --  e.g. unix://: no host and port
      end if;

      --  net.SplitHostPort: the last ':' outside "[...]" starts the port.
      for I in reverse HP'Range loop
         exit when HP (I) = ']';
         if HP (I) = ':' then
            Colon := I;
            exit;
         end if;
      end loop;
      if Colon > 0 then
         declare
            Host : constant String := HP (HP'First .. Colon - 1);
         begin
            Set_Tag (Attrs, "host",
                     (if Host'Length >= 2 and then Host (Host'First) = '['
                        and then Host (Host'Last) = ']'
                      then Host (Host'First + 1 .. Host'Last - 1) else Host));
            Set_Tag (Attrs, "port", HP (Colon + 1 .. HP'Last));
         end;
      else
         Set_Tag (Attrs, "host", HP);
      end if;
   end Fill_Addr_Attrs;

   --  networkAddrFromAttrs.  (Go does not bracket an IPv6 host, which makes
   --  "::1" + "6667" the unusable "::1:6667"; soja does, SOJU-BUGS.md.)
   function Addr_From_Attrs (Attrs : Tag_Map) return String is
      Host : constant String :=
        (if Has_Tag (Attrs, "host") then Get_Tag (Attrs, "host") else "");
   begin
      if Host = "" then
         return "";
      end if;
      declare
         Port : constant String :=
           (if Has_Tag (Attrs, "port") then Get_Tag (Attrs, "port") else "");
         Addr : Unbounded_String := To_Unbounded_String
           ((if Ada.Strings.Fixed.Index (Host, ":") > 0 then "[" & Host & "]"
             else Host));
      begin
         if Port /= "" then
            Append (Addr, ":" & Port);
         end if;
         if Has_Tag (Attrs, "tls") and then Get_Tag (Attrs, "tls") = "0" then
            return "irc+insecure://" & To_String (Addr);
         end if;
         return To_String (Addr);
      end;
   end Addr_From_Attrs;

   --  updateNetworkAttrs.
   function Update_Network_Attrs
     (Rec : in out Soja.Database.Network; Attrs : Tag_Map; Sub : String)
      return Irc_Error_Result
   is
      Addr_Attrs  : Tag_Map;
      Update_Addr : Boolean := False;
   begin
      Fill_Addr_Attrs (Addr_Attrs, Rec);
      for C in Attrs.Data.Iterate loop
         declare
            K : constant String := Soja.Irc.Messages.Tag_Maps.Key (C);
            V : constant String := Soja.Irc.Messages.Tag_Maps.Element (C);
         begin
            if K = "host" or else K = "port" or else K = "tls" then
               Update_Addr := True;
               Set_Tag (Addr_Attrs, K, V);
            elsif K = "name" then
               Rec.Name := To_Unbounded_String (V);
            elsif K = "nickname" then
               Rec.Nick := To_Unbounded_String (V);
            elsif K = "username" then
               Rec.Username := To_Unbounded_String (V);
            elsif K = "realname" then
               Rec.Realname := To_Unbounded_String (V);
            elsif K = "pass" then
               Rec.Pass := To_Unbounded_String (V);
            else
               return IRC_Fail
                 ("FAIL", ["BOUNCER", "UNKNOWN_ATTRIBUTE", Sub, K,
                           "Unknown attribute"]);
            end if;
         end;
      end loop;

      if Update_Addr then
         Rec.Addr := To_Unbounded_String (Addr_From_Attrs (Addr_Attrs));
         if Length (Rec.Addr) = 0 then
            return IRC_Fail
              ("FAIL", ["BOUNCER", "NEED_ATTRIBUTE", Sub, "host",
                        "Missing required host attribute"]);
         end if;
      end if;
      return Success;
   end Update_Network_Attrs;

   function Cmd_Bouncer
     (DC : not null Downstream_Conn_Access; M : Message)
      return Irc_Error_Result
   is
      PR  : Params_Result := Parse_Message_Params (M, 1);
      U   : constant User_Access := DC.User;

      --  The nick / realname of a record are stored empty when they are the
      --  user's defaults.
      procedure Drop_Defaults (Rec : in out Soja.Database.Network) is
      begin
         if Rec.Nick = U.User_Record.Username then
            Rec.Nick := Null_Unbounded_String;
         end if;
         if Rec.Realname = U.User_Record.Realname then
            Rec.Realname := Null_Unbounded_String;
         end if;
      end Drop_Defaults;
   begin
      if not PR.Ok then
         return Need_More (PR);
      end if;

      declare
         Sub : constant String := Param (M, 0);
         USub : constant String := Soja.Irc.Helpers.Upper (Sub);
      begin
         if USub = "BIND" then
            return IRC_Fail
              ("FAIL", ["BOUNCER", "REGISTRATION_IS_COMPLETED", "BIND",
                        "Cannot bind to a network after registration"]);

         elsif USub = "LISTNETWORKS" then
            declare
               procedure Each (Batch_Ref : String) is
               begin
                  for Net of U.Networks loop
                     declare
                        Out_Msg : Message := Make
                          ("BOUNCER",
                           ["NETWORK", Img (Net.Network_Record.ID),
                            Image (Soja.Core.User_Ops.Network_Attrs (Net))]);
                     begin
                        Set_Tag (Out_Msg.Tags, "batch", Batch_Ref);
                        Send_Message (DC, Out_Msg);
                     end;
                  end loop;
               end Each;
            begin
               Send_Batch (DC, "soju.im/bouncer-networks",
                           String_Vectors.Empty_Vector, Each'Access);
            end;

         elsif USub = "ADDNETWORK" then
            PR := Parse_Message_Params (M, 2);
            if not PR.Ok then
               return Need_More (PR);
            end if;
            declare
               Rec : Soja.Database.Network := Soja.Database.New_Network ("");
               R   : Irc_Error_Result;
            begin
               Rec.Nick := DC.Nick;
               R := Update_Network_Attrs (Rec, Parse_Tags (Param (M, 1)), Sub);
               if R.Failed then
                  return R;
               end if;
               Drop_Defaults (Rec);
               declare
                  Net : Network_Access;
               begin
                  Net := Soja.Core.User_Ops.Create_Network (U, Rec);
                  Send_Message
                    (DC, Make ("BOUNCER",
                               ["ADDNETWORK", Img (Net.Network_Record.ID)]));
               exception
                  when E : Soja.Core.User_Ops.Operation_Error =>
                     return IRC_Fail
                       ("FAIL", ["BOUNCER", "UNKNOWN_ERROR", Sub,
                                 "Failed to create network: "
                                 & Ada.Exceptions.Exception_Message (E)]);
               end;
            end;

         elsif USub = "CHANGENETWORK" then
            PR := Parse_Message_Params (M, 3);
            if not PR.Ok then
               return Need_More (PR);
            end if;
            declare
               ID : constant Soja.Downstream.Parse_Net_ID_Result :=
                 Soja.Downstream.Parse_Bouncer_Net_ID (Sub, Param (M, 1));
            begin
               if not ID.Ok then
                  return From_Error (ID.Err);
               end if;
               declare
                  Net : constant Network_Access :=
                    Get_Network_By_ID (U, ID.ID);
               begin
                  if Net = null then
                     return IRC_Fail
                       ("FAIL", ["BOUNCER", "INVALID_NETID", Sub,
                                 Param (M, 1), "Invalid network ID"]);
                  end if;
                  declare
                     Rec : Soja.Database.Network := Net.Network_Record;
                     Was_Enabled : constant Boolean := Rec.Enabled;
                     R   : constant Irc_Error_Result :=
                       Update_Network_Attrs
                         (Rec, Parse_Tags (Param (M, 2)), Sub);
                  begin
                     if R.Failed then
                        return R;
                     end if;
                     Drop_Defaults (Rec);
                     declare
                        --  Only enabling a disabled network is limited.
                        Updated : constant Network_Access :=
                          Soja.Core.User_Ops.Update_Network
                            (U, Rec, Enforce_Limit => not Was_Enabled);
                        pragma Unreferenced (Updated);
                     begin
                        Send_Message
                          (DC, Make ("BOUNCER",
                                     ["CHANGENETWORK", Param (M, 1)]));
                     exception
                        when E : Soja.Core.User_Ops.Operation_Error =>
                           return IRC_Fail
                             ("FAIL", ["BOUNCER", "UNKNOWN_ERROR", Sub,
                                       "Failed to update network: "
                                       & Ada.Exceptions.Exception_Message
                                           (E)]);
                     end;
                  end;
               end;
            end;

         elsif USub = "DELNETWORK" then
            PR := Parse_Message_Params (M, 2);
            if not PR.Ok then
               return Need_More (PR);
            end if;
            declare
               ID : constant Soja.Downstream.Parse_Net_ID_Result :=
                 Soja.Downstream.Parse_Bouncer_Net_ID (Sub, Param (M, 1));
            begin
               if not ID.Ok then
                  return From_Error (ID.Err);
               end if;
               declare
                  Net : constant Network_Access :=
                    Get_Network_By_ID (U, ID.ID);
               begin
                  if Net = null then
                     return IRC_Fail
                       ("FAIL", ["BOUNCER", "INVALID_NETID", Sub,
                                 Param (M, 1), "Invalid network ID"]);
                  end if;
                  begin
                     Soja.Core.User_Ops.Delete_Network
                       (U, Net.Network_Record.ID);
                  exception
                     when E : Soja.Core.User_Ops.Operation_Error =>
                        return Text_Fail
                          (Ada.Exceptions.Exception_Message (E));
                  end;
                  Send_Message
                    (DC, Make ("BOUNCER", ["DELNETWORK", Param (M, 1)]));
               end;
            end;

         else
            return IRC_Fail
              ("FAIL", ["BOUNCER", "UNKNOWN_COMMAND", Sub,
                        "Unknown subcommand"]);
         end if;
      end;
      return Success;
   end Cmd_Bouncer;

   ----------------------------------------------------------------------
   --  CHATHISTORY, SEARCH
   ----------------------------------------------------------------------

   --  strconv.Atoi: an optional sign and digits; Ok is False for anything
   --  else or a value that does not fit.
   procedure Parse_Atoi (S : String; Value : out Integer; Ok : out Boolean) is
      Pos : Natural := S'First;
      Neg : Boolean := False;
      Acc : Long_Long_Integer := 0;
   begin
      Value := 0;
      Ok := False;
      if S'Length = 0 then
         return;
      end if;
      if S (Pos) = '+' or else S (Pos) = '-' then
         Neg := S (Pos) = '-';
         Pos := Pos + 1;
      end if;
      if Pos > S'Last then
         return;
      end if;
      for I in Pos .. S'Last loop
         if S (I) not in '0' .. '9' then
            return;
         end if;
         Acc := Acc * 10 + Long_Long_Integer (Character'Pos (S (I)) - 48);
         if Acc > Long_Long_Integer (Integer'Last) then
            return;
         end if;
      end loop;
      Value := Integer (if Neg then -Acc else Acc);
      Ok := True;
   end Parse_Atoi;

   function FAIL (Params : String_Vectors.Vector) return Irc_Error_Result is
     (IRC_Fail ("FAIL", Params));

   function Cmd_Chat_History
     (DC : not null Downstream_Conn_Access; M : Message)
      return Irc_Error_Result
   is
      PR : Params_Result := Parse_Message_Params (M, 1);
      Nick : constant String := Nick_Of (DC);
   begin
      if not PR.Ok then
         return Need_More (PR);
      end if;

      declare
         Sub    : constant String := Param (M, 0);
         Target : Unbounded_String;
         Bound0, Bound1, Limit_Str : Unbounded_String;

         procedure Empty_Batch (Typ : String; Params : String_Vectors.Vector)
         is
            procedure None (Batch_Ref : String) is
               pragma Unreferenced (Batch_Ref);
            begin
               null;
            end None;
         begin
            Send_Batch (DC, Typ, Params, None'Access);
         end Empty_Batch;
      begin
         if Sub = "AFTER" or else Sub = "BEFORE" or else Sub = "LATEST" then
            PR := Parse_Message_Params (M, 4);
            if not PR.Ok then
               return Need_More (PR);
            end if;
            Target := To_Unbounded_String (Param (M, 1));
            Bound0 := To_Unbounded_String (Param (M, 2));
            Limit_Str := To_Unbounded_String (Param (M, 3));
         elsif Sub = "BETWEEN" then
            PR := Parse_Message_Params (M, 5);
            if not PR.Ok then
               return Need_More (PR);
            end if;
            Target := To_Unbounded_String (Param (M, 1));
            Bound0 := To_Unbounded_String (Param (M, 2));
            Bound1 := To_Unbounded_String (Param (M, 3));
            Limit_Str := To_Unbounded_String (Param (M, 4));
         elsif Sub = "TARGETS" then
            if DC.Network = null then
               Empty_Batch ("draft/chathistory-targets",
                            String_Vectors.Empty_Vector);
               return Success;
            end if;
            PR := Parse_Message_Params (M, 4);
            if not PR.Ok then
               return Need_More (PR);
            end if;
            Bound0 := To_Unbounded_String (Param (M, 1));
            Bound1 := To_Unbounded_String (Param (M, 2));
            Limit_Str := To_Unbounded_String (Param (M, 3));
         else
            --  TODO (Go): support AROUND.
            return FAIL (["CHATHISTORY", "INVALID_PARAMS", Sub,
                          "Unknown command"]);
         end if;

         --  We don't save history for our service.
         if Fold (DC, To_String (Target)) = Service_Nick_CM then
            Empty_Batch ("chathistory", [To_String (Target)]);
            return Success;
         end if;

         declare
            Store : constant Soja.Msgstore.Store_Access := DC.User.Msg_Store;
         begin
            if Store = null or else not Store.Supports_Chat_History then
               return IRC_Fail
                 (ERR_UNKNOWNCOMMAND,
                  [Nick, "CHATHISTORY", "Chat history disabled"]);
            end if;

            if DC.Network = null then
               return FAIL (["CHATHISTORY", "INVALID_TARGET", Sub,
                             To_String (Target),
                             "Cannot fetch chat history on bouncer "
                             & "connection"]);
            end if;

            declare
               Net     : constant Network_Access := DC.Network;
               Entity  : constant String := Soja.Irc.Case_Mapping.Fold
                 (Net.Casemap, To_String (Target));
               Bounds  : array (0 .. 1) of Ada.Calendar.Time :=
                 [others => Soja.Database.Null_Time];
               Valid   : Boolean;
               Limit   : Integer;
               Limit_Ok : Boolean;
            begin
               --  TODO (Go): support msgid criteria.
               Bounds (0) := Soja.Irc.Helpers.Parse_Chat_History_Bound
                 (To_String (Bound0), Valid);
               if Sub = "LATEST" and then To_String (Bound0) = "*" then
                  Bounds (0) := Soja.Database.Null_Time;
               elsif not Valid then
                  return FAIL (["CHATHISTORY", "INVALID_PARAMS", Sub,
                                To_String (Bound0), "Invalid first bound"]);
               end if;

               if Length (Bound1) > 0 then
                  Bounds (1) := Soja.Irc.Helpers.Parse_Chat_History_Bound
                    (To_String (Bound1), Valid);
                  if not Valid then
                     return FAIL
                       (["CHATHISTORY", "INVALID_PARAMS", Sub,
                         To_String (Bound1), "Invalid second bound"]);
                  end if;
               end if;

               Parse_Atoi (To_String (Limit_Str), Limit, Limit_Ok);
               if not Limit_Ok or else Limit < 0
                 or else Limit > Soja.Server.Chat_History_Limit
               then
                  return FAIL (["CHATHISTORY", "INVALID_PARAMS", Sub,
                                To_String (Limit_Str), "Invalid limit"]);
               end if;

               declare
                  use type Ada.Calendar.Time;
                  Events  : constant Boolean :=
                    Soja.Irc.Cap_Registry.Is_Enabled
                      (DC.Caps, "draft/event-playback");
                  Options : constant Soja.Msgstore.Load_Message_Options :=
                    (Network => Net.Network_Record,
                     Entity  => To_Unbounded_String (Entity),
                     Limit   => Limit, Events => Events);
                  History : Soja.Msgstore.Message_Vector;
               begin
                  if Sub = "TARGETS" then
                     declare
                        Targets : Soja.Msgstore.Target_Vectors.Vector;

                        procedure Each (Batch_Ref : String) is
                        begin
                           for T of Targets loop
                              declare
                                 Ch : constant Channel_Access :=
                                   Net.Channels.Get (To_String (T.Name));
                              begin
                                 if Ch = null or else not Ch.Detached then
                                    declare
                                       Out_Msg : Message := Make
                                         ("CHATHISTORY",
                                          ["TARGETS", To_String (T.Name),
                                           Soja.Irc.Xirc.Format_Server_Time
                                             (T.Latest_Message)]);
                                    begin
                                       Set_Tag (Out_Msg.Tags, "batch",
                                                Batch_Ref);
                                       Send_Message (DC, Out_Msg);
                                    end;
                                 end if;
                              end;
                           end loop;
                        end Each;
                     begin
                        begin
                           Targets := Store.List_Targets
                             (Net.Network_Record, Bounds (0), Bounds (1),
                              Limit, Events);
                        exception
                           when E : Soja.Msgstore.Store_Error =>
                              DC.Logger.Print
                                ("failed fetching targets for chathistory: "
                                 & Ada.Exceptions.Exception_Message (E));
                              return FAIL (["CHATHISTORY", "MESSAGE_ERROR",
                                            Sub,
                                            "Failed to retrieve targets"]);
                        end;
                        Send_Batch (DC, "draft/chathistory-targets",
                                    String_Vectors.Empty_Vector, Each'Access);
                        return Success;
                     end;
                  end if;

                  begin
                     if Sub = "BEFORE" then
                        History := Store.Load_Before_Time
                          (Bounds (0), Soja.Database.Null_Time, Options);
                     elsif Sub = "LATEST" then
                        History := Store.Load_Before_Time
                          (Ada.Calendar.Clock, Bounds (0), Options);
                     elsif Sub = "AFTER" then
                        History := Store.Load_After_Time
                          (Bounds (0), Ada.Calendar.Clock, Options);
                     else   --  BETWEEN
                        if Bounds (0) < Bounds (1) then
                           History := Store.Load_After_Time
                             (Bounds (0), Bounds (1), Options);
                        else
                           History := Store.Load_Before_Time
                             (Bounds (0), Bounds (1), Options);
                        end if;
                     end if;
                  exception
                     when E : Soja.Msgstore.Store_Error =>
                        DC.Logger.Print
                          ("failed fetching " & Soja.Irc.Helpers.Quote (Entity)
                           & " messages for chathistory: "
                           & Ada.Exceptions.Exception_Message (E));
                        return FAIL (["CHATHISTORY", "MESSAGE_ERROR", Sub,
                                      Entity,
                                      "Messages could not be retrieved"]);
                  end;

                  declare
                     procedure Each (Batch_Ref : String) is
                     begin
                        for Stored of History loop
                           declare
                              Out_Msg : Message := Copy (Stored);
                           begin
                              Set_Tag (Out_Msg.Tags, "batch", Batch_Ref);
                              Send_Message (DC, Out_Msg);
                           end;
                        end loop;
                     end Each;
                  begin
                     Send_Batch (DC, "chathistory", [Entity], Each'Access);
                  end;
               end;
            end;
         end;
      end;
      return Success;
   end Cmd_Chat_History;

   function Cmd_Search
     (DC : not null Downstream_Conn_Access; M : Message)
      return Irc_Error_Result
   is
      Search_Max_Limit : constant := 100;
      Store : constant Soja.Msgstore.Store_Access := DC.User.Msg_Store;
      PR    : Params_Result;
   begin
      if Store = null or else not Store.Supports_Search then
         return IRC_Fail
           (ERR_UNKNOWNCOMMAND, [Nick_Of (DC), "SEARCH", "Unknown command"]);
      end if;
      PR := Parse_Message_Params (M, 1);
      if not PR.Ok then
         return Need_More (PR);
      end if;

      declare
         Attrs   : constant Tag_Map := Parse_Tags (Param (M, 0));
         Net     : Network_Access := null;
         Opts    : Soja.Msgstore.Search_Options :=
           (Limit => Search_Max_Limit, others => <>);
      begin
         for C in Attrs.Data.Iterate loop
            declare
               Name  : constant String := Soja.Irc.Messages.Tag_Maps.Key (C);
               Value : constant String :=
                 Soja.Irc.Messages.Tag_Maps.Element (C);
            begin
               if Name = "before" or else Name = "after" then
                  declare
                     Valid : Boolean;
                     T     : constant Ada.Calendar.Time :=
                       Soja.Irc.Helpers.Parse_Server_Time (Value, Valid);
                  begin
                     if not Valid then
                        return FAIL (["SEARCH", "INVALID_PARAMS", Name,
                                      "Invalid criteria"]);
                     end if;
                     if Name = "after" then
                        Opts.Start := T;
                     else
                        Opts.End_Time := T;
                     end if;
                  end;
               elsif Name = "from" then
                  Opts.From := To_Unbounded_String (Value);
               elsif Name = "in" then
                  Net := DC.Network;
                  if Net = null then
                     return FAIL (["SEARCH", "INVALID_PARAMS", Name,
                                   "Cannot search on bouncer connection"]);
                  end if;
                  Opts.In_Target := To_Unbounded_String
                    (Soja.Irc.Case_Mapping.Fold (Net.Casemap, Value));
               elsif Name = "text" then
                  Opts.Text := To_Unbounded_String (Value);
               elsif Name = "limit" then
                  declare
                     Limit : Integer;
                     Ok    : Boolean;
                  begin
                     Parse_Atoi (Value, Limit, Ok);
                     if not Ok or else Limit <= 0 then
                        return FAIL (["SEARCH", "INVALID_PARAMS", Name,
                                      "Invalid limit"]);
                     end if;
                     Opts.Limit := Limit;
                  end;
               end if;
            end;
         end loop;

         if Net = null then
            return FAIL (["SEARCH", "INVALID_PARAMS", "in",
                          "The in parameter is mandatory"]);
         end if;
         if Opts.Limit > Search_Max_Limit then
            Opts.Limit := Search_Max_Limit;
         end if;

         declare
            Found : Soja.Msgstore.Message_Vector;

            procedure Each (Batch_Ref : String) is
            begin
               for Stored of Found loop
                  declare
                     Out_Msg : Message := Copy (Stored);
                  begin
                     Set_Tag (Out_Msg.Tags, "batch", Batch_Ref);
                     Send_Message (DC, Out_Msg);
                  end;
               end loop;
            end Each;
         begin
            begin
               Found := Store.Search (Net.Network_Record, Opts);
            exception
               when E : Soja.Msgstore.Store_Error =>
                  DC.Logger.Print
                    ("failed fetching messages for search: "
                     & Ada.Exceptions.Exception_Message (E));
                  return FAIL (["SEARCH", "INTERNAL_ERROR",
                                "Messages could not be retrieved"]);
            end;
            Send_Batch (DC, "soju.im/search", String_Vectors.Empty_Vector,
                        Each'Access);
         end;
      end;
      return Success;
   end Cmd_Search;

   ----------------------------------------------------------------------
   --  READ, MARKREAD
   ----------------------------------------------------------------------

   function Cmd_Read
     (DC : not null Downstream_Conn_Access; M : Message)
      return Irc_Error_Result
   is
      use type Ada.Calendar.Time;
      use type Soja.Database.Read_Receipt_Access;
      Cmd  : constant String := To_String (M.Command);
      PR   : constant Params_Result := Parse_Message_Params (M, 1);
   begin
      if not PR.Ok then
         return FAIL ([Cmd, "NEED_MORE_PARAMS", "Missing parameters"]);
      end if;

      declare
         Target   : constant String := Param (M, 0);
         Criteria : constant String :=
           (if M.Params.Length > 1 then Param (M, 1) else "");
      begin
         --  We don't save read receipts for our service.
         if Fold (DC, Target) = Service_Nick_CM then
            declare
               Reply : Message := Make (Cmd, [Target, "*"]);
            begin
               Reply.Prefix := new Prefix'(Prefix_Of (DC));
               Send_Message (DC, Reply);
            end;
            return Success;
         end if;

         if DC.Network = null then
            return FAIL ([Cmd, "INTERNAL_ERROR", Target,
                          "Cannot set read markers on bouncer connection"]);
         end if;

         declare
            Net       : constant Network_Access := DC.Network;
            Target_CM : constant String :=
              Soja.Irc.Case_Mapping.Fold (Net.Casemap, Target);
            Receipt   : Soja.Database.Read_Receipt :=
              (Target => To_Unbounded_String (Target_CM),
               Timestamp => Soja.Database.Null_Time, others => <>);
            Broadcast : Boolean := False;
         begin
            begin
               declare
                  Stored : constant Soja.Database.Read_Receipt_Access :=
                    Soja.Database.Get_Read_Receipt
                      (DB_Of (DC).all, Net.Network_Record.ID, Target_CM);
               begin
                  if Stored /= null then
                     Receipt := Stored.all;
                  end if;
               end;
            exception
               when E : Soja.Database.Database_Error =>
                  DC.Logger.Print
                    ("failed to get the read receipt for "
                     & Soja.Irc.Helpers.Quote (Target) & ": "
                     & Ada.Exceptions.Exception_Message (E));
                  return FAIL ([Cmd, "INTERNAL_ERROR", Target,
                                "Internal error"]);
            end;

            if Criteria /= "" then
               --  TODO (Go): support msgid criteria.
               declare
                  Eq : constant Natural :=
                    Ada.Strings.Fixed.Index (Criteria, "=");
               begin
                  if Eq = 0
                    or else Criteria (Criteria'First .. Eq - 1) /= "timestamp"
                  then
                     return FAIL ([Cmd, "INVALID_PARAMS", Criteria,
                                   "Unknown criteria"]);
                  end if;

                  declare
                     Valid : Boolean;
                     Stamp : Ada.Calendar.Time :=
                       Soja.Irc.Helpers.Parse_Server_Time
                         (Criteria (Eq + 1 .. Criteria'Last), Valid);
                     Now   : constant Ada.Calendar.Time := Ada.Calendar.Clock;
                  begin
                     if not Valid then
                        return FAIL ([Cmd, "INVALID_PARAMS", Criteria,
                                      "Invalid criteria"]);
                     end if;
                     if Stamp > Now then
                        Stamp := Now;
                     end if;
                     if Receipt.Timestamp < Stamp then
                        Receipt.Timestamp := Stamp;
                        begin
                           Soja.Database.Store_Read_Receipt
                             (DB_Of (DC).all, Net.Network_Record.ID, Receipt);
                        exception
                           when E : Soja.Database.Database_Error =>
                              DC.Logger.Print
                                ("failed to store receipt for "
                                 & Soja.Irc.Helpers.Quote (Target) & ": "
                                 & Ada.Exceptions.Exception_Message (E));
                              return FAIL ([Cmd, "INTERNAL_ERROR", Target,
                                            "Internal error"]);
                        end;
                        Broadcast := True;
                     end if;
                  end;
               end;
            end if;

            declare
               Stamp_Str : constant String :=
                 (if Receipt.Timestamp = Soja.Database.Null_Time then "*"
                  else "timestamp="
                       & Soja.Irc.Xirc.Format_Server_Time (Receipt.Timestamp));
            begin
               for D of Downstreams (Net) loop
                  if Broadcast or else D.ID = DC.ID then
                     declare
                        Out_Msg : Message := Make
                          ((if Soja.Irc.Cap_Registry.Is_Enabled
                                 (D.Caps, "draft/read-marker")
                            then "MARKREAD" else "READ"),
                           [Target, Stamp_Str]);
                     begin
                        Out_Msg.Prefix := new Prefix'(Prefix_Of (D));
                        Send_Message (D, Out_Msg);
                     end;
                  end if;
               end loop;

               --  A marker past the time of a pending push target clears it,
               --  and the other devices hear of it.
               if Broadcast and then Net.Push_Targets.Has (Target) then
                  if not (Receipt.Timestamp
                          < Net.Push_Targets.Get (Target))
                  then
                     Net.Push_Targets.Del (Target);
                  end if;
                  Soja.Core.Push.Broadcast
                    (Net, Make ("MARKREAD", [Target, Stamp_Str]));
               end if;
            end;
         end;
      end;
      return Success;
   end Cmd_Read;

   ----------------------------------------------------------------------
   --  WEBPUSH
   ----------------------------------------------------------------------

   function Cmd_Webpush
     (DC : not null Downstream_Conn_Access; M : Message)
      return Irc_Error_Result
   is
      use type Ada.Calendar.Time;
      PR : Params_Result := Parse_Message_Params (M, 1);
   begin
      if not Soja.Irc.Cap_Registry.Is_Enabled (DC.Caps, "soju.im/webpush") then
         return From_Error
           (Soja.Downstream.New_Unknown_Command_Error (To_String (M.Command)));
      end if;
      if not PR.Ok then
         return Need_More (PR);
      end if;

      declare
         Sub_Cmd : constant String := Param (M, 0);
         DB      : constant Soja.Database.Database_Access := DC.Srv.DB;
         User_ID : constant Long_Long_Integer := DC.User.User_Record.ID;
         Net_ID  : constant Long_Long_Integer :=
           (if DC.Network /= null then DC.Network.Network_Record.ID else 0);

         function Internal return Irc_Error_Result is
           (FAIL (["WEBPUSH", "INTERNAL_ERROR", Sub_Cmd, "Internal error"]));

         function Find
           (Subs : Soja.Database.WebPush_Subscription_Lists.Vector;
            Endpoint : String) return Natural is
         begin
            for I in 1 .. Natural (Subs.Length) loop
               if To_String (Subs (I).Endpoint) = Endpoint then
                  return I;
               end if;
            end loop;
            return 0;
         end Find;
      begin
         if Sub_Cmd = "REGISTER" then
            PR := Parse_Message_Params (M, 3);
            if not PR.Ok then
               return Need_More (PR);
            end if;
            declare
               Endpoint : constant String := Param (M, 1);
               Raw_Keys : constant Tag_Map := Parse_Tags (Param (M, 2));
               Subs     : Soja.Database.WebPush_Subscription_Lists.Vector;
               New_Sub  : Soja.Database.WebPush_Subscription;
               Update   : Boolean := True;
               Old      : Natural;
            begin
               if not Raw_Keys.Data.Contains ("auth")
                 or else not Raw_Keys.Data.Contains ("p256dh")
               then
                  return FAIL (["WEBPUSH", "INVALID_PARAMS", Sub_Cmd,
                                "Missing auth or p256dh key"]);
               end if;
               New_Sub.Endpoint := To_Unbounded_String (Endpoint);
               New_Sub.Key_VAPID :=
                 Soja.Server.Web_Push (DC.Srv.all).VAPID_Public;
               New_Sub.Key_Auth :=
                 To_Unbounded_String (Raw_Keys.Data.Element ("auth"));
               New_Sub.Key_P256DH :=
                 To_Unbounded_String (Raw_Keys.Data.Element ("p256dh"));

               begin
                  Subs := DB.List_WebPush_Subscriptions (User_ID, Net_ID);
               exception
                  when E : others =>
                     DC.Logger.Print
                       ("failed to fetch Web push subscription: "
                        & Ada.Exceptions.Exception_Message (E));
                     return Internal;
               end;
               if Natural (Subs.Length) > 25 then
                  return FAIL (["WEBPUSH", "INTERNAL_ERROR", Sub_Cmd,
                                "Too many subscriptions"]);
               end if;

               Old := Find (Subs, Endpoint);
               if Old /= 0 then
                  --  Update the old subscription, not a new one.
                  New_Sub.ID := Subs (Old).ID;
                  New_Sub.Created_At := Subs (Old).Created_At;
                  --  Rate-limit subscription checks.
                  Update :=
                    Ada.Calendar.Clock - Subs (Old).Updated_At
                      > Soja.Server.Webpush_Check_Subscription_Delay
                    or else Subs (Old).Key_Auth /= New_Sub.Key_Auth
                    or else Subs (Old).Key_P256DH /= New_Sub.Key_P256DH
                    or else Subs (Old).Key_VAPID /= New_Sub.Key_VAPID;
               end if;

               --  Send a test Web Push message, to make sure the endpoint is
               --  valid.
               if Update then
                  if not Soja.Webpush.Endpoint_Is_Acceptable (Endpoint) then
                     DC.Logger.Print
                       ("failed to sanity check Web push endpoint "
                        & Quote (Endpoint) & ": scheme must be HTTPS");
                     return FAIL (["WEBPUSH", "INVALID_PARAMS", Sub_Cmd,
                                   "Invalid endpoint"]);
                  end if;
                  begin
                     Soja.Core.Push.Send
                       (DC.Srv.all, New_Sub,
                        Make ("NOTE", ["WEBPUSH", "REGISTERED",
                                       "Push notifications enabled"]));
                  exception
                     when E : others =>
                        DC.Logger.Print
                          ("failed to send Web push notification to endpoint "
                           & Quote (Endpoint) & ": "
                           & Ada.Exceptions.Exception_Message (E));
                        return FAIL (["WEBPUSH", "INVALID_PARAMS", Sub_Cmd,
                                      "Invalid endpoint"]);
                  end;
                  begin
                     DB.Store_WebPush_Subscription (User_ID, Net_ID, New_Sub);
                  exception
                     when E : others =>
                        DC.Logger.Print
                          ("failed to store Web push subscription: "
                           & Ada.Exceptions.Exception_Message (E));
                        return Internal;
                  end;
               end if;
               Send_Message (DC, Make ("WEBPUSH", ["REGISTER", Endpoint]));
            end;

         elsif Sub_Cmd = "UNREGISTER" then
            PR := Parse_Message_Params (M, 2);
            if not PR.Ok then
               return Need_More (PR);
            end if;
            declare
               Endpoint : constant String := Param (M, 1);
               Subs     : Soja.Database.WebPush_Subscription_Lists.Vector;
               Old      : Natural;
            begin
               begin
                  Subs := DB.List_WebPush_Subscriptions (User_ID, Net_ID);
               exception
                  when E : others =>
                     DC.Logger.Print
                       ("failed to fetch Web push subscription: "
                        & Ada.Exceptions.Exception_Message (E));
                     return Internal;
               end;
               Old := Find (Subs, Endpoint);
               if Old /= 0 then
                  begin
                     DB.Delete_WebPush_Subscription (Subs (Old).ID);
                  exception
                     when E : others =>
                        DC.Logger.Print
                          ("failed to delete Web push subscription: "
                           & Ada.Exceptions.Exception_Message (E));
                        return Internal;
                  end;
               end if;
               Send_Message (DC, Make ("WEBPUSH", ["UNREGISTER", Endpoint]));
            end;

         else
            return FAIL (["WEBPUSH", "INVALID_PARAMS", Sub_Cmd,
                          "Unknown command"]);
         end if;
      end;
      return Success;
   end Cmd_Webpush;

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
      elsif Cmd = "PRIVMSG" or else Cmd = "NOTICE" or else Cmd = "TAGMSG" then
         return Cmd_Chat (DC, M);
      elsif Cmd = "INVITE" then
         return Cmd_Invite (DC, M);
      elsif Cmd = "AUTHENTICATE" then
         return Cmd_Authenticate (DC, M);
      elsif Cmd = "REGISTER" or else Cmd = "VERIFY" then
         return Cmd_Register (DC, M);
      elsif Cmd = "AWAY" then
         return Cmd_Away (DC, M);
      elsif Cmd = "INFO" then
         return Cmd_Info (DC, M);
      elsif Cmd = "MONITOR" then
         return Cmd_Monitor (DC, M);
      elsif Cmd = "BOUNCER" then
         return Cmd_Bouncer (DC, M);
      elsif Cmd = "CHATHISTORY" then
         return Cmd_Chat_History (DC, M);
      elsif Cmd = "SEARCH" then
         return Cmd_Search (DC, M);
      elsif Cmd = "READ" or else Cmd = "MARKREAD" then
         return Cmd_Read (DC, M);
      elsif Cmd = "WEBPUSH" then
         return Cmd_Webpush (DC, M);
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
