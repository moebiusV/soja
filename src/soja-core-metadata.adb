pragma Ada_2022;

with Ada.Containers;
with Ada.Containers.Vectors;
with Ada.Exceptions;
with Ada.Strings.Unbounded;

with Soja.Core.Downstream_Helpers;
with Soja.Irc.Cap_Registry;
with Soja.Irc.Case_Mapping;
with Soja.Irc.Genmsg;
with Soja.Irc.Helpers;
with Soja.Irc.Numerics;
with Soja.Server;

package body Soja.Core.Metadata is

   use Ada.Strings.Unbounded;
   use Soja.Core.Downstream_Helpers;
   use Soja.Irc.Genmsg;
   use Soja.Irc.Helpers;
   use Soja.Irc.Messages;
   use type Ada.Containers.Count_Type;

   Success : constant Irc_Error_Result := (Failed => False);

   function IRC_Fail
     (Command : String; Params : String_Vectors.Vector)
      return Irc_Error_Result is
     (Failed => True, Is_IRC => True,
      Err    => (Message => Make (Command, Params)),
      Text   => Null_Unbounded_String);

   function Internal_Error (Target : String) return Irc_Error_Result is
     (IRC_Fail ("FAIL", ["METADATA", "INTERNAL_ERROR", Target,
                         "Internal error"]));

   --  The value of a key of a target ("" when there is no such key).
   function Value_Of
     (Info : Soja.Database.Message_Target_Info; Key : String) return String
   is
   begin
      if Key = Pinned_Key then
         return (if Info.Pinned then "1" else "0");
      elsif Key = Muted_Key then
         return (if Info.Muted then "1" else "0");
      elsif Key = Blocked_Key then
         return (if Info.Blocked then "1" else "0");
      end if;
      return "";
   end Value_Of;

   Keys : constant array (1 .. 3) of access constant String :=
     [new String'(Pinned_Key), new String'(Muted_Key),
      new String'(Blocked_Key)];

   procedure Send_Fail
     (DC : not null Downstream_Conn_Access; Batch_Ref : String;
      Params : String_Vectors.Vector)
   is
      Msg : Message := Make ("FAIL", Params);
   begin
      if Batch_Ref /= "" then
         Set_Tag (Msg.Tags, "batch", Batch_Ref);
      end if;
      Send_Message (DC, Msg);
   end Send_Fail;

   ----------------------
   -- Send_Target_Metadata --
   ----------------------

   procedure Send_Target_Metadata
     (DC   : not null Downstream_Conn_Access;
      Info : Soja.Database.Message_Target_Info)
   is
      procedure Process (Batch_Ref : String) is
      begin
         for K of Keys loop
            if DC.Metadata_Subs.Contains (K.all) then
               declare
                  Msg : Message := Make
                    ("METADATA", [To_String (Info.Target), K.all, "*",
                                  Value_Of (Info, K.all)]);
               begin
                  Set_Tag (Msg.Tags, "batch", Batch_Ref);
                  Send_Message (DC, Msg);
               end;
            end if;
         end loop;
      end Process;
   begin
      if not Soja.Irc.Cap_Registry.Is_Enabled (DC.Caps, "draft/metadata-2")
      then
         return;
      end if;
      Send_Batch (DC, "metadata", String_Vectors.Empty_Vector,
                  Process'Access);
   end Send_Target_Metadata;

   ------------------
   -- Send_Welcome --
   ------------------

   procedure Send_Welcome (DC : not null Downstream_Conn_Access) is
      procedure None (Batch_Ref : String) is
         pragma Unreferenced (Batch_Ref);
      begin
         null;
      end None;
   begin
      if not Soja.Irc.Cap_Registry.Is_Enabled (DC.Caps, "draft/metadata-2")
      then
         return;
      end if;
      --  No user-specific metadata.
      Send_Batch (DC, "metadata", String_Vectors.Empty_Vector, None'Access);

      if DC.Network /= null then
         declare
            Targets : constant Soja.Database.Message_Target_Info_Lists.Vector
              := Soja.Database.List_Message_Targets
                   (Soja.Server.DB (DC.Srv.all).all,
                    DC.Network.Network_Record.ID);
         begin
            for T of Targets loop
               Send_Target_Metadata (DC, T);
            end loop;
         end;
      end if;
   exception
      when E : Soja.Database.Database_Error =>
         DC.Logger.Print
           ("failed to list message targets: "
            & Ada.Exceptions.Exception_Message (E));
   end Send_Welcome;

   ----------------
   -- Handle_Sub --
   ----------------

   function Handle_Sub
     (DC      : not null Downstream_Conn_Access;
      M       : Message;
      Handled : out Boolean) return Irc_Error_Result
   is
      PR : constant Params_Result := Parse_Message_Params (M, 2);
   begin
      Handled := True;
      if not PR.Ok then
         return (Failed => True, Is_IRC => True, Err => PR.Err,
                 Text => Null_Unbounded_String);
      end if;

      declare
         Sub : constant String := Param (M, 1);
         Cmd : constant String := To_String (M.Command);
      begin
         if Sub = "SUB" or else Sub = "UNSUB" then
            for I in 2 .. Natural (M.Params.Length) - 1 loop
               declare
                  Key : constant String := Lower (Param (M, I));
               begin
                  if Key not in "soju.im/pinned" | "soju.im/muted"
                                | "soju.im/blocked"
                  then
                     Send_Message
                       (DC, Make ("FAIL", [Cmd, "KEY_INVALID", Key,
                                           "Invalid key"]));
                  elsif Sub = "SUB" then
                     DC.Metadata_Subs.Include (Key);

                     --  Technically we are only required to send the
                     --  METADATA of channels we are joined to, and users we
                     --  are sharing a channel with or are MONITOR-ing, but it
                     --  is easier to send all METADATA we are aware of, and
                     --  the spec guarantees that servers MAY send these
                     --  messages at any time.
                     if DC.Network /= null then
                        declare
                           Targets : constant
                             Soja.Database.Message_Target_Info_Lists.Vector :=
                             Soja.Database.List_Message_Targets
                               (Soja.Server.DB (DC.Srv.all).all,
                                DC.Network.Network_Record.ID);
                        begin
                           for T of Targets loop
                              Send_Message
                                (DC, Make ("METADATA",
                                           [To_String (T.Target), Key, "*",
                                            Value_Of (T, Key)]));
                           end loop;
                        exception
                           when E : Soja.Database.Database_Error =>
                              DC.Logger.Print
                                ("failed to list message targets for "
                                 & "METADATA SUB: "
                                 & Ada.Exceptions.Exception_Message (E));
                              return Internal_Error ("*");
                        end;
                     end if;

                     Send_Message
                       (DC, Make (Soja.Irc.Numerics.RPL_METADATASUBOK,
                                  ["*", Key]));
                  else
                     DC.Metadata_Subs.Exclude (Key);
                     Send_Message
                       (DC, Make (Soja.Irc.Numerics.RPL_METADATAUNSUBOK,
                                  ["*", Key]));
                  end if;
               end;
            end loop;
            return Success;
         elsif Sub = "SUBS" then
            for K of DC.Metadata_Subs loop
               Send_Message
                 (DC, Make (Soja.Irc.Numerics.RPL_METADATASUBS, ["*", K]));
            end loop;
            return Success;
         end if;
      end;
      Handled := False;
      return Success;
   end Handle_Sub;

   -------------------------
   -- Handle_Unregistered --
   -------------------------

   function Handle_Unregistered
     (DC : not null Downstream_Conn_Access; M : Message)
      return Irc_Error_Result
   is
      Handled : Boolean;
      R       : constant Irc_Error_Result := Handle_Sub (DC, M, Handled);
   begin
      if Handled then
         return R;
      end if;
      return IRC_Fail
        ("FAIL", ["METADATA", "INVALID_PARAMS", Param (M, 1),
                  "Unknown command"]);
   end Handle_Unregistered;

   ----------------------------------
   -- Setting the keys of a target --
   ----------------------------------

   type Key_Value is record
      Key       : Unbounded_String;
      Has_Value : Boolean := False;
      Value     : Unbounded_String;
   end record;

   package Key_Value_Vectors is new Ada.Containers.Vectors
     (Positive, Key_Value);

   --  dc.setMessageTargetMetadata.  Info is null (Has_Info False) for a
   --  target that cannot have any (the bouncer connection, "*").
   procedure Set_Target_Metadata
     (DC        : not null Downstream_Conn_Access;
      Target    : String;
      Has_Info  : Boolean;
      Info      : in out Soja.Database.Message_Target_Info;
      Changes   : Key_Value_Vectors.Vector;
      Batch_Ref : String)
   is
      procedure Fail_With (Params : String_Vectors.Vector) is
      begin
         Send_Fail (DC, Batch_Ref, Params);
      end Fail_With;
   begin
      for C of Changes loop
         declare
            Key : constant String := To_String (C.Key);
            Bad : Boolean := False;
            Out_Value : Unbounded_String;
            Bool : Boolean := False;
         begin
            if not Has_Info then
               Fail_With (["METADATA", "KEY_INVALID", Key, "Invalid key"]);
            elsif Key not in "soju.im/pinned" | "soju.im/muted"
                             | "soju.im/blocked"
            then
               Fail_With (["METADATA", "KEY_INVALID", Key, "Invalid key"]);
            else
               --  parseMessageTargetMetadataBool
               if not C.Has_Value then
                  Bool := False;
                  Out_Value := To_Unbounded_String ("0");
               elsif To_String (C.Value) = "1" then
                  Bool := True;
                  Out_Value := To_Unbounded_String ("1");
               elsif To_String (C.Value) = "0" then
                  Bool := False;
                  Out_Value := To_Unbounded_String ("0");
               else
                  Bad := True;
               end if;

               if Bad then
                  Fail_With (["METADATA", "VALUE_INVALID", "Invalid value"]);
               else
                  if Key = Pinned_Key then
                     Info.Pinned := Bool;
                  elsif Key = Muted_Key then
                     Info.Muted := Bool;
                  else
                     Info.Blocked := Bool;
                  end if;

                  declare
                     Msg : Message := Make
                       (Soja.Irc.Numerics.RPL_KEYVALUE,
                        ["*", Target, Key, "*", To_String (Out_Value)]);
                  begin
                     if Batch_Ref /= "" then
                        Set_Tag (Msg.Tags, "batch", Batch_Ref);
                     end if;
                     Send_Message (DC, Msg);
                  end;

                  for Other of DC.Network.User.Downstream_Conns loop
                     if Other.Network = DC.Network then
                        Send_Message
                          (Other, Make ("METADATA",
                                        [Target, Key, "*",
                                         To_String (Out_Value)]));
                     end if;
                  end loop;
               end if;
            end if;
         end;
      end loop;
   end Set_Target_Metadata;

   -----------------------
   -- Handle_Registered --
   -----------------------

   function Handle_Registered
     (DC : not null Downstream_Conn_Access; M : Message)
      return Irc_Error_Result
   is
      PR : constant Params_Result := Parse_Message_Params (M, 2);
   begin
      if not PR.Ok then
         return (Failed => True, Is_IRC => True, Err => PR.Err,
                 Text => Null_Unbounded_String);
      end if;

      declare
         Target  : constant String := Param (M, 0);
         Sub     : constant String := Param (M, 1);
         Handled : Boolean;
         R       : constant Irc_Error_Result := Handle_Sub (DC, M, Handled);
      begin
         if Handled then
            return R;
         end if;

         declare
            Has_Info : constant Boolean :=
              DC.Network /= null and then Target /= "*";
            Info     : Soja.Database.Message_Target_Info;
         begin
            if Has_Info then
               begin
                  Info := Soja.Database.Get_Message_Target
                    (Soja.Server.DB (DC.Srv.all).all,
                     DC.Network.Network_Record.ID,
                     Soja.Irc.Case_Mapping.Fold (DC.Network.Casemap, Target));
               exception
                  when E : Soja.Database.Database_Error =>
                     DC.Logger.Print
                       ("failed to get the message target for "
                        & Quote (Target) & ": "
                        & Ada.Exceptions.Exception_Message (E));
                     return Internal_Error (Target);
               end;
            end if;

            if Sub = "LIST" or else Sub = "GET" then
               declare
                  procedure Process (Batch_Ref : String) is
                     procedure Reply (Key : String) is
                        Msg : Message := Make
                          (Soja.Irc.Numerics.RPL_KEYVALUE,
                           ["*", Target, Key, "*", Value_Of (Info, Key)]);
                     begin
                        Set_Tag (Msg.Tags, "batch", Batch_Ref);
                        Send_Message (DC, Msg);
                     end Reply;
                  begin
                     if Sub = "LIST" then
                        if Has_Info then
                           for K of Keys loop
                              Reply (K.all);
                           end loop;
                        end if;
                     else
                        for I in 2 .. Natural (M.Params.Length) - 1 loop
                           declare
                              Key : constant String := Lower (Param (M, I));
                           begin
                              if Has_Info
                                and then Key in "soju.im/pinned"
                                                | "soju.im/muted"
                                                | "soju.im/blocked"
                              then
                                 Reply (Key);
                              else
                                 Send_Fail
                                   (DC, Batch_Ref,
                                    ["METADATA", "KEY_INVALID", Key,
                                     "Invalid key"]);
                              end if;
                           end;
                        end loop;
                     end if;
                  end Process;
               begin
                  Send_Batch (DC, "metadata", String_Vectors.Empty_Vector,
                              Process'Access);
               end;
               return Success;

            elsif Sub = "SET" or else Sub = "CLEAR" then
               declare
                  Changes : Key_Value_Vectors.Vector;
               begin
                  if Sub = "SET" then
                     declare
                        PR3 : constant Params_Result :=
                          Parse_Message_Params (M, 3);
                     begin
                        if not PR3.Ok then
                           return (Failed => True, Is_IRC => True,
                                   Err => PR3.Err,
                                   Text => Null_Unbounded_String);
                        end if;
                     end;
                     Changes.Append
                       (Key_Value'
                          (Key       => To_Unbounded_String
                                          (Lower (Param (M, 2))),
                           Has_Value => M.Params.Length > 3,
                           Value     => To_Unbounded_String
                                          (if M.Params.Length > 3
                                           then Param (M, 3) else "")));
                     Set_Target_Metadata
                       (DC, Target, Has_Info, Info, Changes, "");
                  else
                     for K of Keys loop
                        Changes.Append
                          (Key_Value'(Key => To_Unbounded_String (K.all),
                                      others => <>));
                     end loop;
                     declare
                        procedure Process (Batch_Ref : String) is
                        begin
                           Set_Target_Metadata
                             (DC, Target, Has_Info, Info, Changes, Batch_Ref);
                        end Process;
                     begin
                        Send_Batch (DC, "metadata",
                                    String_Vectors.Empty_Vector,
                                    Process'Access);
                     end;
                  end if;
               end;

               if Has_Info then
                  begin
                     Soja.Database.Store_Message_Target
                       (Soja.Server.DB (DC.Srv.all).all,
                        DC.Network.Network_Record.ID, Info);
                  exception
                     when E : Soja.Database.Database_Error =>
                        DC.Logger.Print
                          ("failed to store the message target for "
                           & Quote (Target) & ": "
                           & Ada.Exceptions.Exception_Message (E));
                        return Internal_Error (Target);
                  end;
               end if;
               return Success;
            end if;
         end;
      end;
      --  TODO (Go): support SYNC
      return IRC_Fail
        ("FAIL", ["METADATA", "INVALID_PARAMS", Param (M, 1),
                  "Unknown command"]);
   end Handle_Registered;

end Soja.Core.Metadata;
