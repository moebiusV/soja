--  An Identification Protocol server (RFC 1413), identd/identd.go.  soja
--  registers the (server, our port) of each upstream connection with the
--  ident string to answer with, so that IRC servers querying port 113 get a
--  stable per-user ident instead of the daemon's.
pragma Ada_2022;

with Ada.Containers.Indefinite_Hashed_Maps;
with Ada.Strings.Hash;
with Ada.Strings.Unbounded;

with AWS.Net;

package Soja.Identd is

   --  identdTimeout: how long a client may take to send its next query.
   Query_Timeout : Duration := 10.0;

   type Identd is limited private;
   type Identd_Access is access all Identd;

   --  Identd.Store / Delete: the upstream connection between Remote_Host
   --  (port Remote_Port) and us (port Local_Port).
   procedure Store
     (I : in out Identd; Remote_Host : String;
      Remote_Port, Local_Port : Positive; Ident : String);
   procedure Delete
     (I : in out Identd; Remote_Host : String;
      Remote_Port, Local_Port : Positive);

   --  parseIdentQuery: "<local port> , <remote port>"; Ok is False for
   --  anything else, a zero port, or a port that is too large.
   procedure Parse_Query
     (Line : String; Local_Port, Remote_Port : out Natural;
      Ok : out Boolean);

   --  The answer to one query from Remote_Host (without the line end), and
   --  whether the connection stays open for another query.
   procedure Answer
     (I : in out Identd; Remote_Host, Line : String;
      Reply : out Ada.Strings.Unbounded.Unbounded_String;
      Keep_Open : out Boolean);

   --  Whether a peer (its IP, as text) may send a PROXY protocol header
   --  (`accept-proxy-ip`).
   type Proxy_Check is access function (Peer : String) return Boolean;

   --  Identd.Serve: accept queries on Listener until Stop is called.  A peer
   --  that Proxy accepts may start with a PROXY header; the address in it is
   --  then the one its queries are matched against.
   procedure Serve
     (I        : aliased in out Identd;
      Listener : not null AWS.Net.Socket_Access;
      Proxy    : Proxy_Check := null);

   procedure Stop (I : in out Identd);

private

   package Entry_Maps is new Ada.Containers.Indefinite_Hashed_Maps
     (String, String, Ada.Strings.Hash, "=");

   protected type Table is
      procedure Put (Key, Ident : String);
      procedure Remove (Key : String);
      function Find (Key : String) return String;   --  "" when absent
   private
      Entries : Entry_Maps.Map;
   end Table;

   protected type Stop_Flag is
      procedure Request;
      function Is_Set return Boolean;
   private
      Set : Boolean := False;
   end Stop_Flag;

   type Identd is limited record
      Entries : Table;
      Flag    : Stop_Flag;
   end record;

end Soja.Identd;
