pragma Ada_2022;

package body Soja_Signals is

   protected body Watcher is

      entry Wait (Which : out Signal) when Pending_Stop or else Pending_Reload
      is
      begin
         --  Stopping wins over reloading.
         if Pending_Stop then
            Which := Stop;
         else
            Which := Reload;
            Pending_Reload := False;
         end if;
      end Wait;

      procedure Interrupt is
      begin
         Pending_Stop := True;
      end Interrupt;

      procedure Terminate_Handler is
      begin
         Pending_Stop := True;
      end Terminate_Handler;

      procedure Hangup is
      begin
         Pending_Reload := True;
      end Hangup;

   end Watcher;

end Soja_Signals;
