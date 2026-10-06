pragma Ada_2022;

with Ada.Command_Line;
with Ada.Strings.Unbounded;
with Ada.Text_IO;
with Soja.Irc.Cap_Registry;
with Soja.Irc.Case_Mapping;
with Soja.Irc.Hbnf;
with Soja.Irc.Messages;

procedure Irc_Check is
   use Ada.Strings.Unbounded;
   use Soja.Irc.Case_Mapping;
   use Soja.Irc.Messages;

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

   --  Tag value escape / unescape (parser.go).
   Check ("encode tag value", Encode_Tag_Value ("a b;c"), "a\sb\:c");
   Check ("decode tag value", Parse_Tag_Value ("a\sb\:c"), "a b;c");
   Check ("encode backslash", Encode_Tag_Value ("x\y"), "x\\y");
   Check ("decode backslash", Parse_Tag_Value ("x\\y"), "x\y");

   --  Prefix.
   Check ("prefix full", Image (Parse_Prefix ("nick!user@host")),
          "nick!user@host");
   Check ("prefix nick only", Image (Parse_Prefix ("nick")), "nick");
   Check ("prefix nick@host", Image (Parse_Prefix ("nick@host")),
          "nick@host");

   --  Message parse / serialize round-trips.
   Check ("msg privmsg",
          Image (Parse_Message ("PRIVMSG #chan :hello world")),
          "PRIVMSG #chan :hello world");
   --  irc.v4 loses the " :" marker for a plain-word trailing param, so
   --  ":nick!... :hi" re-emits as "#chan hi" (single space).  Documented in
   --  PORTING.md ("Trailing/middle param loss").
   Check ("msg prefix",
          Image (Parse_Message (":nick!user@host PRIVMSG #chan :hi")),
          ":nick!user@host PRIVMSG #chan hi");
   Check ("msg tags",
          Image (Parse_Message ("@tag1=val1;tag2 PRIVMSG #chan")),
          "@tag1=val1;tag2 PRIVMSG #chan");
   Check ("msg numeric",
          Image (Parse_Message ("332 nick #chan :No topic here")),
          "332 nick #chan :No topic here");
   Check ("msg no params", Image (Parse_Message ("PING")), "PING");
   Check ("msg empty trailing", Image (Parse_Message ("PING :")), "PING :");
   Check ("msg trailing starts colon",
          Image (Parse_Message ("NOTICE AUTH :*** hello")),
          "NOTICE AUTH :*** hello");

   --  Message component access.
   declare
      M : constant Message :=
        Parse_Message (":nick!user@host PRIVMSG #chan :hello");
   begin
      Check ("component command", To_String (M.Command), "PRIVMSG");
      Check ("component prefix", Image (M.Prefix.all), "nick!user@host");
      Check ("component param0", Param (M, 0), "#chan");
      Check ("component param1", Param (M, 1), "hello");
      Check ("component param oob", Param (M, 2), "");
      Check ("component trailing", Trailing (M), "hello");
   end;

   --  The hbnf-generated parser (walked) must match the hand-written
   --  reference byte-for-byte on the golden lines.
   declare
      procedure Check_Hbnf (L : String) is
      begin
         Check ("hbnf " & L,
                Image (Soja.Irc.Hbnf.Parse (L)),
                Image (Parse_Message (L)));
      end Check_Hbnf;
   begin
      Check_Hbnf ("PRIVMSG #chan :hello world");
      Check_Hbnf (":nick!user@host PRIVMSG #chan :hi");
      Check_Hbnf ("@tag1=val1;tag2 PRIVMSG #chan");
      Check_Hbnf ("332 nick #chan :No topic here");
      Check_Hbnf ("PING");
      Check_Hbnf ("PING :");
      Check_Hbnf ("NOTICE AUTH :*** hello");
      Check_Hbnf ("@a=b;c :nick!u@h PRIVMSG #chan :hello world");
   end;

   if Fails = 0 then
      Ada.Text_IO.Put_Line ("ALL PASS");
   else
      Ada.Text_IO.Put_Line (Fails'Image & " failure(s)");
      Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
   end if;
end Irc_Check;
