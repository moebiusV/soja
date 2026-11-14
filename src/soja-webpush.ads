--  Soja.Webpush -- Web Push (RFC 8030) as soju's webpush-go uses it: VAPID
--  (RFC 8292) key pairs and authorization, and message encryption with the
--  aes128gcm content coding (RFC 8188, RFC 8291).  Keys are carried as
--  webpush-go carries them: base64url without padding (the VAPID private key
--  is the P-256 scalar, the public key the uncompressed point).
pragma Ada_2022;

with Ada.Strings.Unbounded;

package Soja.Webpush is

   Webpush_Error : exception;   --  Exception_Message says why

   --  The key pair of GenerateVAPIDKeys.
   procedure Generate_VAPID_Keys
     (Private_Key, Public_Key : out Ada.Strings.Unbounded.Unbounded_String);

   --  The body of the push message: the aes128gcm coding of Payload for the
   --  user agent with the (65 byte) public key UA_Public and the
   --  authentication secret Auth_Secret, from the 16 byte Salt and the
   --  application server's
   --  key (32 byte private scalar AS_Private).  All are octet strings.
   --  Record_Size is the rs field.
   function Encrypt
     (Payload     : String;
      UA_Public   : String;
      Auth_Secret : String;
      Salt        : String;
      AS_Private  : String;
      Record_Size : Positive) return String;

   --  The Authorization header's value for a request to Endpoint:
   --  "vapid t=<JWT>, k=<public key>".  Now is the Unix time.
   function VAPID_Authorization
     (Endpoint    : String;
      Subscriber  : String;
      Public_Key  : String;
      Private_Key : String;
      Now         : Long_Long_Integer) return String;

   --  Test hook: with it set, an endpoint may be plain http and on an
   --  internal address (soja's end-to-end test pushes to a server on
   --  localhost).  The daemon sets it from the environment variable
   --  SOJA_WEBPUSH_TEST; it is off otherwise.
   Allow_Internal_Endpoints : Boolean := False;

   --  sanityCheckWebPushEndpoint: Ok is False unless the endpoint is an
   --  https URL.
   function Endpoint_Is_Acceptable (Endpoint : String) return Boolean;

   --  isInternalIP: whether a numeric address is loopback, unspecified,
   --  multicast, private or link-local (an IPv4 address inside an IPv6 one
   --  counts as the IPv4 address).
   function Is_Internal_Address (Address : String) return Boolean;

   type Urgency is (Normal, High);

   --  SendNotification: encrypts Payload for the subscription and POSTs it to
   --  its endpoint (15 s at most).  Result is the HTTP status; Webpush_Error
   --  for what stops before there is one.
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
      Subscriber  : String := "https://soju.im") return Natural;

end Soja.Webpush;
