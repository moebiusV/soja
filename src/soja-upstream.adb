pragma Ada_2022;

package body Soja.Upstream is

   ---------------------
   -- Has_WHOX_Fields --
   ---------------------

   function Has_WHOX_Fields (UU : Upstream_User; Fields : String)
      return Boolean
   is
      Ok : Boolean;
   begin
      for I in Fields'Range loop
         Ok := False;
         case Fields (I) is
            when 'n' => Ok := UU.Nickname /= Null_Unbounded_String;
            when 'u' => Ok := UU.Username /= Null_Unbounded_String;
            when 'h' => Ok := UU.Hostname /= Null_Unbounded_String;
            when 's' => Ok := UU.Server /= Null_Unbounded_String;
            when 'f' => Ok := UU.Flags /= Null_Unbounded_String;
            when 'a' => Ok := UU.Account /= Null_Unbounded_String;
            when 'r' => Ok := UU.Realname /= Null_Unbounded_String;
            when 't' | 'c' | 'i' | 'd' | 'l' | 'o' => Ok := True;
            when others => null;
         end case;
         if not Ok then
            return False;
         end if;
      end loop;
      return True;
   end Has_WHOX_Fields;

   -----------------
   -- Update_From --
   -----------------

   procedure Update_From (UU : in out Upstream_User; Update : Upstream_User) is
   begin
      if Update.Nickname /= Null_Unbounded_String then
         UU.Nickname := Update.Nickname;
      end if;
      if Update.Username /= Null_Unbounded_String then
         UU.Username := Update.Username;
      end if;
      if Update.Hostname /= Null_Unbounded_String then
         UU.Hostname := Update.Hostname;
      end if;
      if Update.Server /= Null_Unbounded_String then
         UU.Server := Update.Server;
      end if;
      if Update.Flags /= Null_Unbounded_String then
         UU.Flags := Update.Flags;
      end if;
      if Update.Account /= Null_Unbounded_String then
         UU.Account := Update.Account;
      end if;
      if Update.Realname /= Null_Unbounded_String then
         UU.Realname := Update.Realname;
      end if;
   end Update_From;

end Soja.Upstream;
