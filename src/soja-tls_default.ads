--  Soja.Tls_Default -- the TLS configuration AWS.Client uses for the HTTPS
--  requests soja makes (OAuth 2.0 servers, Web Push endpoints): certificates
--  are verified against the system's CA bundle.
pragma Ada_2022;

package Soja.Tls_Default is

   --  Sets the default configuration up, once.
   procedure Ensure;

end Soja.Tls_Default;
