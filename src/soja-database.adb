pragma Ada_2022;

with Ada.Streams;
with CryptoLib.Bcrypt;
with CryptoLib.Errors;
with CryptoLib.OS_Random;

package body Soja.Database is

   use Ada.Strings.Unbounded;
   use Ada.Streams;

   Default_Cost : constant := 10;   -- bcrypt.DefaultCost

   function To_Bytes (S : String) return Stream_Element_Array is
      R : Stream_Element_Array (1 .. S'Length);
   begin
      for I in S'Range loop
         R (Stream_Element_Offset (I - S'First + 1)) :=
           Stream_Element (Character'Pos (S (I)));
      end loop;
      return R;
   end To_Bytes;

   --  bcrypt.Cost: the cost factor encoded in a "$2b$10$..." hash.
   function Parse_Cost (Hash : String) return Natural is
      D1, D2 : Character;
   begin
      if Hash'Length < 7 then
         raise Database_Error with "invalid password cost";
      end if;
      D1 := Hash (Hash'First + 4);
      D2 := Hash (Hash'First + 5);
      if D1 not in '0' .. '9' or else D2 not in '0' .. '9' then
         raise Database_Error with "invalid password cost";
      end if;
      return (Character'Pos (D1) - Character'Pos ('0')) * 10
        + (Character'Pos (D2) - Character'Pos ('0'));
   end Parse_Cost;

   ---------
   -- New_User --
   ---------

   function Strip_ANSI (S : String) return String is
      R : Unbounded_String;
      I : Natural := S'First;

      function Digit (At_I : Natural) return Boolean is
        (At_I <= S'Last and then S (At_I) in '0' .. '9');

      --  startsHexColor: six hex digits from From.
      function Starts_Hex_Color (From : Natural) return Boolean is
      begin
         if From + 5 > S'Last then
            return False;
         end if;
         return (for all K in From .. From + 5 =>
                   S (K) in '0' .. '9' | 'a' .. 'f' | 'A' .. 'F');
      end Starts_Hex_Color;
   begin
      if (for all C of S => C not in
            ASCII.STX | Character'Val (16#1D#) | Character'Val (16#1F#)
            | Character'Val (16#1E#) | Character'Val (16#11#)
            | Character'Val (16#16#) | Character'Val (16#0F#)
            | ASCII.ETX | ASCII.EOT)
      then
         return S;
      end if;

      while I <= S'Last loop
         case S (I) is
            when ASCII.STX | Character'Val (16#1D#) | Character'Val (16#1F#)
               | Character'Val (16#1E#) | Character'Val (16#11#)
               | Character'Val (16#16#) | Character'Val (16#0F#) =>
               null;
            when ASCII.ETX =>
               if Digit (I + 1) then
                  I := I + 1;
                  if Digit (I + 1) then
                     I := I + 1;
                  end if;
                  if I + 2 <= S'Last and then S (I + 1) = ','
                    and then Digit (I + 2)
                  then
                     I := I + 2;
                     if Digit (I + 1) then
                        I := I + 1;
                     end if;
                  end if;
               end if;
            when ASCII.EOT =>
               if Starts_Hex_Color (I + 1) then
                  I := I + 6;
                  if I + 1 <= S'Last and then S (I + 1) = ','
                    and then Starts_Hex_Color (I + 2)
                  then
                     I := I + 7;
                  end if;
               end if;
            when others =>
               Append (R, S (I));
         end case;
         I := I + 1;
      end loop;
      return To_String (R);
   end Strip_ANSI;

   function New_User (Username : String) return User is
   begin
      return User'
        (ID                       => 0,
         Username                 => To_Unbounded_String (Username),
         Password                 => Null_Unbounded_String,
         Nick                     => Null_Unbounded_String,
         Realname                 => Null_Unbounded_String,
         Admin                    => False,
         Enabled                  => True,
         Downstream_Interacted_At => Null_Time,
         Max_Networks             => -1);
   end New_User;

   ---------
   -- Set_Password --
   ---------

   procedure Set_Password (U : in out User; Password : String) is
      Pw     : Stream_Element_Array (1 .. Password'Length);
      Salt   : CryptoLib.Bcrypt.Salt;
      Result : CryptoLib.Bcrypt.Hash_String;
      OK     : Boolean;
   begin
      Pw := To_Bytes (Password);

      CryptoLib.OS_Random.Fill_OS (Salt, OK);
      if not OK then
         raise Database_Error with "no OS entropy available";
      end if;

      if not CryptoLib.Errors.Is_Success
        (CryptoLib.Bcrypt.Hash (Pw, Salt, Default_Cost, Result))
      then
         raise Database_Error with "failed to hash password";
      end if;

      U.Password := To_Unbounded_String (Result);
   end Set_Password;

   ---------
   -- Check_Password --
   ---------

   function Check_Password (U : in out User; Password : String) return Boolean
     is
      Stored : constant String := To_String (U.Password);
      Pw     : Stream_Element_Array (1 .. Password'Length);
   begin
      if Stored = "" then
         raise Database_Error with "password auth disabled";
      end if;

      Pw := To_Bytes (Password);

      if not CryptoLib.Bcrypt.Verify (Pw, Stored) then
         raise Database_Error with "wrong password";
      end if;

      if Parse_Cost (Stored) < Default_Cost then
         Set_Password (U, Password);
         return True;
      end if;
      return False;
   end Check_Password;

   ---------
   -- New_Network --
   ---------

   function New_Network (Addr : String) return Network is
   begin
      return Network'
        (ID               => 0,
         Name             => Null_Unbounded_String,
         Addr             => To_Unbounded_String (Addr),
         Nick             => Null_Unbounded_String,
         Username         => Null_Unbounded_String,
         Realname         => Null_Unbounded_String,
         Pass             => Null_Unbounded_String,
         Connect_Commands => Connect_Command_Vectors.Empty_Vector,
         Cert_FP          => Null_Unbounded_String,
         SASL             => (others => <>),
         Auto_Away        => True,
         Enabled          => True);
   end New_Network;

   ---------
   -- Get_Name --
   ---------

   function Get_Name (Net : Network) return String is
   begin
      if Net.Name /= Null_Unbounded_String then
         return To_String (Net.Name);
      end if;
      return To_String (Net.Addr);
   end Get_Name;

   ---------
   -- Get_Nick / Get_Username / Get_Realname --
   ---------

   function Get_Nick (U : User; Net : Network) return String is
   begin
      if Net.Nick /= Null_Unbounded_String then
         return To_String (Net.Nick);
      end if;
      if U.Nick /= Null_Unbounded_String then
         return To_String (U.Nick);
      end if;
      return To_String (U.Username);
   end Get_Nick;

   function Get_Username (U : User; Net : Network) return String is
   begin
      if Net.Username /= Null_Unbounded_String then
         return To_String (Net.Username);
      end if;
      return Get_Nick (U, Net);
   end Get_Username;

   function Get_Realname (U : User; Net : Network) return String is
   begin
      if Net.Realname /= Null_Unbounded_String then
         return To_String (Net.Realname);
      end if;
      if U.Realname /= Null_Unbounded_String then
         return To_String (U.Realname);
      end if;
      return Get_Nick (U, Net);
   end Get_Realname;

   ---------
   -- URL --
   ---------

   function URL (Net : Network) return Network_URL is
      Addr   : Unbounded_String := Net.Addr;
      Scheme : Unbounded_String;
      Host   : Unbounded_String;
      Path   : Unbounded_String;
      Sep    : Natural;
      Slash  : Natural;
      Rest   : Unbounded_String;
   begin
      if Index (Addr, "://") = 0 then
         Addr := "ircs://" & Addr;
      end if;

      Sep := Index (Addr, "://");
      Scheme := Head (Addr, Sep - 1);
      Rest := Tail (Addr, Length (Addr) - (Sep + 2));

      if Length (Rest) > 0 and then Element (Rest, 1) = '/' then
         --  No host (e.g. "irc+unix:///path").
         Host := Null_Unbounded_String;
         Path := Rest;
      else
         Slash := Index (Rest, "/");
         if Slash = 0 then
            Host := Rest;
            Path := Null_Unbounded_String;
         else
            Host := Head (Rest, Slash - 1);
            Path := Tail (Rest, Length (Rest) - (Slash - 1));
         end if;
      end if;

      return (Scheme => Scheme, Host => Host, Path => Path);
   end URL;

end Soja.Database;
