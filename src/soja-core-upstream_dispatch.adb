pragma Ada_2022;

with Ada.Calendar;
with Ada.Containers;
with Ada.Calendar.Conversions;
with Ada.Containers.Indefinite_Hashed_Sets;
with Ada.Exceptions;
with Ada.Strings.Fixed;
with Ada.Strings.Hash;
with Interfaces.C;

with Soja.Base64;
with Soja.Core.Downstream_Helpers;
with Soja.Core.Network_Ops;
with Soja.Downstream;
with Soja.Irc.Cap_Registry;
with Soja.Irc.Case_Mapping;
with Soja.Irc.Genmsg;
with Soja.Irc.Helpers;
with Soja.Irc.Modes;
with Soja.Irc.Numerics;
with Soja.Irc.User_Modes;
with Soja.Irc.Whox;
with Soja.Backoff;
with Soja.Timers;
with Soja.Irc.Xirc;

package body Soja.Core.Upstream_Dispatch is

   use Soja.Irc.Cap_Registry;
   use Soja.Irc.Genmsg;
   use Soja.Irc.Helpers;
   use Soja.Irc.Messages;
   use Soja.Irc.Numerics;

   use type Ada.Calendar.Time;
   use type Ada.Containers.Count_Type;
   use type Soja.Irc.Members.Membership_Set_Access;

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

   function Passthrough_Isupport_Tokens
     (UC : not null Upstream_Conn_Access)
      return Soja.Irc.Genmsg.String_Vectors.Vector
   is
      V : Soja.Irc.Genmsg.String_Vectors.Vector;
   begin
      for T of Passthrough_Isupport loop
         if UC.Isupport.Contains (T.all) then
            declare
               Item : constant Isupport_Value := UC.Isupport (T.all);
            begin
               V.Append
                 (if Item.Has_Value then T.all & "=" & To_String (Item.Value)
                  else T.all);
            end;
         end if;
      end loop;
      return V;
   end Passthrough_Isupport_Tokens;

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

         --  If we didn't get a reply after a while, just give up on it, and
         --  send the next command, which nothing else would.  (Go writes
         --  this as copy(l, l[1:]), which keeps the length and so
         --  duplicates the last entry, and its `len == 1` test then
         --  never sends the new command; fixed, see PORTING.md.)
         if V (1).Sent_At /= Zero_Time
           and then Ada.Calendar.Clock - V (1).Sent_At > 30.0
         then
            V.Delete_First;
            UC.Pending_Cmds.Replace (Cmd, V);
            Send_Next_Pending_Command (UC, Cmd);
            return;
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
   begin
      if not Is_Available (UC.Caps, "sasl") then
         return False;
      end if;

      --  A "sasl" cap without a value supports every mechanism; otherwise
      --  the value lists them (case-insensitively).  (Go compares the loop
      --  variable with itself, so it accepted any list; fixed.)
      declare
         V     : constant String := Value (UC.Caps, "sasl");
         Start : Positive := V'First;
      begin
         if V = "" then
            return True;
         end if;
         for I in V'First .. V'Last + 1 loop
            if I > V'Last or else V (I) = ',' then
               if Upper (V (Start .. I - 1)) = Upper (Mech) then
                  return True;
               end if;
               Start := I + 1;
            end if;
         end loop;
         return False;
      end;
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
               --  (Go formats the capability name here; fixed.)
               return Fail ("unsupported SASL mechanism " & Quote (Mech));
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

   procedure Update_Away (UC : not null Upstream_Conn_Access) is
      Away : Boolean := True;
   begin
      if not UC.Network.Network_Record.Auto_Away then
         return;
      end if;

      for DC of Downstreams (UC.Network) loop
         if Length (DC.Away) = 0 then
            Away := False;
         end if;
      end loop;
      if Away = UC.Away then
         return;
      end if;

      if Away then
         Send_Message
           (UC, Make ("AWAY",
                      [(if Is_Available (UC.Caps, "draft/pre-away") then "*"
                        else "Auto away")]));
      else
         Send_Message (UC, Make ("AWAY"));
      end if;
      UC.Away := Away;
   end Update_Away;

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

   ----------------------------------------------------------------------
   --  Channel state (4b): users, channels, produce
   ----------------------------------------------------------------------

   procedure Cache_User_Info
     (UC   : not null Upstream_Conn_Access;
      Nick : String;
      Info : Soja.Upstream.Upstream_User)
   is
      Existing : constant Upstream_User_Access := UC.Users.Get (Nick);
      Data     : Soja.Upstream.Upstream_User := Info;
   begin
      if Nick = "" then
         raise Program_Error with "cacheUserInfo called with empty nickname";
      end if;

      if Existing = null then
         if Length (Data.Nickname) > 0 then
            UC.Users.Set (To_String (Data.Nickname),
                          new Soja.Upstream.Upstream_User'(Data));
         else
            Data.Nickname := To_Unbounded_String (Nick);
            UC.Users.Set (Nick, new Soja.Upstream.Upstream_User'(Data));
         end if;
      else
         Soja.Upstream.Update_From (Existing.all, Info);
         if Length (Info.Nickname) > 0
           and then Nick /= To_String (Info.Nickname)
         then
            UC.Users.Del (Nick);
            UC.Users.Set (To_String (Existing.Nickname), Existing);
         end if;
      end if;
   end Cache_User_Info;

   procedure Update_Channel_Auto_Detach
     (UC : not null Upstream_Conn_Access; Name : String)
   is
      Uch : constant Upstream_Channel_Access := UC.Channels.Get (Name);
      Ch  : constant Channel_Access := UC.Network.Channels.Get (Name);
   begin
      if Uch = null or else Ch = null or else Ch.Detached then
         return;
      end if;
      Update_Auto_Detach (Uch, Ch.Detach_After);
   end Update_Channel_Auto_Detach;

   procedure Produce
     (UC        : not null Upstream_Conn_Access;
      Target    : String;
      Msg       : Soja.Irc.Messages.Message;
      Origin_ID : Long_Long_Integer)
   is
      use Soja.Core.Downstream_Helpers;
      Msg_ID   : constant String :=
        (if Target /= "" then Append_Log (UC, Target, Msg) else "");
      Ch       : constant Channel_Access := UC.Network.Channels.Get (Target);
      Detached : constant Boolean := Ch /= null and then Ch.Detached;
   begin
      --  Don't forward messages if it's a detached channel.
      for DC of Downstreams (UC.Network) loop
         declare
            Echo : constant Boolean :=
              DC.ID = Origin_ID and then Msg.Prefix /= null
              and then Is_Our_Nick (UC, To_String (Msg.Prefix.Name));
         begin
            if not Detached
              and then (not Echo or else Is_Enabled (DC.Caps, "echo-message"))
            then
               Send_Message_With_ID (DC, Msg, Msg_ID);
            else
               Advance_Message_With_ID (DC, Msg, Msg_ID);
            end if;
         end;
      end loop;
   end Produce;

   procedure Parse_Membership_Prefix
     (UC          : not null Upstream_Conn_Access;
      S           : String;
      Memberships : out Soja.Irc.Members.Membership_Vectors.Vector;
      Nick        : out Unbounded_String)
   is
      I : Natural := 0;
   begin
      Memberships.Clear;
      for M of UC.Available_Memberships loop
         exit when I >= S'Length;
         if S (S'First + I) = M.Prefix then
            Memberships.Append (M);
            I := I + 1;
         end if;
      end loop;
      Nick := To_Unbounded_String (S (S'First + I .. S'Last));
   end Parse_Membership_Prefix;

   --  strings.Split(s, ","): every piece, empty ones included.
   function Split_Commas (S : String) return String_Vectors.Vector is
      V     : String_Vectors.Vector;
      Start : Positive := S'First;
   begin
      for I in S'Range loop
         if S (I) = ',' then
            V.Append (S (Start .. I - 1));
            Start := I + 1;
         end if;
      end loop;
      V.Append (S (Start .. S'Last));
      return V;
   end Split_Commas;

   function Unknown_Channel (Name : String) return Handle_Result is
     (Fail ("unknown channel " & Quote (Name)));

   function Is_Detached
     (UC : not null Upstream_Conn_Access; Name : String) return Boolean
   is
      C : constant Channel_Access := UC.Network.Channels.Get (Name);
   begin
      return C /= null and then C.Detached;
   end Is_Detached;

   --  uc.appendLog, for the callers that ignore the message ID.
   procedure Log
     (UC : not null Upstream_Conn_Access; Entity : String; Msg : Message)
   is
      ID : constant String := Append_Log (UC, Entity, Msg);
      pragma Unreferenced (ID);
   begin
      null;
   end Log;

   function Handle_Batch
     (UC : not null Upstream_Conn_Access;
      Msg : Message;
      Label : Unbounded_String;
      Outer : Upstream_Batch_Access) return Handle_Result
   is
      Bad : Boolean;
      R   : Handle_Result := Check_Params (Msg, 1, Bad);
   begin
      if Bad then
         return R;
      end if;

      declare
         Tag : constant String := Param (Msg, 0);
      begin
         if Tag'Length > 0 and then Tag (Tag'First) = '+' then
            declare
               Name : constant String := Tag (Tag'First + 1 .. Tag'Last);
               B    : Upstream_Batch;
            begin
               if UC.Batches.Contains (Name) then
                  return Fail
                    ("unexpected BATCH reference tag: batch was already "
                     & "defined: " & Quote (Name));
               end if;
               R := Check_Params (Msg, 2, Bad);
               if Bad then
                  return R;
               end if;
               B.Batch_Type := Msg.Params (2);
               for I in 3 .. Natural (Msg.Params.Length) loop
                  B.Params.Append (Msg.Params (I));
               end loop;
               B.Outer := Outer;
               B.Label := Label;
               if Length (B.Label) = 0 and then Outer /= null then
                  B.Label := Outer.Label;
               end if;
               UC.Batches.Insert (Name, B);
            end;
         elsif Tag'Length > 0 and then Tag (Tag'First) = '-' then
            declare
               Name : constant String := Tag (Tag'First + 1 .. Tag'Last);
            begin
               if not UC.Batches.Contains (Name) then
                  return Fail ("unknown BATCH reference tag: " & Quote (Name));
               end if;
               UC.Batches.Delete (Name);
            end;
         else
            return Fail
              ("unexpected BATCH reference tag: missing +/- prefix: "
               & Quote (Tag));
         end if;
      end;
      return Success;
   end Handle_Batch;

   function Handle_Nick
     (UC : not null Upstream_Conn_Access; Msg : Message) return Handle_Result
   is
      use Soja.Core.Downstream_Helpers;
      Bad : Boolean;
      R   : constant Handle_Result := Check_Params (Msg, 1, Bad);
   begin
      if Bad then
         return R;
      end if;

      declare
         New_Nick : constant String := Param (Msg, 0);
         Old_Nick : constant String := To_String (Msg.Prefix.Name);
         Me       : Boolean := False;

         procedure Rename (Name : String; Ch : Upstream_Channel_Access) is
            pragma Unreferenced (Name);
            Memberships : constant Soja.Irc.Members.Membership_Set_Access :=
              Ch.Members.Get (Old_Nick);
         begin
            if Memberships /= null then
               Ch.Members.Del (Old_Nick);
               Ch.Members.Set (New_Nick, Memberships);
               Log (UC, To_String (Ch.Name), Msg);
            end if;
         end Rename;
      begin
         if Is_Our_Nick (UC, Old_Nick) then
            UC.Logger.Print
              ("changed nick from " & Quote (To_String (UC.Nick)) & " to "
               & Quote (New_Nick));
            Me := True;
            UC.Nick := To_Unbounded_String (New_Nick);

            if Equal_Casemap
                 (UC.Network, To_String (UC.Pending_Regain_Nick), New_Nick)
            then
               UC.Pending_Regain_Nick := Null_Unbounded_String;
               Stop_Regain_Nick_Timer (UC);
            end if;
            if Equal_Casemap
                 (UC.Network,
                  Soja.Database.Get_Nick
                    (UC.User.User_Record, UC.Network.Network_Record),
                  New_Nick)
            then
               UC.Has_Desired_Nick := True;
            end if;
         end if;

         UC.Channels.For_Each (Rename'Access);

         Cache_User_Info
           (UC, Old_Nick,
            (Nickname => To_Unbounded_String (New_Nick), others => <>));

         if not Me then
            Forward_Message (UC, Msg);
         else
            for DC of Downstreams (UC.Network) loop
               Update_Nick (DC);
            end loop;
            Update_Monitor (UC);
         end if;
      end;
      return Success;
   end Handle_Nick;

   function Handle_Join
     (UC : not null Upstream_Conn_Access; Msg : Message) return Handle_Result
   is
      Bad : Boolean;
      R   : constant Handle_Result := Check_Params (Msg, 1, Bad);
      UU  : Soja.Upstream.Upstream_User;
   begin
      if Bad then
         return R;
      end if;

      UU.Username := Msg.Prefix.User;
      UU.Hostname := Msg.Prefix.Host;
      if Is_Enabled (UC.Caps, "away-notify") then
         --  We have enough info to build the user flags in a best-effort
         --  manner: H (here) first, replaced by G later if the user is AWAY;
         --  and the bot flag if the JOIN comes from a bot.
         UU.Flags := To_Unbounded_String ("H");
         if Has_Tag (Msg.Tags, "bot") and then UC.Isupport.Contains ("BOT")
           and then UC.Isupport ("BOT").Has_Value
         then
            Append (UU.Flags, UC.Isupport ("BOT").Value);
         end if;
      end if;
      if Msg.Params.Length > 2 then   --  extended-join
         UU.Account := Msg.Params (2);
         UU.Realname := Msg.Params (3);
      end if;
      Cache_User_Info (UC, To_String (Msg.Prefix.Name), UU);

      for Name of Split_Commas (Param (Msg, 0)) loop
         if Is_Our_Nick (UC, To_String (Msg.Prefix.Name)) then
            UC.Logger.Print ("joined channel " & Quote (Name));
            Clear_Kick (UC.Network, Name);   --  back in: no longer "kicked"
            Cancel_Join_Retry (UC, Name);
            UC.Channels.Set (Name, New_Upstream_Channel (UC, Name));
            Update_Channel_Auto_Detach (UC, Name);

            Send_Message (UC, Make ("MODE", [Name]));
         else
            declare
               Ch : constant Upstream_Channel_Access := UC.Channels.Get (Name);
            begin
               if Ch = null then
                  return Unknown_Channel (Name);
               end if;
               Ch.Members.Set
                 (To_String (Msg.Prefix.Name),
                  new Soja.Irc.Members.Membership_Vectors.Vector);
            end;
         end if;

         declare
            Ch_Msg : Message := Copy (Msg);
         begin
            Ch_Msg.Params.Replace_Element (1, To_Unbounded_String (Name));
            Produce (UC, Name, Ch_Msg, 0);
         end;
      end loop;
      return Success;
   end Handle_Join;

   function Handle_Part
     (UC : not null Upstream_Conn_Access; Msg : Message) return Handle_Result
   is
      Bad : Boolean;
      R   : constant Handle_Result := Check_Params (Msg, 1, Bad);
   begin
      if Bad then
         return R;
      end if;

      for Name of Split_Commas (Param (Msg, 0)) loop
         if Is_Our_Nick (UC, To_String (Msg.Prefix.Name)) then
            UC.Logger.Print ("parted channel " & Quote (Name));
            declare
               Uch : constant Upstream_Channel_Access := UC.Channels.Get (Name);

               procedure Forget (Nick : String;
                  Set : Soja.Irc.Members.Membership_Set_Access)
               is
                  pragma Unreferenced (Set);
               begin
                  if not Should_Cache_User_Info (UC, Nick) then
                     UC.Users.Del (Nick);
                  end if;
               end Forget;
            begin
               if Uch /= null then
                  UC.Channels.Del (Name);
                  Update_Auto_Detach (Uch, 0.0);
                  Uch.Members.For_Each (Forget'Access);
               end if;
            end;
         else
            declare
               Ch   : constant Upstream_Channel_Access := UC.Channels.Get (Name);
               Nick : constant String := To_String (Msg.Prefix.Name);
            begin
               if Ch = null then
                  return Unknown_Channel (Name);
               end if;
               Ch.Members.Del (Nick);
               if not Should_Cache_User_Info (UC, Nick) then
                  UC.Users.Del (Nick);
               end if;
            end;
         end if;

         declare
            Ch_Msg : Message := Copy (Msg);
         begin
            Ch_Msg.Params.Replace_Element (1, To_Unbounded_String (Name));
            Produce (UC, Name, Ch_Msg, 0);
         end;
      end loop;
      return Success;
   end Handle_Part;

   function Handle_Kick
     (UC : not null Upstream_Conn_Access; Msg : Message) return Handle_Result
   is
      Bad : Boolean;
      R   : constant Handle_Result := Check_Params (Msg, 2, Bad);
   begin
      if Bad then
         return R;
      end if;

      declare
         Channel : constant String := Param (Msg, 0);
         Victim  : constant String := Param (Msg, 1);
      begin
         if Is_Our_Nick (UC, Victim) then
            --  We are not rejoining: nothing here sends a JOIN, and the kick
            --  is remembered so that neither the 001 autojoin of a later
            --  connection nor anything else rejoins on its own; clients are
            --  told when they connect (Send_Kicked_Notices).  The channel
            --  stays in the saved list so a manual JOIN works as usual.
            UC.Logger.Print
              ("kicked from channel " & Quote (Channel) & " by "
               & To_String (Msg.Prefix.Name));
            Record_Kick
              (UC.Network, Channel, To_String (Msg.Prefix.Name),
               (if Msg.Params.Length > 2 then Param (Msg, 2) else ""));
            declare
               Uch : constant Upstream_Channel_Access :=
                 UC.Channels.Get (Channel);

               procedure Forget (Nick : String;
                  Set : Soja.Irc.Members.Membership_Set_Access)
               is
                  pragma Unreferenced (Set);
               begin
                  if not Should_Cache_User_Info (UC, Nick) then
                     UC.Users.Del (Nick);
                  end if;
               end Forget;
            begin
               if Uch /= null then
                  UC.Channels.Del (Channel);
                  Uch.Members.For_Each (Forget'Access);
               end if;
            end;
         else
            declare
               Ch : constant Upstream_Channel_Access :=
                 UC.Channels.Get (Channel);
            begin
               if Ch = null then
                  return Unknown_Channel (Channel);
               end if;
               Ch.Members.Del (Victim);
               if not Should_Cache_User_Info (UC, Victim) then
                  UC.Users.Del (Victim);
               end if;
            end;
         end if;

         Produce (UC, Channel, Msg, 0);
      end;
      return Success;
   end Handle_Kick;

   procedure Handle_Quit
     (UC : not null Upstream_Conn_Access; Msg : Message)
   is
      Nick : constant String := To_String (Msg.Prefix.Name);

      procedure Leave (Name : String; Ch : Upstream_Channel_Access) is
         pragma Unreferenced (Name);
      begin
         if Ch.Members.Has (Nick) then
            Ch.Members.Del (Nick);
            Log (UC, To_String (Ch.Name), Msg);
         end if;
      end Leave;
   begin
      if Is_Our_Nick (UC, Nick) then
         UC.Logger.Print ("quit");
      end if;

      UC.Channels.For_Each (Leave'Access);
      UC.Users.Del (Nick);

      if Nick /= To_String (UC.Nick) then
         Forward_Message (UC, Msg);
      end if;
   end Handle_Quit;

   function Handle_Topic_Reply
     (UC : not null Upstream_Conn_Access;
      Msg : Message;
      Downstream_ID : Long_Long_Integer) return Handle_Result
   is
      Bad : Boolean;
      R   : constant Handle_Result := Check_Params (Msg, 3, Bad);
   begin
      if Bad then
         return R;
      end if;
      declare
         Ch : constant Upstream_Channel_Access := UC.Channels.Get (Param (Msg, 1));
      begin
         if Ch = null then
            Forward_Msg_By_ID (UC, Downstream_ID, Msg);
         elsif To_String (Msg.Command) = RPL_TOPIC then
            Ch.Topic := Msg.Params (3);
         else
            Ch.Topic := Null_Unbounded_String;
         end if;
      end;
      return Success;
   end Handle_Topic_Reply;

   function Handle_Topic
     (UC : not null Upstream_Conn_Access; Msg : Message) return Handle_Result
   is
      Bad : Boolean;
      R   : constant Handle_Result := Check_Params (Msg, 1, Bad);
   begin
      if Bad then
         return R;
      end if;
      declare
         Ch : constant Upstream_Channel_Access := UC.Channels.Get (Param (Msg, 0));
      begin
         if Ch = null then
            return Unknown_Channel (Param (Msg, 0));
         end if;
         if Msg.Params.Length > 1 then
            Ch.Topic := Msg.Params (2);
            Ch.Topic_Who := new Prefix'(Msg.Prefix.all);
            Ch.Topic_Time := Ada.Calendar.Clock;   --  TODO (Go): the time tag
         else
            Ch.Topic := Null_Unbounded_String;
         end if;
         Produce (UC, To_String (Ch.Name), Msg, 0);
      end;
      return Success;
   end Handle_Topic;

   --  applyChannelModes(ch, modeStr, args) with the upstream's tables.
   function Apply_Modes
     (UC       : not null Upstream_Conn_Access;
      Ch       : not null Upstream_Channel_Access;
      Mode_Str : String;
      Args     : Param_Vectors.Vector) return Handle_Result
   is
   begin
      Soja.Irc.Modes.Apply_Channel_Modes
        (UC.Available_Memberships, UC.Available_Channel_Modes, Ch.Members,
         Ch.Modes, Mode_Str, Args);
      return Success;
   exception
      when E : Soja.Irc.Modes.Mode_Error =>
         return Fail (Ada.Exceptions.Exception_Message (E));
   end Apply_Modes;

   --  msg.Params[From:] (0-based).
   function Params_From (Msg : Message; From : Natural)
      return Param_Vectors.Vector
   is
      V : Param_Vectors.Vector;
   begin
      for I in From + 1 .. Natural (Msg.Params.Length) loop
         V.Append (Msg.Params (I));
      end loop;
      return V;
   end Params_From;

   function Handle_Mode
     (UC : not null Upstream_Conn_Access; Msg : Message) return Handle_Result
   is
      Bad : Boolean;
      R   : Handle_Result := Check_Params (Msg, 2, Bad);
   begin
      if Bad then
         return R;
      end if;

      declare
         Name     : constant String := Param (Msg, 0);
         Mode_Str : constant String := Param (Msg, 1);
      begin
         if not Is_Channel (UC, Name) then   --  user mode change
            declare
               Ok : Boolean;
            begin
               if Name /= To_String (UC.Nick) then
                  return Fail
                    ("received MODE message for unknown nick "
                     & Quote (Name));
               end if;
               Soja.Irc.User_Modes.Apply (UC.Modes, Mode_Str, Ok);
               if not Ok then
                  return Fail
                    ("malformed modestring " & Quote (Mode_Str)
                     & ": missing plus/minus");
               end if;
               Forward_Message (UC, Msg);
            end;
         else   --  channel mode change
            declare
               Ch : constant Upstream_Channel_Access := UC.Channels.Get (Name);
            begin
               if Ch = null then
                  return Unknown_Channel (Name);
               end if;
               R := Apply_Modes (UC, Ch, Mode_Str, Params_From (Msg, 2));
               if R.Failed then
                  return R;
               end if;

               Log (UC, To_String (Ch.Name), Msg);

               if not Is_Detached (UC, Name) then
                  Forward_Message (UC, Msg);
               end if;
            end;
         end if;
      end;
      return Success;
   end Handle_Mode;

   function Handle_User_Mode_Is
     (UC : not null Upstream_Conn_Access; Msg : Message) return Handle_Result
   is
      Bad : Boolean;
      R   : constant Handle_Result := Check_Params (Msg, 1, Bad);
      Ok  : Boolean;
   begin
      if Bad then
         return R;
      end if;
      declare
         Mode_Str : constant String :=
           (if Msg.Params.Length > 1 then Param (Msg, 1) else "");
      begin
         UC.Modes.Value := Null_Unbounded_String;
         Soja.Irc.User_Modes.Apply (UC.Modes, Mode_Str, Ok);
         if not Ok then
            return Fail
              ("malformed modestring " & Quote (Mode_Str)
               & ": missing plus/minus");
         end if;
      end;
      Forward_Message (UC, Msg);
      return Success;
   end Handle_User_Mode_Is;

   function Handle_Channel_Mode_Is
     (UC : not null Upstream_Conn_Access;
      Msg : Message;
      Downstream_ID : Long_Long_Integer) return Handle_Result
   is
      Bad : Boolean;
      R   : Handle_Result := Check_Params (Msg, 2, Bad);
   begin
      if Bad then
         return R;
      end if;

      declare
         Channel  : constant String := Param (Msg, 1);
         Mode_Str : constant String :=
           (if Msg.Params.Length > 2 then Param (Msg, 2) else "");
         Ch       : constant Upstream_Channel_Access := UC.Channels.Get (Channel);
      begin
         if Ch = null then
            Forward_Msg_By_ID (UC, Downstream_ID, Msg);
            return Success;
         end if;

         declare
            First_Mode : constant Boolean := not Ch.Modes.Known;
         begin
            Ch.Modes.Known := True;
            Ch.Modes.Values.Clear;
            R := Apply_Modes (UC, Ch, Mode_Str, Params_From (Msg, 3));
            if R.Failed then
               return R;
            end if;
            if First_Mode and then not Is_Detached (UC, Channel) then
               Forward_Message (UC, Msg);
            end if;
         end;
      end;
      return Success;
   end Handle_Channel_Mode_Is;

   function Handle_Creation_Time
     (UC : not null Upstream_Conn_Access;
      Msg : Message;
      Downstream_ID : Long_Long_Integer) return Handle_Result
   is
      Bad : Boolean;
      R   : constant Handle_Result := Check_Params (Msg, 3, Bad);
   begin
      if Bad then
         return R;
      end if;
      declare
         Channel : constant String := Param (Msg, 1);
         Ch      : constant Upstream_Channel_Access := UC.Channels.Get (Channel);
      begin
         if Ch = null then
            Forward_Msg_By_ID (UC, Downstream_ID, Msg);
            return Success;
         end if;
         declare
            First : constant Boolean := Length (Ch.Creation_Time) = 0;
         begin
            Ch.Creation_Time := Msg.Params (3);
            if First and then not Is_Detached (UC, Channel) then
               Forward_Message (UC, Msg);
            end if;
         end;
      end;
      return Success;
   end Handle_Creation_Time;

   function Handle_Topic_Who_Time
     (UC : not null Upstream_Conn_Access;
      Msg : Message;
      Downstream_ID : Long_Long_Integer) return Handle_Result
   is
      Bad : Boolean;
      R   : constant Handle_Result := Check_Params (Msg, 4, Bad);
   begin
      if Bad then
         return R;
      end if;
      declare
         Channel : constant String := Param (Msg, 1);
         Ch      : constant Upstream_Channel_Access := UC.Channels.Get (Channel);
      begin
         if Ch = null then
            Forward_Msg_By_ID (UC, Downstream_ID, Msg);
            return Success;
         end if;
         declare
            First : constant Boolean := Ch.Topic_Who = null;
            Sec   : Long_Long_Integer;
         begin
            Ch.Topic_Who := new Prefix'(Parse_Prefix (Param (Msg, 2)));
            begin
               Sec := Long_Long_Integer'Value (Param (Msg, 3));
               Ch.Topic_Time := Ada.Calendar.Conversions.To_Ada_Time_64
                 (Interfaces.C.long_long (Sec));
            exception
               when Constraint_Error =>
                  return Fail
                    ("failed to parse topic time: strconv.ParseInt: parsing "
                     & Quote (Param (Msg, 3)) & ": invalid syntax");
            end;
            if First and then not Is_Detached (UC, Channel) then
               Forward_Message (UC, Msg);
            end if;
         end;
      end;
      return Success;
   end Handle_Topic_Who_Time;

   function Handle_Names_Reply
     (UC : not null Upstream_Conn_Access;
      Msg : Message;
      Downstream_ID : Long_Long_Integer) return Handle_Result
   is
      Bad : Boolean;
      R   : constant Handle_Result := Check_Params (Msg, 4, Bad);
   begin
      if Bad then
         return R;
      end if;
      declare
         Name   : constant String := Param (Msg, 2);
         Ch     : constant Upstream_Channel_Access := UC.Channels.Get (Name);
         Status : Soja.Irc.Members.Channel_Status;
         Ok     : Boolean;
      begin
         if Ch = null then
            --  NAMES on a channel we have not joined, forward to downstream.
            Forward_Msg_By_ID (UC, Downstream_ID, Msg);
            return Success;
         end if;

         Status := Soja.Irc.Members.Parse_Channel_Status (Param (Msg, 1), Ok);
         if not Ok then
            return Fail
              ("invalid channel status " & Quote (Param (Msg, 1)));
         end if;
         Ch.Status := Status;

         --  splitSpace: only ' ' separates.
         declare
            Members : constant String := Param (Msg, 3);
            Start   : Natural := 0;

            procedure Add (Item : String) is
               Set  : constant Soja.Irc.Members.Membership_Set_Access :=
                 new Soja.Irc.Members.Membership_Vectors.Vector;
               Nick : Unbounded_String;
            begin
               Parse_Membership_Prefix (UC, Item, Set.all, Nick);
               Ch.Members.Set (To_String (Nick), Set);
            end Add;
         begin
            for I in Members'Range loop
               if Members (I) = ' ' then
                  if Start /= 0 then
                     Add (Members (Start .. I - 1));
                     Start := 0;
                  end if;
               elsif Start = 0 then
                  Start := I;
               end if;
            end loop;
            if Start /= 0 then
               Add (Members (Start .. Members'Last));
            end if;
         end;
      end;
      return Success;
   end Handle_Names_Reply;

   function Handle_End_Of_Names
     (UC : not null Upstream_Conn_Access;
      Msg : Message;
      Downstream_ID : Long_Long_Integer) return Handle_Result
   is
      use Soja.Core.Downstream_Helpers;
      Bad : Boolean;
      R   : constant Handle_Result := Check_Params (Msg, 2, Bad);
   begin
      if Bad then
         return R;
      end if;
      declare
         Name : constant String := Param (Msg, 1);
         Ch   : constant Upstream_Channel_Access := UC.Channels.Get (Name);
      begin
         if Ch = null then
            --  NAMES on a channel we have not joined, forward to downstream.
            Forward_Msg_By_ID (UC, Downstream_ID, Msg);
            return Success;
         end if;

         if Ch.Complete then
            return Fail ("received unexpected RPL_ENDOFNAMES");
         end if;
         Ch.Complete := True;

         if not Is_Detached (UC, Name) then
            for DC of Downstreams (UC.Network) loop
               Forward_Channel (DC, Ch);
            end loop;
         end if;
      end;
      return Success;
   end Handle_End_Of_Names;

   ----------------------------------------------------------------------
   --  Chat messages (4c)
   ----------------------------------------------------------------------

   --  A message arrived in a detached channel: relay it as a service notice
   --  when asked to, and reattach on the configured trigger.
   procedure Handle_Detached_Message
     (UC : not null Upstream_Conn_Access;
      Ch : not null Channel_Access;
      Msg : Message)
   is
      use Soja.Core.Downstream_Helpers;
      use Soja.Database;
      Net : constant Network_Access := UC.Network;
   begin
      if Soja.Core.Network_Ops.Detached_Message_Needs_Relay (Net, Ch, Msg) then
         for DC of Downstreams (Net) loop
            Relay_Detached_Message (DC, Net, Msg);
         end loop;
      end if;

      if Ch.Reattach_On = Filter_Message
        or else (Ch.Reattach_On = Filter_Highlight
                 and then Soja.Core.Network_Ops.Is_Highlight (Net, Msg))
      then
         Soja.Core.Network_Ops.Attach (Net, Ch);
         declare
            DB : constant Soja.Database.Database_Access :=
              Soja.Server.DB (UC.Srv.all);
         begin
            if DB /= null then
               Soja.Database.Store_Channel
                 (DB.all, Net.Network_Record.ID, Ch.all);
            end if;
         exception
            when E : others =>
               UC.Logger.Print
                 ("failed to update channel " & Quote (To_String (Ch.Name))
                  & ": " & Ada.Exceptions.Exception_Message (E));
         end;
      end if;
   end Handle_Detached_Message;

   --  strings.TrimLeft(s, cutset).
   function Trim_Left (S, Cutset : String) return String is
   begin
      for I in S'Range loop
         if Ada.Strings.Fixed.Index (Cutset, [1 => S (I)]) = 0 then
            return S (I .. S'Last);
         end if;
      end loop;
      return "";
   end Trim_Left;

   function Handle_Chat
     (UC : not null Upstream_Conn_Access;
      Msg : Message;
      Downstream_ID : Long_Long_Integer) return Handle_Result
   is
      use Soja.Database;
      Cmd : constant String := To_String (Msg.Command);
      Net : constant Network_Access := UC.Network;
      Bad : Boolean;
      R   : constant Handle_Result :=
        Check_Params (Msg, (if Cmd /= "TAGMSG" then 2 else 1), Bad);
   begin
      if Bad then
         return R;
      end if;

      declare
         --  Remove statusmsg sigils from the target.
         Target : constant String :=
           Trim_Left (Param (Msg, 0), To_String (UC.Available_Status_Msg));
         Sender : constant String := To_String (Msg.Prefix.Name);
      begin
         if Equal_Casemap (Net, Sender, Service_Nick) then
            UC.Logger.Print
              ("skipping " & Cmd & " from soju's service: " & Text_Of (Msg));
            return Success;
         end if;
         if Equal_Casemap (Net, Target, Service_Nick) then
            UC.Logger.Print
              ("skipping " & Cmd & " to soju's service: " & Text_Of (Msg));
            return Success;
         end if;

         if not UC.Registered
           or else Equal_Casemap
                     (Net, Sender, To_String (UC.Server_Prefix.Name))
           or else Target = "*"
           or else (Target'Length > 0 and then Target (Target'First) = '$')
         then
            --  This is a server message.
            Produce (UC, "", Msg, 0);
            return Success;
         end if;

         declare
            Direct      : Boolean := Is_Our_Nick (UC, Target);
            Buffer_Name : Unbounded_String :=
              To_Unbounded_String (if Direct then Sender else Target);
            Self        : constant Boolean := Is_Our_Nick (UC, Sender);
            Highlight   : Boolean := False;
         begin
            if Has_Tag (Msg.Tags, "+draft/channel-context") then
               declare
                  Ctx : constant Upstream_Channel_Access :=
                    UC.Channels.Get (Get_Tag (Msg.Tags, "+draft/channel-context"));
               begin
                  if Ctx /= null and then Ctx.Members.Has (Sender) then
                     Buffer_Name := Ctx.Name;
                     Direct := False;
                  end if;
               end;
            end if;

            declare
               Buffer : constant String := To_String (Buffer_Name);
               Ch     : constant Channel_Access := Net.Channels.Get (Buffer);
            begin
               if Ch /= null and then Cmd /= "TAGMSG" and then not Self then
                  if Ch.Detached then
                     Handle_Detached_Message (UC, Ch, Msg);
                  end if;

                  Highlight := Soja.Core.Network_Ops.Is_Highlight (Net, Msg);
                  if Ch.Detach_On = Filter_Message
                    or else Ch.Detach_On = Filter_Default
                    or else (Ch.Detach_On = Filter_Highlight and then Highlight)
                  then
                     Update_Channel_Auto_Detach (UC, Buffer);
                  end if;
               end if;

               if not Self and then (Highlight or else Direct) then
                  --  TODO: Web Push (broadcastWebPush) is not ported yet.
                  declare
                     Valid : Boolean;
                     T     : constant Ada.Calendar.Time :=
                       Parse_Server_Time (Get_Tag (Msg.Tags, "time"), Valid);
                  begin
                     if Valid then
                        Net.Push_Targets.Set (Buffer, T);
                     end if;
                  end;
               end if;

               Produce (UC, Buffer, Msg, Downstream_ID);
            end;
         end;
      end;
      return Success;
   end Handle_Chat;

   ----------------------------------------------------------------------
   --  4d: replies, users, MONITOR
   ----------------------------------------------------------------------

   function Handle_List
     (UC : not null Upstream_Conn_Access; Msg : Message; Is_End : Boolean)
      return Handle_Result
   is
      P : constant Pending_Command :=
        (if Is_End then Dequeue_Command (UC, "LIST")
         else Current_Pending_Command (UC, "LIST"));
   begin
      if not P.Found then
         return Fail
           ((if Is_End then "unexpected RPL_LISTEND"
             else "unexpected RPL_LIST") & ": no matching pending LIST");
      elsif P.DC = null then
         return Success;
      end if;
      Send_Message (P.DC, Msg);
      return Success;
   end Handle_List;

   function Replace_All (S : String; From, To : Character) return String is
      R : String := S;
   begin
      for C of R loop
         if C = From then
            C := To;
         end if;
      end loop;
      return R;
   end Replace_All;

   function Handle_Who_Reply
     (UC : not null Upstream_Conn_Access; Msg : Message) return Handle_Result
   is
      Bad : Boolean;
      R   : constant Handle_Result := Check_Params (Msg, 8, Bad);
   begin
      if Bad then
         return R;
      end if;

      declare
         Pending : constant Pending_Command :=
           Current_Pending_Command (UC, "WHO");
      begin
         if not Pending.Found then
            return Fail ("unexpected RPL_WHOREPLY: no matching pending WHO");
         elsif Pending.DC = null then
            return Success;
         end if;

         declare
            Trailing : constant String := Param (Msg, 7);
            Space    : constant Natural :=
              Ada.Strings.Fixed.Index (Trailing, " ");
            Nick     : constant String := Param (Msg, 5);
         begin
            if Space = 0 then
               return Fail
                 ("malformed RPL_WHOREPLY: failed to parse real name");
            end if;

            Send_Message (Pending.DC, Msg);

            if Should_Cache_User_Info (UC, Nick) then
               Cache_User_Info
                 (UC, Nick,
                  (Username => Msg.Params (3),
                   Hostname => Msg.Params (4),
                   Server   => Msg.Params (5),
                   Nickname => To_Unbounded_String (Nick),
                   Flags    => To_Unbounded_String
                     (Strip_Member_Prefixes
                        (Param (Msg, 6), UC.Available_Memberships)),
                   Realname => To_Unbounded_String
                     (Trailing (Space + 1 .. Trailing'Last)),
                   others   => <>));
            end if;
         end;
      end;
      return Success;
   end Handle_Who_Reply;

   function Handle_Whox_Reply
     (UC : not null Upstream_Conn_Access; Msg : Message) return Handle_Result
   is
      Pending : constant Pending_Command := Current_Pending_Command (UC, "WHO");
   begin
      if not Pending.Found then
         return Fail ("unexpected RPL_WHOSPCRPL: no matching pending WHO");
      elsif Pending.DC = null then
         return Success;
      end if;

      Send_Message (Pending.DC, Msg);

      if Pending.Msg.Params.Length > 1 then
         declare
            Fields, Token : Unbounded_String;
         begin
            Soja.Irc.Whox.Parse_Whox_Options
              (Param (Pending.Msg, 1), Fields, Token);
            if Ada.Strings.Fixed.Index (To_String (Fields), "n") = 0 then
               return Success;
            end if;

            declare
               Info : constant Soja.Irc.Whox.Whox_Info :=
                 Soja.Irc.Whox.Parse_Whox_Reply (Msg, To_String (Fields));
            begin
               if Should_Cache_User_Info (UC, To_String (Info.Nickname)) then
                  Cache_User_Info
                    (UC, To_String (Info.Nickname),
                     (Nickname => Info.Nickname,
                      Username => Info.Username,
                      Hostname => Info.Hostname,
                      Server   => Info.Server,
                      Flags    => To_Unbounded_String
                        (Strip_Member_Prefixes
                           (To_String (Info.Flags), UC.Available_Memberships)),
                      Account  => Info.Account,
                      Realname => Info.Realname));
               end if;
            end;
         exception
            when E : Soja.Irc.Whox.Whox_Error =>
               return Fail (Ada.Exceptions.Exception_Message (E));
         end;
      end if;
      return Success;
   end Handle_Whox_Reply;

   function Handle_End_Of_Who
     (UC : not null Upstream_Conn_Access; Msg : Message) return Handle_Result
   is
      Pending : constant Pending_Command := Dequeue_Command (UC, "WHO");
   begin
      --  No pending WHO: some servers send RPL_TRYAGAIN followed by
      --  RPL_ENDOFWHO.  No downstream: it is gone.
      if Pending.Found and then Pending.DC /= null then
         Send_Message (Pending.DC, Msg);
      end if;
      return Success;
   end Handle_End_Of_Who;

   function Handle_Whois_Reply
     (UC : not null Upstream_Conn_Access; Msg : Message) return Handle_Result
   is
      Pending : constant Pending_Command := Current_Pending_Command (UC, "WHOIS");
   begin
      if not Pending.Found then
         return Fail
           ("unexpected WHOIS reply " & Quote (To_String (Msg.Command))
            & ": no matching pending WHOIS");
      elsif Pending.DC /= null then
         Send_Message (Pending.DC, Msg);
      end if;
      return Success;
   end Handle_Whois_Reply;

   function Handle_End_Of_Whois
     (UC : not null Upstream_Conn_Access; Msg : Message) return Handle_Result
   is
      Pending : constant Pending_Command := Dequeue_Command (UC, "WHOIS");
   begin
      if not Pending.Found then
         return Fail
           ("unexpected RPL_ENDOFWHOIS: no matching pending WHOIS");
      elsif Pending.DC /= null then
         Send_Message (Pending.DC, Msg);
      end if;
      return Success;
   end Handle_End_Of_Whois;

   function Handle_No_Such_Nick
     (UC : not null Upstream_Conn_Access;
      Msg : Message;
      Downstream_ID : Long_Long_Integer) return Handle_Result
   is
      Bad : Boolean;
      R   : constant Handle_Result := Check_Params (Msg, 3, Bad);
   begin
      if Bad then
         return R;
      end if;

      --  A one-argument WHOIS fails with NOSUCHNICK, the two-argument
      --  variant with NOSUCHSERVER.
      declare
         use Soja.Irc.Case_Mapping;
         Nick    : constant String := Param (Msg, 1);
         Pending : constant Pending_Command :=
           Current_Pending_Command (UC, "WHOIS");
      begin
         if Pending.Found and then Pending.Msg.Params.Length > 0
           and then Fold (UC.Network.Casemap, Trailing (Pending.Msg))
                    = Fold (UC.Network.Casemap, Nick)
         then
            declare
               Ignored : constant Pending_Command :=
                 Dequeue_Command (UC, "WHOIS");
               pragma Unreferenced (Ignored);
            begin
               if Pending.DC /= null then
                  Send_Message (Pending.DC, Msg);
               end if;
            end;
         else
            Forward_Msg_By_ID (UC, Downstream_ID, Msg);
         end if;
      end;
      return Success;
   end Handle_No_Such_Nick;

   function Handle_Invite
     (UC : not null Upstream_Conn_Access; Msg : Message) return Handle_Result
   is
      Bad : Boolean;
      R   : constant Handle_Result := Check_Params (Msg, 2, Bad);
   begin
      if Bad then
         return R;
      end if;

      declare
         Channel : constant String := Param (Msg, 1);
         Invited : constant Boolean := Is_Our_Nick (UC, Param (Msg, 0));
      begin
         if Invited then
            declare
               Joined : constant Boolean := UC.Channels.Get (Channel) /= null;
               Saved  : constant Channel_Access :=
                 UC.Network.Channels.Get (Channel);
            begin
               --  Automatically join a saved channel when we are invited --
               --  unless we were kicked from it and stayed out: then the
               --  invitation is shown to the clients, who decide.
               if not Joined and then Saved /= null
                 and then not UC.Network.Kicked.Has (Channel)
               then
                  for M of Generate_Join
                             ([To_String (Saved.Name)], [To_String (Saved.Key)])
                  loop
                     Send_Message (UC, M);
                  end loop;
                  return Success;
               end if;
            end;
         end if;

         for DC of Downstreams (UC.Network) loop
            if Invited or else Is_Enabled (DC.Caps, "invite-notify") then
               Send_Message (DC, Msg);
            end if;
         end loop;
         --  TODO: Web Push (broadcastWebPush) when we are invited.
      end;
      return Success;
   end Handle_Invite;

   function Handle_Monitor_Status
     (UC : not null Upstream_Conn_Access; Msg : Message) return Handle_Result
   is
      Bad : Boolean;
      R   : constant Handle_Result := Check_Params (Msg, 2, Bad);
   begin
      if Bad then
         return R;
      end if;

      declare
         Cmd     : constant String := To_String (Msg.Command);
         Targets : constant String_Vectors.Vector :=
           Split_Commas (Param (Msg, 1));
         Online  : constant Boolean := Cmd = RPL_MONONLINE;
         Want    : constant String := Soja.Database.Get_Nick
           (UC.User.User_Record, UC.Network.Network_Record);
      begin
         for Target of Targets loop
            UC.Monitored.Set (To_String (Parse_Prefix (Target).Name), Online);
         end loop;

         --  Check if the nick we want is now free.
         if not Online and then not Is_Our_Nick (UC, Want)
           and then not UC.Has_Desired_Nick
         then
            for Target of Targets loop
               if Equal_Casemap
                    (UC.Network, To_String (Parse_Prefix (Target).Name), Want)
               then
                  UC.Logger.Print
                    ("desired nick " & Quote (Want) & " is now available");
                  Send_Message (UC, Make ("NICK", [Want]));
                  exit;
               end if;
            end loop;
         end if;

         for DC of Downstreams (UC.Network) loop
            for Target of Targets loop
               if DC.Monitored.Has (To_String (Parse_Prefix (Target).Name))
               then
                  Send_Message (DC, Make (Cmd, [To_String (DC.Nick), Target]));
               end if;
            end loop;
         end loop;
      end;
      return Success;
   end Handle_Monitor_Status;

   function Handle_Monitor_List_Full
     (UC : not null Upstream_Conn_Access; Msg : Message) return Handle_Result
   is
      Bad : Boolean;
      R   : constant Handle_Result := Check_Params (Msg, 3, Bad);
   begin
      if Bad then
         return R;
      end if;
      declare
         Limit   : constant String := Param (Msg, 1);
         Targets : constant String_Vectors.Vector :=
           Split_Commas (Param (Msg, 2));
      begin
         for DC of Downstreams (UC.Network) loop
            for Target of Targets loop
               if DC.Monitored.Has (Target) then
                  Send_Message
                    (DC, Make (ERR_MONLISTFULL,
                               [To_String (DC.Nick), Limit, Target]));
               end if;
            end loop;
         end loop;
      end;
      return Success;
   end Handle_Monitor_List_Full;

   procedure Handle_Away (UC : not null Upstream_Conn_Access; Msg : Message) is
      Nick : constant String := To_String (Msg.Prefix.Name);
      Uu   : constant Upstream_User_Access := UC.Users.Get (Nick);
   begin
      --  Update the user flags, if we already have them cached.
      if Uu /= null and then Length (Uu.Flags) > 0 then
         declare
            Flags : constant String := To_String (Uu.Flags);
            Away  : constant Boolean := not Msg.Params.Is_Empty;
         begin
            Cache_User_Info
              (UC, Nick,
               (Flags => To_Unbounded_String
                  (if Away then Replace_All (Flags, 'H', 'G')
                   else Replace_All (Flags, 'G', 'H')),
                others => <>));
         end;
      end if;
      Forward_Message (UC, Msg);
   end Handle_Away;

   function Handle_Account
     (UC : not null Upstream_Conn_Access; Msg : Message) return Handle_Result
   is
      Bad : Boolean;
      R   : constant Handle_Result := Check_Params (Msg, 1, Bad);
   begin
      if Bad then
         return R;
      end if;
      Cache_User_Info
        (UC, To_String (Msg.Prefix.Name),
         (Account => Msg.Params (1), others => <>));
      Forward_Message (UC, Msg);
      return Success;
   end Handle_Account;

   function Handle_Setname
     (UC : not null Upstream_Conn_Access; Msg : Message) return Handle_Result
   is
      use Soja.Core.Downstream_Helpers;
      Bad : Boolean;
      R   : constant Handle_Result := Check_Params (Msg, 1, Bad);
   begin
      if Bad then
         return R;
      end if;

      Cache_User_Info
        (UC, To_String (Msg.Prefix.Name),
         (Realname => Msg.Params (1), others => <>));

      --  TODO (Go): consider appending this message to logs.
      if Is_Our_Nick (UC, To_String (Msg.Prefix.Name)) then
         UC.Logger.Print
           ("changed realname from " & Quote (To_String (UC.Realname))
            & " to " & Quote (Param (Msg, 0)));
         UC.Realname := Msg.Params (1);
         for DC of Downstreams (UC.Network) loop
            Update_Realname (DC);
         end loop;
      else
         Forward_Message (UC, Msg);
      end if;
      return Success;
   end Handle_Setname;

   function Handle_Chghost
     (UC : not null Upstream_Conn_Access; Msg : Message) return Handle_Result
   is
      use Soja.Core.Downstream_Helpers;
      Bad : Boolean;
      R   : constant Handle_Result := Check_Params (Msg, 2, Bad);
   begin
      if Bad then
         return R;
      end if;

      if Is_Our_Nick (UC, To_String (Msg.Prefix.Name)) then
         declare
            New_Prefix : constant Soja.Irc.Messages.Prefix :=
              (Name => UC.Nick, User => Msg.Params (1), Host => Msg.Params (2));
         begin
            UC.Logger.Print
              ("changed prefix from " & Quote (To_String (Msg.Prefix.Host))
               & " to " & Quote (Image (New_Prefix)));
         end;
         UC.Username := Msg.Params (1);
         UC.Hostname := Msg.Params (2);
         for DC of Downstreams (UC.Network) loop
            Update_Host (DC);
         end loop;
      else
         --  TODO (Go): add a fallback with QUIT/JOIN/MODE messages.
         Forward_Message (UC, Msg);
      end if;
      return Success;
   end Handle_Chghost;

   ----------------------------------------------------------------------
   --  Channel-full retries (soja-specific; see PORTING.md)
   ----------------------------------------------------------------------

   type Join_Retry_Action is new Soja.Timers.Action with record
      UC   : Upstream_Conn_Access;
      Name : Unbounded_String;
   end record;

   overriding procedure Run (A : in out Join_Retry_Action) is
      Ok : Boolean := False;
   begin
      --  Post without blocking for good: whoever stops this timer waits for
      --  this procedure, and may be the very task that must make room.
      for Attempt in 1 .. 20 loop
         A.UC.Network.User.Events.Try_Enqueue
           (new Retry_Join_Event'(UC => A.UC, Name => A.Name), Ok);
         exit when Ok;
         delay 0.5;
      end loop;
      if not Ok then
         A.UC.Logger.Print
           ("skipping a join retry: the event queue is full");
      end if;
   end Run;

   --  The channel is saved, we are not in it, we were not kicked from it, and
   --  UC is still the network's connection.
   function Should_Retry_Join
     (UC : not null Upstream_Conn_Access; Name : String) return Boolean
   is
   begin
      return UC.Network.Conn = UC
        and then UC.Network.Channels.Has (Name)
        and then UC.Channels.Get (Name) = null
        and then not UC.Network.Kicked.Has (Name);
   end Should_Retry_Join;

   procedure Cancel_Join_Retry
     (UC : not null Upstream_Conn_Access; Name : String)
   is
      R : constant Join_Retry_Access := UC.Join_Retries.Get (Name);
   begin
      if R /= null then
         Soja.Timers.Stop (R.Timer);
         UC.Join_Retries.Del (Name);
      end if;
   end Cancel_Join_Retry;

   procedure Stop_Join_Retries (UC : not null Upstream_Conn_Access) is
      Names : String_Vectors.Vector;

      procedure Collect (Name : String; R : Join_Retry_Access) is
         pragma Unreferenced (R);
      begin
         Names.Append (Name);
      end Collect;
   begin
      UC.Join_Retries.For_Each (Collect'Access);
      for Name of Names loop
         Cancel_Join_Retry (UC, Name);
      end loop;
   end Stop_Join_Retries;

   --  Arm the next retry (unless one is pending already).
   procedure Schedule_Join_Retry
     (UC : not null Upstream_Conn_Access; Name : String)
   is
      R : Join_Retry_Access := UC.Join_Retries.Get (Name);
   begin
      if not Should_Retry_Join (UC, Name) then
         Cancel_Join_Retry (UC, Name);
         return;
      end if;

      if R = null then
         R := new Join_Retry;
         R.Backoff := new Soja.Backoff.Backoffer'
           (Soja.Backoff.New_Backoffer
              (Join_Retry_Min, Join_Retry_Max, Join_Retry_Jitter));
         declare
            First : constant Duration := Soja.Backoff.Next (R.Backoff.all);
            pragma Unreferenced (First);   --  the immediate first value
         begin
            null;
         end;
         UC.Join_Retries.Set (Name, R);
      end if;

      if R.Armed then
         return;
      end if;
      R.Armed := True;
      Soja.Timers.Stop (R.Timer);
      R.Timer := Soja.Timers.After_Func
        (Soja.Backoff.Next (R.Backoff.all),
         new Join_Retry_Action'(UC => UC, Name => To_Unbounded_String (Name)));
   end Schedule_Join_Retry;

   procedure Retry_Join
     (UC : not null Upstream_Conn_Access; Name : String)
   is
      R : constant Join_Retry_Access := UC.Join_Retries.Get (Name);
   begin
      if R = null then
         return;
      end if;
      R.Armed := False;

      if not Should_Retry_Join (UC, Name) then
         Cancel_Join_Retry (UC, Name);
         return;
      end if;

      declare
         Saved : constant Channel_Access := UC.Network.Channels.Get (Name);
      begin
         UC.Logger.Print
           ("retrying to join " & Quote (Name) & ", it was full");
         for M of Generate_Join
                    ([To_String (Saved.Name)], [To_String (Saved.Key)])
         loop
            Send_Message (UC, M);
         end loop;
      end;

      --  Keep trying, with a growing delay, until we are in (the JOIN
      --  handler cancels this), kicked, or the channel is no longer saved.
      Schedule_Join_Retry (UC, Name);
   end Retry_Join;

   --  ERR_CHANNELISFULL: relay it, and retry the saved channel later.  The
   --  other join failures (banned, bad key, invite-only, ...) are only
   --  relayed: they are not retried.
   function Handle_Channel_Full
     (UC : not null Upstream_Conn_Access;
      Msg : Message;
      Downstream_ID : Long_Long_Integer) return Handle_Result
   is
   begin
      Forward_Msg_By_ID (UC, Downstream_ID, Msg);
      if Msg.Params.Length >= 2 then
         Schedule_Join_Retry (UC, Param (Msg, 1));
      end if;
      return Success;
   end Handle_Channel_Full;

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
               --  The sub-parameter before the last one is "*" when more lines
               --  follow.  (Go indexes msg.Params with len(subParams)-2,
               --  missing the offset of two; fixed.)
               More : constant Boolean :=
                 N >= 2 and then Param (Msg, N) = "*";
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
               Kick : constant Kick_Info_Access := UC.Network.Kicked.Get (Name);
            begin
               if Kick /= null then
                  --  We were kicked from this channel and have not rejoined
                  --  it by hand: stay out.
                  UC.Logger.Print
                    ("not rejoining " & Quote (Name) & ": kicked by "
                     & To_String (Kick.Kicked_By));
                  return;
               end if;
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
            Parameter : Unbounded_String := To_Unbounded_String (Raw);
            Negate    : Boolean := False;
            Has_Value : Boolean := False;
            Value     : Unbounded_String;
         begin
            if Raw'Length > 0 and then Raw (Raw'First) = '-' then
               --  A negated token: the parameter is the name after the dash.
               --  (Go leaves it "-"-prefixed, so none of the negation
               --  branches below could ever match; fixed, see PORTING.md.)
               Negate := True;
               Parameter :=
                 To_Unbounded_String (Raw (Raw'First + 1 .. Raw'Last));
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

               --  Downstreams get the token as the server sent it, so a
               --  negation reaches them as a negation.  (Go passes it
               --  without its dash, i.e. as if it were being set.)
               if Is_Passthrough_Isupport (Name) then
                  Downstream_Isupport.Append (Raw);
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
      Msg_Batch     : Upstream_Batch_Access;
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
            Msg_Batch := new Upstream_Batch'(UC.Batches (Name));
            if Length (Label) = 0 then
               Label := Msg_Batch.Label;
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

      elsif Cmd = "NOTICE" or else Cmd = "PRIVMSG" or else Cmd = "TAGMSG" then
         return Handle_Chat (UC, Msg, Downstream_ID);

      elsif Cmd = "BATCH" then
         return Handle_Batch (UC, Msg, Label, Msg_Batch);

      elsif Cmd = "NICK" then
         return Handle_Nick (UC, Msg);

      elsif Cmd = "JOIN" then
         return Handle_Join (UC, Msg);

      elsif Cmd = "PART" then
         return Handle_Part (UC, Msg);

      elsif Cmd = "KICK" then
         return Handle_Kick (UC, Msg);

      elsif Cmd = "QUIT" then
         Handle_Quit (UC, Msg);

      elsif Cmd = RPL_TOPIC or else Cmd = RPL_NOTOPIC then
         return Handle_Topic_Reply (UC, Msg, Downstream_ID);

      elsif Cmd = "TOPIC" then
         return Handle_Topic (UC, Msg);

      elsif Cmd = "MODE" then
         return Handle_Mode (UC, Msg);

      elsif Cmd = RPL_UMODEIS then
         return Handle_User_Mode_Is (UC, Msg);

      elsif Cmd = RPL_CHANNELMODEIS then
         return Handle_Channel_Mode_Is (UC, Msg, Downstream_ID);

      elsif Cmd = RPL_CREATIONTIME then
         return Handle_Creation_Time (UC, Msg, Downstream_ID);

      elsif Cmd = RPL_TOPICWHOTIME then
         return Handle_Topic_Who_Time (UC, Msg, Downstream_ID);

      elsif Cmd = RPL_NAMREPLY then
         return Handle_Names_Reply (UC, Msg, Downstream_ID);

      elsif Cmd = RPL_ENDOFNAMES then
         return Handle_End_Of_Names (UC, Msg, Downstream_ID);

      elsif Cmd = RPL_LISTSTART or else Cmd = RPL_LIST then
         return Handle_List (UC, Msg, Is_End => False);

      elsif Cmd = RPL_LISTEND then
         return Handle_List (UC, Msg, Is_End => True);

      elsif Cmd = RPL_WHOREPLY then
         return Handle_Who_Reply (UC, Msg);

      elsif Cmd = RPL_WHOSPCRPL then
         return Handle_Whox_Reply (UC, Msg);

      elsif Cmd = RPL_ENDOFWHO then
         return Handle_End_Of_Who (UC, Msg);

      elsif Cmd = RPL_WHOISCERTFP or else Cmd = RPL_WHOISREGNICK
        or else Cmd = RPL_WHOISUSER or else Cmd = RPL_WHOISSERVER
        or else Cmd = RPL_WHOISCHANNELS or else Cmd = RPL_WHOISOPERATOR
        or else Cmd = RPL_WHOISIDLE or else Cmd = RPL_WHOISSPECIAL
        or else Cmd = RPL_WHOISACCOUNT or else Cmd = RPL_WHOISACTUALLY
        or else Cmd = RPL_WHOISHOST or else Cmd = RPL_WHOISMODES
        or else Cmd = RPL_WHOISSECURE
      then
         return Handle_Whois_Reply (UC, Msg);

      elsif Cmd = RPL_ENDOFWHOIS then
         return Handle_End_Of_Whois (UC, Msg);

      elsif Cmd = "INVITE" then
         return Handle_Invite (UC, Msg);

      elsif Cmd = RPL_INVITING then
         R := Check_Params (Msg, 3, Bad);
         if Bad then
            return R;
         end if;
         Forward_Msg_By_ID (UC, Downstream_ID, Msg);

      elsif Cmd = RPL_MONONLINE or else Cmd = RPL_MONOFFLINE then
         return Handle_Monitor_Status (UC, Msg);

      elsif Cmd = ERR_MONLISTFULL then
         return Handle_Monitor_List_Full (UC, Msg);

      elsif Cmd = RPL_AWAY then
         Forward_Msg_By_ID (UC, Downstream_ID, Msg);

      elsif Cmd = "AWAY" then
         Handle_Away (UC, Msg);

      elsif Cmd = "ACCOUNT" then
         return Handle_Account (UC, Msg);

      elsif Cmd = "SETNAME" then
         return Handle_Setname (UC, Msg);

      elsif Cmd = "CHGHOST" then
         return Handle_Chghost (UC, Msg);

      elsif Cmd = RPL_BANLIST or else Cmd = RPL_INVITELIST
        or else Cmd = RPL_EXCEPTLIST or else Cmd = RPL_ENDOFBANLIST
        or else Cmd = RPL_ENDOFINVITELIST or else Cmd = RPL_ENDOFEXCEPTLIST
      then
         Forward_Msg_By_ID (UC, Downstream_ID, Msg);

      elsif Cmd = ERR_NOSUCHNICK or else Cmd = ERR_NOSUCHSERVER then
         return Handle_No_Such_Nick (UC, Msg, Downstream_ID);

      elsif Cmd = ERR_CHANNELISFULL then
         return Handle_Channel_Full (UC, Msg, Downstream_ID);

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
