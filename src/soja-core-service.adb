pragma Ada_2022;

with Ada.Characters.Handling;
with Ada.Containers.Generic_Array_Sort;
with Ada.Containers.Vectors;
with Ada.Exceptions;
with Ada.Streams;
with Ada.Strings.Fixed;

with CryptoLib.Hashes;

with Soja.Core.Downstream_Helpers;
with Soja.Core.Network_Ops;
with Soja.Core.Upstream_Dispatch;
with Soja.Core.User_Ops;
with Soja.Flags;
with Soja.Irc.Genmsg;
with Soja.Irc.Helpers;
with Soja.Irc.Messages;       use Soja.Irc.Messages;
with Soja.Service_Words;

package body Soja.Core.Service is

   use type Ada.Containers.Count_Type;
   use type Soja.Database.Message_Filter;

   function Quote (S : String) return String renames Soja.Irc.Helpers.Quote;

   procedure Fail (Text : String) with No_Return;
   procedure Fail (Text : String) is
   begin
      raise Service_Error with Text;
   end Fail;

   procedure Say (Ctx : Service_Context; Text : String) is
   begin
      Ctx.Output.Print (Text);
   end Say;

   function Join (V : String_Vector; Sep : String) return String is
      R : Unbounded_String;
   begin
      for I in 1 .. Natural (V.Length) loop
         if I > 1 then
            Append (R, Sep);
         end if;
         Append (R, V (I));
      end loop;
      return To_String (R);
   end Join;

   --  Params (From ..): the rest of a word list.
   function Tail (V : String_Vector; From : Positive) return String_Vector is
      R : String_Vector;
   begin
      for I in From .. Natural (V.Length) loop
         R.Append (V (I));
      end loop;
      return R;
   end Tail;

   function Starts_With (S, Prefix : String) return Boolean is
     (S'Length >= Prefix'Length
      and then S (S'First .. S'First + Prefix'Length - 1) = Prefix);

   function Net_Name (Net : not null Network_Access) return String is
     (Soja.Database.Get_Name (Net.Network_Record));

   function DB_Of (Ctx : Service_Context) return Soja.Database.Database_Access
   is (Soja.Server.DB (Ctx.Srv.all));

   ----------------------------------------------------------------------
   --  The command tree
   ----------------------------------------------------------------------

   type Handler is access procedure
     (Ctx : Service_Context; Params : String_Vector);

   type Node is record
      Name   : Unbounded_String;
      Usage  : Unbounded_String;
      Desc   : Unbounded_String;
      Run    : Handler;
      Admin  : Boolean := False;
      Global : Boolean := False;
      Parent : Natural := 0;       --  0: a top-level command
   end record;

   package Node_Vectors is new Ada.Containers.Vectors (Positive, Node);
   Nodes : Node_Vectors.Vector;

   function Add
     (Parent : Natural; Name : String; Usage, Desc : String := "";
      Run    : Handler := null; Admin, Global : Boolean := False)
      return Natural is
   begin
      Nodes.Append
        (Node'(Name => To_Unbounded_String (Name),
          Usage => To_Unbounded_String (Usage),
          Desc => To_Unbounded_String (Desc),
          Run => Run, Admin => Admin, Global => Global, Parent => Parent));
      return Natural (Nodes.Length);
   end Add;

   function Has_Children (Index : Natural) return Boolean is
   begin
      for N of Nodes loop
         if N.Parent = Index then
            return True;
         end if;
      end loop;
      return False;
   end Has_Children;

   --  The children of Parent, sorted by name (serviceCommandSet.Names).
   function Names (Parent : Natural) return String_Vector is
      Items : array (1 .. Natural (Nodes.Length)) of Natural;
      Last  : Natural := 0;
      R     : String_Vector;

      function Name_Of (I : Natural) return String is
        (To_String (Nodes (I).Name));
      procedure Swap (A, B : in out Natural) is
         T : constant Natural := A;
      begin
         A := B;
         B := T;
      end Swap;
   begin
      for I in 1 .. Natural (Nodes.Length) loop
         if Nodes (I).Parent = Parent then
            Last := Last + 1;
            Items (Last) := I;
         end if;
      end loop;
      for I in 1 .. Last loop
         for J in I + 1 .. Last loop
            if Name_Of (Items (J)) < Name_Of (Items (I)) then
               Swap (Items (I), Items (J));
            end if;
         end loop;
      end loop;
      for I in 1 .. Last loop
         R.Append (Name_Of (Items (I)));
      end loop;
      return R;
   end Names;

   function Child (Parent : Natural; Name : String) return Natural is
   begin
      for I in 1 .. Natural (Nodes.Length) loop
         if Nodes (I).Parent = Parent and then To_String (Nodes (I).Name) = Name
         then
            return I;
         end if;
      end loop;
      return 0;
   end Child;

   --  serviceCommandSet.Get: walk Words (From ..) down the tree.  Index is
   --  the command, Next the first word that is not part of its name.
   procedure Get
     (Parent : Natural; Words : String_Vector; From : Positive;
      Index : out Natural; Next : out Positive)
   is
   begin
      if From > Natural (Words.Length) then
         Fail ("no command specified");
      end if;

      declare
         Name  : constant String := Words (From);
         Found : Natural := Child (Parent, Name);
      begin
         if Found = 0 then
            for K of Names (Parent) loop
               if Starts_With (K, Name) then
                  if Found /= 0 then
                     Fail ("command " & Quote (Name) & " is ambiguous");
                  end if;
                  Found := Child (Parent, K);
               end if;
            end loop;
         end if;
         if Found = 0 then
            Fail ("command " & Quote (Name) & " not found");
         end if;

         if From = Natural (Words.Length) or else not Has_Children (Found) then
            Index := Found;
            Next := From + 1;
         else
            Get (Found, Words, From + 1, Index, Next);
         end if;
      end;
   end Get;

   --  appendServiceCommandSetHelp.
   procedure Help_Lines
     (Parent : Natural; Prefix : String_Vector; Admin, Global : Boolean;
      Into   : in out String_Vector)
   is
   begin
      for Name of Names (Parent) loop
         declare
            Index : constant Natural := Child (Parent, Name);
            N     : Node renames Nodes (Index);
            Words : String_Vector := Prefix;
         begin
            if (not N.Admin or else Admin) and then (N.Global or else not Global)
            then
               Words.Append (Name);
               if not Has_Children (Index) then
                  Into.Append (Join (Words, " "));
               else
                  Help_Lines (Index, Words, Admin, Global, Into);
               end if;
            end if;
         end;
      end loop;
   end Help_Lines;

   procedure Say_Available
     (Ctx : Service_Context; Parent : Natural; Prefix : String_Vector)
   is
      L : String_Vector;
   begin
      Help_Lines (Parent, Prefix, Ctx.Admin, Ctx.User = null, L);
      Say (Ctx, "available commands: " & Join (L, ", "));
   end Say_Available;

   procedure Handle_Help (Ctx : Service_Context; Params : String_Vector) is
   begin
      if Params.Length > 0 then
         declare
            Index : Natural;
            Next  : Positive;
         begin
            Get (0, Params, 1, Index, Next);
            declare
               Words : constant String_Vector := Params;
               Used  : String_Vector;
               N     : Node renames Nodes (Index);
            begin
               for I in 1 .. Next - 1 loop
                  Used.Append (Words (I));
               end loop;
               if Has_Children (Index) then
                  Say_Available (Ctx, Index, Used);
               else
                  declare
                     Text : Unbounded_String :=
                       To_Unbounded_String (Join (Used, " "));
                  begin
                     if Length (N.Usage) > 0 then
                        Append (Text, " " & To_String (N.Usage));
                     end if;
                     Append (Text, ": " & To_String (N.Desc));
                     Say (Ctx, To_String (Text));
                  end;
               end if;
            end;
         end;
      else
         Say_Available (Ctx, 0, String_Vector'(Soja.Irc.Genmsg.String_Vectors.Empty_Vector));
      end if;
   end Handle_Help;

   ----------------------------------------------------------------------
   --  Flag helpers
   ----------------------------------------------------------------------

   --  fs.Parse, with its error returned as the command's error.
   procedure Parse_Flags
     (FS : in out Soja.Flags.Flag_Set; Params : String_Vector) is
   begin
      Soja.Flags.Parse (FS, Params);
   exception
      when E : Soja.Flags.Flag_Error =>
         Fail (Ada.Exceptions.Exception_Message (E));
   end Parse_Flags;

   procedure No_Extra_Args (FS : Soja.Flags.Flag_Set) is
   begin
      if Soja.Flags.N_Arg (FS) > 0 then
         Fail ("unexpected argument: " & Soja.Flags.Arg (FS, 0));
      end if;
   end No_Extra_Args;

   --  popArg: a leading word that is not a flag.
   procedure Pop_Arg
     (Params : String_Vector; Name : out Unbounded_String;
      Rest   : out String_Vector) is
   begin
      if Params.Length > 0 and then not Starts_With (Params (1), "-") then
         Name := To_Unbounded_String (Params (1));
         Rest := Tail (Params, 2);
      else
         Name := Null_Unbounded_String;
         Rest := Params;
      end if;
   end Pop_Arg;

   function Network_From_Arg
     (Ctx : Service_Context; Name : String) return Network_Access is
   begin
      if Name = "" then
         if Ctx.Network = null then
            Fail ("no network selected, a name argument is required");
         end if;
         return Ctx.Network;
      end if;
      declare
         Net : constant Network_Access := Get_Network (Ctx.User, Name);
      begin
         if Net = null then
            Fail ("unknown network " & Quote (Name));
         end if;
         return Net;
      end;
   end Network_From_Arg;

   function Network_From_Flag
     (Ctx : Service_Context; Name : String) return Network_Access is
   begin
      if Name = "" then
         if Ctx.Network = null then
            Fail ("no network selected, -network is required");
         end if;
         return Ctx.Network;
      end if;
      declare
         Net : constant Network_Access := Get_Network (Ctx.User, Name);
      begin
         if Net = null then
            Fail ("unknown network " & Quote (Name));
         end if;
         return Net;
      end;
   end Network_From_Flag;

   ----------------------------------------------------------------------
   --  network
   ----------------------------------------------------------------------

   function New_Network_Flags return Soja.Flags.Flag_Set is
      FS : Soja.Flags.Flag_Set;
   begin
      FS.Add_String ("addr");
      FS.Add_String ("name");
      FS.Add_String ("nick");
      FS.Add_String ("username");
      FS.Add_String ("pass");
      FS.Add_String ("realname");
      FS.Add_String ("certfp");
      FS.Add_Bool_Value ("auto-away");
      FS.Add_Bool_Value ("enabled");
      FS.Add_List ("connect-command");
      return FS;
   end New_Network_Flags;

   function Is_Hex (S : String) return Boolean is
   begin
      if S'Length mod 2 /= 0 then
         return False;
      end if;
      for C of S loop
         if C not in '0' .. '9' | 'a' .. 'f' | 'A' .. 'F' then
            return False;
         end if;
      end loop;
      return True;
   end Is_Hex;

   --  networkFlagSet.update: apply the flags that were given to Rec.
   procedure Update_Network_From_Flags
     (FS : Soja.Flags.Flag_Set; Rec : in out Soja.Database.Network)
   is
      use Soja.Flags;
   begin
      if Is_Set (FS, "addr") then
         declare
            Addr : constant String := Get (FS, "addr");
            Sep  : constant Natural := Ada.Strings.Fixed.Index (Addr, "://");
         begin
            if Sep > 0 then
               declare
                  Scheme : constant String := Addr (Addr'First .. Sep - 1);
               begin
                  if Scheme /= "ircs" and then Scheme /= "irc+insecure"
                    and then Scheme /= "unix"
                  then
                     Fail ("unknown scheme " & Quote (Scheme)
                           & " (supported schemes: ircs, irc+insecure, unix)");
                  end if;
               end;
            end if;
            Rec.Addr := To_Unbounded_String (Addr);
         end;
      end if;
      if Is_Set (FS, "name") then
         if Get (FS, "name") = "*" then
            Fail ("the network name " & Quote ("*")
                  & " is reserved for multi-upstream mode");
         end if;
         Rec.Name := To_Unbounded_String (Get (FS, "name"));
      end if;
      if Is_Set (FS, "nick") then
         Rec.Nick := To_Unbounded_String (Get (FS, "nick"));
      end if;
      if Is_Set (FS, "username") then
         Rec.Username := To_Unbounded_String (Get (FS, "username"));
      end if;
      if Is_Set (FS, "pass") then
         Rec.Pass := To_Unbounded_String (Get (FS, "pass"));
      end if;
      if Is_Set (FS, "realname") then
         Rec.Realname := To_Unbounded_String (Get (FS, "realname"));
      end if;
      if Is_Set (FS, "certfp") then
         declare
            Raw : constant String := Get (FS, "certfp");
            FP  : Unbounded_String;
         begin
            for C of Raw loop
               if C /= ':' then
                  Append (FP, Ada.Characters.Handling.To_Lower (C));
               end if;
            end loop;
            if not Is_Hex (To_String (FP)) then
               Fail ("the certificate fingerprint must be hex-encoded");
            end if;
            if Length (FP) = 0 then
               Rec.Cert_FP := Null_Unbounded_String;
            elsif Length (FP) = 64 then
               Rec.Cert_FP := To_Unbounded_String ("sha-256:") & FP;
            elsif Length (FP) = 128 then
               Rec.Cert_FP := To_Unbounded_String ("sha-512:") & FP;
            else
               Fail ("the certificate fingerprint must be a SHA256 or SHA512 "
                     & "hash");
            end if;
         end;
      end if;
      if Is_Set (FS, "auto-away") then
         Rec.Auto_Away := Get_Bool (FS, "auto-away");
      end if;
      if Is_Set (FS, "enabled") then
         Rec.Enabled := Get_Bool (FS, "enabled");
      end if;
      if Is_Set (FS, "connect-command") then
         declare
            Commands : constant String_Vector := Get_List (FS, "connect-command");
         begin
            if Commands.Length = 1 and then Commands (1) = "" then
               Rec.Connect_Commands.Clear;
            else
               if Commands.Length > 20 then
                  Fail ("too many -connect-command flags supplied");
               end if;
               for Command of Commands loop
                  declare
                     Parsed : Message;
                     pragma Unreferenced (Parsed);
                  begin
                     Parsed := Parse_Message (Command);
                  exception
                     when E : others =>
                        Fail ("flag -connect-command must be a valid raw irc "
                              & "command string: " & Quote (Command) & ": "
                              & Ada.Exceptions.Exception_Message (E));
                  end;
               end loop;
               Rec.Connect_Commands.Clear;
               for Command of Commands loop
                  Rec.Connect_Commands.Append (To_Unbounded_String (Command));
               end loop;
            end if;
         end;
      end if;
   end Update_Network_From_Flags;

   procedure Handle_Network_Create
     (Ctx : Service_Context; Params : String_Vector)
   is
      FS : Soja.Flags.Flag_Set := New_Network_Flags;
   begin
      Parse_Flags (FS, Params);
      No_Extra_Args (FS);
      if not FS.Is_Set ("addr") then
         Fail ("flag -addr is required");
      end if;

      declare
         Rec : Soja.Database.Network := Soja.Database.New_Network (FS.Get ("addr"));
      begin
         Update_Network_From_Flags (FS, Rec);
         declare
            Net : constant Network_Access :=
              Soja.Core.User_Ops.Create_Network (Ctx.User, Rec);
         begin
            Say (Ctx, "created network " & Quote (Net_Name (Net)));
         end;
      exception
         when E : Soja.Core.User_Ops.Operation_Error =>
            Fail ("could not create network: "
                  & Ada.Exceptions.Exception_Message (E));
      end;
   end Handle_Network_Create;

   procedure Handle_Network_Status
     (Ctx : Service_Context; Params : String_Vector)
   is
      N : Natural := 0;
   begin
      if Params.Length /= 0 then
         Fail ("expected no argument");
      end if;

      for Net of Ctx.User.Networks loop
         declare
            Statuses : String_Vector;
            Details  : Unbounded_String;
            UC       : constant Upstream_Conn_Access := Net.Conn;
            Name     : Unbounded_String := To_Unbounded_String (Net_Name (Net));
         begin
            if UC /= null then
               if Length (Ctx.Nick) > 0 and then Ctx.Nick /= UC.Nick then
                  Statuses.Append ("connected as " & To_String (UC.Nick));
               else
                  Statuses.Append ("connected");
               end if;
               Details := To_Unbounded_String
                 (Natural'Image (UC.Channels.Length) (2 ..
                    Natural'Image (UC.Channels.Length)'Last) & " channels");
            elsif not Net.Network_Record.Enabled then
               Statuses.Append ("disabled");
            else
               Statuses.Append ("disconnected");
               if Net.Has_Last_Error then
                  Details := Net.Last_Error;
               end if;
            end if;

            if Net = Ctx.Network then
               Statuses.Append ("current");
            end if;

            if To_String (Name) /= To_String (Net.Network_Record.Addr) then
               Name := To_Unbounded_String
                 (To_String (Name) & " ("
                  & To_String (Net.Network_Record.Addr) & ")");
            end if;

            declare
               Line : Unbounded_String :=
                 To_Unbounded_String (To_String (Name) & " ["
                                      & Join (Statuses, ", ") & "]");
            begin
               if Length (Details) > 0 then
                  Append (Line, ": " & To_String (Details));
               end if;
               Say (Ctx, To_String (Line));
            end;
            N := N + 1;
         end;
      end loop;

      if N = 0 then
         Say (Ctx, "No network configured, add one with ""network create"".");
      end if;
   end Handle_Network_Status;

   procedure Handle_Network_Update
     (Ctx : Service_Context; Params : String_Vector)
   is
      Name : Unbounded_String;
      Rest : String_Vector;
   begin
      Pop_Arg (Params, Name, Rest);
      declare
         Net : constant Network_Access :=
           Network_From_Arg (Ctx, To_String (Name));
         FS  : Soja.Flags.Flag_Set := New_Network_Flags;
         Rec : Soja.Database.Network := Net.Network_Record;
      begin
         Parse_Flags (FS, Rest);
         No_Extra_Args (FS);
         Update_Network_From_Flags (FS, Rec);
         declare
            Updated : constant Network_Access :=
              Soja.Core.User_Ops.Update_Network (Ctx.User, Rec);
         begin
            Say (Ctx, "updated network " & Quote (Net_Name (Updated)));
         end;
      exception
         when E : Soja.Core.User_Ops.Operation_Error =>
            Fail ("could not update network: "
                  & Ada.Exceptions.Exception_Message (E));
      end;
   end Handle_Network_Update;

   procedure Handle_Network_Delete
     (Ctx : Service_Context; Params : String_Vector) is
   begin
      if Params.Length /= 1 then
         Fail ("expected exactly one argument");
      end if;
      --  (Go reads a flag-like word as "no name" and deletes the current
      --  network; refused here, SOJU-BUGS.md.)
      if Starts_With (Params (1), "-") then
         Fail ("unexpected argument: " & Params (1));
      end if;
      declare
         Net  : constant Network_Access := Network_From_Arg (Ctx, Params (1));
         Name : constant String := Net_Name (Net);
      begin
         Soja.Core.User_Ops.Delete_Network (Ctx.User, Net.Network_Record.ID);
         Say (Ctx, "deleted network " & Quote (Name));
      exception
         when E : Soja.Core.User_Ops.Operation_Error =>
            Fail (Ada.Exceptions.Exception_Message (E));
      end;
   end Handle_Network_Delete;

   procedure Handle_Network_Quote
     (Ctx : Service_Context; Params : String_Vector) is
   begin
      if Params.Length /= 1 and then Params.Length /= 2 then
         Fail ("expected one or two arguments");
      end if;

      declare
         Raw  : constant String := Params (Natural (Params.Length));
         Name : constant String :=
           (if Params.Length = 2 then Params (1) else "");
         Net  : constant Network_Access := Network_From_Arg (Ctx, Name);
         UC   : constant Upstream_Conn_Access := Net.Conn;
      begin
         if UC = null then
            Fail ("network " & Quote (Net_Name (Net))
                  & " is not currently connected");
         end if;
         declare
            M : Message;
         begin
            M := Parse_Message (Raw);
            Send_Message (UC, M);
         exception
            when E : Soja.Irc.Messages.Parse_Error =>
               Fail ("failed to parse command " & Quote (Raw) & ": "
                     & Ada.Exceptions.Exception_Message (E));
         end;
         Say (Ctx, "sent command to " & Quote (Net_Name (Net)));
      end;
   end Handle_Network_Quote;

   ----------------------------------------------------------------------
   --  certfp, sasl
   ----------------------------------------------------------------------

   function Hex_Of (Data : Ada.Streams.Stream_Element_Array) return String is
      Digits_Of : constant String := "0123456789abcdef";
      R : String (1 .. Data'Length * 2);
      J : Positive := 1;
   begin
      for B of Data loop
         R (J) := Digits_Of (Natural (B) / 16 + 1);
         R (J + 1) := Digits_Of (Natural (B) mod 16 + 1);
         J := J + 2;
      end loop;
      return R;
   end Hex_Of;

   function To_Bytes (S : String) return Ada.Streams.Stream_Element_Array is
      use Ada.Streams;
      R : Stream_Element_Array (1 .. Stream_Element_Offset (S'Length));
   begin
      for I in S'Range loop
         R (Stream_Element_Offset (I - S'First + 1)) :=
           Stream_Element (Character'Pos (S (I)));
      end loop;
      return R;
   end To_Bytes;

   function Digest_Hex (D : CryptoLib.Hashes.SHA1_Digest) return String is
      B : Ada.Streams.Stream_Element_Array (1 .. D'Length);
   begin
      for I in D'Range loop
         B (Ada.Streams.Stream_Element_Offset (I)) := D (I);
      end loop;
      return Hex_Of (B);
   end Digest_Hex;

   function Digest_Hex (D : CryptoLib.Hashes.SHA256_Digest) return String is
      B : Ada.Streams.Stream_Element_Array (1 .. D'Length);
   begin
      for I in D'Range loop
         B (Ada.Streams.Stream_Element_Offset (I)) := D (I);
      end loop;
      return Hex_Of (B);
   end Digest_Hex;

   function Digest_Hex (D : CryptoLib.Hashes.SHA512_Digest) return String is
      B : Ada.Streams.Stream_Element_Array (1 .. D'Length);
   begin
      for I in D'Range loop
         B (Ada.Streams.Stream_Element_Offset (I)) := D (I);
      end loop;
      return Hex_Of (B);
   end Digest_Hex;

   --  sendCertfpFingerprints.
   procedure Say_Fingerprints (Ctx : Service_Context; Cert : String) is
      Bytes : constant Ada.Streams.Stream_Element_Array := To_Bytes (Cert);
   begin
      Say (Ctx, "SHA-1 fingerprint: "
           & Digest_Hex (CryptoLib.Hashes.SHA1 (Bytes)));
      Say (Ctx, "SHA-256 fingerprint: "
           & Digest_Hex (CryptoLib.Hashes.SHA256 (Bytes)));
      Say (Ctx, "SHA-512 fingerprint: "
           & Digest_Hex (CryptoLib.Hashes.SHA512 (Bytes)));
   end Say_Fingerprints;

   function Network_Flag_Set return Soja.Flags.Flag_Set is
      FS : Soja.Flags.Flag_Set;
   begin
      FS.Add_String ("network");
      return FS;
   end Network_Flag_Set;

   procedure Handle_Certfp_Generate
     (Ctx : Service_Context; Params : String_Vector)
   is
      FS : Soja.Flags.Flag_Set := Network_Flag_Set;
   begin
      FS.Add_String ("key-type", "rsa");
      FS.Add_Int ("bits", 3072);
      Parse_Flags (FS, Params);
      No_Extra_Args (FS);
      if FS.Get_Int ("bits") <= 0 or else FS.Get_Int ("bits") > 8192 then
         Fail ("invalid value for -bits");
      end if;
      declare
         Net : constant Network_Access :=
           Network_From_Flag (Ctx, FS.Get ("network"));
         pragma Unreferenced (Net);
      begin
         --  Needs X.509 certificate creation; see PORTING.md (Milestone B).
         Fail ("generating certificates is not supported by this build yet");
      end;
   end Handle_Certfp_Generate;

   procedure Handle_Certfp_Fingerprints
     (Ctx : Service_Context; Params : String_Vector)
   is
      FS : Soja.Flags.Flag_Set := Network_Flag_Set;
   begin
      Parse_Flags (FS, Params);
      No_Extra_Args (FS);
      declare
         Net : constant Network_Access :=
           Network_From_Flag (Ctx, FS.Get ("network"));
      begin
         if To_String (Net.Network_Record.SASL.Mechanism) /= "EXTERNAL" then
            Fail ("CertFP not set up");
         end if;
         Say_Fingerprints (Ctx, To_String (Net.Network_Record.SASL.External_Cert));
      end;
   end Handle_Certfp_Fingerprints;

   procedure Handle_Sasl_Status
     (Ctx : Service_Context; Params : String_Vector)
   is
      FS : Soja.Flags.Flag_Set := Network_Flag_Set;
   begin
      Parse_Flags (FS, Params);
      No_Extra_Args (FS);
      declare
         Net  : constant Network_Access :=
           Network_From_Flag (Ctx, FS.Get ("network"));
         Mech : constant String := To_String (Net.Network_Record.SASL.Mechanism);
         UC   : constant Upstream_Conn_Access := Net.Conn;
      begin
         if Mech = "PLAIN" then
            Say (Ctx, "SASL PLAIN enabled with username "
                 & Quote (To_String (Net.Network_Record.SASL.Plain_Username)));
         elsif Mech = "EXTERNAL" then
            Say (Ctx, "SASL EXTERNAL (CertFP) enabled");
         elsif Mech = "" then
            Say (Ctx, "SASL is disabled");
         end if;

         if UC /= null then
            if Length (UC.Account) > 0 then
               Say (Ctx, "Authenticated on upstream network with account "
                    & Quote (To_String (UC.Account)));
            else
               Say (Ctx, "Unauthenticated on upstream network");
            end if;
         else
            Say (Ctx, "Disconnected from upstream network");
         end if;
      end;
   end Handle_Sasl_Status;

   procedure Store_Network_Record
     (Ctx : Service_Context; Net : not null Network_Access) is
   begin
      Soja.Database.Store_Network
        (DB_Of (Ctx).all, Ctx.User.User_Record.ID, Net.Network_Record);
   exception
      when E : others =>
         Fail (Ada.Exceptions.Exception_Message (E));
   end Store_Network_Record;

   procedure Handle_Sasl_Set_Plain
     (Ctx : Service_Context; Params : String_Vector)
   is
      FS : Soja.Flags.Flag_Set := Network_Flag_Set;
   begin
      Parse_Flags (FS, Params);
      if FS.N_Arg /= 2 then
         Fail ("expected exactly 2 arguments");
      end if;
      declare
         Net : constant Network_Access :=
           Network_From_Flag (Ctx, FS.Get ("network"));
      begin
         Net.Network_Record.SASL.Plain_Username :=
           To_Unbounded_String (FS.Arg (0));
         Net.Network_Record.SASL.Plain_Password :=
           To_Unbounded_String (FS.Arg (1));
         Net.Network_Record.SASL.Mechanism := To_Unbounded_String ("PLAIN");
         Store_Network_Record (Ctx, Net);
         Say (Ctx, "credentials saved");
      end;
   end Handle_Sasl_Set_Plain;

   procedure Handle_Sasl_Reset
     (Ctx : Service_Context; Params : String_Vector)
   is
      FS : Soja.Flags.Flag_Set := Network_Flag_Set;
   begin
      Parse_Flags (FS, Params);
      No_Extra_Args (FS);
      declare
         Net : constant Network_Access :=
           Network_From_Flag (Ctx, FS.Get ("network"));
      begin
         Net.Network_Record.SASL.Plain_Username := Null_Unbounded_String;
         Net.Network_Record.SASL.Plain_Password := Null_Unbounded_String;
         Net.Network_Record.SASL.External_Cert := Null_Unbounded_String;
         Net.Network_Record.SASL.External_Key := Null_Unbounded_String;
         Net.Network_Record.SASL.Mechanism := Null_Unbounded_String;
         Store_Network_Record (Ctx, Net);
         Say (Ctx, "credentials reset");
      end;
   end Handle_Sasl_Reset;

   ----------------------------------------------------------------------
   --  channel
   ----------------------------------------------------------------------

   function Strip_Hashes (S : String) return String is
      R : Unbounded_String;
   begin
      for C of S loop
         if C /= '#' then
            Append (R, C);
         end if;
      end loop;
      return To_String (R);
   end Strip_Hashes;

   procedure Handle_Channel_Status
     (Ctx : Service_Context; Params : String_Vector)
   is
      Default_Name : constant String :=
        (if Ctx.Network /= null then Net_Name (Ctx.Network) else "");
      FS : Soja.Flags.Flag_Set;
      N  : Natural := 0;
   begin
      FS.Add_String ("network", Default_Name);
      Parse_Flags (FS, Params);
      No_Extra_Args (FS);

      declare
         Network_Name : constant String := FS.Get ("network");

         procedure Show (Net : not null Network_Access) is
            type Channel_Array is array (Positive range <>) of Channel_Access;
            Items : Channel_Array (1 .. Net.Channels.Length);
            Last  : Natural := 0;

            procedure Collect (Name : String; Ch : Channel_Access) is
               pragma Unreferenced (Name);
            begin
               Last := Last + 1;
               Items (Last) := Ch;
            end Collect;

            function Before (A, B : Channel_Access) return Boolean is
              (Strip_Hashes (To_String (A.Name))
               < Strip_Hashes (To_String (B.Name)));
            procedure Sort is new Ada.Containers.Generic_Array_Sort
              (Positive, Channel_Access, Channel_Array, Before);
         begin
            Net.Channels.For_Each (Collect'Access);
            Sort (Items (1 .. Last));

            for I in 1 .. Last loop
               declare
                  Ch  : constant Channel_Access := Items (I);
                  Uch : constant Upstream_Channel_Access :=
                    (if Net.Conn /= null
                     then Net.Conn.Channels.Get (To_String (Ch.Name))
                     else null);
                  Name   : Unbounded_String := Ch.Name;
                  Status : Unbounded_String;
               begin
                  if Network_Name = "" then
                     Append (Name, "/" & Net_Name (Net));
                  end if;
                  if Uch /= null then
                     Status := To_Unbounded_String ("joined");
                  elsif Net.Conn /= null then
                     Status := To_Unbounded_String ("parted");
                  else
                     Status := To_Unbounded_String ("disconnected");
                  end if;
                  if Ch.Detached then
                     Append (Status, ", detached");
                  end if;
                  Say (Ctx, To_String (Name) & " [" & To_String (Status) & "]");
                  N := N + 1;
               end;
            end loop;
         end Show;
      begin
         if Network_Name = "" then
            for Net of Ctx.User.Networks loop
               Show (Net);
            end loop;
         else
            declare
               Net : constant Network_Access :=
                 Get_Network (Ctx.User, Network_Name);
            begin
               if Net = null then
                  Fail ("unknown network " & Quote (Network_Name));
               end if;
               Show (Net);
            end;
         end if;
      end;

      if N = 0 then
         Say (Ctx, "No channel configured.");
      end if;
   end Handle_Channel_Status;

   function Parse_Filter (Filter : String) return Soja.Database.Message_Filter is
   begin
      if Filter = "default" then
         return Soja.Database.Filter_Default;
      elsif Filter = "none" then
         return Soja.Database.Filter_None;
      elsif Filter = "highlight" then
         return Soja.Database.Filter_Highlight;
      elsif Filter = "message" then
         return Soja.Database.Filter_Message;
      end if;
      Fail ("unknown filter: " & Quote (Filter));
   end Parse_Filter;

   --  stripNetworkSuffix: "#chan/network" when the client is on no network.
   procedure Strip_Network_Suffix
     (Ctx  : Service_Context; Name : in out Unbounded_String;
      Net  : out Network_Access)
   is
      Full  : constant String := To_String (Name);
      Slash : constant Natural := Ada.Strings.Fixed.Index (Full, "/");
   begin
      if Ctx.Network /= null then
         Net := Ctx.Network;
         return;
      end if;
      if Slash = 0 then
         Fail ("missing network name");
      end if;
      declare
         Net_Part : constant String := Full (Slash + 1 .. Full'Last);
      begin
         Name := To_Unbounded_String (Full (Full'First .. Slash - 1));
         for Candidate of Ctx.User.Networks loop
            if Net_Name (Candidate) = Net_Part then
               Net := Candidate;
               return;
            end if;
         end loop;
         Fail ("unknown network " & Quote (Net_Part));
      end;
   end Strip_Network_Suffix;

   procedure Handle_Channel_Update
     (Ctx : Service_Context; Params : String_Vector)
   is
      FS : Soja.Flags.Flag_Set;
      Net : Network_Access;
      Name : Unbounded_String;
   begin
      if Params.Length < 1 then
         Fail ("expected at least one argument");
      end if;
      Name := To_Unbounded_String (Params (1));

      FS.Add_Bool_Value ("detached");
      FS.Add_String ("relay-detached");
      FS.Add_String ("reattach-on");
      FS.Add_String ("detach-after");
      FS.Add_String ("detach-on");
      Parse_Flags (FS, Tail (Params, 2));
      No_Extra_Args (FS);

      Strip_Network_Suffix (Ctx, Name, Net);

      declare
         Ch : constant Channel_Access := Net.Channels.Get (To_String (Name));
      begin
         if Ch = null then
            Fail ("unknown channel " & Quote (To_String (Name)));
         end if;

         --  Work on a copy, so that a bad value leaves the channel as it was
         --  (Go changes the fields one by one, SOJU-BUGS.md).
         declare
            Rec : Soja.Database.Channel := Ch.all;
         begin
            if FS.Is_Set ("relay-detached") then
               Rec.Relay_Detached := Parse_Filter (FS.Get ("relay-detached"));
            end if;
            if FS.Is_Set ("reattach-on") then
               Rec.Reattach_On := Parse_Filter (FS.Get ("reattach-on"));
            end if;
            if FS.Is_Set ("detach-after") then
               declare
                  Dur : Duration;
                  Ok  : Boolean;
               begin
                  Soja.Irc.Helpers.Parse_Go_Duration
                    (FS.Get ("detach-after"), Dur, Ok);
                  if not Ok or else Dur < 0.0 then
                     Fail ("unknown duration for -detach-after "
                           & Quote (FS.Get ("detach-after"))
                           & " (duration format: 0, 300s, 22h30m, ...)");
                  end if;
                  Rec.Detach_After := Dur;
               end;
            end if;
            if FS.Is_Set ("detach-on") then
               Rec.Detach_On := Parse_Filter (FS.Get ("detach-on"));
            end if;
            Ch.all := Rec;
         end;

         if FS.Is_Set ("detached")
           and then FS.Get_Bool ("detached") /= Ch.Detached
         then
            if FS.Get_Bool ("detached") then
               Soja.Core.Network_Ops.Detach (Net, Ch);
            else
               Soja.Core.Network_Ops.Attach (Net, Ch);
            end if;
         end if;

         if Net.Conn /= null then
            Soja.Core.Upstream_Dispatch.Update_Channel_Auto_Detach
              (Net.Conn, To_String (Name));
         end if;

         declare
            Stored : Soja.Database.Channel := Ch.all;
         begin
            Soja.Database.Store_Channel
              (DB_Of (Ctx).all, Net.Network_Record.ID, Stored);
            Ch.ID := Stored.ID;
         exception
            when E : others =>
               Fail ("failed to update channel: "
                     & Ada.Exceptions.Exception_Message (E));
         end;
         Say (Ctx, "updated channel " & Quote (To_String (Name)));
      end;
   end Handle_Channel_Update;

   procedure Handle_Channel_Delete
     (Ctx : Service_Context; Params : String_Vector)
   is
      Net  : Network_Access;
      Name : Unbounded_String;
   begin
      if Params.Length /= 1 then
         Fail ("expected exactly one argument");
      end if;
      Name := To_Unbounded_String (Params (1));
      Strip_Network_Suffix (Ctx, Name, Net);

      begin
         Soja.Core.Network_Ops.Delete_Channel (Net, To_String (Name));
      exception
         when E : Soja.Core.User_Ops.Operation_Error =>
            Fail ("failed to delete channel: "
                  & Ada.Exceptions.Exception_Message (E));
      end;

      if Net.Conn /= null and then Net.Conn.Channels.Has (To_String (Name))
      then
         Send_Message
           (Net.Conn,
            Soja.Irc.Genmsg.Make ("PART", [To_String (Name)]));
      end if;
      Say (Ctx, "deleted channel " & Quote (To_String (Name)));
   end Handle_Channel_Delete;

   ----------------------------------------------------------------------
   --  user
   ----------------------------------------------------------------------

   procedure Handle_User_Status
     (Ctx : Service_Context; Params : String_Vector)
   is
      Limit : constant := 50;   --  avoid thousands of messages on big servers
      Shown : User_Vectors.Vector;
      N     : Natural;
   begin
      if Params.Length > 1 then
         Fail ("expected 0 or 1 argument");
      end if;

      if Params.Length = 0 then
         N := Users.Count;
         Shown := Users.Snapshot (Limit);
      else
         declare
            U : constant User_Access := Users.Find (Params (1));
         begin
            if U = null then
               Fail ("unknown username " & Quote (Params (1)));
            end if;
            Shown.Append (U);
            N := 1;
         end;
      end if;

      for U of Shown loop
         declare
            Rec   : constant Soja.Database.User := U.User_Record;
            Attrs : String_Vector;
            Line  : Unbounded_String := Rec.Username;
         begin
            if Rec.Admin then
               Attrs.Append ("admin");
            end if;
            if not Rec.Enabled then
               Attrs.Append ("disabled");
            end if;
            if Attrs.Length > 0 then
               Append (Line, " (" & Join (Attrs, ", ") & ")");
            end if;
            begin
               declare
                  Networks : constant Soja.Database.Network_Lists.Vector :=
                    Soja.Database.List_Networks (DB_Of (Ctx).all, Rec.ID);
               begin
                  Append
                    (Line, ":" & Natural'Image (Natural (Networks.Length))
                     & " networks");
               end;
            exception
               when E : others =>
                  Fail ("could not get networks of user "
                        & Quote (To_String (Rec.Username)) & ": "
                        & Ada.Exceptions.Exception_Message (E));
            end;
            Say (Ctx, To_String (Line));
         end;
      end loop;

      if N > Natural (Shown.Length) then
         Say (Ctx, "(" & Ada.Strings.Fixed.Trim
                           (Natural'Image (N - Natural (Shown.Length)),
                            Ada.Strings.Left)
              & " more users omitted)");
      end if;
   end Handle_User_Status;

   procedure Handle_User_Create
     (Ctx : Service_Context; Params : String_Vector)
   is
      FS : Soja.Flags.Flag_Set;
   begin
      FS.Add_String ("username");
      FS.Add_String ("password");
      FS.Add_Bool ("disable-password");
      FS.Add_String ("nick");
      FS.Add_String ("realname");
      FS.Add_Bool ("admin");
      FS.Add_Bool ("enabled", Default => True);
      Parse_Flags (FS, Params);
      No_Extra_Args (FS);
      if FS.Get ("username") = "" then
         Fail ("flag -username is required");
      end if;
      if FS.Get ("password") /= "" and then FS.Get_Bool ("disable-password") then
         Fail ("flags -password and -disable-password are mutually exclusive");
      end if;
      if FS.Get ("password") = "" and then not FS.Get_Bool ("disable-password")
      then
         Fail ("flag -password is required");
      end if;

      declare
         Rec : Soja.Database.User :=
           Soja.Database.New_User (FS.Get ("username"));
      begin
         Rec.Nick := To_Unbounded_String (FS.Get ("nick"));
         Rec.Realname := To_Unbounded_String (FS.Get ("realname"));
         Rec.Admin := FS.Get_Bool ("admin");
         Rec.Enabled := FS.Get_Bool ("enabled");
         if not FS.Get_Bool ("disable-password") then
            begin
               Soja.Database.Set_Password (Rec, FS.Get ("password"));
            exception
               when E : others =>
                  Fail (Ada.Exceptions.Exception_Message (E));
            end;
         end if;
         begin
            declare
               Created : constant User_Access := Users.Create (Rec);
               pragma Unreferenced (Created);
            begin
               null;
            end;
         exception
            when E : Service_Error =>
               Fail ("could not create user: "
                     & Ada.Exceptions.Exception_Message (E));
         end;
      end;
      Say (Ctx, "created user " & Quote (FS.Get ("username")));
   end Handle_User_Create;

   procedure Handle_User_Update
     (Ctx : Service_Context; Params : String_Vector)
   is
      Username : Unbounded_String;
      Rest     : String_Vector;
      FS       : Soja.Flags.Flag_Set;
   begin
      FS.Add_String ("password");
      FS.Add_Bool ("disable-password");
      FS.Add_String ("nick");
      FS.Add_String ("realname");
      FS.Add_Bool_Value ("admin");
      FS.Add_Bool_Value ("enabled");

      Pop_Arg (Params, Username, Rest);
      Parse_Flags (FS, Rest);
      No_Extra_Args (FS);
      if Length (Username) = 0 and then Ctx.User = null then
         Fail ("cannot determine the user to update");
      end if;
      if FS.Is_Set ("password") and then FS.Get_Bool ("disable-password") then
         Fail ("flags -password and -disable-password are mutually exclusive");
      end if;
      --  (Go accepts an empty password here, storing the hash of "".)
      if FS.Is_Set ("password") and then FS.Get ("password") = "" then
         Fail ("the password must not be empty (use -disable-password)");
      end if;

      if Length (Username) > 0
        and then (Ctx.User = null
                  or else To_String (Username)
                          /= To_String (Ctx.User.User_Record.Username))
      then
         if not Ctx.Admin then
            Fail ("you must be an admin to update other users");
         end if;
         if FS.Is_Set ("nick") then
            Fail ("cannot update -nick of other user");
         end if;
         if FS.Is_Set ("realname") then
            Fail ("cannot update -realname of other user");
         end if;

         if FS.Is_Set ("password") then
            --  Fail now, on this task, if the password cannot be hashed.
            declare
               Probe : Soja.Database.User := Soja.Database.New_User ("probe");
            begin
               Soja.Database.Set_Password (Probe, FS.Get ("password"));
            exception
               when E : others =>
                  Fail (Ada.Exceptions.Exception_Message (E));
            end;
         end if;

         declare
            Target : constant User_Access := Users.Find (To_String (Username));
         begin
            if Target = null then
               Fail ("unknown username " & Quote (To_String (Username)));
            end if;

            declare
               Result : constant Update_Result_Access := new Update_Result;
               Error  : Unbounded_String;
            begin
               Target.Events.Enqueue
                 (new User_Update_Event'
                    (Has_Password => FS.Is_Set ("password")
                                     or else FS.Get_Bool ("disable-password"),
                     Password     => To_Unbounded_String (FS.Get ("password")),
                     Has_Admin    => FS.Is_Set ("admin"),
                     Admin        => FS.Get_Bool ("admin"),
                     Has_Enabled  => FS.Is_Set ("enabled"),
                     Enabled      => FS.Get_Bool ("enabled"),
                     Result       => Result));
               select
                  Result.Wait (Error);
               or
                  delay 30.0;
                  Fail ("timeout executing command");
               end select;
               if Length (Error) > 0 then
                  Fail (To_String (Error));
               end if;
            end;
            Say (Ctx, "updated user " & Quote (To_String (Username)));
         end;

      else
         if FS.Is_Set ("admin") then
            Fail ("cannot update -admin of own user");
         end if;
         if FS.Is_Set ("enabled") then
            Fail ("cannot update -enabled of own user");
         end if;

         declare
            procedure Apply (Rec : in out Soja.Database.User) is
            begin
               if FS.Is_Set ("password") then
                  begin
                     Soja.Database.Set_Password (Rec, FS.Get ("password"));
                  exception
                     when E : others =>
                        raise Soja.Core.User_Ops.Operation_Error
                          with Ada.Exceptions.Exception_Message (E);
                  end;
               end if;
               if FS.Get_Bool ("disable-password") then
                  Rec.Password := Null_Unbounded_String;
               end if;
               if FS.Is_Set ("nick") then
                  Rec.Nick := To_Unbounded_String (FS.Get ("nick"));
               end if;
               if FS.Is_Set ("realname") then
                  Rec.Realname := To_Unbounded_String (FS.Get ("realname"));
               end if;
            end Apply;
         begin
            Soja.Core.User_Ops.Update_User (Ctx.User, Apply'Access);
         exception
            when E : Soja.Core.User_Ops.Operation_Error =>
               Fail (Ada.Exceptions.Exception_Message (E));
         end;
         Say (Ctx, "updated user "
              & Quote (To_String (Ctx.User.User_Record.Username)));
      end if;
   end Handle_User_Update;

   procedure Handle_User_Delete
     (Ctx : Service_Context; Params : String_Vector)
   is
   begin
      if Params.Length /= 1 and then Params.Length /= 2 then
         Fail ("expected one or two arguments");
      end if;

      declare
         Username : constant String := Params (1);
         Sum      : constant CryptoLib.Hashes.SHA1_Digest :=
           CryptoLib.Hashes.SHA1 (To_Bytes (Username));
         Hash     : constant String :=
           Digest_Hex (Sum) (1 .. 6);   --  the first three bytes
         Self     : constant Boolean :=
           Ctx.User /= null
           and then To_String (Ctx.User.User_Record.Username) = Username;
         Target   : User_Access;
      begin
         if not Ctx.Admin and then not Self then
            Fail ("only admins may delete other users");
         end if;

         Target := Users.Find (Username);
         if Target = null then
            Fail ("unknown username " & Quote (Username));
         end if;

         if Params.Length < 2 then
            Say (Ctx, "To confirm user deletion, send ""user delete "
                 & Username & " " & Hash & """");
            return;
         end if;
         if Params (2) /= Hash then
            Fail ("provided confirmation token doesn't match user");
         end if;

         if Self then
            --  We run on the user's own task, so we cannot wait for it to
            --  stop (Go does, and never returns, SOJU-BUGS.md): ask it to
            --  stop once this command is over; Run deletes the record then.
            Say (Ctx, "Goodbye " & Username & ", deleting your account. "
                 & "There will be no further confirmation.");
            declare
               Queued : Boolean;
            begin
               Target.Delete_On_Stop := True;
               Target.Events.Try_Enqueue (new Stop_Event, Queued);
               if not Queued then
                  Target.Delete_On_Stop := False;
                  Fail ("failed to stop user: too busy");
               end if;
            end;
         else
            if not Stop_User (Target) then
               Fail ("failed to stop user: timeout");
            end if;
            begin
               Soja.Database.Delete_User
                 (DB_Of (Ctx).all, Target.User_Record.ID);
            exception
               when E : others =>
                  Fail ("failed to delete user: "
                        & Ada.Exceptions.Exception_Message (E));
            end;
            Say (Ctx, "deleted user " & Quote (Username));
         end if;
      end;
   end Handle_User_Delete;

   procedure Handle_User_Run
     (Ctx : Service_Context; Params : String_Vector) is
   begin
      if Params.Length < 2 then
         Fail ("expected at least two arguments");
      end if;

      declare
         Username : constant String := Params (1);
         Words    : constant String_Vector := Tail (Params, 2);
      begin
         if Ctx.User /= null
           and then To_String (Ctx.User.User_Record.Username) = Username
         then
            Handle_Command (Ctx, Words);
            return;
         end if;

         declare
            Target : constant User_Access := Users.Find (Username);
         begin
            if Target = null then
               Fail ("unknown username " & Quote (Username));
            end if;

            declare
               Output : constant Run_Output_Access := new Run_Output;
            begin
               Target.Events.Enqueue
                 (new User_Run_Event'(Params => Words, Output => Output));
               loop
                  declare
                     Is_Line, Failed : Boolean;
                     Text            : Unbounded_String;
                  begin
                     select
                        Output.Next (Is_Line, Text, Failed);
                     or
                        delay 30.0;
                        Fail ("timeout executing command");
                     end select;
                     if Is_Line then
                        Say (Ctx, To_String (Text));
                     elsif Failed then
                        Fail (To_String (Text));
                     else
                        exit;
                     end if;
                  end;
               end loop;
            end;
         end;
      end;
   end Handle_User_Run;

   ----------------------------------------------------------------------
   --  server
   ----------------------------------------------------------------------

   function Img (N : Long_Long_Integer) return String is
     (Ada.Strings.Fixed.Trim (Long_Long_Integer'Image (N), Ada.Strings.Left));

   procedure Handle_Server_Status
     (Ctx : Service_Context; Params : String_Vector) is
   begin
      if Params.Length /= 0 then
         Fail ("expected no argument");
      end if;

      declare
         DB_Stats : Soja.Database.Database_Stats;
         Gauges   : constant Soja.Server.Server_Stats := Ctx.Srv.Stats;
      begin
         begin
            DB_Stats := Soja.Database.Stats (DB_Of (Ctx).all);
         exception
            when E : others =>
               Fail (Ada.Exceptions.Exception_Message (E));
         end;
         Say (Ctx, Img (Long_Long_Integer (Users.Count)) & "/"
              & Img (DB_Stats.Users) & " users, "
              & Img (Long_Long_Integer (Gauges.Downstreams))
              & " downstreams, "
              & Img (Long_Long_Integer (Gauges.Upstreams)) & " upstreams, "
              & Img (DB_Stats.Networks) & " networks, "
              & Img (DB_Stats.Channels) & " channels");
      end;
   end Handle_Server_Status;

   procedure Handle_Server_Notice
     (Ctx : Service_Context; Params : String_Vector) is
   begin
      if Params.Length /= 1 then
         Fail ("expected exactly one argument");
      end if;

      declare
         Text   : constant String := Params (1);
         Logger : constant Soja.Logging.Logger_Access :=
           (if Ctx.User /= null then Ctx.User.Logger
            else Soja.Server.Logger (Ctx.Srv.all));
         Msg    : Message := Soja.Irc.Genmsg.Make
           ("NOTICE",
            ["$" & To_String (Soja.Server.Config (Ctx.Srv.all).Hostname), Text]);
         Sent, Total : Natural;
      begin
         Logger.Print ("broadcasting bouncer-wide NOTICE: " & Text);
         Msg.Prefix := Soja.Core.Downstream_Helpers.Service_Prefix;
         Users.Broadcast (Msg, Sent, Total);
         Logger.Print
           ("broadcast bouncer-wide NOTICE to"
            & Natural'Image (Sent) & "/" & Ada.Strings.Fixed.Trim
                                             (Natural'Image (Total),
                                              Ada.Strings.Left)
            & " downstreams");
         Say (Ctx, "sent to "
              & Ada.Strings.Fixed.Trim (Natural'Image (Sent), Ada.Strings.Left)
              & "/" & Ada.Strings.Fixed.Trim
                        (Natural'Image (Total), Ada.Strings.Left)
              & " downstream connections");
      end;
   end Handle_Server_Notice;

   ----------------------------------------------------------------------
   --  Running a command
   ----------------------------------------------------------------------

   procedure Handle_Command (Ctx : Service_Context; Words : String_Vector) is
      Index  : Natural := 0;
      Next   : Positive := 1;
   begin
      begin
         Get (0, Words, 1, Index, Next);
      exception
         when E : Service_Error =>
            Fail (Ada.Exceptions.Exception_Message (E)
                  & " (type ""help"" for a list of commands)");
      end;

      declare
         N : Node renames Nodes (Index);
      begin
         if N.Admin and then not Ctx.Admin then
            Fail ("you must be an admin to use this command");
         end if;
         if not N.Global and then Ctx.User = null then
            Fail ("this command must be run as a user (try running with "
                  & "user run)");
         end if;

         if N.Run = null then
            if Has_Children (Index) then
               Say_Available (Ctx, Index, Words);
               return;
            end if;
            --  Pretend the command does not exist if it has neither
            --  children nor handler: a bug, but better not to die.
            Fail ("command " & Quote (Words (1)) & " not found");
         end if;

         N.Run (Ctx, Tail (Words, Next));
      end;
   end Handle_Command;

   procedure Handle_Privmsg (Ctx : Service_Context; Text : String) is
      Words : String_Vector;
   begin
      begin
         Words := Soja.Service_Words.Split_Words (Text);
      exception
         when E : Soja.Service_Words.Split_Error =>
            Fail ("failed to parse command: "
                  & Ada.Exceptions.Exception_Message (E));
      end;
      Handle_Command (Ctx, Words);
   end Handle_Privmsg;

   type Client_Printer (DC : Downstream_Conn_Access) is
     new Printer with null record;
   overriding procedure Print (P : in out Client_Printer; Text : String) is
   begin
      Soja.Core.Downstream_Helpers.Send_Service_Privmsg (P.DC, Text);
   end Print;

   type Run_Printer (Output : Run_Output_Access) is
     new Printer with null record;
   overriding procedure Print (P : in out Run_Printer; Text : String) is
   begin
      P.Output.Put (Text);
   end Print;

   procedure Handle_Client
     (DC : not null Downstream_Conn_Access; Text : String)
   is
      P   : aliased Client_Printer (DC);
      Ctx : constant Service_Context :=
        (Nick    => DC.Nick,
         Network => DC.Network,
         User    => DC.User,
         Srv     => DC.Srv,
         Admin   => DC.User /= null and then DC.User.User_Record.Admin,
         Output  => P'Unchecked_Access);
   begin
      Handle_Privmsg (Ctx, Text);
   exception
      when E : Service_Error =>
         Soja.Core.Downstream_Helpers.Send_Service_Privmsg
           (DC, "error: " & Ada.Exceptions.Exception_Message (E));
   end Handle_Client;

   procedure Run_Event
     (U : not null User_Access; Params : String_Vector;
      Output : not null Run_Output_Access)
   is
      P   : aliased Run_Printer (Output);
      Ctx : constant Service_Context :=
        (Nick    => Null_Unbounded_String,
         Network => null,
         User    => U,
         Srv     => U.Srv,
         Admin   => U.User_Record.Admin,
         Output  => P'Unchecked_Access);
   begin
      begin
         Handle_Command (Ctx, Params);
         Output.Finish (False, "");
      exception
         when E : Service_Error =>
            Output.Finish (True, Ada.Exceptions.Exception_Message (E));
      end;
   end Run_Event;

   ----------------------------------------------------------------------
   --  The tree
   ----------------------------------------------------------------------

   Network_Flags_Usage : constant String :=
     "[-addr addr] [-name name] [-username username] [-pass pass] "
     & "[-realname realname] [-certfp fingerprint] [-nick nick] "
     & "[-auto-away auto-away] [-enabled enabled] "
     & "[-connect-command command]...";

   Help_Node, Network_Node, Certfp_Node, Sasl_Node, User_Node, Channel_Node,
   Server_Node, Unused : Natural;
   pragma Unreferenced (Help_Node, Unused);

begin
   Help_Node := Add (0, "help", "[command]", "print help message",
                     Handle_Help'Access, Global => True);

   Network_Node := Add (0, "network");
   Unused := Add (Network_Node, "create",
                  "-addr <addr> [-name name] [-username username] "
                  & "[-pass pass] [-realname realname] [-certfp fingerprint] "
                  & "[-nick nick] [-auto-away auto-away] [-enabled enabled] "
                  & "[-connect-command command]...",
                  "add a new network", Handle_Network_Create'Access);
   Unused := Add (Network_Node, "status", "",
                  "show a list of saved networks and their current status",
                  Handle_Network_Status'Access);
   Unused := Add (Network_Node, "update", "[name] " & Network_Flags_Usage,
                  "update a network", Handle_Network_Update'Access);
   Unused := Add (Network_Node, "delete", "[name]", "delete a network",
                  Handle_Network_Delete'Access);
   Unused := Add (Network_Node, "quote", "[name] <command>",
                  "send a raw line to a network",
                  Handle_Network_Quote'Access);

   Certfp_Node := Add (0, "certfp");
   Unused := Add (Certfp_Node, "generate",
                  "[-key-type rsa|ecdsa|ed25519] [-bits N] [-network name]",
                  "generate a new self-signed certificate, defaults to using "
                  & "RSA-3072 key", Handle_Certfp_Generate'Access);
   Unused := Add (Certfp_Node, "fingerprint", "[-network name]",
                  "show fingerprints of certificate",
                  Handle_Certfp_Fingerprints'Access);

   Sasl_Node := Add (0, "sasl");
   Unused := Add (Sasl_Node, "status", "[-network name]", "show SASL status",
                  Handle_Sasl_Status'Access);
   Unused := Add (Sasl_Node, "set-plain",
                  "[-network name] <username> <password>",
                  "set SASL PLAIN credentials", Handle_Sasl_Set_Plain'Access);
   Unused := Add (Sasl_Node, "reset", "[-network name]",
                  "disable SASL authentication and remove stored credentials",
                  Handle_Sasl_Reset'Access);

   User_Node := Add (0, "user", Global => True);
   Unused := Add (User_Node, "status", "[username]",
                  "show a list of users and their current status",
                  Handle_User_Status'Access, Admin => True, Global => True);
   Unused := Add (User_Node, "create",
                  "-username <username> -password <password> "
                  & "[-disable-password] [-admin true|false] [-nick <nick>] "
                  & "[-realname <realname>] [-enabled true|false]",
                  "create a new soju user", Handle_User_Create'Access,
                  Admin => True, Global => True);
   Unused := Add (User_Node, "update",
                  "[username] [-password <password>] [-disable-password] "
                  & "[-admin true|false] [-nick <nick>] "
                  & "[-realname <realname>] [-enabled true|false]",
                  "update a user", Handle_User_Update'Access, Global => True);
   Unused := Add (User_Node, "delete", "<username> [confirmation token]",
                  "delete a user", Handle_User_Delete'Access, Global => True);
   Unused := Add (User_Node, "run", "<username> <command>",
                  "run a command as another user", Handle_User_Run'Access,
                  Admin => True, Global => True);

   Channel_Node := Add (0, "channel");
   Unused := Add (Channel_Node, "status", "[-network name]",
                  "show a list of saved channels and their current status",
                  Handle_Channel_Status'Access);
   Unused := Add (Channel_Node, "update",
                  "<name> [-detached <true|false>] "
                  & "[-relay-detached <default|none|highlight|message>] "
                  & "[-reattach-on <default|none|highlight|message>] "
                  & "[-detach-after <duration>] "
                  & "[-detach-on <default|none|highlight|message>]",
                  "update a channel", Handle_Channel_Update'Access);
   Unused := Add (Channel_Node, "delete", "<name>", "delete a channel",
                  Handle_Channel_Delete'Access);

   Server_Node := Add (0, "server", Admin => True);
   Unused := Add (Server_Node, "status", "", "show server statistics",
                  Handle_Server_Status'Access, Admin => True, Global => True);
   Unused := Add (Server_Node, "notice", "<notice>",
                  "broadcast a notice to all connected bouncer users",
                  Handle_Server_Notice'Access, Admin => True, Global => True);
end Soja.Core.Service;
