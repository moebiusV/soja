--  Soja.Certgen -- certfp.go's generateCertFP: a new client certificate
--  and its key, for SASL EXTERNAL (`certfp generate`), and the PEM form of
--  what is stored (DER, as soju stores it) that TLS libraries read.
--
--  The certificate is issued by the bracke-cryptolib X.509 code, with the TLS
--  client profile, for the common name "soju-auto-generated-certificate", valid
--  for 20 years.  Deviations from soju: it is issued by a certificate
--  authority made for the purpose and thrown away (cryptolib issues no
--  client-profile certificate that is self-signed; a server that checks the
--  certificate's fingerprint, as IRC servers do, does not look), ecdsa keys
--  are P-384 (cryptolib has no P-521), RSA keys are 2048, 3072 or 4096 bits
--  (not any size up to 8192), and the common name has hyphens where soju has
--  blanks (cryptolib refuses blanks).
pragma Ada_2022;

with Ada.Strings.Unbounded;

package Soja.Certgen is

   Generate_Error : exception;   --  Exception_Message says why

   --  generateCertFP: the PKCS#8 private key and the certificate, both DER.
   --  Key_Type is "rsa", "ecdsa" or "ed25519"; Bits is for rsa.
   procedure Generate
     (Key_Type    : String;
      Bits        : Positive;
      Private_Key : out Ada.Strings.Unbounded.Unbounded_String;
      Certificate : out Ada.Strings.Unbounded.Unbounded_String);

   --  DER in the PEM armour of Label ("CERTIFICATE", "PRIVATE KEY"), and back:
   --  the first block of the text.  Valid is False when there is none.
   function To_PEM (DER, Label : String) return String;
   function From_PEM
     (Text : String; Valid : out Boolean) return String;

   --  A TLS library reads files: the certificate and key (DER, as stored)
   --  written as PEM to one file in a new private directory (mode 0700, the
   --  file 0600), for Initialize's Client_Certificate.  Remove deletes both
   --  once the library has read them.
   type Client_File is record
      Dir  : Ada.Strings.Unbounded.Unbounded_String;
      Path : Ada.Strings.Unbounded.Unbounded_String;
   end record;

   function Write_Client_File (Cert_DER, Key_DER : String) return Client_File;
   procedure Remove (File : Client_File);

end Soja.Certgen;
