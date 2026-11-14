pragma Ada_2022;

with Ada.Directories;
with Ada.Exceptions;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;
with Ada.Text_IO;
with GNAT.OS_Lib;

with Soja.Certgen;

--  certfp's generated certificates: the DER that is stored, its PEM form and
--  the file a TLS library reads.
procedure Certgen_Check is

   procedure Check (Cond : Boolean; What : String) is
   begin
      if not Cond then
         raise Program_Error with What;
      end if;
   end Check;

   --  A DER SEQUENCE: tag 0x30 then a length.
   function Is_Sequence (DER : String) return Boolean is
     (DER'Length > 4 and then Character'Pos (DER (DER'First)) = 16#30#);

   procedure Try (Kind : String; Bits : Positive) is
      Key, Cert : Unbounded_String;
   begin
      Soja.Certgen.Generate (Kind, Bits, Key, Cert);
      Check (Is_Sequence (To_String (Cert)) and then Length (Cert) > 100,
             Kind & ": the certificate is DER");
      Check (Is_Sequence (To_String (Key)) and then Length (Key) > 30,
             Kind & ": the key is DER");
      --  Its common name is in the certificate.
      Check (Ada.Strings.Fixed.Index
               (To_String (Cert), "soju-auto-generated-certificate") > 0,
             Kind & ": the common name");
      --  PEM and back.
      declare
         Pem : constant String := Soja.Certgen.To_PEM (To_String (Cert),
                                                        "CERTIFICATE");
         Ok  : Boolean;
      begin
         Check (Ada.Strings.Fixed.Index (Pem, "-----BEGIN CERTIFICATE-----") = 1
                and then Ada.Strings.Fixed.Index
                           (Pem, "-----END CERTIFICATE-----") > 0,
                Kind & ": PEM armour");
         Check (Soja.Certgen.From_PEM (Pem, Ok) = To_String (Cert) and then Ok,
                Kind & ": PEM round trip");
      end;
      --  The file a TLS library reads: both blocks, in a private directory.
      declare
         File : constant Soja.Certgen.Client_File :=
           Soja.Certgen.Write_Client_File (To_String (Cert), To_String (Key));
         Path : constant String := To_String (File.Path);
         F    : Ada.Text_IO.File_Type;
         Text : Unbounded_String;
      begin
         Check (Ada.Directories.Exists (Path), Kind & ": the file exists");
         Ada.Text_IO.Open (F, Ada.Text_IO.In_File, Path);
         while not Ada.Text_IO.End_Of_File (F) loop
            Append (Text, Ada.Text_IO.Get_Line (F) & ASCII.LF);
         end loop;
         Ada.Text_IO.Close (F);
         Check (Ada.Strings.Fixed.Index (To_String (Text), "BEGIN CERTIFICATE") > 0
                and then Ada.Strings.Fixed.Index
                           (To_String (Text), "BEGIN PRIVATE KEY") > 0,
                Kind & ": certificate and key in the file");
         Soja.Certgen.Remove (File);
         Check (not Ada.Directories.Exists (Path)
                and then not Ada.Directories.Exists (To_String (File.Dir)),
                Kind & ": removed");
      end;
   end Try;

   Raised : Boolean := False;
begin
   Try ("ed25519", 3072);
   Try ("ecdsa", 3072);
   Try ("rsa", 2048);
   begin
      Try ("rsa", 8192);
   exception
      when Soja.Certgen.Generate_Error => Raised := True;
   end;
   Check (Raised, "RSA over 4096 bits is refused");
   Raised := False;
   begin
      Try ("dsa", 1024);
   exception
      when Soja.Certgen.Generate_Error => Raised := True;
   end;
   Check (Raised, "an unknown key type is refused");
   Ada.Text_IO.Put_Line ("ALL PASS");
exception
   when E : others =>
      Ada.Text_IO.Put_Line
        ("FAILED: " & Ada.Exceptions.Exception_Information (E));
      GNAT.OS_Lib.OS_Exit (1);
end Certgen_Check;
