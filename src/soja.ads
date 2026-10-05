pragma Ada_2022;

--  soja: a drop-in replacement for the soju IRC bouncer, written in Ada 2022
--  using the ada-on-alpine packages.  "soja" is soju-in-Ada -- we are all
--  sojas now.
--
--  This root package is the namespace for the translation.  Each soju Go
--  source file becomes a child package (see PORTING.md for the map):
--    rate.go        -> Soja.Backoff
--    irc.go, xirc/  -> Soja.Irc
--    config/        -> Soja.Config
--    database/      -> Soja.Database
--    ...
package Soja is

end Soja;
