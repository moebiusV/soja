--  Go's path.Match: shell patterns, as the `http-origin` directive uses them.
--
--     *        any sequence of characters other than '/'
--     ?        any single character other than '/'
--     [a-z]    a character class ([^...] negates); \c is c itself
--
--  The whole name must match.  A malformed pattern matches nothing (the
--  configuration refuses those at load time).  Matching is by byte; '?' and
--  classes take a whole UTF-8 sequence as one character.
pragma Ada_2022;

package Soja.Glob is

   function Match (Pattern, Name : String) return Boolean;

end Soja.Glob;
