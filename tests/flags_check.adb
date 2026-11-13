pragma Ada_2022;

with Ada.Exceptions;
with Ada.Text_IO;
with GNAT.OS_Lib;

with Ada.Containers;
with Soja.Flags; use Soja.Flags;

--  Go's flag package, as BouncerServ uses it.
procedure Flags_Check is
   use type Ada.Containers.Count_Type;

   procedure Check (Cond : Boolean; What : String) is
   begin
      if not Cond then
         Ada.Text_IO.Put_Line ("FAILED: " & What);
         GNAT.OS_Lib.OS_Exit (1);
      end if;
   end Check;

   function V (A, B, C, D, E, F, G, H, I : String := "")
      return String_Vector is
      R : String_Vector;
   begin
      if A /= "" then R.Append (A); end if;
      if B /= "" then R.Append (B); end if;
      if C /= "" then R.Append (C); end if;
      if D /= "" then R.Append (D); end if;
      if E /= "" then R.Append (E); end if;
      if F /= "" then R.Append (F); end if;
      if G /= "" then R.Append (G); end if;
      if H /= "" then R.Append (H); end if;
      if I /= "" then R.Append (I); end if;
      return R;
   end V;

   --  The error a parse fails with ("" if it works).
   function Fails (Make : not null access procedure (FS : in out Flag_Set);
                   Args : String_Vector) return String
   is
      FS : Flag_Set;
   begin
      Make (FS);
      Parse (FS, Args);
      return "";
   exception
      when E : Flag_Error =>
         return Ada.Exceptions.Exception_Message (E);
   end Fails;

   procedure Define (FS : in out Flag_Set) is
   begin
      FS.Add_String ("name");
      FS.Add_String ("key-type", "rsa");
      FS.Add_Int ("bits", 3072);
      FS.Add_Bool ("disable-password");
      FS.Add_Bool_Value ("enabled");
      FS.Add_List ("connect-command");
   end Define;

   function Fresh return Flag_Set is
      Result : Flag_Set;
   begin
      Define (Result);
      return Result;
   end Fresh;

   FS : Flag_Set := Fresh;
begin
   Parse (FS, V ("-name", "my net", "-bits=4096", "--key-type", "ed25519",
                 "rest", "-notflag"));
   Check (FS.Is_Set ("name") and then FS.Get ("name") = "my net", "-name v");
   Check (FS.Get_Int ("bits") = 4096, "-bits=n");
   Check (FS.Get ("key-type") = "ed25519", "--name v");
   Check (FS.N_Arg = 2 and then FS.Arg (0) = "rest"
          and then FS.Arg (1) = "-notflag" and then FS.Arg (5) = "",
          "the first non-flag ends the flags");
   Check (not FS.Is_Set ("enabled") and then not FS.Get_Bool ("enabled"),
          "an unset bool value flag");
   Check (not FS.Is_Set ("disable-password"), "an unset bool");

   FS := Fresh;
   Parse (FS, V ("-disable-password", "-enabled", "false", "-name=",
                 "-connect-command", "A", "-connect-command=B", "--", "-x"));
   Check (FS.Get_Bool ("disable-password"), "-bool alone is true");
   Check (FS.Is_Set ("enabled") and then not FS.Get_Bool ("enabled"),
          "-bool value false");
   Check (FS.Is_Set ("name") and then FS.Get ("name") = "", "-name= is set");
   Check (FS.Get_List ("connect-command").Length = 2
          and then FS.Get_List ("connect-command") (2) = "B", "repeated");
   Check (FS.N_Arg = 1 and then FS.Arg (0) = "-x", "-- ends the flags");

   FS := Fresh;
   Parse (FS, V ("-", "-name", "x"));
   Check (FS.N_Arg = 3, "a lone - is an argument");

   Check (Fails (Define'Access, V ("-bogus")) =
          "flag provided but not defined: -bogus", "undefined");
   Check (Fails (Define'Access, V ("-name")) =
          "flag needs an argument: -name", "missing value");
   Check (Fails (Define'Access, V ("-enabled", "maybe")) =
          "invalid value ""maybe"" for flag -enabled: "
          & "strconv.ParseBool: parsing ""maybe"": invalid syntax", "bad bool");
   Check (Fails (Define'Access, V ("-bits", "x")) =
          "invalid value ""x"" for flag -bits: parse error", "bad int");
   Check (Fails (Define'Access, V ("-bits", "99999999999999999999")) =
          "invalid value ""99999999999999999999"" for flag -bits: "
          & "value out of range", "int range");
   Check (Fails (Define'Access, V ("--=x")) = "bad flag syntax: --=x",
          "bad syntax");
   Check (Fails (Define'Access, V ("---x")) = "bad flag syntax: ---x",
          "three dashes");
   Check (Fails (Define'Access, V ("-h")) = "flag: help requested", "help");
   Check (Fails (Define'Access, V ("-bits", "0x10")) = "", "hex");
   FS := Fresh;
   Parse (FS, V ("-bits", "-5"));
   Check (FS.Get_Int ("bits") = -5, "negative");
   FS := Fresh;
   Parse (FS, V ("-bits", "010"));
   Check (FS.Get_Int ("bits") = 8, "leading zero is octal in base 0");
   Ada.Text_IO.Put_Line ("ALL PASS");
end Flags_Check;
