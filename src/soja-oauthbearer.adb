pragma Ada_2022;

with Oauth_Response;
with Oauth_Response.Parser;

package body Soja.Oauthbearer is

   use Ada.Strings.Unbounded;

   Bearer : constant String := "Bearer ";

   procedure Parse
     (Response : String; Result : out Options; Ok : out Boolean)
   is
      use Oauth_Response;
      Tree : Response_Type;
      Bad  : Boolean := False;
   begin
      Result := (others => <>);
      Ok := False;
      begin
         Tree := Oauth_Response.Parser.Parse_Text (Response);
      exception
         when Oauth_Response.Parser.Parse_Error | Constraint_Error =>
            return;
      end;

      if Tree.Gs2_header.With_authzid /= null then
         Result.Username := Tree.Gs2_header.With_authzid.Authzid;
      end if;

      for Pair of Tree.Pairs.Pairs_1 loop
         declare
            Key   : constant String := To_String (Pair.Key);
            Value : constant String := To_String (Pair.Value);
         begin
            if Key = "auth" then
               if Value'Length > Bearer'Length
                 and then Value (Value'First .. Value'First + 6) = Bearer
               then
                  Result.Token := To_Unbounded_String
                    (Value (Value'First + 7 .. Value'Last));
               else
                  Bad := True;   --  not a bearer token
               end if;
            elsif Key = "host" then
               Result.Host := Pair.Value;
            elsif Key = "port" then
               if Value = ""
                 or else not (for all C of Value => C in '0' .. '9')
                 or else Value'Length > 9
               then
                  Bad := True;
               else
                  Result.Port := Natural'Value (Value);
               end if;
            end if;
         end;
      end loop;
      Oauth_Response.Parser.Free_Response (Tree);
      Ok := not Bad and then Length (Result.Token) > 0;
   end Parse;

end Soja.Oauthbearer;
