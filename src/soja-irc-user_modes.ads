pragma Ada_2022;

with Ada.Strings.Unbounded;

--  irc.go's userModes: a user's set of mode flags (e.g. "iwz").
package Soja.Irc.User_Modes is

   type User_Modes is record
      Value : Ada.Strings.Unbounded.Unbounded_String;
   end record;

   function Has (M : User_Modes; C : Character) return Boolean;
   procedure Add (M : in out User_Modes; C : Character);
   procedure Del (M : in out User_Modes; C : Character);
   --  Apply a modestring ("+iw-z"): Success is False on a malformed string
   --  (a mode character before any '+'/'-').
   procedure Apply (M : in out User_Modes; S : String; Success : out Boolean);
   function Image (M : User_Modes) return String;   -- Go's string(ms)

end Soja.Irc.User_Modes;
