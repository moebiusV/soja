pragma Ada_2022;

package body Soja.Irc.Case_Mapping is

   --  Lower A-Z in place; every other byte is left alone.
   procedure Lower_AZ (Name : in out String; I : Positive) is
   begin
      if Name (I) in 'A' .. 'Z' then
         Name (I) := Character'Val (Character'Pos (Name (I)) + 32);
      end if;
   end Lower_AZ;

   function Fold (CM : Kind; Name : String) return String is
      Result : String := Name;
   begin
      for I in Result'Range loop
         Lower_AZ (Result, I);
         case CM is
            when Case_ASCII =>
               null;
            when Case_RFC1459 =>
               case Result (I) is
                  when '{' =>
                     Result (I) := '[';
                  when '}' =>
                     Result (I) := ']';
                  when '\' =>
                     Result (I) := '|';
                  when '~' =>
                     Result (I) := '^';
                  when others =>
                     null;
               end case;
            when Case_RFC1459_Strict =>
               case Result (I) is
                  when '{' =>
                     Result (I) := '[';
                  when '}' =>
                     Result (I) := ']';
                  when '\' =>
                     Result (I) := '|';
                  when others =>
                     null;
               end case;
         end case;
      end loop;
      return Result;
   end Fold;

   function Parse_Case_Mapping (S : String) return Kind is
   begin
      if S = "ascii" then
         return Case_ASCII;
      elsif S = "rfc1459" then
         return Case_RFC1459;
      elsif S = "rfc1459-strict" then
         return Case_RFC1459_Strict;
      else
         return Case_RFC1459;
      end if;
   end Parse_Case_Mapping;

end Soja.Irc.Case_Mapping;
