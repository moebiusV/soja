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

end Soja.Utf8;
