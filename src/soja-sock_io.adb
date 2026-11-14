pragma Ada_2022;

package body Soja.Sock_Io is

   use Ada.Streams;

   protected body Gate is
      entry Seize when not Held is
      begin
         Held := True;
      end Seize;

      procedure Release is
      begin
         Held := False;
      end Release;
   end Gate;

   procedure Receive
     (Sock : AWS.Net.Socket_Type'Class;
      G    : not null Gate_Access;
      Buf  : out Stream_Element_Array;
      Last : out Stream_Element_Offset)
   is
   begin
      --  (An error or a timeout here is met again, and told properly, by the
      --  Receive that follows.)
      loop
         declare
            Ready : constant AWS.Net.Event_Set :=
              Sock.Wait ([AWS.Net.Input => True, AWS.Net.Output => False]);
         begin
            exit when Ready (AWS.Net.Input) or else Ready (AWS.Net.Error);
         exception
            when AWS.Net.Socket_Error => exit;
         end;
      end loop;
      G.Seize;
      begin
         Sock.Receive (Buf, Last);
      exception
         when others =>
            G.Release;
            raise;
      end;
      G.Release;
   end Receive;

   procedure Send
     (Sock : AWS.Net.Socket_Type'Class;
      G    : not null Gate_Access;
      Data : Stream_Element_Array;
      Last : out Stream_Element_Offset)
   is
   begin
      G.Seize;
      begin
         Sock.Send (Data, Last);
      exception
         when others =>
            G.Release;
            raise;
      end;
      G.Release;
   end Send;

end Soja.Sock_Io;
