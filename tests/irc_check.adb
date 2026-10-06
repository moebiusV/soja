pragma Ada_2022;

with Ada.Command_Line;
with Ada.Text_IO;
with Soja.Irc.Cap_Registry;
with Soja.Irc.Case_Mapping;

procedure Irc_Check is
   use Soja.Irc.Case_Mapping;

   Fails : Natural := 0;

   procedure Check (Label : String; Got, Want : String) is
   begin
      if Got /= Want then
         Fails := Fails + 1;
         Ada.Text_IO.Put_Line
           ("FAIL: " & Label & " got """ & Got & """ want """ & Want & """");
      else
         Ada.Text_IO.Put_Line ("ok: " & Label);
      end if;
   end Check;

   procedure Check_Bool (Label : String; Got, Want : Boolean) is
   begin
      if Got /= Want then
         Fails := Fails + 1;
         Ada.Text_IO.Put_Line
           ("FAIL: " & Label & " got " & Got'Image
            & " want " & Want'Image);
      else
         Ada.Text_IO.Put_Line ("ok: " & Label);
      end if;
   end Check_Bool;

   R : Soja.Irc.Cap_Registry.Registry := Soja.Irc.Cap_Registry.New_Registry;

begin
   --  Case-mapping folds (byte-wise, matching xirc/casemapping.go).
   Check ("ascii", Fold (Case_ASCII, "NickName"), "nickname");
   Check ("ascii punct", Fold (Case_ASCII, "[Nick]{}"), "[nick]{}");
   Check ("rfc1459", Fold (Case_RFC1459, "Nick{Name}"), "nick[name]");
   Check ("rfc1459 8-bit", Fold (Case_RFC1459, "A\B~C^"), "a|b^c^");
   Check ("rfc1459 tilde", Fold (Case_RFC1459, "A~B"), "a^b");
   Check ("rfc1459-strict tilde",
          Fold (Case_RFC1459_Strict, "A~B"), "a~b");

   --  Parse_Case_Mapping.
   Check_Bool ("parse ascii",
               Parse_Case_Mapping ("ascii") = Case_ASCII, True);
   Check_Bool ("parse rfc1459",
               Parse_Case_Mapping ("rfc1459") = Case_RFC1459, True);
   Check_Bool ("parse strict",
               Parse_Case_Mapping ("rfc1459-strict") = Case_RFC1459_Strict,
               True);
   Check_Bool ("parse unknown -> rfc1459",
               Parse_Case_Mapping ("bogus") = Case_RFC1459, True);

   --  Capability registry.
   Check_Bool ("not available",
               Soja.Irc.Cap_Registry.Is_Available (R, "sasl"), False);
   Soja.Irc.Cap_Registry.Set_Available (R, "sasl", "PLAIN,EXTERNAL");
   Check_Bool ("available",
               Soja.Irc.Cap_Registry.Is_Available (R, "sasl"), True);
   Check ("value", Soja.Irc.Cap_Registry.Value (R, "sasl"),
          "PLAIN,EXTERNAL");
   Check_Bool ("not enabled",
               Soja.Irc.Cap_Registry.Is_Enabled (R, "sasl"), False);
   Soja.Irc.Cap_Registry.Set_Enabled (R, "sasl", True);
   Check_Bool ("enabled", Soja.Irc.Cap_Registry.Is_Enabled (R, "sasl"), True);
   Soja.Irc.Cap_Registry.Set_Enabled (R, "sasl", False);
   Check_Bool ("disabled",
               Soja.Irc.Cap_Registry.Is_Enabled (R, "sasl"), False);
   Soja.Irc.Cap_Registry.Delete (R, "sasl");
   Check_Bool ("deleted",
               Soja.Irc.Cap_Registry.Is_Available (R, "sasl"), False);

   if Fails = 0 then
      Ada.Text_IO.Put_Line ("ALL PASS");
   else
      Ada.Text_IO.Put_Line (Fails'Image & " failure(s)");
      Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
   end if;
end Irc_Check;
