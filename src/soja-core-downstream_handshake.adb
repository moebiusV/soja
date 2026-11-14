pragma Ada_2022;

with Ada.Calendar;
with Ada.Exceptions;
with Ada.IO_Exceptions;
with Ada.Strings.Fixed;

with AWS.Default;
with AWS.Net;
with AWS.Net.SSL;
with AWS.Net.Std;

with Soja.Auth;
with Soja.Oauthbearer;
with Soja.Base64;
with Soja.Core.Downstream_Helpers;
with Soja.Core.Upstream_Dispatch;
with Soja.Core.User_Ops;
with Soja.Database;
with Soja.Downstream;
with Soja.Irc.Cap_Registry;
with Soja.Irc.Case_Mapping;
with Soja.Irc.Genmsg;
with Soja.Irc.Helpers;
with Soja.Irc.Numerics;
with Soja.Irc.Xirc;
with Soja.Msgstore;
with Soja.Server;
with Soja.Timers;
with Soja.User;

package body Soja.Core.Downstream_Handshake is

   use Soja.Core.Downstream_Helpers;
   use Soja.Irc.Cap_Registry;
   use Soja.Irc.Genmsg;
   use Soja.Irc.Helpers;
   use Soja.Irc.Messages;
   use Soja.Irc.Numerics;
   use type Soja.Database.Database_Access;
   use type Soja.Msgstore.Store_Access;
   use type AWS.Net.Socket_Access;

   ----------------------------------------------------------------------
   --  Results
   ----------------------------------------------------------------------

   Success : constant Irc_Error_Result := (Failed => False);

   function IRC_Fail
     (Command : String; Params : String_Vectors.Vector)
      return Irc_Error_Result is
     (Failed => True, Is_IRC => True,
      Err    => (Message => Make (Command, Params)),
      Text   => Null_Unbounded_String);

   function Text_Fail (Text : String) return Irc_Error_Result is
     (Failed => True, Is_IRC => False,
      Err    => (Message => (others => <>)),
      Text   => To_Unbounded_String (Text));

   function Need_More (R : Params_Result) return Irc_Error_Result is
     (Failed => True, Is_IRC => True, Err => R.Err,
      Text   => Null_Unbounded_String);

   function Nick_Of (DC : not null Downstream_Conn_Access) return String is
     (To_String (DC.Nick));

   ----------------------------------------------------------------------
   --  Sanity check of a new server (a TLS connection works)
   ----------------------------------------------------------------------

   function Default_Sanity_Check (Addr : String) return String is
      Colon : constant Natural := Ada.Strings.Fixed.Index (Addr, ":",
        Ada.Strings.Backward);
      Host  : constant String :=
        (if Colon = 0 then Addr else Addr (Addr'First .. Colon - 1));
      Port  : constant Positive :=
        (if Colon = 0 then 6697
         else Positive'Value (Addr (Colon + 1 .. Addr'Last)));
      Plain  : AWS.Net.Socket_Access := AWS.Net.Socket (False);
      Config : AWS.Net.SSL.Config := AWS.Net.SSL.Null_Config;
   begin
      AWS.Net.Std.Socket_Type (Plain.all).Set_Timeout (15.0);
      AWS.Net.Std.Socket_Type (Plain.all).Connect (Host, Port);
      AWS.Net.SSL.Initialize
        (Config,
         Security_Mode       => AWS.Net.SSL.TLS_Client,
         Check_Certificate   => True,
         Trusted_CA_Filename => AWS.Default.Trusted_CA);
      declare
         SSL_Sock : AWS.Net.SSL.Socket_Type :=
           AWS.Net.SSL.Secure_Client (Plain.all, Config, Host);
      begin
         AWS.Net.Free (Plain);
         SSL_Sock.Shutdown;
      end;
      return "";
   exception
      when E : others =>
         if Plain /= null then
            AWS.Net.Free (Plain);
         end if;
         return Ada.Exceptions.Exception_Message (E);
   end Default_Sanity_Check;

   ----------------------------------------------------------------------
   --  CAP
   ----------------------------------------------------------------------

   function Handle_Cap
     (DC : not null Downstream_Conn_Access; M : Message)
      return Irc_Error_Result
   is
      PR : constant Params_Result := Parse_Message_Params (M, 1);
   begin
      if not PR.Ok then
         return Need_More (PR);
      end if;

      declare
         Cmd    : constant String := Upper (Param (M, 0));
         N_Args : constant Natural := Natural (M.Params.Length) - 1;
         Nick   : constant String := Nick_Of (DC);
      begin
         if Cmd = "LS" then
            if N_Args > 0 then
               begin
                  DC.Cap_Version := Integer'Value (Param (M, 1));
               exception
                  when Constraint_Error =>
                     return Text_Fail
                       ("strconv.Atoi: parsing " & Quote (Param (M, 1))
                        & ": invalid syntax");
               end;
            end if;

            if not DC.Registered and then DC.Cap_Version >= 302 then
               --  Let the client show everything it supports, and trim down
               --  the available capabilities when upstreams are known.
               for Cap of Need_All_Downstream_Caps loop
                  Set_Available (DC.Caps, Cap.all, "");
               end loop;
            end if;

            declare
               List : Unbounded_String;

               procedure Add (Name, Value : String) is
               begin
                  if Length (List) > 0 then
                     Append (List, " ");
                  end if;
                  if DC.Cap_Version >= 302 and then Value /= "" then
                     Append (List, Name & "=" & Value);
                  else
                     Append (List, Name);
                  end if;
               end Add;

               Reply : Message;
            begin
               For_Each_Available (DC.Caps, Add'Access);
               --  TODO (Go): multi-line replies.
               Reply := Make ("CAP", [Nick, "LS", To_String (List)]);
               Reply.Prefix := Server_Prefix (DC.Srv);
               Send_Message (DC, Reply);
            end;

            if DC.Cap_Version >= 302 then
               --  CAP version 302 implicitly enables cap-notify.
               Set_Enabled (DC.Caps, "cap-notify", True);
            end if;
            if not DC.Registered then
               DC.Registration.Negotiating_Caps := True;
            end if;

         elsif Cmd = "LIST" then
            declare
               List : Unbounded_String;

               procedure Add (Name : String) is
               begin
                  if Length (List) > 0 then
                     Append (List, " ");
                  end if;
                  Append (List, Name);
               end Add;

               Reply : Message;
            begin
               For_Each_Enabled (DC.Caps, Add'Access);
               Reply := Make ("CAP", [Nick, "LIST", To_String (List)]);
               Reply.Prefix := Server_Prefix (DC.Srv);
               Send_Message (DC, Reply);
            end;

         elsif Cmd = "REQ" then
            if N_Args = 0 then
               return IRC_Fail
                 (ERR_INVALIDCAPCMD,
                  [Nick, Cmd, "Missing argument in CAP REQ command"]);
            end if;

            declare
               Caps    : constant String_Vectors.Vector := Fields (Param (M,
                 1));
               Ack     : Boolean := True;
               Names   : String_Vectors.Vector;
               Enables : array (1 .. Natural (Caps.Length)) of Boolean;
               Count   : Natural := 0;
               Reply   : Message;
            begin
               for Raw of Caps loop
                  declare
                     Lowered : constant String := Lower (Raw);
                     Enable  : constant Boolean :=
                       Lowered'Length = 0 or else Lowered (Lowered'First) /=
                         '-';
                     Name    : constant String :=
                       (if Enable then Lowered
                        else Lowered (Lowered'First + 1 .. Lowered'Last));
                  begin
                     if Enable /= Is_Enabled (DC.Caps, Name) then
                        if not Is_Available (DC.Caps, Name) then
                           Ack := False;
                           exit;
                        end if;
                        if Name = "cap-notify" and then DC.Cap_Version >= 302
                          and then not Enable
                        then
                           --  cap-notify cannot be disabled with CAP 302.
                           Ack := False;
                           exit;
                        end if;
                        if Name = "soju.im/account-required" then
                           --  An informational cap.
                           Ack := False;
                           exit;
                        end if;
                        Count := Count + 1;
                        Names.Append (Name);
                        Enables (Count) := Enable;
                     end if;
                  end;
               end loop;

               --  Atomically ack the whole capability set.
               if Ack then
                  for I in 1 .. Count loop
                     Set_Enabled (DC.Caps, Names (I), Enables (I));
                  end loop;
               end if;

               Reply := Make
                 ("CAP", [Nick, (if Ack then "ACK" else "NAK"), Param (M, 1)]);
               Reply.Prefix := Server_Prefix (DC.Srv);
               Send_Message (DC, Reply);
            end;

            if not DC.Registered then
               DC.Registration.Negotiating_Caps := True;
            end if;

         elsif Cmd = "END" then
            if not DC.Registered then
               DC.Registration.Negotiating_Caps := False;
            end if;

         else
            return IRC_Fail
              (ERR_INVALIDCAPCMD, [Nick, Cmd, "Unknown CAP command"]);
         end if;
      end;
      return Success;
   end Handle_Cap;

   ----------------------------------------------------------------------
   --  AUTHENTICATE
   ----------------------------------------------------------------------

   function Handle_Authenticate
     (DC : not null Downstream_Conn_Access; M : Message)
      return Authenticate_Step
   is
      Nick : constant String := Nick_Of (DC);

      function Fail (R : Irc_Error_Result) return Authenticate_Step is
      begin
         DC.Sasl := null;   --  (Go: deferred on any error)
         return (Done => False, Result => R);
      end Fail;

      function SASL_Fail (Text : String) return Authenticate_Step is
        (Fail (IRC_Fail (ERR_SASLFAIL, [Nick, Text])));

      --  The client's response, once base64-decoded (empty on the first step,
      --  when there is none).
      Resp     : Unbounded_String;
      Has_Resp : Boolean := False;
   begin
      if not Is_Enabled (DC.Caps, "sasl") then
         return SASL_Fail
           ("AUTHENTICATE requires the ""sasl"" capability to be enabled");
      end if;
      if M.Params.Is_Empty then
         return SASL_Fail ("Missing AUTHENTICATE argument");
      end if;
      if Param (M, 0) = "*" then
         return Fail
           (IRC_Fail (ERR_SASLABORTED, [Nick, "SASL authentication aborted"]));
      end if;

      if DC.Sasl = null then
         declare
            Mech : constant String := Upper (Param (M, 0));
         begin
            if Mech /= "PLAIN" and then Mech /= "ANONYMOUS"
              and then Mech /= "OAUTHBEARER"
            then
               return SASL_Fail ("Unsupported SASL mechanism");
            end if;
            DC.Sasl := new Downstream_SASL;
            DC.Sasl.Mechanism := To_Unbounded_String (Mech);
         end;
      else
         declare
            Chunk : constant String :=
              (if Param (M, 0) = "+" then "" else Param (M, 0));
            Valid : Boolean;
         begin
            if Length (DC.Sasl.Pending_Resp) + Chunk'Length > 10 * 1024 then
               return SASL_Fail ("Response too long");
            end if;

            Append (DC.Sasl.Pending_Resp, Chunk);

            if Chunk'Length = Soja.Irc.Xirc.Max_SASL_Length then
               --  A multi-line response: wait for the next command.
               return (Done => False, Result => Success);
            end if;

            declare
               Decoded : constant String :=
                 Soja.Base64.Decode (To_String (DC.Sasl.Pending_Resp), Valid);
            begin
               if not Valid then
                  return SASL_Fail ("Invalid base64-encoded response");
               end if;
               Resp := To_Unbounded_String (Decoded);
               Has_Resp := True;
            end;
            DC.Sasl.Pending_Resp := Null_Unbounded_String;
         end;
      end if;

      --  server.Next(resp)
      declare
         Mech : constant String := To_String (DC.Sasl.Mechanism);
      begin
         if not DC.Sasl.Challenged then
            --  The first step has no client response: an empty challenge.
            DC.Sasl.Challenged := True;
            Send_Message (DC, Make ("AUTHENTICATE", ["+"]));
            return (Done => False, Result => Success);
         end if;
         pragma Assert (Has_Resp);

         if Mech = "PLAIN" then
            --  [authzid] NUL authcid NUL passwd
            declare
               R   : constant String := To_String (Resp);
               N1  : Natural := 0;
               N2  : Natural := 0;
               Nul : Natural := 0;
            begin
               for I in R'Range loop
                  if R (I) = ASCII.NUL then
                     Nul := Nul + 1;
                     if Nul = 1 then
                        N1 := I;
                     elsif Nul = 2 then
                        N2 := I;
                     end if;
                  end if;
               end loop;
               if Nul /= 2 then
                  return Fail (Text_Fail ("sasl: invalid response"));
               end if;

               declare
                  Identity : constant String := R (R'First .. N1 - 1);
                  Username : constant String := R (N1 + 1 .. N2 - 1);
                  Password : constant String := R (N2 + 1 .. R'Last);
               begin
                  if Identity /= "" and then Identity /= Username then
                     return Fail
                       (Text_Fail ("SASL PLAIN identity not supported"));
                  end if;
                  DC.Sasl.Plain_Set := True;
                  DC.Sasl.Plain_Username := To_Unbounded_String (Username);
                  DC.Sasl.Plain_Password := To_Unbounded_String (Password);
               end;
            end;
         end if;
         if Mech = "OAUTHBEARER" then
            declare
               Options : Soja.Oauthbearer.Options;
               Valid   : Boolean;
            begin
               Soja.Oauthbearer.Parse (To_String (Resp), Options, Valid);
               if not Valid then
                  return Fail (Text_Fail ("sasl: invalid response"));
               end if;
               DC.Sasl.Bearer_Set := True;
               DC.Sasl.Bearer_Username := Options.Username;
               DC.Sasl.Bearer_Token := Options.Token;
            end;
         end if;
         --  (ANONYMOUS takes any trace string.)
         return (Done => True, Result => Success);
      end;
   end Handle_Authenticate;

   ----------------------------------------------------------------------
   --  Messages before registration
   ----------------------------------------------------------------------

   procedure Set_Auth_Username
     (DC : not null Downstream_Conn_Access;
      Username, Client_Name, Network_Name : Unbounded_String) is
   begin
      DC.Client_Name := Client_Name;
      DC.Registration.Auth_Username := Username;
      DC.Registration.Network_Name := Network_Name;
   end Set_Auth_Username;

   function Handle_Message_Unregistered
     (DC : not null Downstream_Conn_Access; M : Message)
      return Irc_Error_Result
   is
      Cmd : constant String := To_String (M.Command);
      PR  : Params_Result;
   begin
      if Cmd = "NICK" then
         PR := Parse_Message_Params (M, 1);
         if not PR.Ok then
            return Need_More (PR);
         end if;
         DC.Registration.Nick := M.Params (1);

      elsif Cmd = "USER" then
         PR := Parse_Message_Params (M, 4);
         if not PR.Ok then
            return Need_More (PR);
         end if;
         DC.Registration.Username := M.Params (1);

      elsif Cmd = "PASS" then
         PR := Parse_Message_Params (M, 1);
         if not PR.Ok then
            return Need_More (PR);
         end if;
         DC.Registration.Pass := M.Params (1);

      elsif Cmd = "CAP" then
         return Handle_Cap (DC, M);

      elsif Cmd = "AUTHENTICATE" then
         declare
            Step : constant Authenticate_Step := Handle_Authenticate (DC, M);
         begin
            if Step.Result.Failed then
               return Step.Result;
            elsif not Step.Done then
               return Success;
            end if;

            declare
               Mech     : constant String := To_String (DC.Sasl.Mechanism);
               Username, Client, Network : Unbounded_String;
               Failure  : Unbounded_String;   --  the log text
               Reason   : Unbounded_String :=
                 To_Unbounded_String ("Authentication failed");
               Driver   : constant String := To_String
                 (Soja.Server.Config (DC.Srv.all).Auth_Driver);
            begin
               if Mech = "PLAIN" then
                  Soja.Downstream.Unmarshal_Username
                    (To_String (DC.Sasl.Plain_Username),
                     Username, Client, Network);
                  if not Soja.Auth.Supports_Plain (Driver) then
                     Failure := To_Unbounded_String
                       ("SASL PLAIN not supported");
                  else
                     declare
                        R : constant Soja.Auth.Result :=
                          Soja.Auth.Auth_Plain
                            (Driver, Soja.Server.DB (DC.Srv.all),
                             To_String (Username),
                             To_String (DC.Sasl.Plain_Password));
                     begin
                        if not R.Ok then
                           Failure := R.Internal & " (username "
                             & To_Unbounded_String
                                 (Quote (To_String (Username))) & ")";
                           Reason := R.External;
                        end if;
                     end;
                  end if;
               elsif Mech = "OAUTHBEARER" then
                  if not Soja.Auth.Supports_Bearer (Driver) then
                     Failure := To_Unbounded_String
                       ("SASL OAUTHBEARER not supported");
                  else
                     declare
                        R : constant Soja.Auth.Result :=
                          Soja.Auth.Auth_Bearer
                            (Driver, To_String (DC.Sasl.Bearer_Token),
                             Username);
                     begin
                        if not R.Ok then
                           Failure := R.Internal;
                           Reason := R.External;
                        elsif Length (DC.Sasl.Bearer_Username) > 0
                          and then DC.Sasl.Bearer_Username /= Username
                        then
                           Failure := To_Unbounded_String
                             ("username mismatch (client provided "
                              & Quote (To_String (DC.Sasl.Bearer_Username))
                              & ", but server returned "
                              & Quote (To_String (Username)) & ")");
                           Reason := To_Unbounded_String
                             ("Invalid credentials");
                        end if;
                     end;
                  end if;
               else
                  Failure := To_Unbounded_String
                    ("unsupported SASL mechanism");
               end if;

               if Length (Failure) > 0 then
                  DC.Logger.Print
                    ("SASL " & Mech & " authentication error for nick "
                     & Quote (To_String (DC.Registration.Nick)) & ": "
                     & To_String (Failure));
                  End_SASL
                    (DC, Make (ERR_SASLFAIL, [Nick_Of (DC), To_String
                      (Reason)]));
                  return Success;
               end if;

               if Length (Username) = 0 then
                  raise Program_Error with
                    "username unset after SASL authentication";
               end if;
               Set_Auth_Username (DC, Username, Client, Network);

               --  Technically we should send RPL_LOGGEDIN here.  However we
               --  use RPL_LOGGEDIN to mirror the upstream connection status.
               End_SASL (DC);
            end;
         end;

      elsif Cmd = "BOUNCER" then
         PR := Parse_Message_Params (M, 1);
         if not PR.Ok then
            return Need_More (PR);
         end if;
         declare
            Sub : constant String := Param (M, 0);
         begin
            if Upper (Sub) = "BIND" then
               PR := Parse_Message_Params (M, 2);
               if not PR.Ok then
                  return Need_More (PR);
               end if;

               if Length (DC.Registration.Auth_Username) = 0 then
                  return IRC_Fail
                    ("FAIL",
                     ["BOUNCER", "ACCOUNT_REQUIRED", "BIND",
                      "Authentication needed to bind to bouncer network"]);
               end if;

               declare
                  ID : constant Soja.Downstream.Parse_Net_ID_Result :=
                    Soja.Downstream.Parse_Bouncer_Net_ID (Sub, Param (M, 1));
               begin
                  if not ID.Ok then
                     return (Failed => True, Is_IRC => True, Err => ID.Err,
                             Text => Null_Unbounded_String);
                  end if;
                  DC.Registration.Network_ID := ID.ID;
               end;
            else
               return IRC_Fail
                 ("FAIL",
                  ["BOUNCER", "UNKNOWN_COMMAND", Sub, "Unknown subcommand"]);
            end if;
         end;

      elsif Cmd = "AWAY" then
         if not M.Params.Is_Empty then
            DC.Away := M.Params (1);
         else
            DC.Away := Null_Unbounded_String;
         end if;
         Send_Message (DC, Generate_Away_Reply (Length (DC.Away) > 0));

      else
         DC.Logger.Debug ("unhandled message: " & Image (M));
         return (Failed => True, Is_IRC => True,
                 Err => Soja.Downstream.New_Unknown_Command_Error (Cmd),
                 Text => Null_Unbounded_String);
      end if;
      return Success;
   end Handle_Message_Unregistered;

   ----------------------------------------------------------------------
   --  Registration
   ----------------------------------------------------------------------

   function Register
     (DC : not null Downstream_Conn_Access) return Irc_Error_Result
   is
      Nick   : constant String := Nick_Of (DC);
      Driver : constant String :=
        To_String (Soja.Server.Config (DC.Srv.all).Auth_Driver);
   begin
      if DC.Registered then
         raise Program_Error with "tried to register twice";
      end if;

      if DC.Sasl /= null then
         End_SASL
           (DC, Make (ERR_SASLABORTED, [Nick, "SASL authentication aborted"]));
      end if;

      declare
         Password : constant String := To_String (DC.Registration.Pass);
      begin
         DC.Registration.Pass := Null_Unbounded_String;

         if Length (DC.Registration.Auth_Username) = 0 then
            if Password = "" then
               if Is_Enabled (DC.Caps, "sasl") then
                  return IRC_Fail
                    ("FAIL", ["*", "ACCOUNT_REQUIRED",
                              "Authentication required"]);
               end if;
               return IRC_Fail
                 (ERR_PASSWDMISMATCH, [Nick, "Authentication required"]);
            end if;

            if not Soja.Auth.Supports_Plain (Driver) then
               return IRC_Fail
                 (ERR_PASSWDMISMATCH, [Nick, "PASS authentication disabled"]);
            end if;

            declare
               Username, Client, Network : Unbounded_String;
               R : Soja.Auth.Result;
            begin
               Soja.Downstream.Unmarshal_Username
                 (To_String (DC.Registration.Username),
                  Username, Client, Network);
               R := Soja.Auth.Auth_Plain
                 (Driver, Soja.Server.DB (DC.Srv.all),
                  To_String (Username), Password);
               if not R.Ok then
                  DC.Logger.Print
                    ("PASS authentication error for user "
                     & Quote (To_String (DC.Registration.Username)) & ": "
                     & To_String (R.Internal));
                  return IRC_Fail
                    (ERR_PASSWDMISMATCH, [Nick, To_String (R.External)]);
               end if;
               Set_Auth_Username (DC, Username, Client, Network);
            end;
         end if;
      end;

      declare
         Ignored, Fallback_Client, Fallback_Network : Unbounded_String;
      begin
         Soja.Downstream.Unmarshal_Username
           (To_String (DC.Registration.Username),
            Ignored, Fallback_Client, Fallback_Network);

         if Length (DC.Client_Name) = 0 then
            DC.Client_Name := Fallback_Client;
         elsif Length (Fallback_Client) > 0
           and then DC.Client_Name /= Fallback_Client
         then
            return IRC_Fail
              (ERR_ERRONEUSNICKNAME,
               [Nick, "Client name mismatch in usernames"]);
         end if;

         if Length (DC.Registration.Network_Name) = 0 then
            DC.Registration.Network_Name := Fallback_Network;
         elsif Length (Fallback_Network) > 0
           and then DC.Registration.Network_Name /= Fallback_Network
         then
            return IRC_Fail
              (ERR_ERRONEUSNICKNAME,
               [Nick, "Network name mismatch in usernames"]);
         end if;
      end;

      DC.Registered := True;
      DC.Username := DC.Registration.Auth_Username;
      DC.Logger.Print
        ("registration complete for user " & Quote (To_String (DC.Username)));
      return Success;
   end Register;

   ----------------------------------------------------------------------
   --  loadNetwork
   ----------------------------------------------------------------------

   function Load_Network
     (DC : not null Downstream_Conn_Access) return Irc_Error_Result
   is
      Nick : constant String := Nick_Of (DC);
      Reg  : Downstream_Registration renames DC.Registration.all;
   begin
      if Reg.Network_ID /= 0 then
         declare
            Net : constant Network_Access :=
              Get_Network_By_ID (DC.User, Reg.Network_ID);
         begin
            if Net = null then
               return IRC_Fail
                 ("FAIL",
                  ["BOUNCER", "INVALID_NETID",
                   Ada.Strings.Fixed.Trim
                     (Long_Long_Integer'Image (Reg.Network_ID),
                      Ada.Strings.Left),
                   "Unknown network ID"]);
            end if;
            DC.Network := Net;
            return Success;
         end;
      end if;

      declare
         Name : constant String := To_String (Reg.Network_Name);
      begin
         if Name = "*" then
            return IRC_Fail
              (ERR_PASSWDMISMATCH,
               [Nick, "Multi-upstream mode is no longer supported"]);
         end if;
         if Name = "" then
            return Success;
         end if;

         declare
            Net : Network_Access := Get_Network (DC.User, Name);
         begin
            if Net = null then
               declare
                  Addr : constant String :=
                    (if Ada.Strings.Fixed.Index (Name, ":") = 0
                     then Name & ":6697" else Name);
                  Failure : constant String := Sanity_Check (Addr);
               begin
                  DC.Logger.Print
                    ("trying to connect to new network " & Quote (Addr));
                  if Failure /= "" then
                     DC.Logger.Print
                       ("failed to connect to " & Quote (Addr) & ": "
                        & Failure);
                     return IRC_Fail
                       (ERR_PASSWDMISMATCH,
                        [Nick, "Failed to connect to " & Quote (Name)]);
                  end if;
               end;

               --  Some clients only allow specifying the nickname (and use
               --  the nickname as a username too).  Strip the network name
               --  from the nickname when auto-saving networks.
               declare
                  Raw_Nick, Stripped, Ignored1, Ignored2 : Unbounded_String;
                  Record_Copy : Soja.Database.Network :=
                    Soja.Database.New_Network (Name);
               begin
                  Raw_Nick := Reg.Nick;
                  Soja.Downstream.Unmarshal_Username
                    (To_String (Raw_Nick), Stripped, Ignored1, Ignored2);
                  declare
                     N : constant String := To_String (Stripped);
                  begin
                     if N = ""
                       or else (for some C of N =>
                                  Ada.Strings.Fixed.Index
                                    (" :@!*?$,.", [1 => C]) > 0)
                     then
                        return IRC_Fail
                          (ERR_ERRONEUSNICKNAME,
                           [Nick, To_String (Raw_Nick),
                            "Nickname contains illegal characters"]);
                     end if;
                     if Soja.Irc.Case_Mapping.Fold
                          (Soja.Irc.Case_Mapping.Case_ASCII, N)
                        = Service_Nick_CM
                     then
                        return IRC_Fail
                          (ERR_NICKNAMEINUSE,
                           [Nick, To_String (Raw_Nick),
                            "Nickname reserved for bouncer service"]);
                     end if;
                     Record_Copy.Nick := To_Unbounded_String (N);
                  end;

                  DC.Logger.Print
                    ("auto-saving network " & Quote (Name));
                  begin
                     Net := Soja.Core.User_Ops.Create_Network
                       (DC.User, Record_Copy);
                  exception
                     when E : Soja.Core.User_Ops.Operation_Error =>
                        return Text_Fail
                          (Ada.Exceptions.Exception_Message (E));
                  end;
               end;
            end if;
            DC.Network := Net;
         end;
      end;
      return Success;
   end Load_Network;

   ----------------------------------------------------------------------
   --  Welcome
   ----------------------------------------------------------------------

   function Welcome
     (DC : not null Downstream_Conn_Access; U : not null User_Access)
      return Irc_Error_Result
   is
      Cfg : constant Soja.Server.Server_Config_Access :=
        Soja.Server.Config (DC.Srv.all);
      Res : Irc_Error_Result;
   begin
      if not DC.Registered then
         raise Program_Error with
           "tried to welcome an unregistered connection";
      end if;
      DC.User := U;

      --  TODO (Go): doing this might take some time; it should be done in
      --  register instead, but a new network must be added on the user's task.
      Res := Load_Network (DC);
      if Res.Failed then
         return Res;
      end if;

      DC.Registration := null;

      Update_Supported_Caps (DC);

      declare
         UC : constant Upstream_Conn_Access := Upstream_Of (DC);
      begin
         if UC /= null then
            DC.Nick := UC.Nick;
         elsif DC.Network /= null then
            DC.Nick := To_Unbounded_String
              (Soja.Database.Get_Nick (U.User_Record,
                DC.Network.Network_Record));
         else
            DC.Nick := U.User_Record.Username;
         end if;
         DC.Nick_CM := To_Unbounded_String
           (Soja.Irc.Case_Mapping.Fold (DC.Casemap, To_String (DC.Nick)));

         declare
            Nick     : constant String := Nick_Of (DC);
            Host     : constant String := To_String (Cfg.Hostname);
         begin
            Send_Message
              (DC, Make (RPL_WELCOME, [Nick, "Welcome to soju, " & Nick]));
            Send_Message
              (DC, Make (RPL_YOURHOST, [Nick, "Your host is " & Host]));
            Send_Message
              (DC, Make (RPL_MYINFO,
                         [Nick, Host, "soju", "aiwroO", "OovaimnqpsrtklbeI"]));
            Soja.Core.Upstream_Dispatch.Update_Isupport (DC);
            if UC /= null then
               Send_Message
                 (DC, Make (RPL_UMODEIS,
                            [Nick, "+" & To_String (UC.Modes.Value)]));
            end if;
            if DC.Network = null and then U.User_Record.Admin then
               Send_Message (DC, Make (RPL_UMODEIS, [Nick, "+o"]));
            end if;
         end;
      end;

      Update_Host (DC);
      Update_Realname (DC);
      Update_Account (DC);
      Soja.Core.Update_Casemapping (DC);

      declare
         MOTD : constant String := To_String (Cfg.MOTD);
         Nick : constant String := Nick_Of (DC);
      begin
         if MOTD /= "" and then DC.Network = null then
            for M of Generate_MOTD (MOTD) loop
               Send_Message (DC, M);
            end loop;
         else
            Send_Message
              (DC, Make (ERR_NOMOTD,
                         [Nick,
                          (if DC.Network /= null
                           then "Use /motd to read the message of the day"
                           else "No MOTD")]));
         end if;
      end;

      if Is_Enabled (DC.Caps, "soju.im/bouncer-networks-notify") then
         declare
            procedure Networks (Batch_Ref : String) is
            begin
               for Net of U.Networks loop
                  declare
                     M : Message := Make
                       ("BOUNCER",
                        ["NETWORK",
                         Ada.Strings.Fixed.Trim
                           (Long_Long_Integer'Image (Net.Network_Record.ID),
                            Ada.Strings.Left),
                         Image (Soja.Core.User_Ops.Network_Attrs (Net))]);
                  begin
                     Set_Tag (M.Tags, "batch", Batch_Ref);
                     Send_Message (DC, M);
                  end;
               end loop;
            end Networks;
         begin
            Send_Batch
              (DC, "soju.im/bouncer-networks", String_Vectors.Empty_Vector,
               Networks'Access);
         end;
      end if;

      --  Replay the channels we are in.
      declare
         UC : constant Upstream_Conn_Access := Upstream_Of (DC);

         procedure Replay (Name : String; Ch : Upstream_Channel_Access) is
            Saved : constant Channel_Access := UC.Network.Channels.Get (Name);
            M     : Message := Make ("JOIN", [To_String (Ch.Name)]);
         begin
            --  extended-join: the account and the real name come with it.
            if Is_Enabled (DC.Caps, "extended-join") then
               M.Params.Append
                 (if Length (UC.Account) > 0 then UC.Account
                  else To_Unbounded_String ("*"));
               M.Params.Append (UC.Realname);
            end if;
            if not Ch.Complete then
               return;
            end if;
            if Saved /= null and then Saved.Detached then
               return;
            end if;
            M.Prefix := new Prefix'(Prefix_Of (DC));
            Send_Message (DC, M);
            Forward_Channel (DC, Ch);
         end Replay;
      begin
         if UC /= null then
            UC.Channels.For_Each (Replay'Access);
         end if;
      end;

      --  History: only for the first connected client with that name on the
      --  network, and for clients that don't ask for it with CHATHISTORY.
      if DC.Network /= null and then not Is_Enabled (DC.Caps,
        "draft/chathistory")
        and then U.Msg_Store /= null
      then
         declare
            Net          : constant Network_Access := DC.Network;
            First_Client : Boolean := True;
            Targets      : String_Vectors.Vector;

            procedure Collect (Target : String) is
            begin
               Targets.Append (Target);
            end Collect;
         begin
            for C of U.Downstream_Conns loop
               if C /= DC and then C.Client_Name = DC.Client_Name
                 and then C.Network = DC.Network
               then
                  First_Client := False;
               end if;
            end loop;

            if First_Client then
               Soja.User.For_Each_Target (Net.Delivered, Collect'Access);
               for Target of Targets loop
                  declare
                     Last_Delivered : constant String :=
                       Soja.User.Load_ID
                         (Net.Delivered, Target, To_String (DC.Client_Name));
                  begin
                     if Last_Delivered /= "" then
                        Send_Target_Backlog (DC, Net, Target, Last_Delivered);

                        --  Fast-forward history to the last message.
                        begin
                           Soja.User.Store_ID
                             (Net.Delivered, Target, To_String
                               (DC.Client_Name),
                              U.Msg_Store.Last_Msg_ID
                                (Net.Network_Record,
                                 Soja.Irc.Case_Mapping.Fold
                                   (Net.Casemap, Target),
                                 Ada.Calendar.Clock));
                        exception
                           when E : Soja.Msgstore.Store_Error =>
                              DC.Logger.Print
                                ("failed to get last message ID: "
                                 & Ada.Exceptions.Exception_Message (E));
                        end;
                     end if;
                  end;
               end loop;
            end if;
         end;
      end if;

      --  Channels we were kicked from and stayed out of (soja-specific).
      Send_Kicked_Notices (DC);
      return Success;
   end Welcome;

   ----------------------------------------------------------------------
   --  runUntilRegistered
   ----------------------------------------------------------------------

   --  Closes the connection with an error if registration takes too long.
   type Register_Timeout_Action is new Soja.Timers.Action with record
      DC : Downstream_Conn_Access;
   end record;

   overriding procedure Run (A : in out Register_Timeout_Action) is
      M : Message := Make ("ERROR", ["Connection registration timed out"]);
   begin
      M.Prefix := Server_Prefix (A.DC.Srv);
      Send_Message (A.DC, M);
      Soja.Conn.Shutdown (A.DC.Conn);
   end Run;

   function Run_Until_Registered
     (DC : not null Downstream_Conn_Access) return Boolean
   is
      Timer : Soja.Timers.Timer_Access := Soja.Timers.After_Func
        (Soja.Server.Downstream_Register_Timeout,
         new Register_Timeout_Action'(DC => DC));
      Result : Boolean := False;
      M      : Message;
      R      : Irc_Error_Result;
   begin
      while not DC.Registered loop
         begin
            M := Soja.Conn.Read_Message (DC.Conn);
         exception
            when Ada.IO_Exceptions.End_Error | AWS.Net.Socket_Error =>
               Soja.Timers.Stop (Timer);
               return False;
         end;

         R := Handle_Downstream_Message (DC, M);
         if R.Failed then
            if R.Is_IRC then
               declare
                  E : Message := Copy (R.Err.Message);
               begin
                  E.Prefix := Server_Prefix (DC.Srv);
                  Send_Message (DC, E);
               end;
            else
               DC.Logger.Print
                 ("failed to handle IRC command " & Quote (Image (M)) & ": "
                  & To_String (R.Text));
               Soja.Timers.Stop (Timer);
               return False;
            end if;
         end if;

         if Length (DC.Registration.Nick) > 0
           and then Length (DC.Registration.Username) > 0
           and then not DC.Registration.Negotiating_Caps
         then
            R := Register (DC);
            if R.Failed then
               --  Tell the client why (Go only logs this and drops the
               --  connection, leaving the client without an answer; fixed,
               --  see SOJU-BUGS.md).  The client may try again.
               if R.Is_IRC then
                  declare
                     E : Message := Copy (R.Err.Message);
                  begin
                     E.Prefix := Server_Prefix (DC.Srv);
                     Send_Message (DC, E);
                  end;
                  DC.Registration.Pass := Null_Unbounded_String;
                  DC.Registration.Username := Null_Unbounded_String;
               else
                  DC.Logger.Print (To_String (R.Text));
                  Soja.Timers.Stop (Timer);
                  return False;
               end if;
            end if;
         end if;
      end loop;

      Result := True;
      Soja.Timers.Stop (Timer);
      return Result;
   end Run_Until_Registered;

end Soja.Core.Downstream_Handshake;
