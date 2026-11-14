pragma Ada_2022;

with Ada.Calendar;
with Ada.Characters.Handling;
with Ada.Streams; use Ada.Streams;
with Ada.Strings.Fixed;

with GNAT.Sockets;

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
   --  Endpoints
   ----------------------------------------------------------------------

   function Endpoint_Is_Acceptable (Endpoint : String) return Boolean is
      Parts : Soja.Url.Parts;
      Ok    : Boolean;
   begin
      Soja.Url.Parse (Endpoint, Parts, Ok);
      return Ok and then (To_String (Parts.Scheme) = "https"
                          or else Allow_Internal_Endpoints);
   end Endpoint_Is_Acceptable;

   function Is_Internal_Address (Address : String) return Boolean is
      --  The four octets of a dotted address, or False.
      procedure Split4 (Text : String; A, B, C, D : out Natural;
                        Ok : out Boolean)
      is
         Values : array (1 .. 4) of Natural := [others => 0];
         N      : Natural := 1;
         Digits_Seen : Natural := 0;
      begin
         Ok := False;
         A := 0; B := 0; C := 0; D := 0;
         for Ch of Text loop
            if Ch in '0' .. '9' then
               Values (N) := Values (N) * 10
                 + (Character'Pos (Ch) - Character'Pos ('0'));
               Digits_Seen := Digits_Seen + 1;
               if Values (N) > 255 then
                  return;
               end if;
            elsif Ch = '.' and then Digits_Seen > 0 and then N < 4 then
               N := N + 1;
               Digits_Seen := 0;
            else
               return;
            end if;
         end loop;
         if N = 4 and then Digits_Seen > 0 then
            A := Values (1); B := Values (2); C := Values (3); D := Values (4);
            Ok := True;
         end if;
      end Split4;

      function Internal_V4 (A, B : Natural) return Boolean is
        (A = 127 or else A = 0 or else A in 224 .. 239
         or else A = 10 or else (A = 172 and then B in 16 .. 31)
         or else (A = 192 and then B = 168)
         or else (A = 169 and then B = 254));

      A, B, C, D : Natural;
      Ok         : Boolean;
      Lower      : constant String :=
        Ada.Characters.Handling.To_Lower (Address);
   begin
      Split4 (Address, A, B, C, D, Ok);
      if Ok then
         return Internal_V4 (A, B);
      end if;

      --  IPv6.  ::ffff:a.b.c.d is the IPv4 address a.b.c.d.
      if Lower'Length > 7 and then Lower (Lower'First .. Lower'First + 6)
                                     = "::ffff:"
      then
         Split4 (Lower (Lower'First + 7 .. Lower'Last), A, B, C, D, Ok);
         if Ok then
            return Internal_V4 (A, B);
         end if;
      end if;
      if Lower = "::" or else Lower = "::1" then
         return True;
      end if;
      if Lower'Length >= 2 then
         declare
            First : constant String := Lower (Lower'First .. Lower'First + 1);
         begin
            --  fc00::/7 (private), fe80::/10 (link-local), ff00::/8
            --  (multicast).
            if First in "fc" | "fd" | "ff" then
               return True;
            end if;
         end;
      end if;
      if Lower'Length >= 3 and then Lower (Lower'First .. Lower'First + 1)
                                       = "fe"
        and then Lower (Lower'First + 2) in '8' | '9' | 'a' | 'b'
      then
         return True;
      end if;
      return False;
   end Is_Internal_Address;

   --  A push goes to external addresses only: otherwise a client could make
   --  the bouncer send requests to the machine's own services (0b76d2d,
   --  a5d11bd).  The name is looked up here, and every address it has must be
   --  external; the connection then looks the name up again, which leaves the
   --  window of a name that changes in between (soju checks the address it
   --  connects to).
   procedure Require_External (Endpoint : String) is
      Parts : Soja.Url.Parts;
      Ok    : Boolean;
   begin
      if Allow_Internal_Endpoints then
         return;
      end if;
      Soja.Url.Parse (Endpoint, Parts, Ok);
      if not Ok or else To_String (Parts.Scheme) /= "https" then
         raise Webpush_Error with "the endpoint must be an https URL";
      end if;
      declare
         Entry_Of : constant GNAT.Sockets.Host_Entry_Type :=
           GNAT.Sockets.Get_Host_By_Name (To_String (Parts.Host));
      begin
         for I in 1 .. GNAT.Sockets.Addresses_Length (Entry_Of) loop
            if Is_Internal_Address
                 (GNAT.Sockets.Image (GNAT.Sockets.Addresses (Entry_Of, I)))
            then
               raise Webpush_Error with
                 "refusing to send to an internal IP address";
            end if;
         end loop;
      exception
         when GNAT.Sockets.Host_Error =>
            raise Webpush_Error with "could not resolve the endpoint's host";
      end;
   end Require_External;

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
      Subscriber  : String := "https://soju.im") return Natural
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
      Require_External (Endpoint);
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
