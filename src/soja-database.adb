pragma Ada_2022;

with Ada.Streams;
with CryptoLib.Bcrypt;
with CryptoLib.Errors;
with CryptoLib.OS_Random;

package body Soja.Database is

   use Ada.Strings.Unbounded;
   use Ada.Streams;

   Default_Cost : constant := 10;   -- bcrypt.DefaultCost

   --  The "zero" time, Go's time.Time{}: means "never"/"unset".
   Null_Time : constant Time := Ada.Calendar.Time_Of (1901, 1, 1, 0.0);

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
         Downstream_Interacted_At => Null_Time);
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

   function Check_Password (U : in out User; Password : String) return Boolean is
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

end Soja.Database;
