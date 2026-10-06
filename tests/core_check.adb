pragma Ada_2022;

with Ada.Containers.Indefinite_Vectors;
with Ada.Strings.Unbounded;
with Ada.Text_IO;

with Soja.Irc.Case_Mapping;
with Soja.Upstream;
with Soja.User;

procedure Core_Check is
   use Ada.Strings.Unbounded;
   use Soja.Irc.Case_Mapping;

   package String_Vectors is new Ada.Containers.Indefinite_Vectors
     (Positive, String);

   Captured : String_Vectors.Vector;

   procedure Capture_Target (Target : String) is
   begin
      Captured.Append (Target);
   end Capture_Target;

   procedure Capture_Client (Client_Name : String) is
   begin
      Captured.Append (Client_Name);
   end Capture_Client;

   function Has_Str (V : String_Vectors.Vector; S : String) return Boolean is
   begin
      for C in V.Iterate loop
         if V (C) = S then
            return True;
         end if;
      end loop;
      return False;
   end Has_Str;
begin
   --  Upstream_User: hasWHOXFields.
   declare
      U : Soja.Upstream.Upstream_User;
   begin
      --  Empty field list is always satisfied.
      if not Soja.Upstream.Has_WHOX_Fields (U, "") then
         raise Program_Error with "empty WHOX fields must pass";
      end if;
      --  Static fields are always available.
      if not Soja.Upstream.Has_WHOX_Fields (U, "tcio") then
         raise Program_Error with "static WHOX fields must pass";
      end if;
      --  Nickname is unset, so "n" must fail.
      if Soja.Upstream.Has_WHOX_Fields (U, "n") then
         raise Program_Error with "unset nickname must fail";
      end if;
      --  Set nickname; "n" now passes, but "nu" (username unset) fails.
      U.Nickname := To_Unbounded_String ("nick");
      if not Soja.Upstream.Has_WHOX_Fields (U, "n") then
         raise Program_Error with "set nickname must pass";
      end if;
      if Soja.Upstream.Has_WHOX_Fields (U, "nu") then
         raise Program_Error with "unset username must fail";
      end if;
   end;

   --  Upstream_User: updateFrom.
   declare
      U : Soja.Upstream.Upstream_User;
   begin
      U.Nickname := To_Unbounded_String ("old");
      U.Realname := To_Unbounded_String ("keep");
      Soja.Upstream.Update_From
        (U, (Nickname => To_Unbounded_String ("new"),
             others  => Null_Unbounded_String));
      if U.Nickname /= "new" or else U.Realname /= "keep" then
         raise Program_Error with "updateFrom must overwrite only non-empty";
      end if;
   end;

   --  Delivered_Store: receipts, with case-folded targets.
   declare
      DS : Soja.User.Delivered_Store :=
        Soja.User.New_Delivered_Store (Case_RFC1459);
   begin
      if Soja.User.Has_Target (DS, "#chan") then
         raise Program_Error with "empty store must have no targets";
      end if;
      if Soja.User.Load_ID (DS, "#chan", "client") /= "" then
         raise Program_Error with "empty store must load empty ID";
      end if;

      Soja.User.Store_ID (DS, "#chan", "client", "m1");
      if not Soja.User.Has_Target (DS, "#CHAN") then
         raise Program_Error with "target must case-fold";
      end if;
      if Soja.User.Load_ID (DS, "#chan", "client") /= "m1" then
         raise Program_Error with "stored ID must load";
      end if;
      if Soja.User.Load_ID (DS, "#chan", "other") /= "" then
         raise Program_Error with "unknown client must load empty";
      end if;

      Soja.User.Store_ID (DS, "#chan", "client", "m2");
      if Soja.User.Load_ID (DS, "#chan", "client") /= "m2" then
         raise Program_Error with "stored ID must overwrite";
      end if;

      Soja.User.Store_ID (DS, "#other", "client", "m3");
      Captured.Clear;
      Soja.User.For_Each_Target (DS, Capture_Target'Access);
      if not Has_Str (Captured, "#chan") or else
         not Has_Str (Captured, "#other")
      then
         raise Program_Error with "For_Each_Target must visit both targets";
      end if;

      Captured.Clear;
      Soja.User.For_Each_Client (DS, Capture_Client'Access);
      if not Has_Str (Captured, "client") then
         raise Program_Error with "For_Each_Client must visit the client";
      end if;
   end;

   Ada.Text_IO.Put_Line ("ALL PASS");
end Core_Check;
