--  Soja.Logging — server.go's Logger interface and its two implementations.
--  Go's Printf/Debugf become Print/Debug taking a plain string: the callers
--  build the message (Go uses printf), so the interface has no format string.
pragma Ada_2022;

with Ada.Strings.Unbounded;

package Soja.Logging is

   type Logger is limited interface;
   procedure Print (L : Logger; Text : String) is abstract;
   procedure Debug (L : Logger; Text : String) is abstract;

   type Logger_Access is access all Logger'Class;

   --  The default logger (server.go's `logger`): writes to standard error with
   --  Go's log.LstdFlags timestamp.  Debug output is dropped unless enabled.
   type Standard_Logger is new Logger with record
      Debug_Enabled : Boolean := False;
   end record;
   overriding procedure Print (L : Standard_Logger; Text : String);
   overriding procedure Debug (L : Standard_Logger; Text : String);

   --  Prepends a fixed prefix to every line, delegating to an inner logger
   --  (server.go's prefixLogger).
   type Prefix_Logger is new Logger with record
      Base   : Logger_Access;
      Prefix : Ada.Strings.Unbounded.Unbounded_String;
   end record;
   overriding procedure Print (L : Prefix_Logger; Text : String);
   overriding procedure Debug (L : Prefix_Logger; Text : String);

end Soja.Logging;
