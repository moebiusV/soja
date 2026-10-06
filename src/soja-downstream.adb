pragma Ada_2022;

with Soja.Irc.Numerics;

package body Soja.Downstream is

   use Soja.Irc.Messages;
   use Soja.Irc.Numerics;

   --  A message with no prefix or tags, only a command and params.
   function Reply (Command : String; Params : Param_Vectors.Vector)
      return Message
   is
      M : Message;
   begin
      M.Command := To_Unbounded_String (Command);
      M.Params := Params;
      return M;
   end Reply;

   -----------
   -- Image --
   -----------

   function Image (E : Irc_Error) return String is
   begin
      return Soja.Irc.Messages.Image (E.Message);
   end Image;

   -------------------------------
   -- New_Unknown_Command_Error --
   -------------------------------

   function New_Unknown_Command_Error (Cmd : String) return Irc_Error is
      P : Param_Vectors.Vector;
   begin
      P.Append (To_Unbounded_String ("*"));
      P.Append (To_Unbounded_String (Cmd));
      P.Append (To_Unbounded_String ("Unknown command"));
      return (Message => Reply (ERR_UNKNOWNCOMMAND, P));
   end New_Unknown_Command_Error;

   --------------------------
   -- New_Unknown_Irc_Error --
   --------------------------

   function New_Unknown_Irc_Error (Cmd, Text : String) return Irc_Error is
      P : Param_Vectors.Vector;
   begin
      P.Append (To_Unbounded_String ("*"));
      P.Append (To_Unbounded_String (Cmd));
      P.Append (To_Unbounded_String (Text));
      return (Message => Reply (ERR_UNKNOWNERROR, P));
   end New_Unknown_Irc_Error;

   -------------------------------
   -- New_Need_More_Params_Error --
   -------------------------------

   function New_Need_More_Params_Error (Cmd : String) return Irc_Error is
      P : Param_Vectors.Vector;
   begin
      P.Append (To_Unbounded_String ("*"));
      P.Append (To_Unbounded_String (Cmd));
      P.Append (To_Unbounded_String ("Not enough parameters"));
      return (Message => Reply (ERR_NEEDMOREPARAMS, P));
   end New_Need_More_Params_Error;

   -----------------------------
   -- New_Chat_History_Error --
   -----------------------------

   function New_Chat_History_Error (Subcommand, Target : String)
      return Irc_Error
   is
      P : Param_Vectors.Vector;
   begin
      P.Append (To_Unbounded_String ("CHATHISTORY"));
      P.Append (To_Unbounded_String ("MESSAGE_ERROR"));
      P.Append (To_Unbounded_String (Subcommand));
      P.Append (To_Unbounded_String (Target));
      P.Append (To_Unbounded_String ("Messages could not be retrieved"));
      return (Message => Reply ("FAIL", P));
   end New_Chat_History_Error;

   ---------------------------
   -- New_Invalid_Net_ID_Error --
   ---------------------------

   function New_Invalid_Net_ID_Error (Subcommand, S : String)
      return Irc_Error
   is
      P : Param_Vectors.Vector;
   begin
      P.Append (To_Unbounded_String ("BOUNCER"));
      P.Append (To_Unbounded_String ("INVALID_NETID"));
      P.Append (To_Unbounded_String (Subcommand));
      P.Append (To_Unbounded_String (S));
      P.Append (To_Unbounded_String ("Invalid network ID"));
      return (Message => Reply ("FAIL", P));
   end New_Invalid_Net_ID_Error;

   ------------------------
   -- Parse_Bouncer_Net_ID --
   ------------------------

   function Parse_Bouncer_Net_ID (Subcommand, S : String)
      return Parse_Net_ID_Result
   is
      ID : Long_Long_Integer;
   begin
      begin
         ID := Long_Long_Integer'Value (S);
      exception
         when Constraint_Error =>
            return (Ok => False,
                    Err => New_Invalid_Net_ID_Error (Subcommand, S));
      end;

      if ID <= 0 then
         return (Ok => False, Err => New_Invalid_Net_ID_Error (Subcommand, S));
      end if;

      return (Ok => True, ID => ID);
   end Parse_Bouncer_Net_ID;

   ----------------
   -- Index_Any --
   ----------------

   function Index_Any (S, Chars : String) return Natural is
   begin
      for I in S'Range loop
         for J in Chars'Range loop
            if S (I) = Chars (J) then
               return I;
            end if;
         end loop;
      end loop;
      return 0;
   end Index_Any;

   ---------------------
   -- Last_Index_Any --
   ---------------------

   function Last_Index_Any (S, Chars : String) return Natural is
   begin
      for I in reverse S'Range loop
         for J in Chars'Range loop
            if S (I) = Chars (J) then
               return I;
            end if;
         end loop;
      end loop;
      return 0;
   end Last_Index_Any;

   -----------------------
   -- Unmarshal_Username --
   -----------------------

   procedure Unmarshal_Username
     (Raw : String; Username, Client, Network : out Unbounded_String)
   is
      I : constant Natural := Index_Any (Raw, "/@");
      J : constant Natural := Last_Index_Any (Raw, "/@");
      U : Unbounded_String := To_Unbounded_String (Raw);
      C : Unbounded_String := Null_Unbounded_String;
      N : Unbounded_String := Null_Unbounded_String;
   begin
      if I > 0 then
         U := To_Unbounded_String (Raw (Raw'First .. I - 1));
      end if;

      if J > 0 then
         if Raw (J) = '@' then
            C := To_Unbounded_String (Raw (J + 1 .. Raw'Last));
         else
            N := To_Unbounded_String (Raw (J + 1 .. Raw'Last));
         end if;
      end if;

      if I > 0 and then J > 0 and then I < J then
         if Raw (I) = '@' then
            C := To_Unbounded_String (Raw (I + 1 .. J - 1));
         else
            N := To_Unbounded_String (Raw (I + 1 .. J - 1));
         end if;
      end if;

      Username := U;
      Client := C;
      Network := N;
   end Unmarshal_Username;

end Soja.Downstream;
