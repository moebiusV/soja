pragma Ada_2022;

with Ada.Exceptions;
with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;
with Ada.Text_IO;
with GNAT.OS_Lib;

with Soja.Base64;
with Soja.Webpush;

--  RFC 8291 appendix A's example, and the VAPID parts.
procedure Webpush_Check is
   function D (S : String) return String is
      V : Boolean;
      R : constant String := Soja.Base64.Decode
        (S, V, URL_Safe => True, Padded => False);
   begin
      if not V then
         raise Program_Error with "bad base64 in the test";
      end if;
      return R;
   end D;

   procedure Check (Cond : Boolean; What : String) is
   begin
      if not Cond then
         raise Program_Error with What;
      end if;
   end Check;
begin
   declare
      Plain : constant String :=
        "When I grow up, I want to be a watermelon";
      Got : constant String := Soja.Webpush.Encrypt
        (Payload     => Plain,
         UA_Public   => D ("BCVxsr7N_eNgVRqvHtD0zTZsEc6-VV-JvLexhqUzORcxaOzi6"
                           & "-AYWXvTBHm4bjyPjs7Vd8pZGH6SRpkNtoIAiw4"),
         Auth_Secret => D ("BTBZMqHH6r4Tts7J_aSIgg"),
         Salt        => D ("DGv6ra1nlYgDCS1FRnbzlw"),
         AS_Private  => D ("yfWPiYE-n46HLnH0KqZOF1fJJU3MYrct3AELtAQ-oRw"),
         Record_Size => 4096);
      Want : constant String := D
        ("DGv6ra1nlYgDCS1FRnbzlwAAEABBBP4z9KsN6nGRTbVYI_c7VJSPQTBtkgcy27mlm"
         & "lMoZIIgDll6e3vCYLocInmYWAmS6TlzAC8wEqKK6PBru3jl7A_yl95bQpu6cVPTpK"
         & "4Mqgkf1CXztLVBSt2Ks3oZwbuwXPXLWyouBWLVWGNWQexSgSxsj_Qulcy4a-fN");
   begin
      Check (Got = Want, "RFC 8291 example: got "
             & Soja.Base64.Encode (Got, True, False));
   end;

   declare
      Priv, Pub : Unbounded_String;
   begin
      Soja.Webpush.Generate_VAPID_Keys (Priv, Pub);
      Check (D (To_String (Priv))'Length = 32
             and then D (To_String (Pub))'Length = 65
             and then D (To_String (Pub)) (1) = Character'Val (4),
             "VAPID key sizes");
      declare
         H : constant String := Soja.Webpush.VAPID_Authorization
           ("https://push.example.com:8443/wpush/abc", "webpush@soju.im",
            To_String (Pub), To_String (Priv), 1_700_000_000);
         T : constant String := H (H'First + 8 .. H'First + 8 + 3);
      begin
         Check (H (H'First .. H'First + 7) = "vapid t="
                and then H (H'Last - To_String (Pub)'Length - 3 .. H'Last)
                         = ", k=" & To_String (Pub), "VAPID header: " & H);
         Check (T = "eyJh", "JWT header: " & T);   --  {"alg":
      end;
   end;
   Ada.Text_IO.Put_Line ("ALL PASS");
exception
   when E : others =>
      Ada.Text_IO.Put_Line
        ("FAILED: " & Ada.Exceptions.Exception_Information (E));
      GNAT.OS_Lib.OS_Exit (1);
end Webpush_Check;
