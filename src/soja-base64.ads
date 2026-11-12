pragma Ada_2022;

--  encoding/base64: the standard and URL-safe alphabets, with or without
--  '=' padding (StdEncoding, URLEncoding, RawStdEncoding, RawURLEncoding).
--  bracke-cryptolib's CryptoLib.Base64 is a private child and unpadded, so
--  soja carries its own.  Data are byte strings (Ada String, one octet per
--  character).
package Soja.Base64 is

   function Encode
     (Data     : String;
      URL_Safe : Boolean := False;
      Padded   : Boolean := True) return String;

   --  Decode as Go's DecodeString does: CR and LF are ignored; padding must
   --  be present and correct when Padded, absent otherwise; trailing bits of
   --  the last group are not required to be zero.  Valid is False (and the
   --  result empty) on bad input.
   function Decode
     (Text     : String;
      Valid    : out Boolean;
      URL_Safe : Boolean := False;
      Padded   : Boolean := True) return String;

end Soja.Base64;
