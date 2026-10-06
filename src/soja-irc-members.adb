pragma Ada_2022;

package body Soja.Irc.Members is

   ---------
   -- Add --
   ---------

   procedure Add (MS : in out Membership_Vectors.Vector;
                  Available : Membership_Vectors.Vector;
                  New_M : Membership)
   is
      I : Natural := 0;   --  0-based insertion index
   begin
      for Avail of Available loop
         exit when I >= Natural (MS.Length);

         if MS (I + 1) = Avail then
            if Avail = New_M then
               return;   --  already present
            end if;
            I := I + 1;
         elsif Avail = New_M then
            exit;        --  insert here
         end if;
      end loop;

      MS.Insert (I + 1, New_M);
   end Add;

   ------------
   -- Remove --
   ------------

   procedure Remove (MS : in out Membership_Vectors.Vector; M : Membership) is
   begin
      for I in 1 .. Natural (MS.Length) loop
         if MS (I) = M then
            MS.Delete (I);
            return;
         end if;
      end loop;
   end Remove;

   ----------
   -- Code --
   ----------

   function Code (S : Channel_Status) return Character is
     (case S is
        when Channel_Public  => '=',
        when Channel_Secret  => '@',
        when Channel_Private => '*');

   -------------------------
   -- Parse_Channel_Status --
   -------------------------

   function Parse_Channel_Status (S : String; Success : out Boolean)
      return Channel_Status
   is
   begin
      if S'Length > 1 then
         Success := False;
         return Channel_Public;
      end if;
      case S (S'First) is
         when '=' =>
            Success := True;
            return Channel_Public;
         when '@' =>
            Success := True;
            return Channel_Secret;
         when '*' =>
            Success := True;
            return Channel_Private;
         when others =>
            Success := False;
            return Channel_Public;
      end case;
   end Parse_Channel_Status;

end Soja.Irc.Members;
