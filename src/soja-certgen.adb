pragma Ada_2022;

with Ada.Directories;
with Ada.Environment_Variables;
with Ada.Streams;
with Ada.Strings.Fixed;
with Ada.Text_IO;
with Interfaces.C;

with CryptoLib.Certificates;
with CryptoLib.Errors;
with CryptoLib.Random;
with CryptoLib.RSA;
with Soja.Base64;
with System;

package body Soja.Certgen is

   use Ada.Strings.Unbounded;
   use Ada.Streams;
   use type System.Address;

   Common_Name : constant String := "soju-auto-generated-certificate";

   --  Twenty years (soju: 24h * 365 * 20).
   Valid_Days : constant := 7300;

   LF : constant Character := ASCII.LF;

   function To_PEM (DER, Label : String) return String is
      Text   : constant String := Soja.Base64.Encode (DER);
      Result : Unbounded_String;
      I      : Natural := Text'First;
   begin
      Append (Result, "-----BEGIN " & Label & "-----" & LF);
      while I <= Text'Last loop
         declare
            Last : constant Natural := Natural'Min (I + 63, Text'Last);
         begin
            Append (Result, Text (I .. Last) & LF);
            I := Last + 1;
         end;
      end loop;
      Append (Result, "-----END " & Label & "-----" & LF);
      return To_String (Result);
   end To_PEM;

   --  The base64 between the first BEGIN line and its END line.
   function From_PEM
     (Text : String; Valid : out Boolean) return String
   is
      Begin_At : constant Natural :=
        Ada.Strings.Fixed.Index (Text, "-----BEGIN ");
      Body_At  : constant Natural :=
        (if Begin_At = 0 then 0
         else Ada.Strings.Fixed.Index (Text, "-----" & LF, Begin_At + 1));
      End_At   : constant Natural :=
        (if Body_At = 0 then 0
         else Ada.Strings.Fixed.Index (Text, "-----END ", Body_At));
   begin
      if Begin_At = 0 or else Body_At = 0 or else End_At = 0 then
         Valid := False;
         return "";
      end if;
      return Soja.Base64.Decode (Text (Body_At + 6 .. End_At - 1), Valid);
   end From_PEM;

   function To_Bytes (S : String) return Stream_Element_Array is
      R : Stream_Element_Array (1 .. Stream_Element_Offset (S'Length));
   begin
      for I in S'Range loop
         R (Stream_Element_Offset (I - S'First + 1)) :=
           Stream_Element (Character'Pos (S (I)));
      end loop;
      return R;
   end To_Bytes;

   --  The certificate and key cryptolib made, as DER.
   procedure Take
     (Cert_PEM, Key_PEM : String;
      Private_Key, Certificate : out Unbounded_String)
   is
      Cert_Ok, Key_Ok : Boolean;
      Cert : constant String := From_PEM (Cert_PEM, Cert_Ok);
      Key  : constant String := From_PEM (Key_PEM, Key_Ok);
   begin
      if not (Cert_Ok and then Key_Ok) then
         raise Generate_Error with "the certificate could not be encoded";
      end if;
      Certificate := To_Unbounded_String (Cert);
      Private_Key := To_Unbounded_String (Key);
   end Take;

   --  The certificate is issued by a CA made for the purpose and thrown away:
   --  the library's self-signed certificate has the CA profile (no
   --  digitalSignature, no client authentication), which a server that checks
   --  the purpose of a client certificate refuses, and an issued one has the
   --  client profile soju's has.
   --  (An empty list of names is refused; the common name is the one.)
   Names : constant CryptoLib.Certificates.Subject_Alternative_Name_List :=
     [1 => To_Unbounded_String (Common_Name)];

   procedure Make_CA
     (Algorithm : CryptoLib.Certificates.Generatable_Key_Algorithm;
      CA_Cert, CA_Key : out Unbounded_String)
   is
      use type CryptoLib.Certificates.Certificate_Status;
      Status : constant CryptoLib.Certificates.Certificate_Status :=
        CryptoLib.Certificates.Create_Local_CA
          ("soju-ephemeral-ca", CA_Cert, CA_Key, Algorithm, Valid_Days + 30);
   begin
      if Status /= CryptoLib.Certificates.Ok then
         raise Generate_Error with
           CryptoLib.Certificates.Status_Image (Status);
      end if;
   end Make_CA;

   procedure Generate_EC
     (Algorithm : CryptoLib.Certificates.Generatable_Key_Algorithm;
      Private_Key, Certificate : out Unbounded_String)
   is
      use type CryptoLib.Certificates.Certificate_Status;
      CA_Cert, CA_Key, Cert, Key : Unbounded_String;
   begin
      Make_CA (Algorithm, CA_Cert, CA_Key);
      declare
         Status : constant CryptoLib.Certificates.Certificate_Status :=
           CryptoLib.Certificates.Issue_Client_Certificate
             (To_String (CA_Cert), To_String (CA_Key), Common_Name, Names,
              Cert, Key, Valid_Days);
      begin
         if Status /= CryptoLib.Certificates.Ok then
            raise Generate_Error with
              CryptoLib.Certificates.Status_Image (Status);
         end if;
      end;
      Take (To_String (Cert), To_String (Key), Private_Key, Certificate);
   end Generate_EC;

   procedure Generate_RSA
     (Size : CryptoLib.RSA.Modulus_Size;
      Private_Key, Certificate : out Unbounded_String)
   is
      use type CryptoLib.Errors.Status;
      use type CryptoLib.Certificates.Certificate_Status;
      N   : constant Positive := CryptoLib.RSA.Modulus_Octets (Size);
      Rng : CryptoLib.Random.Random_Source;
      Modulus, D : Stream_Element_Array (1 .. Stream_Element_Offset (N));
      E          : Stream_Element_Array (1 .. 3);
      Half       : constant Stream_Element_Offset :=
        Stream_Element_Offset (N / 2);
      P, Q, EP, EQ, C : Stream_Element_Array (1 .. Half);
      CA_Cert, CA_Key, Cert : Unbounded_String;
   begin
      CryptoLib.Random.Initialize_Production (Rng);
      if CryptoLib.RSA.Generate_Keypair_With_Primes
           (Size, Rng, Modulus, E, D, P, Q, EP, EQ, C)
         /= CryptoLib.Errors.Ok
      then
         raise Generate_Error with "failed to generate an RSA key";
      end if;
      Make_CA (CryptoLib.Certificates.P256_Key, CA_Cert, CA_Key);
      declare
         Key_PEM : constant String :=
           CryptoLib.Certificates.RSA_Private_Key_PEM
             (Modulus, E, D, P, Q, EP, EQ, C);
         Spki    : constant String :=
           CryptoLib.Certificates.RSA_Public_Key_Info (Modulus, E);
         Status  : CryptoLib.Certificates.Certificate_Status;
      begin
         Status := CryptoLib.Certificates.Issue_Client_Certificate_For_Key
           (To_String (CA_Cert), To_String (CA_Key), Common_Name, Names,
            To_Bytes (Spki), Cert, Valid_Days);
         if Status /= CryptoLib.Certificates.Ok then
            raise Generate_Error with
              CryptoLib.Certificates.Status_Image (Status);
         end if;
         Take (To_String (Cert), Key_PEM, Private_Key, Certificate);
      end;
   end Generate_RSA;

   procedure Generate
     (Key_Type    : String;
      Bits        : Positive;
      Private_Key : out Unbounded_String;
      Certificate : out Unbounded_String)
   is
   begin
      if Key_Type = "ed25519" then
         Generate_EC (CryptoLib.Certificates.Ed25519_Key, Private_Key,
                      Certificate);
      elsif Key_Type = "ecdsa" then
         Generate_EC (CryptoLib.Certificates.P384_Key, Private_Key,
                      Certificate);
      elsif Key_Type = "rsa" then
         if Bits > 4096 then
            raise Generate_Error with
              "RSA keys of more than 4096 bits are not supported";
         end if;
         Generate_RSA
           ((if Bits <= 2048 then CryptoLib.RSA.RSA_2048
             elsif Bits <= 3072 then CryptoLib.RSA.RSA_3072
             else CryptoLib.RSA.RSA_4096),
            Private_Key, Certificate);
      else
         raise Generate_Error with "unknown key type";
      end if;
   end Generate;

   ----------------------------------------------------------------------
   --  The files a TLS library reads
   ----------------------------------------------------------------------

   function C_Mkdtemp (Template : in out Interfaces.C.char_array)
      return System.Address
     with Import, Convention => C, External_Name => "mkdtemp";

   function C_Chmod
     (Path : Interfaces.C.char_array; Mode : Interfaces.C.unsigned)
      return Interfaces.C.int
     with Import, Convention => C, External_Name => "chmod";

   function Write_Client_File
     (Cert_DER, Key_DER : String) return Client_File
   is
      Base     : constant String :=
        (if Ada.Environment_Variables.Exists ("TMPDIR")
         then Ada.Environment_Variables.Value ("TMPDIR") else "/tmp");
      Template : Interfaces.C.char_array :=
        Interfaces.C.To_C (Base & "/soja-cert-XXXXXX");
      Dir      : constant System.Address := C_Mkdtemp (Template);
      Dummy    : Interfaces.C.int;
      pragma Unreferenced (Dummy);
   begin
      if Dir = System.Null_Address then
         raise Generate_Error with "cannot make a private directory in "
           & Base;
      end if;
      declare
         Dir_Name : constant String := Interfaces.C.To_Ada (Template);
         Path     : constant String := Dir_Name & "/client.pem";
         File     : Ada.Text_IO.File_Type;
      begin
         Ada.Text_IO.Create (File, Ada.Text_IO.Out_File, Path);
         Dummy := C_Chmod (Interfaces.C.To_C (Path), 8#600#);
         Ada.Text_IO.Put (File, To_PEM (Cert_DER, "CERTIFICATE")
                          & To_PEM (Key_DER, "PRIVATE KEY"));
         Ada.Text_IO.Close (File);
         return (Dir => To_Unbounded_String (Dir_Name),
                 Path => To_Unbounded_String (Path));
      end;
   end Write_Client_File;

   procedure Remove (File : Client_File) is
   begin
      if Length (File.Dir) > 0 then
         Ada.Directories.Delete_Tree (To_String (File.Dir));
      end if;
   exception
      when others => null;
   end Remove;

end Soja.Certgen;
