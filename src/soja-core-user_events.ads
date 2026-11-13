pragma Ada_2022;

--  user.go's event loop body: what the user's task does with each event
--  (upstream and downstream connections coming, going and talking; idle
--  channels; broadcasts; user updates; stopping).
package Soja.Core.User_Events is

   --  handleEvent: Stop is True when the loop must end (Stop_Event).
   procedure Handle_Event
     (U    : not null User_Access;
      E    : not null Event_Access;
      Stop : out Boolean);

end Soja.Core.User_Events;
