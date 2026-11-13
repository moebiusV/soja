--  UTF-8 validation, for WebSocket text frames (which must be valid UTF-8)
--  and for what is sent in them (strings.ToValidUTF8).
pragma Ada_2022;

package Soja.Utf8 is

   --  Whether S is well-formed UTF-8: no overlong forms, no surrogates,
   --  nothing above U+10FFFF.
   function Is_Valid (S : String) return Boolean;

   --  strings.ToValidUTF8 (S, "�"): each run of invalid bytes becomes one
   --  U+FFFD.
   function To_Valid (S : String) return String;

   --  Bytes that are not UTF-8 (an IRC line may be in any charset) made into
   --  text a parser reads: each such byte becomes the private-use character
   --  U+F700 + the byte, and Restore turns them back, so what went through
   --  comes out byte for byte.  (A text that really has those characters,
   --  U+F780 .. U+F7FF, comes back as the bytes: a rarity.)
   function Escape_Invalid (S : String) return String;
   function Restore (S : String) return String;

end Soja.Utf8;
