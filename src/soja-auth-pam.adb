pragma Ada_2022;

with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;
with Ada.Strings.Fixed;
with Ada.Unchecked_Conversion;
with Interfaces.C;
with Interfaces.C.Strings;
with System;

package body Soja.Auth.Pam is

   use Interfaces.C;
   use type System.Address;
   use type Interfaces.C.Strings.chars_ptr;

   package CS renames Interfaces.C.Strings;

   ----------------------------------------------------------------------
   --  libc
   ----------------------------------------------------------------------

   RTLD_NOW : constant int := 2;

   function dlopen (Name : CS.chars_ptr; Flags : int) return System.Address
     with Import, Convention => C, External_Name => "dlopen";
   function dlsym (Handle : System.Address; Name : CS.chars_ptr)
     return System.Address
     with Import, Convention => C, External_Name => "dlsym";
   function calloc (N, Size : size_t) return System.Address
     with Import, Convention => C, External_Name => "calloc";
   function strdup (S : CS.chars_ptr) return CS.chars_ptr
     with Import, Convention => C, External_Name => "strdup";

   function To_Address is new Ada.Unchecked_Conversion
     (CS.chars_ptr, System.Address);
   function To_Chars is new Ada.Unchecked_Conversion
     (System.Address, CS.chars_ptr);

   ----------------------------------------------------------------------
   --  PAM's types (security/_pam_types.h)
   ----------------------------------------------------------------------

   type Message is record
      Style : int;
      Text  : System.Address;
   end record
     with Convention => C;
   type Message_Access is access all Message with Convention => C;

   type Message_Pointers is array (Natural range 0 .. 1023) of Message_Access
     with Convention => C;
   type Messages_Access is access all Message_Pointers with Convention => C;

   type Response is record
      Text : CS.chars_ptr;
      Code : int;
   end record
     with Convention => C;

   type Responses is array (Natural range 0 .. 1023) of Response
     with Convention => C;
   type Responses_Access is access all Responses with Convention => C;
   type Responses_Out is access all Responses_Access with Convention => C;

   function Converse
     (Count : int;
      Msgs  : Messages_Access;
      Resp  : Responses_Out;
      Data  : System.Address) return int
     with Convention => C;

   type Conversation is record
      Func : System.Address;
      Data : System.Address;
   end record
     with Convention => C;

   PAM_PROMPT_ECHO_OFF : constant := 1;
   PAM_PROMPT_ECHO_ON  : constant := 2;
   PAM_ERROR_MSG       : constant := 3;
   PAM_TEXT_INFO       : constant := 4;
   PAM_SUCCESS         : constant := 0;
   PAM_CONV_ERR        : constant := 19;
   PAM_USER            : constant := 2;

   function Converse
     (Count : int;
      Msgs  : Messages_Access;
      Resp  : Responses_Out;
      Data  : System.Address) return int
   is
      function To_Responses is new Ada.Unchecked_Conversion
        (System.Address, Responses_Access);
      Raw : System.Address;
      Out_Array : Responses_Access;
      Empty : CS.chars_ptr := CS.New_String ("");
   begin
      if Count <= 0 or else Count > 1024 then
         return PAM_CONV_ERR;
      end if;
      Raw := calloc (size_t (Count), (Response'Size + 7) / 8);
      if Raw = System.Null_Address then
         return PAM_CONV_ERR;
      end if;
      Out_Array := To_Responses (Raw);
      for I in 0 .. Natural (Count) - 1 loop
         case Msgs (I).Style is
            when PAM_PROMPT_ECHO_OFF =>
               Out_Array (I).Text := strdup (To_Chars (Data));
            when PAM_PROMPT_ECHO_ON | PAM_ERROR_MSG | PAM_TEXT_INFO =>
               Out_Array (I).Text := strdup (Empty);
            when others =>
               CS.Free (Empty);
               return PAM_CONV_ERR;   --  unsupported conversation style
         end case;
      end loop;
      CS.Free (Empty);
      Resp.all := Out_Array;
      return PAM_SUCCESS;
   end Converse;

   ----------------------------------------------------------------------
   --  The library
   ----------------------------------------------------------------------

   type Start_Fn is access function
     (Service, User : CS.chars_ptr;
      Conv          : access Conversation;
      Handle        : access System.Address) return int
     with Convention => C;
   type Authenticate_Fn is access function (H : System.Address; Flags : int)
     return int with Convention => C;
   type Get_Item_Fn is access function
     (H : System.Address; Item : int; Value : access System.Address)
     return int with Convention => C;
   type End_Fn is access function (H : System.Address; Status : int)
     return int with Convention => C;

   function To_Start is new Ada.Unchecked_Conversion
     (System.Address, Start_Fn);
   function To_Authenticate is new Ada.Unchecked_Conversion
     (System.Address, Authenticate_Fn);
   function To_Get_Item is new Ada.Unchecked_Conversion
     (System.Address, Get_Item_Fn);
   function To_End is new Ada.Unchecked_Conversion (System.Address, End_Fn);

   type Library is record
      Ok           : Boolean := False;
      Start        : Start_Fn;
      Authenticate : Authenticate_Fn;
      Acct_Mgmt    : Authenticate_Fn;
      Get_Item     : Get_Item_Fn;
      Finish       : End_Fn;
   end record;

   function Load return Library is
      Names : constant array (1 .. 2) of String (1 .. 11) :=
        ["libpam.so.0", "libpam.so  "];
      Handle : System.Address := System.Null_Address;
      Result : Library;

      function Symbol (Name : String) return System.Address is
         C : CS.chars_ptr := CS.New_String (Name);
         A : constant System.Address := dlsym (Handle, C);
      begin
         CS.Free (C);
         return A;
      end Symbol;
   begin
      for N of Names loop
         declare
            C : CS.chars_ptr :=
              CS.New_String (Ada.Strings.Fixed.Trim (N, Ada.Strings.Both));
         begin
            Handle := dlopen (C, RTLD_NOW);
            CS.Free (C);
         end;
         exit when Handle /= System.Null_Address;
      end loop;
      if Handle = System.Null_Address then
         return Result;
      end if;
      Result.Start := To_Start (Symbol ("pam_start"));
      Result.Authenticate := To_Authenticate (Symbol ("pam_authenticate"));
      Result.Acct_Mgmt := To_Authenticate (Symbol ("pam_acct_mgmt"));
      Result.Get_Item := To_Get_Item (Symbol ("pam_get_item"));
      Result.Finish := To_End (Symbol ("pam_end"));
      Result.Ok := Result.Start /= null and then Result.Authenticate /= null
        and then Result.Acct_Mgmt /= null and then Result.Get_Item /= null
        and then Result.Finish /= null;
      return Result;
   end Load;

   Lib : constant Library := Load;

   function Available return Boolean is (Lib.Ok);

   ----------------------------------------------------------------------
   --  AuthPlain
   ----------------------------------------------------------------------

   function Plain (Username, Password : String) return Result is
      Service  : CS.chars_ptr := CS.New_String ("login");
      User     : CS.chars_ptr := CS.New_String (Username);
      Secret   : CS.chars_ptr := CS.New_String (Password);
      Conv     : aliased Conversation :=
        (Func => Converse'Address, Data => To_Address (Secret));
      Handle   : aliased System.Address := System.Null_Address;
      Status   : int;
      Ignored  : int;
      Item     : aliased System.Address;
      Outcome  : Result;

      procedure Release is
      begin
         CS.Free (Service);
         CS.Free (User);
         CS.Free (Secret);
      end Release;
   begin
      if not Lib.Ok then
         Release;
         return (Ok => False,
                 Internal => To_Unbounded_String
                   ("failed to start PAM conversation: libpam is not "
                    & "available"),
                 External => To_Unbounded_String ("Authentication failed"));
      end if;

      Status := Lib.Start (Service, User, Conv'Access, Handle'Access);
      if Status /= PAM_SUCCESS then
         Release;
         return (Ok => False,
                 Internal => To_Unbounded_String
                   ("failed to start PAM conversation: PAM error"
                    & int'Image (Status)),
                 External => To_Unbounded_String ("Authentication failed"));
      end if;

      Status := Lib.Authenticate (Handle, 0);
      if Status /= PAM_SUCCESS then
         Outcome :=
           (Ok => False,
            Internal => To_Unbounded_String
              ("PAM auth error: PAM error" & int'Image (Status)),
            External => To_Unbounded_String ("Invalid credentials"));
      else
         Status := Lib.Acct_Mgmt (Handle, 0);
         if Status /= PAM_SUCCESS then
            Outcome :=
              (Ok => False,
               Internal => To_Unbounded_String
                 ("PAM account unavailable: PAM error" & int'Image (Status)),
               External => To_Unbounded_String ("Authentication failed"));
         else
            Status := Lib.Get_Item (Handle, PAM_USER, Item'Access);
            if Status /= PAM_SUCCESS then
               Outcome :=
                 (Ok => False,
                  Internal => To_Unbounded_String
                    ("failed to get PAM user: PAM error"
                     & int'Image (Status)),
                  External => To_Unbounded_String
                    ("Authentication failed"));
            elsif CS.Value (To_Chars (Item)) /= Username then
               Outcome :=
                 (Ok => False,
                  Internal => To_Unbounded_String
                    ("PAM user doesn't match supplied username"),
                  External => To_Unbounded_String
                    ("Authentication failed"));
            else
               Outcome := (Ok => True, others => <>);
            end if;
         end if;
      end if;
      Ignored := Lib.Finish (Handle, Status);
      Release;
      return Outcome;
   end Plain;

end Soja.Auth.Pam;
