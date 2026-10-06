pragma Ada_2022;

with Ada.Text_IO;

with Soja.Irc.Members;
with Soja.Irc.User_Modes;

procedure Members_Check is
   use Soja.Irc.Members;
   use Soja.Irc.User_Modes;

   Available : Membership_Vectors.Vector;

   function Elem (V : Membership_Vectors.Vector; I : Positive)
      return Membership is (V (I));
begin
   for M of Std_Memberships loop
      Available.Append (M);
   end loop;

   --  User_Modes.
   declare
      M : User_Modes;
      Ok : Boolean;
   begin
      if Has (M, 'i') then
         raise Program_Error with "empty modes must not have flags";
      end if;
      Add (M, 'i');
      Add (M, 'i');   --  no duplicate
      Add (M, 'w');
      if Image (M) /= "iw" then
         raise Program_Error with "Add must append flags";
      end if;
      Del (M, 'i');
      if Image (M) /= "w" then
         raise Program_Error with "Del must remove the flag";
      end if;
      Apply (M, "+iw-z", Ok);
      if not Ok or else Image (M) /= "wi" then
         raise Program_Error with "Apply +iw-z wrong: " & Image (M);
      end if;
      Apply (M, "x", Ok);   --  no leading +/- is malformed
      if Ok then
         raise Program_Error with "malformed modestring must fail";
      end if;
   end;

   --  Membership set (rank-ordered insert).
   declare
      MS : Membership_Vectors.Vector;
   begin
      Add (MS, Available, ('o', '@'));
      if Natural (MS.Length) /= 1 or else Elem (MS, 1) /= ('o', '@') then
         raise Program_Error with "first add wrong";
      end if;

      Add (MS, Available, ('v', '+'));
      if Natural (MS.Length) /= 2 or else Elem (MS, 2) /= ('v', '+') then
         raise Program_Error with "voice must sort after op";
      end if;

      Add (MS, Available, ('a', '&'));
      if Natural (MS.Length) /= 3 or else Elem (MS, 1) /= ('a', '&') then
         raise Program_Error with "protected must sort before op";
      end if;

      Add (MS, Available, ('o', '@'));   --  already present
      if Natural (MS.Length) /= 3 then
         raise Program_Error with "duplicate add must be a no-op";
      end if;

      Remove (MS, ('o', '@'));
      if Natural (MS.Length) /= 2 or else Elem (MS, 1) /= ('a', '&') then
         raise Program_Error with "remove op wrong";
      end if;
   end;

   --  Channel_Status.
   declare
      Ok : Boolean;
      S  : Channel_Status;
   begin
      S := Parse_Channel_Status ("=", Ok);
      if not Ok or else S /= Channel_Public or else Code (S) /= '=' then
         raise Program_Error with "public status wrong";
      end if;
      S := Parse_Channel_Status ("@", Ok);
      if not Ok or else S /= Channel_Secret then
         raise Program_Error with "secret status wrong";
      end if;
      S := Parse_Channel_Status ("*", Ok);
      if not Ok or else S /= Channel_Private then
         raise Program_Error with "private status wrong";
      end if;
      S := Parse_Channel_Status ("x", Ok);
      if Ok then
         raise Program_Error with "unknown status must fail";
      end if;
      S := Parse_Channel_Status ("==", Ok);
      if Ok then
         raise Program_Error with "multi-char status must fail";
      end if;
   end;

   Ada.Text_IO.Put_Line ("ALL PASS");
end Members_Check;
