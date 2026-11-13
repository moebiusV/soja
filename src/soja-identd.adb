pragma Ada_2022;

with Ada.Streams;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;

with AWS.Net.Std;
with GNAT.Sockets;

with Ident_Query.Parser;
with Soja.Proxy_Protocol;

package body Soja.Identd is

   use type Ada.Streams.Stream_Element_Offset;
   use type GNAT.Sockets.Selector_Status;

   CRLF : constant String := ASCII.CR & ASCII.LF;

   --  The key of an entry: Remote_Host, Remote_Port and Local_Port.
   function Key_Of
     (Remote_Host : String; Remote_Port, Local_Port : Positive)
      return String
   is
      function Img (N : Positive) return String is
        (Ada.Strings.Fixed.Trim (Positive'Image (N), Ada.Strings.Left));
   begin
      return Remote_Host & "|" & Img (Remote_Port) & "|" & Img (Local_Port);
   end Key_Of;

   protected body Table is
      procedure Put (Key, Ident : String) is
      begin
         Entries.Include (Key, Ident);
      end Put;

      procedure Remove (Key : String) is
      begin
         Entries.Exclude (Key);
      end Remove;

      function Find (Key : String) return String is
         Pos : constant Entry_Maps.Cursor := Entries.Find (Key);
      begin
         return (if Entry_Maps.Has_Element (Pos)
                 then Entry_Maps.Element (Pos) else "");
      end Find;
   end Table;

   protected body Stop_Flag is
      procedure Request is
      begin
         Set := True;
      end Request;
      function Is_Set return Boolean is (Set);
   end Stop_Flag;

   procedure Store
     (I : in out Identd; Remote_Host : String;
      Remote_Port, Local_Port : Positive; Ident : String) is
   begin
      I.Entries.Put (Key_Of (Remote_Host, Remote_Port, Local_Port), Ident);
   end Store;

   procedure Delete
     (I : in out Identd; Remote_Host : String;
      Remote_Port, Local_Port : Positive) is
   begin
      I.Entries.Remove (Key_Of (Remote_Host, Remote_Port, Local_Port));
   end Delete;

   procedure Parse_Query
     (Line : String; Local_Port, Remote_Port : out Natural;
      Ok : out Boolean)
   is
      type Step is (Want_First, Want_Comma, Want_Second, Done);
      Where : Step := Want_First;
      Bad   : Boolean := False;
   begin
      Local_Port := 0;
      Remote_Port := 0;
      Ok := False;
      declare
         Tree : constant Standard.Ident_Query.Query_Type :=
           Standard.Ident_Query.Parser.Parse_Text (Line);
      begin
         --  number comma number, white space anywhere between.
         for E of Tree loop
            if Length (E.Ws) > 0 then
               null;
            elsif Length (E.Num) > 0 then
               case Where is
                  when Want_First =>
                     Local_Port := Natural'Value (To_String (E.Num));
                     Where := Want_Comma;
                  when Want_Second =>
                     Remote_Port := Natural'Value (To_String (E.Num));
                     Where := Done;
                  when others =>
                     Bad := True;
               end case;
            elsif Where = Want_Comma then
               Where := Want_Second;
            else
               Bad := True;
            end if;
         end loop;
      end;
      Ok := not Bad and then Where = Done
        and then Local_Port > 0 and then Remote_Port > 0;
      if not Ok then
         Local_Port := 0;
         Remote_Port := 0;
      end if;
   exception
      when Standard.Ident_Query.Parser.Parse_Error | Constraint_Error =>
         Local_Port := 0;
         Remote_Port := 0;
         Ok := False;
   end Parse_Query;

   procedure Answer
     (I : in out Identd; Remote_Host, Line : String;
      Reply : out Unbounded_String; Keep_Open : out Boolean)
   is
      Local, Remote : Natural;
      Ok            : Boolean;
   begin
      Parse_Query (Line, Local, Remote, Ok);
      if not Ok then
         Reply := To_Unbounded_String (Line & " : ERROR : INVALID-PORT");
         Keep_Open := False;
         return;
      end if;

      declare
         Ident : constant String :=
           I.Entries.Find (Key_Of (Remote_Host, Remote, Local));
      begin
         if Ident = "" then
            Reply := To_Unbounded_String (Line & " : ERROR : NO-USER");
            Keep_Open := False;
         else
            --  The "OTHER" operating system may be rejected by IRC servers,
            --  because it may be used when the ident string isn't stable.
            --  Use "UNKNOWN" from RFC 1340 instead.
            Reply := To_Unbounded_String
              (Line & " : USERID : UNKNOWN : " & Ident);
            Keep_Open := True;
         end if;
      end;
   end Answer;

   ----------------------------------------------------------------------
   --  Serving
   ----------------------------------------------------------------------

   Max_Line : constant := 512;   --  the scanner's buffer in Go

   --  Identd.handle: read queries from one client.
   procedure Handle
     (I : in out Identd; Sock : in out AWS.Net.Std.Socket_Type;
      Proxy : Proxy_Check)
   is
      Peer        : constant String := Sock.Peer_Addr;
      Remote_Host : Unbounded_String := To_Unbounded_String (Peer);
      Pending     : Unbounded_String;
      Chunk       : Ada.Streams.Stream_Element_Array (1 .. 256);
      Last        : Ada.Streams.Stream_Element_Offset;

      procedure Send (Text : String) is
         Data : Ada.Streams.Stream_Element_Array
           (1 .. Ada.Streams.Stream_Element_Offset (Text'Length));
         Sent : Ada.Streams.Stream_Element_Offset;
      begin
         for K in Text'Range loop
            Data (Ada.Streams.Stream_Element_Offset (K - Text'First + 1)) :=
              Ada.Streams.Stream_Element (Character'Pos (Text (K)));
         end loop;
         Sock.Send (Data, Sent);
      end Send;
   begin
      if Proxy /= null and then Proxy (Peer) then
         declare
            Header : Soja.Proxy_Protocol.Info;
         begin
            Soja.Proxy_Protocol.Read_Header (Sock, Pending, 5.0, Header);
            if not Header.Local then
               Remote_Host := Header.Source_Host;
            end if;
         exception
            when Soja.Proxy_Protocol.Proxy_Error =>
               return;   --  not a connection we can trust or understand
         end;
      end if;
      Sock.Set_Timeout (Query_Timeout);
      loop
         --  A complete line?
         declare
            Text : constant String := To_String (Pending);
            NL   : constant Natural :=
              Ada.Strings.Fixed.Index (Text, "" & ASCII.LF);
         begin
            if NL > 0 then
               declare
                  Raw  : constant String := Text (Text'First .. NL - 1);
                  Line : constant String :=
                    (if Raw'Length > 0 and then Raw (Raw'Last) = ASCII.CR
                     then Raw (Raw'First .. Raw'Last - 1) else Raw);
                  Reply : Unbounded_String;
                  Keep  : Boolean;
               begin
                  Pending := To_Unbounded_String (Text (NL + 1 .. Text'Last));
                  Answer (I, To_String (Remote_Host), Line, Reply, Keep);
                  Send (To_String (Reply) & CRLF);
                  exit when not Keep;
               end;
            elsif Text'Length >= Max_Line then
               exit;   --  too long for a query: hang up, as the scanner does
            else
               Sock.Receive (Chunk, Last);
               exit when Last < Chunk'First;
               for K in Chunk'First .. Last loop
                  Append (Pending, Character'Val (Chunk (K)));
               end loop;
            end if;
         end;
      end loop;
   exception
      when AWS.Net.Socket_Error =>
         null;   --  timeout or the peer went away
   end Handle;

   task type Client_Task
     (I : not null access Identd; Sock : not null AWS.Net.Socket_Access;
      Proxy : Proxy_Check)
   is
      entry Start;
   end Client_Task;

   task body Client_Task is
   begin
      accept Start;
      begin
         Handle (I.all, AWS.Net.Std.Socket_Type (Sock.all), Proxy);
      exception
         when others => null;
      end;
      begin
         AWS.Net.Std.Socket_Type (Sock.all).Shutdown;
      exception
         when others => null;
      end;
      declare
         S : AWS.Net.Socket_Access := Sock;
      begin
         AWS.Net.Free (S);
      end;
   end Client_Task;

   type Client_Task_Access is access Client_Task;

   procedure Serve
     (I        : aliased in out Identd;
      Listener : not null AWS.Net.Socket_Access;
      Proxy    : Proxy_Check := null)
   is
      FD   : constant Integer := AWS.Net.Std.Socket_Type (Listener.all).Get_FD;
      GS   : constant GNAT.Sockets.Socket_Type := GNAT.Sockets.To_Ada (FD);
      Sel  : aliased GNAT.Sockets.Selector_Type;
      Rset, Wset : GNAT.Sockets.Socket_Set_Type;
      St   : GNAT.Sockets.Selector_Status;
   begin
      GNAT.Sockets.Create_Selector (Sel);
      while not I.Flag.Is_Set loop
         GNAT.Sockets.Empty (Rset);
         GNAT.Sockets.Empty (Wset);
         GNAT.Sockets.Set (Rset, GS);
         GNAT.Sockets.Check_Selector (Sel, Rset, Wset, St, 0.1);

         if St = GNAT.Sockets.Completed
           and then not GNAT.Sockets.Is_Empty (Rset)
         then
            declare
               New_Sock : AWS.Net.Socket_Access := AWS.Net.Socket (False);
            begin
               AWS.Net.Accept_Socket (Listener.all, New_Sock.all);
               declare
                  T : constant Client_Task_Access :=
                    new Client_Task (I'Unchecked_Access, New_Sock, Proxy);
               begin
                  T.Start;
               end;
            exception
               when AWS.Net.Socket_Error =>
                  AWS.Net.Free (New_Sock);
                  --  A failed accept is retried (retryListener), unless the
                  --  listener was closed.
                  exit when I.Flag.Is_Set;
                  delay 0.05;
            end;
         end if;
      end loop;
      GNAT.Sockets.Close_Selector (Sel);
   end Serve;

   procedure Stop (I : in out Identd) is
   begin
      I.Flag.Request;
   end Stop;

end Soja.Identd;
