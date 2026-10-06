pragma Ada_2022;

with Ada.Strings.Unbounded;
with Ada.Text_IO;

with Soja.Irc.Case_Mapping;
with Soja.Irc.Case_Mapping_Maps;

procedure CM_Map_Check is
   use Ada.Strings.Unbounded;
   use Soja.Irc.Case_Mapping;

   package Int_Maps is new Soja.Irc.Case_Mapping_Maps (Integer, 0);

   M : Int_Maps.Map := Int_Maps.New_Map (Case_RFC1459);

   Seen_Key : Unbounded_String := Null_Unbounded_String;
   Seen_Val : Integer := -1;

   procedure Capture (Name : String; Value : Integer) is
   begin
      Seen_Key := To_Unbounded_String (Name);
      Seen_Val := Value;
   end Capture;
begin
   --  RFC1459 folds A-Z and {, }, \, ~.
   Int_Maps.Set (M, "Nick", 1);
   if not Int_Maps.Has (M, "nick") then
      raise Program_Error with "case-fold lookup failed";
   end if;
   if Int_Maps.Get (M, "NICK") /= 1 then
      raise Program_Error with "Get via folded key wrong";
   end if;
   if Int_Maps.Get (M, "absent") /= 0 then
      raise Program_Error with "absent key must return Null_Element";
   end if;

   --  Updating a folded key keeps the original key and replaces the value.
   Int_Maps.Set (M, "nIcK", 2);
   if Int_Maps.Length (M) /= 1 then
      raise Program_Error with "folded update must not add an entry";
   end if;
   if Int_Maps.Get (M, "nick") /= 2 then
      raise Program_Error with "folded update must replace value";
   end if;

   Int_Maps.For_Each (M, Capture'Access);
   if Seen_Key /= "Nick" or else Seen_Val /= 2 then
      raise Program_Error with "For_Each must yield the original key";
   end if;

   Int_Maps.Del (M, "NICK");
   if Int_Maps.Has (M, "nick") then
      raise Program_Error with "Del must remove the entry";
   end if;

   --  "a{" and "a[" are the same key under RFC1459, distinct under ASCII.
   Int_Maps.Set (M, "a{", 1);
   Int_Maps.Set (M, "a[", 2);
   if Int_Maps.Length (M) /= 1 then
      raise Program_Error with "rfc1459 specials must fold together";
   end if;

   Int_Maps.Set_Case_Mapping (M, Case_ASCII);
   if not Int_Maps.Has (M, "a{") or else Int_Maps.Has (M, "a[") then
      raise Program_Error with "Set_Case_Mapping must re-fold keys";
   end if;

   Ada.Text_IO.Put_Line ("ALL PASS");
end CM_Map_Check;
