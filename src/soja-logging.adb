pragma Ada_2022;

with Ada.Calendar;
with Ada.Calendar.Formatting;
with Ada.Strings.Unbounded;
with Ada.Text_IO;

package body Soja.Logging is

   use Ada.Strings.Unbounded;

   --  Go's log.LstdFlags prefix: "YYYY-MM-DD HH:MM:SS " (Go uses slashes in
   --  the date; the dash form is the closest Ada gives without hand-rolling).
   function Stamp return String is
   begin
      return Ada.Calendar.Formatting.Image (Ada.Calendar.Clock, False) & " ";
   end Stamp;

   overriding procedure Print (L : Standard_Logger; Text : String) is
   begin
      Ada.Text_IO.Put_Line (Ada.Text_IO.Standard_Error, Stamp & Text);
   end Print;

   overriding procedure Debug (L : Standard_Logger; Text : String) is
   begin
      if L.Debug_Enabled then
         Print (L, Text);
      end if;
   end Debug;

   overriding procedure Print (L : Prefix_Logger; Text : String) is
   begin
      if L.Base /= null then
         L.Base.Print (To_String (L.Prefix) & Text);
      end if;
   end Print;

   overriding procedure Debug (L : Prefix_Logger; Text : String) is
   begin
      if L.Base /= null then
         L.Base.Debug (To_String (L.Prefix) & Text);
      end if;
   end Debug;

end Soja.Logging;
