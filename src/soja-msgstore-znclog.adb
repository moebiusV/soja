pragma Ada_2022;

with Ada.Calendar.Formatting;
with Ada.Strings.Fixed;
with Ada.Strings.Maps.Constants;
with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;

with Soja.Irc.Messages;     use Soja.Irc.Messages;
with Soja.Irc.Xirc;
with Soja.Utf8;

with Znc_Line;
with Znc_Line.Parser;

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

   --  strings.Split (S, " "): the fields between the spaces, the empty ones
   --  too.
   function Split_Spaces (S : String) return Param_Vectors.Vector is
      Result : Param_Vectors.Vector;
      From   : Positive := S'First;
   begin
      for I in S'Range when S (I) = ' ' loop
         Result.Append (To_Unbounded_String (S (From .. I - 1)));
         From := I + 1;
      end loop;
      Result.Append (To_Unbounded_String (S (From .. S'Last)));
      return Result;
   end Split_Spaces;

   function Digits_At (S : String; I : Positive) return Integer is
     (if S (I) in '0' .. '9' and then S (I + 1) in '0' .. '9'
      then (Character'Pos (S (I)) - 48) * 10 + (Character'Pos (S (I + 1)) - 48)
      else -1);

   --  What is in parentheses: "(why)" is "why".
   function Unparen (S : String) return String is
     (Trim_Suffix (Trim_Prefix (S, "("), ")"));

   function Who (Name : String) return Prefix_Access is
     (new Soja.Irc.Messages.Prefix'(Name => To_Unbounded_String (Name),
                                    others => <>));

   --  The line is read by the generated parser (grammars/znclog.hbnf), which
   --  says what kind of line it is and where its words are; what is left is
   --  to take off the parentheses and quotes and to build the message.
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
      use Znc_Line;
      use type Param_Vectors.Vector;

      Tree   : Znc_line_Type;
      Cmd    : Unbounded_String;
      Prefix : Prefix_Access;
      Params : Param_Vectors.Vector;

      --  A message of Sender: to the entity, or to us when the entity is the
      --  sender (a direct message).  Our nick is not in the logs, so take it
      --  from the settings: it may not be the one we had then, but we cannot
      --  do better.
      procedure Chat (Command, Sender, Text : String) is
         To : constant String :=
           (if Entity = Sender then Soja.Database.Get_Nick (User, Network)
            else Entity);
      begin
         Cmd := To_Unbounded_String (Command);
         Prefix := Who (Sender);
         Params := [To_Unbounded_String (To), To_Unbounded_String (Text)];
      end Chat;

      --  Joins, Parts and Quits: <nick> (<user>@<host>) [(<reason>)].  A mask
      --  without an "@" is not an event.
      procedure Membership
        (Word : Join_word_Type; Nick, Mask, Reason : String)
      is
         Bare : constant String := Unparen (Mask);
         At_I : constant Natural := Ada.Strings.Fixed.Index (Bare, "@");
         Why  : constant String := Unparen (Reason);
      begin
         if At_I = 0 then
            return;
         end if;
         Prefix := new Soja.Irc.Messages.Prefix'
           (Name => To_Unbounded_String (Nick),
            User => To_Unbounded_String (Bare (Bare'First .. At_I - 1)),
            Host => To_Unbounded_String (Bare (At_I + 1 .. Bare'Last)));
         case Word is
            when Join_word_Joins =>
               Cmd := To_Unbounded_String ("JOIN");
               Params := [To_Unbounded_String (Entity)];
            when Join_word_Parts =>
               Cmd := To_Unbounded_String ("PART");
               Params := [To_Unbounded_String (Entity)];
               if Why /= "" then
                  Params.Append (To_Unbounded_String (Why));
               end if;
            when Join_word_Quits =>
               Cmd := To_Unbounded_String ("QUIT");
               if Why /= "" then
                  Params.Append (To_Unbounded_String (Why));
               end if;
         end case;
      end Membership;

      --  The message of one kind of line; Cmd stays empty for a line that is
      --  not a message (or an event when events are not asked for).
      procedure Read_Entry (E : Log_entry_Type) is
      begin
         if E.Privmsg /= null then
            Chat ("PRIVMSG", To_String (E.Privmsg.Sender_gt),
                  To_String (E.Privmsg.Text));
         elsif E.Notice /= null then
            Chat ("NOTICE", To_String (E.Notice.Sender_dash),
                  To_String (E.Notice.Text));
         elsif E.Action /= null then
            Chat ("PRIVMSG", To_String (E.Action.Sender_sp),
                  ASCII.SOH & "ACTION " & To_String (E.Action.Text)
                  & ASCII.SOH);
         elsif E.Event = null or else not Events then
            null;
         elsif E.Event.Event_1.Joined_why /= null then
            declare
               J : Joined_why_Type renames E.Event.Event_1.Joined_why.all;
            begin
               Membership (J.Join_word, To_String (J.Nick),
                           To_String (J.Mask), To_String (J.Reason));
            end;
         elsif E.Event.Event_1.Joined /= null then
            declare
               J : Joined_Type renames E.Event.Event_1.Joined.all;
            begin
               Membership (J.Join_word, To_String (J.Nick),
                           To_String (J.Mask), "");
            end;
         elsif E.Event.Event_1.Renamed /= null then
            declare
               R : Renamed_Type renames E.Event.Event_1.Renamed.all;
            begin
               Cmd := To_Unbounded_String ("NICK");
               Prefix := Who (To_String (R.Nick));
               Params := [R.Text];
            end;
         elsif E.Event.Event_1.Kicked /= null then
            declare
               K : Kicked_Type renames E.Event.Event_1.Kicked.all;
               Why : constant String := Unparen (To_String (K.Reason));
            begin
               Cmd := To_Unbounded_String ("KICK");
               Prefix := Who (To_String (K.Kicker));
               Params := [To_Unbounded_String (Entity), K.Nick];
               if Why /= "" then
                  Params.Append (To_Unbounded_String (Why));
               end if;
            end;
         elsif E.Event.Event_1.Retopic /= null then
            declare
               R : Retopic_Type renames E.Event.Event_1.Retopic.all;
            begin
               Cmd := To_Unbounded_String ("TOPIC");
               Prefix := Who (To_String (R.Nick));
               Params := [To_Unbounded_String (Entity),
                          To_Unbounded_String
                            (Trim_Suffix
                               (Trim_Prefix (To_String (R.Text), "'"), "'"))];
            end;
         elsif E.Event.Event_1.Remode /= null then
            declare
               R : Remode_Type renames E.Event.Event_1.Remode.all;
            begin
               Cmd := To_Unbounded_String ("MODE");
               Prefix := Who (To_String (R.Nick));
               Params := [To_Unbounded_String (Entity)]
                         & Split_Spaces (To_String (R.Text));
            end;
         end if;
      end Read_Entry;

      Hour, Minute, Second : Integer;
   begin
      Found := False;
      T := Soja.Database.Null_Time;

      --  Bytes that are not UTF-8 would be refused by the parser, and with
      --  them the whole day's file: they are replaced instead.
      begin
         Tree := Znc_Line.Parser.Parse_Text (Soja.Utf8.To_Valid (Line));
      exception
         when Znc_Line.Parser.Parse_Error =>
            raise Store_Error with "malformed timestamp prefix";
      end;

      Hour := Digits_At (To_String (Tree.Stamp), 2);
      Minute := Digits_At (To_String (Tree.Stamp), 5);
      Second := Digits_At (To_String (Tree.Stamp), 8);
      if Hour not in 0 .. 23 or else Minute not in 0 .. 59
        or else Second not in 0 .. 59
      then
         Znc_Line.Parser.Free_Znc_line (Tree);
         raise Store_Error with "malformed timestamp prefix";
      end if;

      Read_Entry (Tree.Log_entry.all);
      Znc_Line.Parser.Free_Znc_line (Tree);
      if Cmd = Null_Unbounded_String then
         return;
      end if;

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
