pragma Ada_2022;

with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;

package body Soja.Irc.Modes is

   use Soja.Irc.Members;

   -----------------------
   -- Std_Channel_Modes --
   -----------------------

   function Std_Channel_Modes return Mode_Type_Maps.Map is
      M : Mode_Type_Maps.Map;
   begin
      M.Insert ('b', Mode_Type_A);   --  ban list
      M.Insert ('e', Mode_Type_A);   --  ban exception list
      M.Insert ('I', Mode_Type_A);   --  invite exception list
      M.Insert ('k', Mode_Type_B);   --  channel key
      M.Insert ('l', Mode_Type_C);   --  channel user limit
      M.Insert ('i', Mode_Type_D);   --  invite-only
      M.Insert ('m', Mode_Type_D);   --  moderated
      M.Insert ('n', Mode_Type_D);   --  no external messages
      M.Insert ('s', Mode_Type_D);   --  secret
      M.Insert ('t', Mode_Type_D);   --  protected topic
      return M;
   end Std_Channel_Modes;

   --  Go's %q for the plain-ASCII mode strings that reach us.
   function Quote (S : String) return String is
      R : Unbounded_String := To_Unbounded_String ("""");
   begin
      for C of S loop
         if C = '"' or else C = '\' then
            Append (R, '\');
         end if;
         Append (R, C);
      end loop;
      Append (R, '"');
      return To_String (R);
   end Quote;

   -------------------------
   -- Apply_Channel_Modes --
   -------------------------

   procedure Apply_Channel_Modes
     (Available_Memberships : Soja.Irc.Members.Membership_Vectors.Vector;
      Available_Modes       : Mode_Type_Maps.Map;
      Members               : Soja.Irc.Members.Member_Maps.Map;
      Modes                 : in out Channel_Modes;
      Mode_Str              : String;
      Arguments             : Soja.Irc.Messages.Param_Vectors.Vector)
   is
      Next_Argument : Natural := 0;   --  0-based, as in Go
      Plus_Minus    : Character := ' ';
      N_Args        : constant Natural := Natural (Arguments.Length);

      function Arg (I : Natural) return String is
        (To_String (Arguments (I + 1)));

      Handled : Boolean;
   begin
      for Mode of Mode_Str loop
         if Mode = '+' or else Mode = '-' then
            Plus_Minus := Mode;
         else
            if Plus_Minus /= '+' and then Plus_Minus /= '-' then
               raise Mode_Error with
                 "malformed modestring " & Quote (Mode_Str)
                 & ": missing plus/minus";
            end if;

            --  Membership modes (e.g. o, v) take a nick argument.
            Handled := False;
            for Ms of Available_Memberships loop
               if Ms.Mode = Mode then
                  if Next_Argument >= N_Args then
                     raise Mode_Error with
                       "malformed modestring " & Quote (Mode_Str)
                       & ": missing mode argument for "
                       & Plus_Minus & Mode;
                  end if;
                  declare
                     M : constant Membership_Set_Access :=
                       Members.Get (Arg (Next_Argument));
                  begin
                     if M /= null then
                        if Plus_Minus = '+' then
                           Add (M.all, Available_Memberships, Ms);
                        else
                           --  TODO (Go): for upstreams without multi-prefix,
                           --  query the user modes again.
                           Remove (M.all, Ms);
                        end if;
                     end if;
                  end;
                  Next_Argument := Next_Argument + 1;
                  Handled := True;
                  exit;
               end if;
            end loop;

            if not Handled and then Available_Modes.Contains (Mode) then
               declare
                  MT : constant Channel_Mode_Type := Available_Modes (Mode);
               begin
                  if MT = Mode_Type_A then
                     Next_Argument := Next_Argument + 1;
                  elsif MT = Mode_Type_B
                    or else (MT = Mode_Type_C and then Plus_Minus = '+')
                  then
                     if Plus_Minus = '+' then
                        --  Sensitive arguments (such as channel keys) can be
                        --  omitted for privacy; that only happens for
                        --  RPL_CHANNELMODEIS, never for MODE messages.
                        if Modes.Known then
                           Modes.Values.Exclude (Mode);
                           Modes.Values.Insert
                             (Mode,
                              (if Next_Argument < N_Args
                               then Arg (Next_Argument) else ""));
                        end if;
                     else
                        Modes.Values.Exclude (Mode);
                     end if;
                     Next_Argument := Next_Argument + 1;
                  else   --  Mode_Type_C (unset) or Mode_Type_D
                     if Plus_Minus = '+' then
                        if Modes.Known then
                           Modes.Values.Exclude (Mode);
                           Modes.Values.Insert (Mode, "");
                        end if;
                     else
                        Modes.Values.Exclude (Mode);
                     end if;
                  end if;
               end;
            end if;
         end if;
      end loop;
   end Apply_Channel_Modes;

   ------------
   -- Format --
   ------------

   procedure Format
     (CM          : Channel_Modes;
      Mode_String : out Ada.Strings.Unbounded.Unbounded_String;
      Parameters  : out Soja.Irc.Messages.Param_Vectors.Vector)
   is
      With_Values    : Unbounded_String;
      Without_Values : Unbounded_String;
   begin
      Parameters.Clear;
      for C in CM.Values.Iterate loop
         declare
            Value : constant String := Mode_Value_Maps.Element (C);
         begin
            if Value /= "" then
               Append (With_Values, Mode_Value_Maps.Key (C));
               Parameters.Append (To_Unbounded_String (Value));
            else
               Append (Without_Values, Mode_Value_Maps.Key (C));
            end if;
         end;
      end loop;
      Mode_String := "+" & With_Values & Without_Values;
   end Format;

end Soja.Irc.Modes;
