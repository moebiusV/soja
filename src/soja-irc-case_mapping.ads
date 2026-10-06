pragma Ada_2022;

--  IRC case-mapping, translated from soju's xirc/casemapping.go.  A
--  case-mapping folds a nickname or channel name to its canonical form so
--  that names differing only in case (or in the punctuation bytes each
--  mapping equates) compare equal.  The folds are byte-wise, exactly as the
--  Go original: only ASCII letters and the mapping's extra punctuation are
--  rewritten; UTF-8 bytes pass through untouched.
package Soja.Irc.Case_Mapping is

   --  "Case_" prefix avoids colliding with Standard.ASCII.
   type Kind is (Case_ASCII, Case_RFC1459, Case_RFC1459_Strict);

   --  Fold returns the canonical form of Name under the given mapping.
   function Fold (CM : Kind; Name : String) return String;

   --  Parse_Case_Mapping maps the scfg string ("ascii", "rfc1459",
   --  "rfc1459-strict") to a Kind.  Unknown names fold to Case_RFC1459,
   --  soju's default (Go's ParseCaseMapping returns nil there).
   function Parse_Case_Mapping (S : String) return Kind;

end Soja.Irc.Case_Mapping;
