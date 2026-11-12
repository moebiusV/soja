pragma Ada_2022;

with Ada.Calendar.Formatting;
with Ada.Strings.Fixed;

package body Soja.Irc.Xirc is

   use Ada.Strings.Unbounded;

   function Img2 (N : Natural) return String is
      S : constant String := Natural'Image (N);
      D : constant String := S (S'First + 1 .. S'Last);
   begin
      return (if D'Length < 2 then "0" & D else D);
   end Img2;

   ------------------------
   -- Format_Server_Time --
   ------------------------

   function Format_Server_Time (T : Ada.Calendar.Time) return String is
      use Ada.Calendar.Formatting;
      Year       : Ada.Calendar.Year_Number;
      Month      : Ada.Calendar.Month_Number;
      Day        : Ada.Calendar.Day_Number;
      Hour       : Hour_Number;
      Minute     : Minute_Number;
      Second     : Second_Number;
      Sub_Second : Second_Duration;
      Millis     : Natural;
   begin
      Split (T, Year, Month, Day, Hour, Minute, Second, Sub_Second,
             Time_Zone => 0);
      Millis := Natural (Long_Float'Floor (Long_Float (Sub_Second) * 1000.0));
      if Millis > 999 then
         Millis := 999;
      end if;
      declare
         Y : constant String := Integer'Image (Year);
         M3 : constant String := Natural'Image (Millis + 1000);
      begin
         return Y (Y'First + 1 .. Y'Last) & "-" & Img2 (Month) & "-"
           & Img2 (Day) & "T" & Img2 (Hour) & ":" & Img2 (Minute) & ":"
           & Img2 (Second) & "." & M3 (M3'First + 2 .. M3'Last) & "Z";
      end;
   end Format_Server_Time;

   ------------------------
   -- Parse_CTCP_Message --
   ------------------------

   procedure Parse_CTCP_Message
     (Msg    : Soja.Irc.Messages.Message;
      Cmd    : out Unbounded_String;
      Params : out Unbounded_String;
      Ok     : out Boolean)
   is
      Command : constant String := To_String (Msg.Command);
   begin
      Cmd := Null_Unbounded_String;
      Params := Null_Unbounded_String;
      Ok := False;

      if (Command /= "PRIVMSG" and then Command /= "NOTICE")
        or else Natural (Msg.Params.Length) < 2
      then
         return;
      end if;

      declare
         Text : constant String := Soja.Irc.Messages.Param (Msg, 1);
         First : Positive := Text'First;
         Last  : Integer := Text'Last;
      begin
         if Text'Length = 0 or else Text (Text'First) /= ASCII.SOH then
            return;
         end if;

         --  strings.Trim(text, "\x01"): both ends, every occurrence.
         while First <= Last and then Text (First) = ASCII.SOH loop
            First := First + 1;
         end loop;
         while Last >= First and then Text (Last) = ASCII.SOH loop
            Last := Last - 1;
         end loop;

         declare
            T  : constant String := Text (First .. Last);
            Sp : constant Natural := Ada.Strings.Fixed.Index (T, " ");
            W0 : String := (if Sp = 0 then T else T (T'First .. Sp - 1));
         begin
            --  strings.ToUpper, ASCII only (so UTF-8 bytes are untouched).
            for C of W0 loop
               if C in 'a' .. 'z' then
                  C := Character'Val (Character'Pos (C) - 32);
               end if;
            end loop;
            Cmd := To_Unbounded_String (W0);
            if Sp /= 0 then
               Params := To_Unbounded_String (T (Sp + 1 .. T'Last));
            end if;
            Ok := True;
         end;
      end;
   end Parse_CTCP_Message;

end Soja.Irc.Xirc;
