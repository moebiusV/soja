pragma Ada_2022;

with Ada.Strings.Unbounded;
with Ada.Text_IO;

with Soja.Downstream;
with Soja.Irc.Messages;

procedure Downstream_Check is
   use Ada.Strings.Unbounded;
   use Soja.Downstream;
   use Soja.Irc.Messages;

   function Cmd (E : Irc_Error) return String is
     (To_String (E.Message.Command));

   procedure Check_Param (E : Irc_Error; I : Natural; Want : String) is
   begin
      if Param (E.Message, I) /= Want then
         raise Program_Error with "param " & I'Image & " = " &
           Param (E.Message, I) & ", want " & Want;
      end if;
   end Check_Param;

   procedure Check_User (Raw, U, C, N : String) is
      Username, Client, Network : Unbounded_String;
   begin
      Unmarshal_Username (Raw, Username, Client, Network);
      if Username /= U or else Client /= C or else Network /= N then
         raise Program_Error with "unmarshal " & Raw & " wrong";
      end if;
   end Check_User;
begin
   --  Error constructors.
   declare
      E : constant Irc_Error := New_Unknown_Command_Error ("FOO");
   begin
      if Cmd (E) /= "421" then
         raise Program_Error with "unknown command numeric";
      end if;
      Check_Param (E, 0, "*");
      Check_Param (E, 1, "FOO");
      Check_Param (E, 2, "Unknown command");
   end;

   declare
      E : constant Irc_Error := New_Unknown_Irc_Error ("JOIN", "boom");
   begin
      if Cmd (E) /= "400" then
         raise Program_Error with "unknown error numeric";
      end if;
      Check_Param (E, 0, "*");
      Check_Param (E, 1, "JOIN");
      Check_Param (E, 2, "boom");
   end;

   declare
      E : constant Irc_Error := New_Need_More_Params_Error ("JOIN");
   begin
      if Cmd (E) /= "461" then
         raise Program_Error with "need more params numeric";
      end if;
      Check_Param (E, 0, "*");
      Check_Param (E, 1, "JOIN");
      Check_Param (E, 2, "Not enough parameters");
   end;

   declare
      E : constant Irc_Error := New_Chat_History_Error ("BEFORE", "#chan");
   begin
      if Cmd (E) /= "FAIL" then
         raise Program_Error with "chathistory command";
      end if;
      Check_Param (E, 0, "CHATHISTORY");
      Check_Param (E, 1, "MESSAGE_ERROR");
      Check_Param (E, 2, "BEFORE");
      Check_Param (E, 3, "#chan");
   end;

   --  Image serialises (contains the numeric).
   declare
      S : constant String := Image (New_Unknown_Command_Error ("FOO"));
   begin
      if S = "" then
         raise Program_Error with "Image must not be empty";
      end if;
   end;

   --  Parse_Bouncer_Net_ID.
   declare
      R : constant Parse_Net_ID_Result := Parse_Bouncer_Net_ID ("network", "42");
   begin
      if not R.Ok or else R.ID /= 42 then
         raise Program_Error with "valid net id must parse";
      end if;
   end;

   if Parse_Bouncer_Net_ID ("network", "0").Ok then
      raise Program_Error with "zero net id must fail";
   end if;
   if Parse_Bouncer_Net_ID ("network", "-1").Ok then
      raise Program_Error with "negative net id must fail";
   end if;
   if Parse_Bouncer_Net_ID ("network", "abc").Ok then
      raise Program_Error with "non-numeric net id must fail";
   end if;

   declare
      R : constant Parse_Net_ID_Result := Parse_Bouncer_Net_ID ("network", "0");
   begin
      if Cmd (R.Err) /= "FAIL" then
         raise Program_Error with "invalid net id must be a FAIL";
      end if;
   end;

   --  Unmarshal_Username.
   Check_User ("alice", "alice", "", "");
   Check_User ("alice/libera", "alice", "", "libera");
   Check_User ("alice@laptop", "alice", "laptop", "");
   Check_User ("alice@laptop/libera", "alice", "laptop", "libera");

   Ada.Text_IO.Put_Line ("ALL PASS");
end Downstream_Check;
