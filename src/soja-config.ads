--  Soja.Config — the port of soju's config/config.go.
--
--  The config file is parsed by the scfg grammar (grammars/scfg.hbnf) into a
--  Scfg tree; this package walks that tree into a typed `Server`, applying
--  go-scfg's unescaping and config.go's directive-specific validation.  The
--  walk is a faithful port: same directives, same defaults, same errors.
pragma Ada_2022;

with Ada.Containers.Vectors;
with Ada.Strings.Unbounded;
with Interfaces;

package Soja.Config is

   use Ada.Strings.Unbounded;
   use Interfaces;

   Config_Error : exception;

   --  A TLS keypair: certificate and key, both PEM paths.
   type TLS is record
      Cert_Path : Unbounded_String;
      Key_Path  : Unbounded_String;
   end record;

   --  A driver + source pair, used by db / message-store / auth / file-upload.
   type DB is record
      Driver : Unbounded_String;
      Source : Unbounded_String;
   end record;

   type Msg_Store is record
      Driver : Unbounded_String;
      Source : Unbounded_String;
   end record;

   type Auth is record
      Driver : Unbounded_String;
      Source : Unbounded_String;
   end record;

   type File_Upload is record
      Driver : Unbounded_String;
      Source : Unbounded_String;
   end record;

   --  A 16-byte IP address; IPv4 is stored v4-mapped (::ffff:a.b.c.d).
   type IP_Addr is array (0 .. 15) of Unsigned_8;

   type IP_Family is (IPv4, IPv6);

   --  A CIDR network, as net.IPNet: the (masked) address and the prefix
   --  length in bits (0..32 for IPv4, 0..128 for IPv6).
   type IPNet is record
      Family : IP_Family;
      Addr   : IP_Addr;
      Prefix : Natural;
   end record;

   package IPNet_Vectors is new Ada.Containers.Vectors (Positive, IPNet);
   subtype IPSet is IPNet_Vectors.Vector;

   package String_Vectors is new Ada.Containers.Vectors
     (Positive, Unbounded_String);

   --  The server configuration, mirroring config.go's Server struct.
   type Server is record
      Listen        : String_Vectors.Vector;
      TLS           : access Soja.Config.TLS;
      Hostname      : Unbounded_String;
      Title         : Unbounded_String;
      MOTD_Path     : Unbounded_String;

      DB            : Soja.Config.DB;
      Msg_Store     : Soja.Config.Msg_Store;
      Auth          : Soja.Config.Auth;
      File_Upload   : access Soja.Config.File_Upload;

      HTTP_Origins  : String_Vectors.Vector;
      HTTP_Ingress  : Unbounded_String;
      Accept_Proxy_IPs : IPSet;

      Max_User_Networks : Integer;
      Upstream_User_IPs : IPNet_Vectors.Vector;
      Disable_Inactive_Users_Delay : Duration;
      Message_Expiry               : Duration;
      Enable_Users_On_Auth : Boolean;
      Icon                 : Unbounded_String;   --  a URL or a file path
      Accept_Proxy_Unix    : Boolean;
      Client_Cert_Auth     : Boolean;
   end record;

   --  The defaults, mirroring config.go's Defaults(): hostname from the OS,
   --  sqlite3 db, in-memory msgstore, internal auth.
   function Defaults return Server;

   --  Parse config text into a Server (the walk).  Raises Config_Error with a
   --  soju-style message on any invalid directive or parameter.
   function Parse (Text : String) return Server;

   --  Load a config file, as config.go's Load(filename).
   function Load (Filename : String) return Server;

end Soja.Config;
