--  The signals soju's main loop waits for: SIGINT and SIGTERM stop the
--  server, SIGHUP reloads the configuration.
pragma Ada_2022;

with Ada.Interrupts.Names;

package Soja_Signals is

   type Signal is (Stop, Reload);

   protected Watcher is
      --  Blocks until a signal arrives.
      entry Wait (Which : out Signal);

      procedure Interrupt
        with Attach_Handler => Ada.Interrupts.Names.SIGINT;
      procedure Terminate_Handler
        with Attach_Handler => Ada.Interrupts.Names.SIGTERM;
      procedure Hangup
        with Attach_Handler => Ada.Interrupts.Names.SIGHUP;
   private
      Pending_Stop   : Boolean := False;
      Pending_Reload : Boolean := False;
   end Watcher;

end Soja_Signals;
