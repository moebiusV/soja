pragma Ada_2022;

with Ada.Calendar;
with Ada.Streams; use Ada.Streams;
with Ada.Strings.Fixed;

with AWS.Client;
with AWS.Headers;
with AWS.Messages;
with AWS.Response;

with CryptoLib.Ciphers;
with CryptoLib.ECDH;
with CryptoLib.ECDSA;
with CryptoLib.EC_Curves;
with CryptoLib.Errors;
with CryptoLib.HKDF;
with CryptoLib.Random;

with Soja.Base64;
with Soja.Tls_Default;
with Soja.Url;

package body Soja.Webpush is

   use Ada.Strings.Unbounded;
   use type CryptoLib.Errors.Status;

   function Bytes (S : String) return Stream_Element_Array is
      R : Stream_Element_Array (1 .. Stream_Element_Offset (S'Length));
   begin
      for I in S'Range loop
         R (Stream_Element_Offset (I - S'First + 1)) :=
           Stream_Element (Character'Pos (S (I)));
      end loop;
      return R;
   end Bytes;

   function Text (B : Stream_Element_Array) return String is
      R : String (1 .. B'Length);
   begin
      for I in B'Range loop
         R (Integer (I - B'First) + 1) := Character'Val (B (I));
      end loop;
      return R;
   end Text;

   procedure Check (S : CryptoLib.Errors.Status; What : String) is
   begin
      if S /= CryptoLib.Errors.Ok then
         raise Webpush_Error with
           What & ": " & CryptoLib.Errors.Status'Image (S);
      end if;
   end Check;

   function B64 (S : String) return String is
     (Soja.Base64.Encode (S, URL_Safe => True, Padded => False));

   --  decodeSubscriptionKey: any of the four base64 forms.
   function Decode_Key (S : String; Valid : out Boolean) return String is
   begin
      for URL in Boolean loop
         for Padded in Boolean loop
            declare
               V : Boolean;
               R : constant String :=
                 Soja.Base64.Decode (S, V, URL_Safe => URL, Padded => Padded);
            begin
               if V then
                  Valid := True;
                  return R;
               end if;
            end;
         end loop;
      end loop;
      Valid := False;
      return "";
   end Decode_Key;

   ----------------------------------------------------------------------
   --  VAPID keys
   ----------------------------------------------------------------------

   procedure Generate_VAPID_Keys
     (Private_Key, Public_Key : out Unbounded_String)
   is
      Rng  : CryptoLib.Random.Random_Source;
      Priv : Stream_Element_Array (1 .. 32);
      Pub  : Stream_Element_Array (1 .. 65);
   begin
      CryptoLib.Random.Initialize_Production (Rng);
      Check (CryptoLib.ECDSA.Generate_Nistp256_Keypair (Rng, Priv, Pub),
             "failed to generate a VAPID key pair");
      Private_Key := To_Unbounded_String (B64 (Text (Priv)));
      Public_Key := To_Unbounded_String (B64 (Text (Pub)));
   end Generate_VAPID_Keys;

   ----------------------------------------------------------------------
   --  RFC 8291
   ----------------------------------------------------------------------

   function Encrypt
     (Payload     : String;
      UA_Public   : String;
      Auth_Secret : String;
      Salt        : String;
      AS_Private  : String;
      Record_Size : Positive) return String
   is
      AS_Public : Stream_Element_Array (1 .. 65);
      Shared    : Stream_Element_Array (1 .. 32);
      PRK_Key   : Stream_Element_Array (1 .. 32);
      IKM       : Stream_Element_Array (1 .. 32);
      PRK       : Stream_Element_Array (1 .. 32);
      CEK       : Stream_Element_Array (1 .. 16);
      Nonce     : Stream_Element_Array (1 .. 12);
   begin
      if UA_Public'Length /= 65 or else Salt'Length /= 16
        or else AS_Private'Length /= 32
      then
         raise Webpush_Error with "bad key or salt length";
      end if;
      if Payload'Length + 1 + 16 > Record_Size then
         raise Webpush_Error with "message too large for the record size";
      end if;

      Check (CryptoLib.ECDH.Public_Key
               (CryptoLib.ECDH.Curve_Id'(CryptoLib.EC_Curves.Nistp256),
                Bytes (AS_Private), AS_Public), "public key");
      Check (CryptoLib.ECDH.Shared_Secret
               (CryptoLib.EC_Curves.Nistp256, Bytes (AS_Private),
                Bytes (UA_Public), Shared), "invalid subscription key");

      declare
         Info : constant String :=
           "WebPush: info" & ASCII.NUL & UA_Public & Text (AS_Public);
      begin
         Check (CryptoLib.HKDF.Extract
                  (CryptoLib.HKDF.SHA256, Bytes (Auth_Secret), Shared,
                   PRK_Key), "HKDF");
         Check (CryptoLib.HKDF.Expand
                  (CryptoLib.HKDF.SHA256, PRK_Key, Bytes (Info), IKM), "HKDF");
      end;
      Check (CryptoLib.HKDF.Extract
               (CryptoLib.HKDF.SHA256, Bytes (Salt), IKM, PRK), "HKDF");
      Check (CryptoLib.HKDF.Expand
               (CryptoLib.HKDF.SHA256, PRK,
                Bytes ("Content-Encoding: aes128gcm" & ASCII.NUL), CEK),
             "HKDF");
      Check (CryptoLib.HKDF.Expand
               (CryptoLib.HKDF.SHA256, PRK,
                Bytes ("Content-Encoding: nonce" & ASCII.NUL), Nonce),
             "HKDF");

      declare
         --  (the delimiter of the last record follows the message)
         Plain  : constant Stream_Element_Array :=
           Bytes (Payload & Character'Val (2));
         Tag    : constant Stream_Element_Offset :=
           Stream_Element_Offset (CryptoLib.Ciphers.AES_GCM_Tag_Length);
         Sealed : Stream_Element_Array (1 .. Plain'Length + Tag);
         RS     : constant Natural := Record_Size;
      begin
         Check (CryptoLib.Ciphers.Seal_AEAD
                  ("aes128-gcm@openssh.com", CEK, Nonce, [1 .. 0 => 0], Plain,
                   Sealed), "encryption");
         return Salt
           & Character'Val (RS / 2 ** 24)
           & Character'Val (RS / 2 ** 16 mod 256)
           & Character'Val (RS / 256 mod 256)
           & Character'Val (RS mod 256) & Character'Val (65)
           & Text (AS_Public) & Text (Sealed);
      end;
   end Encrypt;

   ----------------------------------------------------------------------
   --  RFC 8292
   ----------------------------------------------------------------------

   function VAPID_Authorization
     (Endpoint    : String;
      Subscriber  : String;
      Public_Key  : String;
      Private_Key : String;
      Now         : Long_Long_Integer) return String
   is
      Parts : Soja.Url.Parts;
      Ok    : Boolean;
      Valid : Boolean;
      D     : constant String := Decode_Key (Private_Key, Valid);
   begin
      Soja.Url.Parse (Endpoint, Parts, Ok);
      if not Ok then
         raise Webpush_Error with "invalid endpoint URL";
      end if;
      if not Valid or else D'Length /= 32 then
         raise Webpush_Error with "invalid VAPID private key";
      end if;
      declare
         Host : constant String := To_String (Parts.Host);
         Aud  : constant String :=
           To_String (Parts.Scheme) & "://"
           & (if Ada.Strings.Fixed.Index (Host, ":") > 0
              then "[" & Host & "]" else Host)
           & (if Length (Parts.Port) > 0 then ":" & To_String (Parts.Port)
              else "");
         Sub  : constant String :=
           (if Subscriber'Length >= 8
              and then Subscriber (Subscriber'First .. Subscriber'First + 7)
                       = "https://"
            then Subscriber else "mailto:" & Subscriber);
         Claims : constant String :=
           "{""aud"":""" & Aud & """,""exp"":"
           & Ada.Strings.Fixed.Trim
               (Long_Long_Integer'Image (Now + 12 * 3600), Ada.Strings.Left)
           & ",""sub"":""" & Sub & """}";
         Signing : constant String :=
           B64 ("{""alg"":""ES256"",""typ"":""JWT""}") & "." & B64 (Claims);
         R, S : Stream_Element_Array (1 .. 32);
      begin
         Check (CryptoLib.ECDSA.Sign_Nistp256_Raw
                  (Bytes (D), Bytes (Signing), R, S), "JWT signature");
         return "vapid t=" & Signing & "." & B64 (Text (R) & Text (S))
           & ", k=" & Public_Key;
      end;
   end VAPID_Authorization;

   ----------------------------------------------------------------------
   --  SendNotification
   ----------------------------------------------------------------------

   function Send
     (Endpoint    : String;
      Auth        : String;
      P256DH      : String;
      VAPID_Pub   : String;
      VAPID_Priv  : String;
      Payload     : String;
      Priority    : Urgency;
      Record_Size : Positive := 2048;
      TTL         : Natural := 604_800;
      Subscriber  : String := "webpush@soju.im") return Natural
   is
      Rng      : CryptoLib.Random.Random_Source;
      Salt     : Stream_Element_Array (1 .. 16);
      AS_Priv  : Stream_Element_Array (1 .. 32);
      AS_Pub   : Stream_Element_Array (1 .. 65);
      Auth_Ok, Key_Ok : Boolean;
      Auth_Secret : constant String := Decode_Key (Auth, Auth_Ok);
      UA_Key      : constant String := Decode_Key (P256DH, Key_Ok);
      Epoch    : constant Ada.Calendar.Time :=
        Ada.Calendar.Time_Of (1970, 1, 1);
      Elapsed  : constant Duration :=
        Ada.Calendar."-" (Ada.Calendar.Clock, Epoch);
      Now      : constant Long_Long_Integer := Long_Long_Integer (Elapsed);
   begin
      if not Auth_Ok or else not Key_Ok then
         raise Webpush_Error with "invalid subscription keys";
      end if;
      CryptoLib.Random.Initialize_Production (Rng);
      Check (CryptoLib.Random.Fill (Rng, Salt), "random salt");
      Check (CryptoLib.ECDH.Generate_Keypair
               (CryptoLib.EC_Curves.Nistp256, Rng, AS_Priv, AS_Pub),
             "ephemeral key");
      declare
         Body_Text : constant String :=
           Encrypt (Payload, UA_Key, Auth_Secret, Text (Salt), Text (AS_Priv),
                    Record_Size);
         Headers   : AWS.Headers.List;
      begin
         Soja.Tls_Default.Ensure;
         AWS.Headers.Add (Headers, "Content-Encoding", "aes128gcm");
         AWS.Headers.Add
           (Headers, "TTL",
            Ada.Strings.Fixed.Trim (Natural'Image (TTL), Ada.Strings.Left));
         AWS.Headers.Add
           (Headers, "Urgency",
            (if Priority = High then "high" else "normal"));
         AWS.Headers.Add
           (Headers, "Authorization",
            VAPID_Authorization
              (Endpoint, Subscriber, VAPID_Pub, VAPID_Priv, Now));
         declare
            Response : constant AWS.Response.Data := AWS.Client.Post
              (Endpoint, Body_Text,
               Content_Type => "application/octet-stream",
               Headers      => Headers,
               User_Agent   => "soju",
               Timeouts     => AWS.Client.Timeouts (Each => 15.0));
         begin
            return Natural'Value
              (AWS.Messages.Image (AWS.Response.Status_Code (Response)));
         end;
      end;
   end Send;

end Soja.Webpush;
