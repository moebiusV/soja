pragma Ada_2022;

with Ada.Strings.Unbounded;
with Interfaces;

--  The subset of the BARE encoding (git.sr.ht/~sircmpwn/go-bare) that soju's
--  message IDs use: uint (unsigned LEB128), int (zig-zag varint) and string
--  (uint length + bytes).  Byte strings are Ada Strings, one octet per
--  character.
package Soja.Bare is

   use Interfaces;

   Bare_Error : exception;

   procedure Write_Uint
     (Buf : in out Ada.Strings.Unbounded.Unbounded_String; V : Unsigned_64);
   procedure Write_Int
     (Buf : in out Ada.Strings.Unbounded.Unbounded_String; V : Integer_64);
   procedure Write_String
     (Buf : in out Ada.Strings.Unbounded.Unbounded_String; S : String);

   type Reader is private;
   function New_Reader (Data : String) return Reader;

   --  Each raises Bare_Error on truncated or overflowing input.
   function Read_Uint (R : in out Reader) return Unsigned_64;
   function Read_Int (R : in out Reader) return Integer_64;
   function Read_String (R : in out Reader) return String;

   --  The bytes not consumed yet.
   function Rest (R : Reader) return String;

private

   type Reader is record
      Data : Ada.Strings.Unbounded.Unbounded_String;
      Pos  : Positive := 1;
   end record;

end Soja.Bare;
