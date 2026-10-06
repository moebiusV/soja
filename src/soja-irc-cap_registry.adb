pragma Ada_2022;

package body Soja.Irc.Cap_Registry is

   function New_Registry return Registry is
   begin
      return (Available => Value_Maps.Empty_Map,
              Enabled   => Name_Sets.Empty_Set);
   end New_Registry;

   function Is_Available (R : Registry; Name : String) return Boolean is
   begin
      return R.Available.Contains (Name);
   end Is_Available;

   function Is_Enabled (R : Registry; Name : String) return Boolean is
   begin
      return R.Enabled.Contains (Name);
   end Is_Enabled;

   procedure Set_Available (R : in out Registry; Name, Value : String) is
   begin
      R.Available.Include (Name, Value);
   end Set_Available;

   function Value (R : Registry; Name : String) return String is
   begin
      if R.Available.Contains (Name) then
         return R.Available.Element (Name);
      end if;
      return "";
   end Value;

   procedure Set_Enabled
     (R : in out Registry; Name : String; Enabled : Boolean)
   is
   begin
      if Enabled then
         R.Enabled.Include (Name);
      else
         R.Enabled.Exclude (Name);
      end if;
   end Set_Enabled;

   procedure Delete (R : in out Registry; Name : String) is
   begin
      R.Available.Exclude (Name);
      R.Enabled.Exclude (Name);
   end Delete;

end Soja.Irc.Cap_Registry;
