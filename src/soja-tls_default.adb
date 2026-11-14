pragma Ada_2022;

with AWS.Default;
with AWS.Net.SSL;

package body Soja.Tls_Default is

   protected Gate is
      procedure Make;
   private
      Done : Boolean := False;
   end Gate;

   protected body Gate is
      procedure Make is
      begin
         if not Done then
            AWS.Net.SSL.Initialize_Default_Config
              (Security_Mode       => AWS.Net.SSL.TLS_Client,
               Check_Certificate   => True,
               Trusted_CA_Filename => AWS.Default.Trusted_CA);
            Done := True;
         end if;
      end Make;
   end Gate;

   procedure Ensure is
   begin
      Gate.Make;
   end Ensure;

end Soja.Tls_Default;
