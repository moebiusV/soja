pragma Ada_2022;

with Ada.Text_IO;

with Soja.Core;

procedure Core_Struct_Check is
   use Soja.Core;
begin
   --  Signal: one-shot flag.
   declare
      S : Signal;
   begin
      if S.Is_Set then
         raise Program_Error with "fresh Signal must be unset";
      end if;
      S.Set;
      S.Set;   --  idempotent
      if not S.Is_Set then
         raise Program_Error with "Signal must be set after Set";
      end if;
      S.Wait;   --  non-blocking once set
   end;

   --  Event type dispatch.
   declare
      Ev : Event_Access := new Upstream_Connected_Event;
   begin
      if not (Ev.all in Upstream_Connected_Event) then
         raise Program_Error with "event membership wrong";
      end if;
      if Ev.all in Downstream_Message_Event then
         raise Program_Error with "event membership false positive";
      end if;
   end;

   declare
      Ev : Event_Access := new Downstream_Message_Event;
   begin
      if not (Ev.all in Downstream_Message_Event) then
         raise Program_Error with "downstream message event membership wrong";
      end if;
   end;

   --  Struct default construction.
   declare
      U  : User;
      N  : Network;
      DC : Downstream_Conn;
      UC : Upstream_Conn;
      CH : Upstream_Channel;
   begin
      if DC.Registered or else UC.Registered then
         raise Program_Error with "fresh connections must be unregistered";
      end if;
      if U.Num_Downstream_Conns /= 0 then
         raise Program_Error with "fresh user must have zero downstream";
      end if;
      if CH.Complete then
         raise Program_Error with "fresh channel must be incomplete";
      end if;
      pragma Unreferenced (N);
   end;

   --  Downstream_Registration.
   declare
      R : Downstream_Registration;
   begin
      if R.Negotiating_Caps or else R.Network_ID /= 0 then
         raise Program_Error with "fresh registration wrong";
      end if;
   end;

   Ada.Text_IO.Put_Line ("ALL PASS");
end Core_Struct_Check;
