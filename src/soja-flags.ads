--  A small port of Go's `flag` package as BouncerServ uses it (service.go's
--  newFlagSet: flag.ContinueOnError, output discarded): "-name value",
--  "-name=value", "--name", a lone "-" or the first non-flag ends the flags,
--  "--" ends them and is consumed.  Errors carry Go's texts.
pragma Ada_2022;

with Ada.Containers.Vectors;
with Ada.Strings.Unbounded;

with Soja.Irc.Genmsg;

package Soja.Flags is

   subtype String_Vector is Soja.Irc.Genmsg.String_Vectors.Vector;

   Flag_Error : exception;   --  Exception_Message is Go's error text

   type Flag_Set is tagged private;

   --  fs.String: a string flag.
   procedure Add_String
     (FS : in out Flag_Set; Name : String; Default : String := "");

   --  fs.Bool: "-name" alone means true; "-name=false" sets it.
   procedure Add_Bool
     (FS : in out Flag_Set; Name : String; Default : Boolean := False);

   --  boolPtrFlag: a bool that needs a value ("-name true"), so that "unset"
   --  can be told from "false" (Is_Set).
   procedure Add_Bool_Value (FS : in out Flag_Set; Name : String);

   --  fs.Int.
   procedure Add_Int
     (FS : in out Flag_Set; Name : String; Default : Integer := 0);

   --  stringSliceFlag: may be repeated; every value is kept.
   procedure Add_List (FS : in out Flag_Set; Name : String);

   --  fs.Parse.
   procedure Parse (FS : in out Flag_Set; Args : String_Vector);

   --  Whether the flag appeared on the command line.
   function Is_Set (FS : Flag_Set; Name : String) return Boolean;

   function Get (FS : Flag_Set; Name : String) return String;
   function Get_Bool (FS : Flag_Set; Name : String) return Boolean;
   function Get_Int (FS : Flag_Set; Name : String) return Integer;
   function Get_List (FS : Flag_Set; Name : String) return String_Vector;

   --  fs.NArg / fs.Arg / fs.Args: what follows the flags (Arg is 0-based and
   --  "" when out of range, as in Go).
   function N_Arg (FS : Flag_Set) return Natural;
   function Arg (FS : Flag_Set; I : Natural) return String;
   function Args (FS : Flag_Set) return String_Vector;

   --  strconv.ParseBool; Constraint_Error when it is not a boolean.
   function Parse_Bool (S : String) return Boolean;

private

   use Ada.Strings.Unbounded;

   type Kind is (K_String, K_Bool, K_Bool_Value, K_Int, K_List);

   type Flag is record
      Name   : Unbounded_String;
      Which  : Kind;
      Seen   : Boolean := False;
      Text   : Unbounded_String;      --  the value (or the default)
      Number : Integer := 0;
      Flag_B : Boolean := False;
      Items  : String_Vector;
   end record;

   package Flag_Vectors is new Ada.Containers.Vectors (Positive, Flag);

   type Flag_Set is tagged record
      Defined : Flag_Vectors.Vector;
      Rest    : String_Vector;
   end record;

end Soja.Flags;
