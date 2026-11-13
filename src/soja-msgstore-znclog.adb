pragma Ada_2022;

with Ada.Calendar.Formatting;
with Ada.Strings.Fixed;
with Ada.Strings.Maps.Constants;
with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;

with Soja.Irc.Messages;     use Soja.Irc.Messages;
with Soja.Irc.Xirc;

package body Soja.Msgstore.Znclog is

   function Two (N : Natural) return String is
      S : constant String := Ada.Strings.Fixed.Trim
        (Natural'Image (N), Ada.Strings.Left);
   begin
      return (if S'Length = 1 then "0" & S else S);
   end Two;

   function Param_Or_Empty (Msg : Message; I : Natural) return String is
     (if Natural (Msg.Params.Length) > I then Param (Msg, I) else "");

   function Name_Of (Msg : Message) return String is
     (if Msg.Prefix = null then "" else To_String (Msg.Prefix.Name));

   function Mask_Of (Msg : Message) return String is
     (if Msg.Prefix = null then "@"
      else To_String (Msg.Prefix.User) & "@" & To_String (Msg.Prefix.Host));

   --  formatMessage: it assumes a well-formed message.
   function Format_Message (Msg : Message) return String is
      Cmd : constant String := To_String (Msg.Command);
      Up  : constant String :=
        Ada.Strings.Fixed.Translate
          (Cmd, Ada.Strings.Maps.Constants.Upper_Case_Map);
   begin
      if Up = "NICK" then
         return "*** " & Name_Of (Msg) & " is now known as "
           & Param_Or_Empty (Msg, 0);
      elsif Up = "JOIN" then
         return "*** Joins: " & Name_Of (Msg) & " (" & Mask_Of (Msg) & ")";
      elsif Up = "PART" then
         return "*** Parts: " & Name_Of (Msg) & " (" & Mask_Of (Msg) & ") ("
           & Param_Or_Empty (Msg, 1) & ")";
      elsif Up = "KICK" then
         return "*** " & Param_Or_Empty (Msg, 1) & " was kicked by "
           & Name_Of (Msg) & " (" & Param_Or_Empty (Msg, 2) & ")";
      elsif Up = "QUIT" then
         return "*** Quits: " & Name_Of (Msg) & " (" & Mask_Of (Msg) & ") ("
           & Param_Or_Empty (Msg, 0) & ")";
      elsif Up = "TOPIC" then
         return "*** " & Name_Of (Msg) & " changes topic to '"
           & Param_Or_Empty (Msg, 1) & "'";
      elsif Up = "MODE" then
         declare
            Modes : Unbounded_String;
         begin
            for I in 2 .. Natural (Msg.Params.Length) loop
               if Length (Modes) > 0 then
                  Append (Modes, ' ');
               end if;
               Append (Modes, Param (Msg, I - 1));
            end loop;
            return "*** " & Name_Of (Msg) & " sets mode: " & To_String (Modes);
         end;
      elsif Up = "NOTICE" then
         return "-" & Name_Of (Msg) & "- " & Param_Or_Empty (Msg, 1);
      elsif Up = "PRIVMSG" then
         declare
            Ctcp, Rest : Unbounded_String;
            Ok         : Boolean;
         begin
            Soja.Irc.Xirc.Parse_CTCP_Message (Msg, Ctcp, Rest, Ok);
            if Ok and then To_String (Ctcp) = "ACTION" then
               return "* " & Name_Of (Msg) & " " & To_String (Rest);
            end if;
            return "<" & Name_Of (Msg) & "> " & Param_Or_Empty (Msg, 1);
         end;
      end if;
      return "";
   end Format_Message;

   function Marshal_Line
     (Msg : Message; T : Ada.Calendar.Time) return String
   is
      Text : constant String := Format_Message (Msg);
      Year   : Ada.Calendar.Year_Number;
      Month  : Ada.Calendar.Month_Number;
      Day    : Ada.Calendar.Day_Number;
      Hour   : Ada.Calendar.Formatting.Hour_Number;
      Minute : Ada.Calendar.Formatting.Minute_Number;
      Second : Ada.Calendar.Formatting.Second_Number;
      Sub    : Ada.Calendar.Formatting.Second_Duration;
   begin
      if Text = "" then
         return "";
      end if;
      Ada.Calendar.Formatting.Split
        (T, Year, Month, Day, Hour, Minute, Second, Sub);
      return "[" & Two (Hour) & ":" & Two (Minute) & ":" & Two (Second)
        & "] " & Text;
   end Marshal_Line;

   ----------------------------------------------------------------------
   --  Reading
   ----------------------------------------------------------------------

   Timestamp_Prefix_Len : constant := 11;   --  "[01:02:03] "

   function Starts_With (S, Prefix : String) return Boolean is
     (S'Length >= Prefix'Length
      and then S (S'First .. S'First + Prefix'Length - 1) = Prefix);

   --  strings.TrimPrefix / TrimSuffix: at most one occurrence.
   function Trim_Prefix (S, P : String) return String is
     (if Starts_With (S, P) then S (S'First + P'Length .. S'Last) else S);

   function Trim_Suffix (S, Suffix : String) return String is
     (if S'Length >= Suffix'Length
        and then S (S'Last - Suffix'Length + 1 .. S'Last) = Suffix
      then S (S'First .. S'Last - Suffix'Length) else S);

   --  strings.SplitN (S, Sep, 2): Ok is False when Sep is not in S.
   procedure Split_First
     (S, Sep : String; Left, Right : out Unbounded_String; Ok : out Boolean)
   is
      I : constant Natural := Ada.Strings.Fixed.Index (S, Sep);
   begin
      Ok := I > 0;
      if Ok then
         Left := To_Unbounded_String (S (S'First .. I - 1));
         Right := To_Unbounded_String (S (I + Sep'Length .. S'Last));
      else
         Left := To_Unbounded_String (S);
         Right := Null_Unbounded_String;
      end if;
   end Split_First;

   function Digits_At (S : String; I : Positive) return Integer is
     (if S (I) in '0' .. '9' and then S (I + 1) in '0' .. '9'
      then (Character'Pos (S (I)) - 48) * 10 + (Character'Pos (S (I + 1)) - 48)
      else -1);

   procedure Unmarshal_Line
     (Line    : String;
      User    : Soja.Database.User;
      Network : Soja.Database.Network;
      Entity  : String;
      Ref     : Ada.Calendar.Time;
      Events  : Boolean;
      Msg     : out Message;
      T       : out Ada.Calendar.Time;
      Found   : out Boolean)
   is
      F : constant Integer := Line'First;
      Hour, Minute, Second : Integer;
      Cmd    : Unbounded_String;
      Prefix : Prefix_Access;
      Params : Param_Vectors.Vector;
   begin
      Found := False;
      T := Soja.Database.Null_Time;

      if Line'Length < Timestamp_Prefix_Len then
         raise Store_Error with "malformed timestamp prefix: too short";
      end if;
      Hour := Digits_At (Line, F + 1);
      Minute := Digits_At (Line, F + 4);
      Second := Digits_At (Line, F + 7);
      if Line (F) /= '[' or else Line (F + 3) /= ':'
        or else Line (F + 6) /= ':'
        or else Line (F + 9) /= ']' or else Line (F + 10) /= ' '
        or else Hour not in 0 .. 23 or else Minute not in 0 .. 59
        or else Second not in 0 .. 59
      then
         raise Store_Error with "malformed timestamp prefix";
      end if;

      declare
         Body_Text : constant String :=
           Line (F + Timestamp_Prefix_Len .. Line'Last);
         Left, Right : Unbounded_String;
         Ok          : Boolean;
      begin
         if Events and then Starts_With (Body_Text, "*** ") then
            Split_First (Body_Text (Body_Text'First + 4 .. Body_Text'Last),
                         " ", Left, Right, Ok);
            if not Ok then
               return;
            end if;
            declare
               Head : constant String := To_String (Left);
               Tail : constant String := To_String (Right);
            begin
               if Head = "Joins:" or else Head = "Parts:"
                 or else Head = "Quits:"
               then
                  --  <nick> (<user>@<host>) [(<reason>)]
                  declare
                     Nick, Rest, Mask_Word, Reason_Word : Unbounded_String;
                     Has_Rest : Boolean;
                  begin
                     Split_First (Tail, " ", Nick, Rest, Has_Rest);
                     if not Has_Rest then
                        return;
                     end if;
                     Split_First (To_String (Rest), " ", Mask_Word,
                                  Reason_Word, Ok);
                     declare
                        Mask : constant String := Trim_Suffix
                          (Trim_Prefix (To_String (Mask_Word), "("), ")");
                        User_Part, Host_Part : Unbounded_String;
                        Has_At : Boolean;
                        Reason : constant String :=
                          (if Ok then Trim_Suffix
                             (Trim_Prefix (To_String (Reason_Word), "("), ")")
                           else "");
                     begin
                        Split_First (Mask, "@", User_Part, Host_Part, Has_At);
                        if not Has_At then
                           return;
                        end if;
                        Prefix := new Soja.Irc.Messages.Prefix'
                          (Name => Nick, User => User_Part, Host => Host_Part);
                        if Head = "Joins:" then
                           Cmd := To_Unbounded_String ("JOIN");
                           Params.Append (To_Unbounded_String (Entity));
                        elsif Head = "Parts:" then
                           Cmd := To_Unbounded_String ("PART");
                           Params.Append (To_Unbounded_String (Entity));
                           if Reason /= "" then
                              Params.Append (To_Unbounded_String (Reason));
                           end if;
                        else
                           Cmd := To_Unbounded_String ("QUIT");
                           if Reason /= "" then
                              Params.Append (To_Unbounded_String (Reason));
                           end if;
                        end if;
                     end;
                  end;
               else
                  --  <nick> <what happened>
                  declare
                     Nick : constant String := Head;
                  begin
                     if Starts_With (Tail, "is now known as ") then
                        Cmd := To_Unbounded_String ("NICK");
                        Prefix := new Soja.Irc.Messages.Prefix'
                          (Name => To_Unbounded_String (Nick), others => <>);
                        Params.Append (To_Unbounded_String
                          (Tail (Tail'First + 16 .. Tail'Last)));
                     elsif Starts_With (Tail, "was kicked by ") then
                        declare
                           Rest : constant String :=
                             Tail (Tail'First + 14 .. Tail'Last);
                           By, Why : Unbounded_String;
                        begin
                           Split_First (Rest, " ", By, Why, Ok);
                           if not Ok then
                              return;
                           end if;
                           Cmd := To_Unbounded_String ("KICK");
                           Prefix := new Soja.Irc.Messages.Prefix'
                             (Name => By, others => <>);
                           Params.Append (To_Unbounded_String (Entity));
                           Params.Append (To_Unbounded_String (Nick));
                           declare
                              Reason : constant String := Trim_Suffix
                                (Trim_Prefix (To_String (Why), "("), ")");
                           begin
                              if Reason /= "" then
                                 Params.Append (To_Unbounded_String (Reason));
                              end if;
                           end;
                        end;
                     elsif Starts_With (Tail, "changes topic to ") then
                        Cmd := To_Unbounded_String ("TOPIC");
                        Prefix := new Soja.Irc.Messages.Prefix'
                          (Name => To_Unbounded_String (Nick), others => <>);
                        Params.Append (To_Unbounded_String (Entity));
                        Params.Append (To_Unbounded_String
                          (Trim_Suffix
                             (Trim_Prefix
                                (Tail (Tail'First + 17 .. Tail'Last), "'"),
                              "'")));
                     elsif Starts_With (Tail, "sets mode: ") then
                        declare
                           Modes : constant String :=
                             Tail (Tail'First + 11 .. Tail'Last);
                           From  : Positive := Modes'First;
                        begin
                           Cmd := To_Unbounded_String ("MODE");
                           Prefix := new Soja.Irc.Messages.Prefix'
                             (Name => To_Unbounded_String (Nick),
                              others => <>);
                           Params.Append (To_Unbounded_String (Entity));
                           --  strings.Split (r, " "): empty fields stay.
                           for I in Modes'Range loop
                              if Modes (I) = ' ' then
                                 Params.Append (To_Unbounded_String
                                   (Modes (From .. I - 1)));
                                 From := I + 1;
                              end if;
                           end loop;
                           Params.Append (To_Unbounded_String
                             (Modes (From .. Modes'Last)));
                        end;
                     else
                        return;
                     end if;
                  end;
               end if;
            end;

         else
            declare
               Sender, Text : Unbounded_String;
               Chat_Entity  : Unbounded_String := To_Unbounded_String (Entity);
            begin
               if Starts_With (Body_Text, "<") then
                  Cmd := To_Unbounded_String ("PRIVMSG");
                  Split_First
                    (Body_Text (Body_Text'First + 1 .. Body_Text'Last),
                     "> ", Sender, Text, Ok);
               elsif Starts_With (Body_Text, "-") then
                  Cmd := To_Unbounded_String ("NOTICE");
                  Split_First
                    (Body_Text (Body_Text'First + 1 .. Body_Text'Last),
                     "- ", Sender, Text, Ok);
               elsif Starts_With (Body_Text, "* ") then
                  Cmd := To_Unbounded_String ("PRIVMSG");
                  Split_First
                    (Body_Text (Body_Text'First + 2 .. Body_Text'Last),
                     " ", Sender, Text, Ok);
                  if Ok then
                     Text := To_Unbounded_String
                       (ASCII.SOH & "ACTION " & To_String (Text) & ASCII.SOH);
                  end if;
               else
                  return;
               end if;
               if not Ok then
                  return;
               end if;

               Prefix := new Soja.Irc.Messages.Prefix'
                 (Name => Sender, others => <>);
               if Entity = To_String (Sender) then
                  --  A direct message to us.  Our nick is not in the logs, so
                  --  take it from the settings: it may not be the one we had
                  --  then, but we cannot do better.
                  Chat_Entity := To_Unbounded_String
                    (Soja.Database.Get_Nick (User, Network));
               end if;
               Params.Append (Chat_Entity);
               Params.Append (Text);
            end;
         end if;
      end;

      declare
         Year   : Ada.Calendar.Year_Number;
         Month  : Ada.Calendar.Month_Number;
         Day    : Ada.Calendar.Day_Number;
         H      : Ada.Calendar.Formatting.Hour_Number;
         Mi     : Ada.Calendar.Formatting.Minute_Number;
         S      : Ada.Calendar.Formatting.Second_Number;
         Sub    : Ada.Calendar.Formatting.Second_Duration;
      begin
         Ada.Calendar.Formatting.Split (Ref, Year, Month, Day, H, Mi, S, Sub);
         T := Ada.Calendar.Formatting.Time_Of
           (Year, Month, Day, Hour, Minute, Second);
      end;

      Msg := (Tags => <>, Prefix => Prefix, Command => Cmd, Params => Params);
      Set_Tag (Msg.Tags, "time", Soja.Irc.Xirc.Format_Server_Time (T));
      Found := True;
   end Unmarshal_Line;

end Soja.Msgstore.Znclog;
