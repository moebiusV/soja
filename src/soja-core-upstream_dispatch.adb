pragma Ada_2022;

with Ada.Calendar;
with Ada.Containers;
with Ada.Containers.Indefinite_Hashed_Sets;
with Ada.Strings.Fixed;
with Ada.Strings.Hash;

with Soja.Base64;
with Soja.Core.Downstream_Helpers;
with Soja.Downstream;
with Soja.Irc.Cap_Registry;
with Soja.Irc.Case_Mapping;
with Soja.Irc.Genmsg;
with Soja.Irc.Helpers;
with Soja.Irc.Members;
with Soja.Irc.Modes;
with Soja.Irc.Numerics;
with Soja.Irc.Xirc;

package body Soja.Core.Upstream_Dispatch is

   use Soja.Irc.Cap_Registry;
   use Soja.Irc.Genmsg;
   use Soja.Irc.Helpers;
   use Soja.Irc.Messages;
   use Soja.Irc.Numerics;

   use type Ada.Calendar.Time;
   use type Ada.Containers.Count_Type;

   ----------------------------------------------------------------------
   --  Static tables (upstream.go / downstream.go)
   ----------------------------------------------------------------------

   type String_Ptr is access constant String;

   --  permanentUpstreamCaps: always requested when the server supports them.
   Permanent_Upstream_Caps :
     constant array (Positive range <>) of String_Ptr :=
     [new String'("account-notify"), new String'("account-tag"),
      new String'("away-notify"), new String'("batch"),
      new String'("chghost"), new String'("extended-join"),
      new String'("extended-monitor"), new String'("invite-notify"),
      new String'("labeled-response"), new String'("message-tags"),
      new String'("multi-prefix"), new String'("sasl"),
      new String'("server-time"), new String'("setname"),
      new String'("draft/account-registration"),
      new String'("draft/extended-monitor")];

   function Is_Permanent_Upstream_Cap (Name : String) return Boolean is
   begin
      for C of Permanent_Upstream_Caps loop
         if C.all = Name then
            return True;
         end if;
      end loop;
      return False;
   end Is_Permanent_Upstream_Cap;

   --  passthroughIsupport: ISUPPORT tokens passed straight through to
   --  downstreams.
   Passthrough_Isupport : constant array (Positive range <>) of String_Ptr :=
     [new String'("AWAYLEN"), new String'("BOT"), new String'("CASEMAPPING"),
      new String'("CHANLIMIT"), new String'("CHANMODES"),
      new String'("CHANNELLEN"), new String'("CHANTYPES"),
      new String'("CLIENTTAGDENY"), new String'("ELIST"),
      new String'("EXCEPTS"), new String'("EXTBAN"), new String'("HOSTLEN"),
      new String'("INVEX"), new String'("KICKLEN"), new String'("LINELEN"),
      new String'("MAXLIST"), new String'("MAXTARGETS"), new String'("MODES"),
      new String'("MONITOR"), new String'("NAMELEN"), new String'("NETWORK"),
      new String'("NICKLEN"), new String'("PREFIX"), new String'("SAFELIST"),
      new String'("STATUSMSG"), new String'("TARGMAX"),
      new String'("TOPICLEN"), new String'("USERLEN"),
      new String'("UTF8ONLY"), new String'("WHOX")];

   function Is_Passthrough_Isupport (Name : String) return Boolean is
   begin
      for T of Passthrough_Isupport loop
         if T.all = Name then
            return True;
         end if;
      end loop;
      return False;
   end Is_Passthrough_Isupport;

   ----------------------------------------------------------------------
   --  Small helpers
   ----------------------------------------------------------------------

   function Upper (S : String) return String is
      R : String := S;
   begin
      for C of R loop
         if C in 'a' .. 'z' then
            C := Character'Val (Character'Pos (C) - 32);
         end if;
      end loop;
      return R;
   end Upper;

   function Lower (S : String) return String is
      R : String := S;
   begin
      for C of R loop
         if C in 'A' .. 'Z' then
            C := Character'Val (Character'Pos (C) + 32);
         end if;
      end loop;
      return R;
   end Lower;

   --  strings.Fields.
   function Fields (S : String) return String_Vectors.Vector is
      V     : String_Vectors.Vector;
      Start : Natural := 0;
   begin
      for I in S'Range loop
         if S (I) in ' ' | ASCII.HT | ASCII.LF | ASCII.VT | ASCII.FF
           | ASCII.CR
         then
            if Start /= 0 then
               V.Append (S (Start .. I - 1));
               Start := 0;
            end if;
         elsif Start = 0 then
            Start := I;
         end if;
      end loop;
      if Start /= 0 then
         V.Append (S (Start .. S'Last));
      end if;
      return V;
   end Fields;

   Success : constant Handle_Result := (others => <>);

   function Fail (Text : String) return Handle_Result is
     (Failed => True, Is_Registration_Error => False,
      Reason => To_Unbounded_String (Text), Temporary => True);

   function Need_More (Command : String) return Handle_Result is
     (Fail (Soja.Downstream.Image
              (Soja.Downstream.New_Need_More_Params_Error (Command))));

   --  registrationError{msg}: Reason is the last param (or the command) and
   --  Temporary is false only when fixing it needs a network configuration
   --  change.
   function Registration_Error (M : Message) return Handle_Result is
      Cmd : constant String := To_String (M.Command);
      Temp : Boolean := True;
   begin
      if Cmd = ERR_PASSWDMISMATCH or else Cmd = ERR_ERRONEUSNICKNAME then
         Temp := False;
      elsif Cmd = "FAIL" then
         Temp := Param (M, 1) /= "ACCOUNT_REQUIRED";
      end if;
      return (Failed => True, Is_Registration_Error => True,
              Reason => (if M.Params.Is_Empty then To_Unbounded_String (Cmd)
                         else M.Params.Last_Element),
              Temporary => Temp);
   end Registration_Error;

   --  parseMessageParams, as a ready-made failure.
   function Check_Params (M : Message; Count : Natural; Bad : out Boolean)
      return Handle_Result
   is
      R : constant Params_Result := Parse_Message_Params (M, Count);
   begin
      Bad := not R.Ok;
      if R.Ok then
         return Success;
      end if;
      return Fail (Soja.Downstream.Image (R.Err));
   end Check_Params;

   function With_Params (Command : String; P : Param_Vectors.Vector)
      return Message
   is
      M : Message := (others => <>);
   begin
      M.Command := To_Unbounded_String (Command);
      M.Params := P;
      return M;
   end With_Params;

   --  The string "<nick>"-less ERR text for logging a message: msg.String().
   function Text_Of (M : Message) return String is (Image (M));

   ----------------------------------------------------------------------
   --  Downstreams and forwarding
   ----------------------------------------------------------------------

   function Downstream_By_ID
     (UC : not null Upstream_Conn_Access; ID : Long_Long_Integer)
      return Downstream_Conn_Access
   is
   begin
      for DC of UC.User.Downstream_Conns loop
         if DC.ID = ID then
            return DC;
         end if;
      end loop;
      return null;
   end Downstream_By_ID;

   procedure Forward_Message
     (UC : not null Upstream_Conn_Access; M : Message) is
   begin
      for DC of Downstreams (UC.Network) loop
         Send_Message (DC, M);
      end loop;
   end Forward_Message;

   procedure Forward_Msg_By_ID
     (UC : not null Upstream_Conn_Access;
      ID : Long_Long_Integer;
      M  : Message)
   is
   begin
      for DC of Downstreams (UC.Network) loop
         if ID = 0 or else ID = DC.ID then
            Send_Message (DC, M);
         end if;
      end loop;
   end Forward_Msg_By_ID;

   function Is_Channel
     (UC : not null Upstream_Conn_Access; Entity : String) return Boolean is
   begin
      return Entity'Length > 0
        and then Ada.Strings.Fixed.Index
                   (To_String (UC.Available_Channel_Types),
                    [1 => Entity (Entity'First)]) > 0;
   end Is_Channel;

   procedure Send_Message_Labeled
     (UC : not null Upstream_Conn_Access;
      ID : Long_Long_Integer;
      M  : Message)
   is
      Msg : Message := Copy (M);
   begin
      if Is_Enabled (UC.Caps, "labeled-response") then
         Set_Tag (Msg.Tags, "label",
                  "sd-" & Ada.Strings.Fixed.Trim
                            (Long_Long_Integer'Image (ID), Ada.Strings.Left)
                  & "-" & Ada.Strings.Fixed.Trim
                            (Long_Long_Integer'Image (UC.Next_Label_ID),
                             Ada.Strings.Left));
         UC.Next_Label_ID := UC.Next_Label_ID + 1;
      end if;
      Send_Message (UC, Msg);
   end Send_Message_Labeled;

   ----------------------------------------------------------------------
   --  Pending commands
   ----------------------------------------------------------------------

   procedure Send_Next_Pending_Command
     (UC : not null Upstream_Conn_Access; Cmd : String)
   is
   begin
      if not UC.Pending_Cmds.Contains (Cmd)
        or else UC.Pending_Cmds (Cmd).Is_Empty
      then
         return;
      end if;

      declare
         V : Pending_Command_Vectors.Vector := UC.Pending_Cmds (Cmd);
         P : Pending_Upstream_Command := V (1);
      begin
         Send_Message_Labeled (UC, P.Downstream_ID, P.Msg);
         P.Sent_At := Ada.Calendar.Clock;
         V.Replace_Element (1, P);
         UC.Pending_Cmds.Replace (Cmd, V);
      end;
   end Send_Next_Pending_Command;

   procedure Enqueue_Command
     (UC : not null Upstream_Conn_Access;
      DC : not null Downstream_Conn_Access;
      M  : Message)
   is
      Cmd : constant String := To_String (M.Command);
   begin
      if not (Cmd in "LIST" | "WHO" | "WHOIS" | "AUTHENTICATE" | "REGISTER"
                     | "VERIFY")
      then
         raise Program_Error with "Unsupported pending command " & Quote (Cmd);
      end if;

      if not UC.Pending_Cmds.Contains (Cmd) then
         UC.Pending_Cmds.Insert (Cmd, Pending_Command_Vectors.Empty_Vector);
      end if;

      declare
         V : Pending_Command_Vectors.Vector := UC.Pending_Cmds (Cmd);
      begin
         V.Append (Pending_Upstream_Command'
                     (Downstream_ID => DC.ID, Msg => Copy (M),
                      Sent_At => Zero_Time));

         --  If we didn't get a reply after a while, just give up.  (Go
         --  writes this as copy(l, l[1:]), which shifts the entries down
         --  but keeps the length, so the last one is duplicated; kept.)
         if V (1).Sent_At /= Zero_Time
           and then Ada.Calendar.Clock - V (1).Sent_At > 30.0
         then
            for I in 1 .. Natural (V.Length) - 1 loop
               V.Replace_Element (I, V (I + 1));
            end loop;
         end if;

         UC.Pending_Cmds.Replace (Cmd, V);
         if V.Length = 1 then
            Send_Next_Pending_Command (UC, Cmd);
         end if;
      end;
   end Enqueue_Command;

   function Current_Pending_Command
     (UC : not null Upstream_Conn_Access; Cmd : String) return Pending_Command
   is
   begin
      if not UC.Pending_Cmds.Contains (Cmd)
        or else UC.Pending_Cmds (Cmd).Is_Empty
      then
         return (Found => False, others => <>);
      end if;
      declare
         P : constant Pending_Upstream_Command := UC.Pending_Cmds (Cmd) (1);
      begin
         return (Found => True,
                 DC    => Downstream_By_ID (UC, P.Downstream_ID),
                 Msg   => Copy (P.Msg));
      end;
   end Current_Pending_Command;

   function Dequeue_Command
     (UC : not null Upstream_Conn_Access; Cmd : String) return Pending_Command
   is
      Result : constant Pending_Command := Current_Pending_Command (UC, Cmd);
   begin
      if UC.Pending_Cmds.Contains (Cmd)
        and then not UC.Pending_Cmds (Cmd).Is_Empty
      then
         declare
            V : Pending_Command_Vectors.Vector := UC.Pending_Cmds (Cmd);
         begin
            V.Delete_First;
            UC.Pending_Cmds.Replace (Cmd, V);
         end;
      end if;

      Send_Next_Pending_Command (UC, Cmd);
      return Result;
   end Dequeue_Command;

   procedure Abort_Pending_Commands (UC : not null Upstream_Conn_Access) is
      use Soja.Core.Downstream_Helpers;
   begin
      for C in UC.Pending_Cmds.Iterate loop
         for P of UC.Pending_Cmds (C) loop
            declare
               DC  : constant Downstream_Conn_Access :=
                 Downstream_By_ID (UC, P.Downstream_ID);
               Cmd : constant String := To_String (P.Msg.Command);
            begin
               if DC /= null then
                  if Cmd = "LIST" then
                     Send_Message
                       (DC, Make (RPL_LISTEND,
                                  [To_String (DC.Nick), "Command aborted"]));
                  elsif Cmd = "WHO" then
                     Send_Message
                       (DC, Make (RPL_ENDOFWHO,
                                  [To_String (DC.Nick),
                                   (if P.Msg.Params.Is_Empty then "*"
                                    else Param (P.Msg, 0)),
                                   "Command aborted"]));
                  elsif Cmd = "WHOIS" then
                     Send_Message
                       (DC, Make (RPL_ENDOFWHOIS,
                                  [To_String (DC.Nick), Trailing (P.Msg),
                                   "Command aborted"]));
                  elsif Cmd = "AUTHENTICATE" then
                     End_SASL
                       (DC, Make (ERR_SASLABORTED,
                                  [To_String (DC.Nick),
                                   "SASL authentication aborted"]));
                  elsif Cmd = "REGISTER" or else Cmd = "VERIFY" then
                     Send_Message
                       (DC, Make ("FAIL",
                                  [Cmd, "TEMPORARILY_UNAVAILABLE",
                                   Param (P.Msg, 0), "Command aborted"]));
                  else
                     raise Program_Error with
                       "Unsupported pending command " & Quote (Cmd);
                  end if;
               end if;
            end;
         end loop;
      end loop;
      UC.Pending_Cmds.Clear;
   end Abort_Pending_Commands;

   procedure Cancel_Pending_Commands_By_Downstream_ID
     (UC : not null Upstream_Conn_Access; ID : Long_Long_Integer)
   is
      Names : String_Vectors.Vector;
   begin
      for C in UC.Pending_Cmds.Iterate loop
         Names.Append (Pending_Command_Maps.Key (C));
      end loop;
      for Cmd of Names loop
         declare
            V : Pending_Command_Vectors.Vector := UC.Pending_Cmds (Cmd);
         begin
            --  The currently running command, V (1), cannot be cancelled.
            for I in reverse 2 .. Natural (V.Length) loop
               if V (I).Downstream_ID = ID then
                  V.Delete (I);
               end if;
            end loop;
            UC.Pending_Cmds.Replace (Cmd, V);
         end;
      end loop;
   end Cancel_Pending_Commands_By_Downstream_ID;

   ----------------------------------------------------------------------
   --  Capabilities and SASL
   ----------------------------------------------------------------------

   procedure Handle_Supported_Caps
     (UC : not null Upstream_Conn_Access; Caps : String)
   is
   begin
      for S of Fields (Caps) loop
         declare
            Eq : constant Natural := Ada.Strings.Fixed.Index (S, "=");
         begin
            if Eq = 0 then
               Set_Available (UC.Caps, Lower (S), "");
            else
               Set_Available
                 (UC.Caps, Lower (S (S'First .. Eq - 1)),
                  S (Eq + 1 .. S'Last));
            end if;
         end;
      end loop;
   end Handle_Supported_Caps;

   procedure Update_Caps (UC : not null Upstream_Conn_Access) is
      Request : String_Vectors.Vector;
      Joined  : Unbounded_String;
      Echo    : constant Boolean := Is_Available (UC.Caps, "labeled-response");
   begin
      for C of Permanent_Upstream_Caps loop
         if Is_Available (UC.Caps, C.all)
           and then not Is_Enabled (UC.Caps, C.all)
         then
            Request.Append (C.all);
         end if;
      end loop;

      if not Is_Enabled (UC.Caps, "echo-message") and then Echo then
         Request.Append ("echo-message");
      elsif Is_Enabled (UC.Caps, "echo-message") and then not Echo then
         Request.Append ("-echo-message");
      end if;

      if Request.Is_Empty then
         return;
      end if;

      for C of Request loop
         if Length (Joined) > 0 then
            Append (Joined, " ");
         end if;
         Append (Joined, C);
      end loop;
      Send_Message (UC, Make ("CAP", ["REQ", To_String (Joined)]));
   end Update_Caps;

   function Supports_SASL
     (UC : not null Upstream_Conn_Access; Mech : String) return Boolean
   is
      pragma Unreferenced (Mech);
   begin
      --  Go: `if strings.EqualFold(mech, mech)` -- the loop variable shadows
      --  the parameter, so any advertised "sasl" counts as support.
      return Is_Available (UC.Caps, "sasl");
   end Supports_SASL;

   function Request_SASL (UC : not null Upstream_Conn_Access) return Boolean is
      Mech : constant String :=
        To_String (UC.Network.Network_Record.SASL.Mechanism);
   begin
      if Mech = "" then
         return False;
      end if;
      return Supports_SASL (UC, Mech);
   end Request_SASL;

   function Handle_Cap_Ack
     (UC : not null Upstream_Conn_Access; Name : String; Ok : Boolean)
      return Handle_Result
   is
   begin
      Set_Enabled (UC.Caps, Name, Ok);

      if Name = "sasl" then
         if not Request_SASL (UC) then
            return Success;
         end if;
         if not Ok then
            UC.Logger.Print
              ("server refused to acknowledge the SASL capability");
            return Success;
         end if;

         declare
            Auth : Soja.Database.SASL renames
              UC.Network.Network_Record.SASL;
            Mech : constant String := To_String (Auth.Mechanism);
         begin
            if Mech = "PLAIN" then
               UC.Logger.Print
                 ("starting SASL PLAIN authentication with username "
                  & Quote (To_String (Auth.Plain_Username)));
               UC.Sasl_Mech := Sasl_Plain;
               UC.Sasl_Username := Auth.Plain_Username;
               UC.Sasl_Password := Auth.Plain_Password;
            elsif Mech = "EXTERNAL" then
               UC.Logger.Print ("starting SASL EXTERNAL authentication");
               UC.Sasl_Mech := Sasl_External;
            else
               --  (Go formats the capability name here, not the mechanism.)
               return Fail ("unsupported SASL mechanism " & Quote (Name));
            end if;
            Send_Message (UC, Make ("AUTHENTICATE", [Mech]));
         end;
      elsif Name = "echo-message" then
         null;
      elsif not Is_Permanent_Upstream_Cap (Name) then
         UC.Logger.Print
           ("received CAP ACK/NAK for a cap we don't support: " & Name);
      end if;
      return Success;
   end Handle_Cap_Ack;

   ----------------------------------------------------------------------
   --  ISUPPORT value handlers
   ----------------------------------------------------------------------

   function Handle_Chan_Modes
     (UC : not null Upstream_Conn_Access; S : String) return Handle_Result
   is
      use Soja.Irc.Modes;
      Modes : Mode_Type_Maps.Map;
      Part  : Natural := 0;      --  0 .. 3: the CHANMODES type being read
      Types : constant array (0 .. 3) of Channel_Mode_Type :=
        [Mode_Type_A, Mode_Type_B, Mode_Type_C, Mode_Type_D];
      Commas : Natural := 0;
   begin
      for C of S loop
         if C = ',' then
            Commas := Commas + 1;
         end if;
      end loop;
      --  strings.SplitN(s, ",", 5): fewer than four parts is malformed.
      if Commas < 3 then
         return Fail ("malformed ISUPPORT CHANMODES value: " & S);
      end if;

      for C of S loop
         exit when Part > 3;
         if C = ',' then
            Part := Part + 1;
         else
            Modes.Include (C, Types (Part));
         end if;
      end loop;
      UC.Available_Channel_Modes := Modes;
      return Success;
   end Handle_Chan_Modes;

   function Handle_Memberships
     (UC : not null Upstream_Conn_Access; S : String) return Handle_Result
   is
      use Soja.Irc.Members;
      Sep : Integer;   --  0-based index of ')', -1 when absent
   begin
      if S = "" then
         UC.Available_Memberships.Clear;
         return Success;
      end if;

      if S (S'First) /= '(' then
         return Fail ("malformed ISUPPORT PREFIX value: " & S);
      end if;
      Sep := (if Ada.Strings.Fixed.Index (S, ")") = 0 then -1
              else Ada.Strings.Fixed.Index (S, ")") - S'First);
      if Sep < 0 or else S'Length /= Sep * 2 then
         return Fail ("malformed ISUPPORT PREFIX value: " & S);
      end if;

      declare
         Result : Membership_Vectors.Vector;
      begin
         for I in 0 .. S'Length / 2 - 2 loop
            Result.Append
              (Membership'(Mode   => S (S'First + I + 1),
                           Prefix => S (S'First + Sep + I + 1)));
         end loop;
         UC.Available_Memberships := Result;
      end;
      return Success;
   end Handle_Memberships;

   ----------------------------------------------------------------------
   --  MONITOR
   ----------------------------------------------------------------------

   function Should_Cache_User_Info
     (UC : not null Upstream_Conn_Access; Nick : String) return Boolean
   is
      Found : Boolean := False;

      procedure Check (Name : String; Ch : Upstream_Channel_Access) is
         pragma Unreferenced (Name);
      begin
         Found := Found or else Ch.Members.Has (Nick);
      end Check;
   begin
      if Is_Our_Nick (UC, Nick) then
         return True;
      end if;
      --  Keep the cached user info only if we MONITOR it, or we share a
      --  channel with them.
      if UC.Monitored.Has (Nick) then
         return True;
      end if;
      UC.Channels.For_Each (Check'Access);
      return Found;
   end Should_Cache_User_Info;

   package Name_Sets is new Ada.Containers.Indefinite_Hashed_Sets
     (Element_Type => String, Hash => Ada.Strings.Hash,
      Equivalent_Elements => "=");

   procedure Update_Monitor (UC : not null Upstream_Conn_Access) is
      Net : constant Network_Access := UC.Network;

      function CM (S : String) return String is
        (Soja.Irc.Case_Mapping.Fold (Net.Casemap, S));

      Add_Set  : Name_Sets.Set;
      Add_List : String_Vectors.Vector;
      Seen     : Name_Sets.Set;
   begin
      if not UC.Isupport.Contains ("MONITOR") then
         return;
      end if;

      for DC of Downstreams (Net) loop
         declare
            procedure Visit (Target : String; Present : Boolean) is
               pragma Unreferenced (Present);
               Target_CM : constant String := CM (Target);
            begin
               if Target_CM = Service_Nick_CM then
                  return;
               end if;
               if not UC.Monitored.Has (Target_CM) then
                  if not Add_Set.Contains (Target_CM) then
                     Add_List.Append (Target_CM);
                     Add_Set.Include (Target_CM);
                  end if;
               else
                  Seen.Include (Target_CM);
               end if;
            end Visit;
         begin
            DC.Monitored.For_Each (Visit'Access);
         end;
      end loop;

      declare
         Want    : constant String := Soja.Database.Get_Nick
           (UC.User.User_Record, Net.Network_Record);
         Want_CM : constant String := CM (Want);
      begin
         if not Add_Set.Contains (Want_CM)
           and then not UC.Monitored.Has (Want)
           and then not Is_Our_Nick (UC, Want)
           and then not UC.Has_Desired_Nick
         then
            Add_List.Append (Want_CM);
            Add_Set.Include (Want_CM);
         end if;
      end;

      declare
         Remove_All  : Boolean := True;
         Remove_List : String_Vectors.Vector;

         procedure Visit (Nick : String; Online : Boolean) is
            pragma Unreferenced (Online);
         begin
            if Seen.Contains (CM (Nick)) then
               Remove_All := False;
            else
               Remove_List.Append (Nick);
            end if;
         end Visit;
      begin
         UC.Monitored.For_Each (Visit'Access);

         --  TODO (Go): better handle the case where the list would exceed
         --  the server's limit, probably by immediately sending
         --  ERR_MONLISTFULL.
         if Remove_All and then Add_List.Is_Empty
           and then not Remove_List.Is_Empty
         then
            --  Optimization when the last MONITOR-aware downstream
            --  disconnects.
            Send_Message (UC, Make ("MONITOR", ["C"]));
         else
            for M of Generate_Monitor ("-", Remove_List) loop
               Send_Message (UC, M);
            end loop;
            for M of Generate_Monitor ("+", Add_List) loop
               Send_Message (UC, M);
            end loop;
         end if;

         for Target of Remove_List loop
            UC.Monitored.Del (Target);
            if not Should_Cache_User_Info (UC, Target) then
               UC.Users.Del (Target);
            end if;
         end loop;
      end;
   end Update_Monitor;

   ----------------------------------------------------------------------
   --  uc.handleMessage, case by case
   ----------------------------------------------------------------------

   function Handle_Cap
     (UC : not null Upstream_Conn_Access; Msg : Message) return Handle_Result
   is
      use Soja.Core.Downstream_Helpers;
      Bad : Boolean;
      R   : Handle_Result := Check_Params (Msg, 2, Bad);
   begin
      if Bad then
         return R;
      end if;

      declare
         Sub_Cmd : constant String := Upper (Param (Msg, 1));
         N       : constant Natural := Natural (Msg.Params.Length) - 2;
         Cmd     : constant String := To_String (Msg.Command);
      begin
         if Sub_Cmd = "LS" then
            if N < 1 then
               return Need_More (Cmd);
            end if;
            declare
               Caps : constant String :=
                 Param (Msg, Natural (Msg.Params.Length) - 1);
               --  (Go indexes msg.Params, not the sub-params, with len-2.)
               More : constant Boolean :=
                 N >= 2 and then Param (Msg, N - 2) = "*";
            begin
               Handle_Supported_Caps (UC, Caps);
               if not More then
                  Update_Caps (UC);
                  if not Request_SASL (UC) then
                     --  Otherwise CAP END is sent once authentication is
                     --  completed.
                     Send_Message (UC, Make ("CAP", ["END"]));
                  end if;
               end if;
            end;

         elsif Sub_Cmd = "ACK" or else Sub_Cmd = "NAK" then
            if N < 1 then
               return Need_More (Cmd);
            end if;
            for Name of Fields (Param (Msg, 2)) loop
               declare
                  Enable : Boolean := Sub_Cmd = "ACK";
                  Cap    : constant String :=
                    (if Name (Name'First) = '-'
                     then Name (Name'First + 1 .. Name'Last) else Name);
               begin
                  if Name (Name'First) = '-' then
                     Enable := False;
                  end if;
                  R := Handle_Cap_Ack (UC, Lower (Cap), Enable);
                  if R.Failed then
                     return R;
                  end if;
               end;
            end loop;

            if UC.Registered then
               for DC of Downstreams (UC.Network) loop
                  Update_Supported_Caps (DC);
               end loop;
            end if;

         elsif Sub_Cmd = "NEW" then
            if N < 1 then
               return Need_More (Cmd);
            end if;
            Handle_Supported_Caps (UC, Param (Msg, 2));
            Update_Caps (UC);

         elsif Sub_Cmd = "DEL" then
            if N < 1 then
               return Need_More (Cmd);
            end if;
            for C of Fields (Param (Msg, 2)) loop
               Delete (UC.Caps, C);
            end loop;
            if UC.Registered then
               for DC of Downstreams (UC.Network) loop
                  Update_Supported_Caps (DC);
               end loop;
            end if;

         else
            UC.Logger.Debug ("unhandled message: " & Text_Of (Msg));
         end if;
      end;
      return Success;
   end Handle_Cap;

   function Handle_Authenticate
     (UC : not null Upstream_Conn_Access; Msg : Message) return Handle_Result
   is
      Star : constant Message := Make ("AUTHENTICATE", ["*"]);
      Bad  : Boolean;
      R    : Handle_Result;
   begin
      if UC.Sasl_Mech = Sasl_None then
         return Fail ("received unexpected AUTHENTICATE message");
      end if;

      --  TODO (Go): if a challenge is 400 bytes long, buffer it.
      R := Check_Params (Msg, 1, Bad);
      if Bad then
         Send_Message (UC, Star);
         return R;
      end if;

      declare
         Challenge_Str : constant String := Param (Msg, 0);
         Valid         : Boolean := True;
         Challenge     : constant String :=
           (if Challenge_Str /= "+"
            then Soja.Base64.Decode (Challenge_Str, Valid) else "");
         pragma Unreferenced (Challenge);   --  PLAIN/EXTERNAL ignore it
      begin
         if not Valid then
            Send_Message (UC, Star);
            return Fail ("illegal base64 data in AUTHENTICATE challenge");
         end if;

         --  go-sasl's PLAIN and EXTERNAL clients (empty authorization
         --  identity): Start gives the initial response, Next fails because
         --  neither mechanism has a server challenge.
         declare
            Resp : Unbounded_String;
         begin
            if not UC.Sasl_Started then
               UC.Sasl_Started := True;
               if UC.Sasl_Mech = Sasl_Plain then
                  Resp := To_Unbounded_String
                    (ASCII.NUL & To_String (UC.Sasl_Username) & ASCII.NUL
                     & To_String (UC.Sasl_Password));
               end if;   --  EXTERNAL: empty
            else
               Send_Message (UC, Star);
               return Fail ("sasl: unexpected server challenge");
            end if;

            for M of Generate_SASL (To_String (Resp)) loop
               Send_Message (UC, M);
            end loop;
         end;
      end;
      return Success;
   end Handle_Authenticate;

   function Handle_Welcome
     (UC : not null Upstream_Conn_Access; Msg : Message) return Handle_Result
   is
      Bad : Boolean;
      R   : constant Handle_Result := Check_Params (Msg, 1, Bad);
   begin
      if Bad then
         return R;
      end if;

      UC.Nick := Msg.Params (1);
      UC.Registered := True;
      UC.Server_Prefix := Msg.Prefix;
      UC.Logger.Print
        ("connection registered with nick " & Quote (To_String (UC.Nick)));

      --  Join the network's saved channels.  This is the only place soja
      --  joins on its own: once per (re)connection, never in response to a
      --  kick or a refused join (see PORTING.md).
      if UC.Network.Channels.Length > 0 then
         declare
            Channels, Keys : String_Vectors.Vector;

            procedure Collect (Name : String; Ch : Channel_Access) is
               pragma Unreferenced (Name);
            begin
               Channels.Append (To_String (Ch.Name));
               Keys.Append (To_String (Ch.Key));
            end Collect;
         begin
            UC.Network.Channels.For_Each (Collect'Access);
            for M of Generate_Join (Channels, Keys) loop
               Send_Message (UC, M);
            end loop;
         end;
      end if;
      return Success;
   end Handle_Welcome;

   function Handle_Isupport
     (UC : not null Upstream_Conn_Access; Msg : Message) return Handle_Result
   is
      Bad : Boolean;
      R   : Handle_Result := Check_Params (Msg, 2, Bad);
      Downstream_Isupport : String_Vectors.Vector;
   begin
      if Bad then
         return R;
      end if;

      --  Params[1 : len-1]: the tokens between the nick and the text.
      for I in 1 .. Natural (Msg.Params.Length) - 2 loop
         declare
            Raw       : constant String := Param (Msg, I);
            Token     : Unbounded_String := To_Unbounded_String (Raw);
            Parameter : Unbounded_String := To_Unbounded_String (Raw);
            Negate    : Boolean := False;
            Has_Value : Boolean := False;
            Value     : Unbounded_String;
         begin
            if Raw'Length > 0 and then Raw (Raw'First) = '-' then
               Negate := True;
               Token := To_Unbounded_String (Raw (Raw'First + 1 .. Raw'Last));
               --  (Go leaves `parameter` as-is here, "-"-prefixed, so the
               --  negation branches of the switch below never match.)
            else
               declare
                  Eq : constant Natural := Ada.Strings.Fixed.Index (Raw, "=");
               begin
                  if Eq > 0 then
                     Parameter := To_Unbounded_String
                       (Raw (Raw'First .. Eq - 1));
                     Value := To_Unbounded_String (Raw (Eq + 1 .. Raw'Last));
                     Has_Value := True;
                  end if;
               end;
            end if;
            Parameter := To_Unbounded_String (Upper (To_String (Parameter)));

            declare
               Name : constant String := To_String (Parameter);
               Val  : constant String := To_String (Value);
            begin
               if Has_Value then
                  UC.Isupport.Include
                    (Name, (Has_Value => True, Value => Value));
               elsif not Negate then
                  UC.Isupport.Include
                    (Name, (Has_Value => False, Value => <>));
               else
                  UC.Isupport.Exclude (Name);
               end if;

               R := Success;
               if Name = "CASEMAPPING" then
                  Update_Casemapping
                    (UC.Network,
                     Soja.Irc.Case_Mapping.Parse_Case_Mapping (Val));
               elsif Name = "CHANMODES" then
                  if not Negate then
                     R := Handle_Chan_Modes (UC, Val);
                  else
                     UC.Available_Channel_Modes :=
                       Soja.Irc.Modes.Std_Channel_Modes;
                  end if;
               elsif Name = "CHANTYPES" then
                  UC.Available_Channel_Types := To_Unbounded_String
                    (if not Negate then Val
                     else Soja.Irc.Members.Std_Channel_Types);
               elsif Name = "STATUSMSG" then
                  UC.Available_Status_Msg :=
                    To_Unbounded_String (if not Negate then Val else "");
               elsif Name = "PREFIX" then
                  if not Negate then
                     R := Handle_Memberships (UC, Val);
                  else
                     UC.Available_Memberships.Clear;
                     for M of Soja.Irc.Members.Std_Memberships loop
                        UC.Available_Memberships.Append (M);
                     end loop;
                  end if;
               end if;
               if R.Failed then
                  return R;
               end if;

               if Is_Passthrough_Isupport (Name) then
                  Downstream_Isupport.Append (To_String (Token));
               end if;
            end;
         end;
      end loop;

      Update_Monitor (UC);

      for DC of Downstreams (UC.Network) loop
         for M of Generate_Isupport (Downstream_Isupport) loop
            Send_Message (DC, M);
         end loop;
      end loop;
      return Success;
   end Handle_Isupport;

   --  The case bodies below are small; Handle_Message dispatches to them.

   function Handle_Sasl_Result
     (UC : not null Upstream_Conn_Access; Msg : Message) return Handle_Result
   is
      use Soja.Core.Downstream_Helpers;
      Cmd : constant String := To_String (Msg.Command);
      Bad : Boolean;
      R   : constant Handle_Result := Check_Params (Msg, 2, Bad);
   begin
      if Bad then
         return R;
      end if;

      if Cmd = ERR_NICKLOCKED then
         UC.Logger.Print
           ("invalid nick used with SASL authentication: " & Param (Msg, 1));
      elsif Cmd = ERR_SASLFAIL then
         UC.Logger.Print ("SASL authentication failed: " & Param (Msg, 1));
      elsif Cmd = ERR_SASLTOOLONG then
         UC.Logger.Print ("SASL message too long: " & Param (Msg, 1));
      end if;

      UC.Sasl_Mech := Sasl_None;
      UC.Sasl_Started := False;

      declare
         Pending : constant Pending_Command :=
           Dequeue_Command (UC, "AUTHENTICATE");
      begin
         if Pending.DC /= null and then Pending.DC.Sasl /= null then
            if Cmd = RPL_SASLSUCCESS and then Pending.DC.Sasl.Plain_Set then
               Auto_Save_SASL_Plain
                 (UC.Network,
                  To_String (Pending.DC.Sasl.Plain_Username),
                  To_String (Pending.DC.Sasl.Plain_Password));
            end if;
            End_SASL (Pending.DC, Msg);
         end if;
      end;

      if not UC.Registered then
         Send_Message (UC, Make ("CAP", ["END"]));
      end if;
      return Success;
   end Handle_Sasl_Result;

   function Handle_End_Of_Motd
     (UC : not null Upstream_Conn_Access;
      Msg : Message;
      Downstream_ID : Long_Long_Integer) return Handle_Result
   is
   begin
      if not UC.Got_MOTD then
         --  Ignore the initial MOTD upon connection, but forward subsequent
         --  MOTD messages downstream.
         UC.Got_MOTD := True;

         --  If upstream did not send any CASEMAPPING token, assume it
         --  implements the old RFCs with rfc1459.  (Go's `== nil` is also
         --  true for a CASEMAPPING token that has no value.)
         if not (UC.Isupport.Contains ("CASEMAPPING")
                 and then UC.Isupport ("CASEMAPPING").Has_Value)
         then
            Update_Casemapping (UC.Network, Std_Case_Mapping);
         end if;

         --  If the server doesn't support MONITOR, periodically try to
         --  regain our desired nick.
         if not UC.Isupport.Contains ("MONITOR") then
            Start_Regain_Nick_Timer (UC);
         end if;
         return Success;
      end if;

      Forward_Msg_By_ID (UC, Downstream_ID, Msg);
      return Success;
   end Handle_End_Of_Motd;

   --------------------
   -- Handle_Message --
   --------------------

   function Handle_Message
     (UC : not null Upstream_Conn_Access;
      M  : Soja.Irc.Messages.Message) return Handle_Result
   is
      use Soja.Core.Downstream_Helpers;

      Msg           : Message := Copy (M);
      Cmd           : constant String := To_String (M.Command);
      Label         : Unbounded_String;
      Downstream_ID : Long_Long_Integer := 0;
      Bad           : Boolean;
      R             : Handle_Result;

   begin
      if Has_Tag (Msg.Tags, "label") then
         Label := To_Unbounded_String (Get_Tag (Msg.Tags, "label"));
         Msg.Tags.Data.Exclude ("label");
      end if;

      if Has_Tag (Msg.Tags, "batch") then
         declare
            Name : constant String := Get_Tag (Msg.Tags, "batch");
         begin
            if not UC.Batches.Contains (Name) then
               return Fail
                 ("unexpected batch reference: batch was not defined: "
                  & Quote (Name));
            end if;
            if Length (Label) = 0 then
               Label := UC.Batches (Name).Label;
            end if;
            Msg.Tags.Data.Exclude ("batch");
         end;
      end if;

      if Length (Label) > 0 then
         --  fmt.Sscanf(label, "sd-%d-%d", &downstreamID, &labelOffset)
         declare
            L : constant String := To_String (Label);
            P : Natural := L'First;

            function Number (Ok : out Boolean) return Long_Long_Integer is
               V : Long_Long_Integer := 0;
               N : Natural := 0;
            begin
               while P <= L'Last and then L (P) in '0' .. '9' loop
                  V := V * 10 + (Character'Pos (L (P)) - Character'Pos ('0'));
                  P := P + 1;
                  N := N + 1;
               end loop;
               Ok := N > 0;
               return V;
            exception
               when Constraint_Error =>
                  Ok := False;
                  return 0;
            end Number;

            Ok1, Ok2 : Boolean := False;
            Offset   : Long_Long_Integer;
            pragma Unreferenced (Offset);
         begin
            if L'Length >= 3 and then L (L'First .. L'First + 2) = "sd-" then
               P := L'First + 3;
               Downstream_ID := Number (Ok1);
               if Ok1 and then P <= L'Last and then L (P) = '-' then
                  P := P + 1;
                  Offset := Number (Ok2);
               end if;
            end if;
            if not (Ok1 and then Ok2) then
               return Fail
                 ("unexpected message label: invalid downstream reference "
                  & "for label " & Quote (L) & ": "
                  & (if Ok1 and then P > L'Last then "unexpected EOF"
                     else "input does not match format"));
            end if;
         end;
      end if;

      if Msg.Prefix = null then
         Msg.Prefix := UC.Server_Prefix;
      end if;

      if not Is_Numeric (Cmd) then
         declare
            Valid : Boolean;
            T     : Ada.Calendar.Time :=
              Parse_Server_Time (Get_Tag (Msg.Tags, "time"), Valid);
         begin
            if not Valid then
               T := Ada.Calendar.Clock;
            end if;
            Set_Tag (Msg.Tags, "time", Soja.Irc.Xirc.Format_Server_Time (T));
         end;
      end if;

      -------------------------------------------------------------------
      if Cmd = "PING" then
         Send_Message (UC, With_Params ("PONG", Msg.Params));

      elsif Cmd = "CAP" then
         return Handle_Cap (UC, Msg);

      elsif Cmd = "AUTHENTICATE" then
         return Handle_Authenticate (UC, Msg);

      elsif Cmd = RPL_LOGGEDIN then
         R := Check_Params (Msg, 3, Bad);
         if Bad then
            return R;
         end if;
         declare
            Prefix : constant Soja.Irc.Messages.Prefix :=
              Parse_Prefix (Param (Msg, 1));
         begin
            UC.Account := Msg.Params (3);
            UC.Username := Prefix.User;
            UC.Hostname := Prefix.Host;
         end;
         UC.Logger.Print
           ("logged in with account " & Quote (To_String (UC.Account)));
         for DC of Downstreams (UC.Network) loop
            Update_Account (DC);
            Update_Host (DC);
         end loop;

      elsif Cmd = RPL_LOGGEDOUT then
         R := Check_Params (Msg, 2, Bad);
         if Bad then
            return R;
         end if;
         declare
            Prefix : constant Soja.Irc.Messages.Prefix :=
              Parse_Prefix (Param (Msg, 1));
         begin
            UC.Account := Null_Unbounded_String;
            UC.Username := Prefix.User;
            UC.Hostname := Prefix.Host;
         end;
         UC.Logger.Print ("logged out");
         for DC of Downstreams (UC.Network) loop
            Update_Account (DC);
            Update_Host (DC);
         end loop;

      elsif Cmd = RPL_VISIBLEHOST then
         R := Check_Params (Msg, 2, Bad);
         if Bad then
            return R;
         end if;
         declare
            Raw : constant String := Param (Msg, 1);
            At_Sign : constant Natural := Ada.Strings.Fixed.Index (Raw, "@");
         begin
            if At_Sign > 0 then
               UC.Username :=
                 To_Unbounded_String (Raw (Raw'First .. At_Sign - 1));
               UC.Hostname :=
                 To_Unbounded_String (Raw (At_Sign + 1 .. Raw'Last));
            else
               UC.Hostname := To_Unbounded_String (Raw);
            end if;
         end;
         for DC of Downstreams (UC.Network) loop
            Update_Host (DC);
         end loop;

      elsif Cmd = ERR_NICKLOCKED or else Cmd = RPL_SASLSUCCESS
        or else Cmd = ERR_SASLFAIL or else Cmd = ERR_SASLTOOLONG
        or else Cmd = ERR_SASLABORTED
      then
         return Handle_Sasl_Result (UC, Msg);

      elsif Cmd = "REGISTER" or else Cmd = "VERIFY" then
         declare
            Pending : constant Pending_Command := Dequeue_Command (UC, Cmd);
         begin
            if Pending.DC /= null then
               if Cmd = "REGISTER" then
                  R := Check_Params (Msg, 2, Bad);
                  if Bad then
                     return R;
                  end if;
                  R := Check_Params (Pending.Msg, 3, Bad);
                  if Bad then
                     return R;
                  end if;
                  Auto_Save_SASL_Plain
                    (UC.Network, Param (Msg, 1), Param (Pending.Msg, 2));
               end if;
               Send_Message (Pending.DC, Msg);
            end if;
         end;

      elsif Cmd = RPL_WELCOME then
         return Handle_Welcome (UC, Msg);

      elsif Cmd = RPL_MYINFO then
         R := Check_Params (Msg, 5, Bad);
         if Bad then
            return R;
         end if;
         UC.Server_Name := Msg.Params (2);
         UC.Available_User_Modes := Msg.Params (4);

      elsif Cmd = RPL_ISUPPORT then
         return Handle_Isupport (UC, Msg);

      elsif Cmd = ERR_NOMOTD or else Cmd = RPL_ENDOFMOTD then
         return Handle_End_Of_Motd (UC, Msg, Downstream_ID);

      elsif Cmd = ERR_UNKNOWNERROR or else Cmd = ERR_UNKNOWNCOMMAND
        or else Cmd = ERR_NEEDMOREPARAMS or else Cmd = RPL_TRYAGAIN
      then
         R := Check_Params (Msg, 3, Bad);
         if Bad then
            return R;
         end if;
         declare
            Command : constant String := Param (Msg, 1);
            Pending : constant Pending_Command :=
              Dequeue_Command (UC, Command);
         begin
            if Pending.DC /= null and then Downstream_ID = 0 then
               Downstream_ID := Pending.DC.ID;
            end if;
            if Command = "AUTHENTICATE" then
               UC.Sasl_Mech := Sasl_None;
               UC.Sasl_Started := False;
            end if;
            Forward_Msg_By_ID (UC, Downstream_ID, Msg);
         end;

      elsif Cmd = "FAIL" then
         R := Check_Params (Msg, 2, Bad);
         if Bad then
            return R;
         end if;
         if not UC.Registered and then Param (Msg, 0) = "*"
           and then Param (Msg, 1) = "ACCOUNT_REQUIRED"
         then
            return Registration_Error (Msg);
         end if;
         declare
            Pending : constant Pending_Command :=
              Dequeue_Command (UC, Param (Msg, 0));
         begin
            if Pending.DC /= null and then Downstream_ID = 0 then
               Downstream_ID := Pending.DC.ID;
            end if;
            Forward_Msg_By_ID (UC, Downstream_ID, Msg);
         end;

      elsif Cmd = "ACK" or else Cmd = RPL_NOWAWAY or else Cmd = RPL_UNAWAY
        or else Cmd = RPL_YOURHOST or else Cmd = RPL_CREATED
      then
         null;   --  ignored

      elsif Cmd = RPL_LUSERCLIENT or else Cmd = RPL_LUSEROP
        or else Cmd = RPL_LUSERUNKNOWN or else Cmd = RPL_LUSERCHANNELS
        or else Cmd = RPL_LUSERME or else Cmd = RPL_STATSVLINE
        or else Cmd = RPL_STATSPING or else Cmd = RPL_STATSBLINE
        or else Cmd = RPL_STATSDLINE or else Cmd = RPL_LOCALUSERS
        or else Cmd = RPL_GLOBALUSERS or else Cmd = RPL_MOTDSTART
        or else Cmd = RPL_MOTD
      then
         --  Ignore these messages if they're part of the initial
         --  registration message burst.  Forward them if the user
         --  explicitly asked for them.
         if UC.Got_MOTD then
            Forward_Msg_By_ID (UC, Downstream_ID, Msg);
         end if;

      elsif Cmd = "ERROR" then
         R := Check_Params (Msg, 1, Bad);
         if Bad then
            return R;
         end if;
         return Fail ("fatal server error: " & Param (Msg, 0));

      elsif Cmd = ERR_NICKNAMEINUSE
        or else Cmd = ERR_PASSWDMISMATCH or else Cmd = ERR_ERRONEUSNICKNAME
        or else Cmd = ERR_NICKCOLLISION or else Cmd = ERR_UNAVAILRESOURCE
        or else Cmd = ERR_NOPERMFORHOST or else Cmd = ERR_YOUREBANNEDCREEP
      then
         if Cmd = ERR_NICKNAMEINUSE then
            --  At this point, we haven't received ISUPPORT so we don't know
            --  the maximum nickname length or whether the server supports
            --  MONITOR.  Many servers have NICKLEN=30 so let's just use that.
            if not UC.Registered and then Length (UC.Nick) + 1 < 30 then
               Append (UC.Nick, "_");
               UC.Has_Desired_Nick := False;
               UC.Logger.Print
                 ("desired nick is not available, falling back to "
                  & Quote (To_String (UC.Nick)));
               Send_Message (UC, Make ("NICK", [To_String (UC.Nick)]));
               return Success;
            end if;

            R := Check_Params (Msg, 2, Bad);
            if Bad then
               return R;
            end if;
            if Equal_Casemap
                 (UC.Network, To_String (UC.Pending_Regain_Nick),
                  Param (Msg, 1))
            then
               --  This message comes from our own logic to try to regain
               --  our desired nick, don't relay to downstream connections.
               UC.Pending_Regain_Nick := Null_Unbounded_String;
               return Success;
            end if;
         end if;

         if not UC.Registered then
            return Registration_Error (Msg);
         end if;
         Forward_Msg_By_ID (UC, Downstream_ID, Msg);

      else
         --  4b - 4d add the channel, chat-message and reply commands here;
         --  until then they are forwarded unchanged, as Go's default does.
         UC.Logger.Debug ("unhandled message: " & Text_Of (Msg));
         Forward_Msg_By_ID (UC, Downstream_ID, Msg);
      end if;

      return Success;
   end Handle_Message;

end Soja.Core.Upstream_Dispatch;
