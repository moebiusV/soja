pragma Ada_2022;

with Ada.Calendar;
with Ada.Containers;
with Ada.Exceptions;
with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;
with Ada.Text_IO;
with Interfaces;

with Soja.Bare;
with Soja.Base64;
with Soja.Conn;
with Soja.Core;
with Soja.Database;
with Soja.Irc.Messages;
with Soja.Logging;
with Soja.Msgstore;
with Soja.Msgstore.Memory;
with Soja.Server;
with Soja.User;

procedure Msgstore_Check is
   use Soja.Msgstore;
   use Soja.Irc.Messages;
   use Interfaces;
   use type Ada.Containers.Count_Type;

   procedure Check (Cond : Boolean; What : String) is
   begin
      if not Cond then
         raise Program_Error with What;
      end if;
   end Check;

   function Bytes (V : Soja.Bare.Reader) return String is (Soja.Bare.Rest (V));

   function Hex (S : String) return String is
      Digits_Of : constant String := "0123456789abcdef";
      R : String (1 .. 2 * S'Length);
   begin
      for I in S'Range loop
         R (2 * (I - S'First) + 1) :=
           Digits_Of (Character'Pos (S (I)) / 16 + 1);
         R (2 * (I - S'First) + 2) :=
           Digits_Of (Character'Pos (S (I)) mod 16 + 1);
      end loop;
      return R;
   end Hex;

   function Msg (Text : String; Cmd : String := "PRIVMSG") return Message is
   begin
      return Parse_Message (Cmd & " #c :" & Text);
   end Msg;

   Net : Soja.Database.Network := Soja.Database.New_Network ("irc.example");
begin
   Net.ID := 1;

   -------------------------------------------------------------------
   --  Soja.Base64 (RFC 4648 vectors).
   -------------------------------------------------------------------
   declare
      Ok : Boolean;
   begin
      Check (Soja.Base64.Encode ("") = "", "b64 empty");
      Check (Soja.Base64.Encode ("f") = "Zg==", "b64 f");
      Check (Soja.Base64.Encode ("fo") = "Zm8=", "b64 fo");
      Check (Soja.Base64.Encode ("foo") = "Zm9v", "b64 foo");
      Check (Soja.Base64.Encode ("foob") = "Zm9vYg==", "b64 foob");
      Check (Soja.Base64.Encode ("fooba") = "Zm9vYmE=", "b64 fooba");
      Check (Soja.Base64.Encode ("foobar") = "Zm9vYmFy", "b64 foobar");
      Check (Soja.Base64.Encode ("f", Padded => False) = "Zg", "raw f");
      Check (Soja.Base64.Encode ("fo", Padded => False) = "Zm8", "raw fo");
      Check (Soja.Base64.Encode ([Character'Val (16#FB#), Character'Val (16#FF#)])
             = "+/8=", "std alphabet");
      Check (Soja.Base64.Encode
               ([Character'Val (16#FB#), Character'Val (16#FF#)],
                URL_Safe => True, Padded => False) = "-_8", "url alphabet");
      Check (Soja.Base64.Decode ("Zm9vYmE=", Ok) = "fooba" and then Ok,
             "decode padded");
      Check (Soja.Base64.Decode ("Zm9vYmE", Ok, Padded => False) = "fooba"
             and then Ok, "decode raw");
      Check (Soja.Base64.Decode ("Zm9v" & ASCII.CR & ASCII.LF & "YmFy", Ok)
             = "foobar" and then Ok, "decode ignores CR/LF");
      Check (Soja.Base64.Decode ("-_8", Ok, URL_Safe => True, Padded => False)
             = [Character'Val (16#FB#), Character'Val (16#FF#)] and then Ok,
             "decode url");
      Check (Soja.Base64.Decode ("", Ok) = "" and then Ok, "decode empty");
      declare
         R : constant String := Soja.Base64.Decode ("Zm9vYmE", Ok);
      begin
         Check (not Ok and then R = "", "padded decode needs padding");
      end;
      declare
         R : constant String := Soja.Base64.Decode ("Zm9vYmE=", Ok,
                                                    Padded => False);
      begin
         Check (not Ok, "raw decode rejects padding: " & R);
      end;
      declare
         R : constant String := Soja.Base64.Decode ("Z", Ok, Padded => False);
      begin
         Check (not Ok, "one leftover char is invalid: " & R);
      end;
      declare
         R : constant String := Soja.Base64.Decode ("Zm9v*", Ok);
      begin
         Check (not Ok, "bad length/alphabet: " & R);
      end;
      declare
         R : constant String := Soja.Base64.Decode ("-_8=", Ok);
      begin
         Check (not Ok, "std decode rejects url alphabet: " & R);
      end;
   end;

   -------------------------------------------------------------------
   --  Soja.Bare (go-bare / encoding/binary vectors).
   -------------------------------------------------------------------
   declare
      Buf : Unbounded_String;
   begin
      Soja.Bare.Write_Uint (Buf, 0);
      Soja.Bare.Write_Uint (Buf, 127);
      Soja.Bare.Write_Uint (Buf, 128);
      Soja.Bare.Write_Uint (Buf, 300);
      Check (Hex (To_String (Buf)) = "007f8001ac02", "uvarint: "
             & Hex (To_String (Buf)));
      Buf := Null_Unbounded_String;
      Soja.Bare.Write_Int (Buf, 0);
      Soja.Bare.Write_Int (Buf, -1);
      Soja.Bare.Write_Int (Buf, 1);
      Soja.Bare.Write_Int (Buf, -64);
      Soja.Bare.Write_Int (Buf, 64);
      Check (Hex (To_String (Buf)) = "0001027f8001", "varint: "
             & Hex (To_String (Buf)));
      Buf := Null_Unbounded_String;
      Soja.Bare.Write_String (Buf, "hi");
      Check (Hex (To_String (Buf)) = "026869", "string");

      Buf := Null_Unbounded_String;
      Soja.Bare.Write_Uint (Buf, Unsigned_64'Last);
      Soja.Bare.Write_Int (Buf, Integer_64'First);
      Soja.Bare.Write_Int (Buf, Integer_64'Last);
      Soja.Bare.Write_Int (Buf, -123_456_789);
      Soja.Bare.Write_String (Buf, "tail");
      declare
         R : Soja.Bare.Reader := Soja.Bare.New_Reader (To_String (Buf));
      begin
         Check (Soja.Bare.Read_Uint (R) = Unsigned_64'Last, "rt uint max");
         Check (Soja.Bare.Read_Int (R) = Integer_64'First, "rt int min");
         Check (Soja.Bare.Read_Int (R) = Integer_64'Last, "rt int max");
         Check (Soja.Bare.Read_Int (R) = -123_456_789, "rt int");
         Check (Soja.Bare.Read_String (R) = "tail", "rt string");
         Check (Bytes (R) = "", "reader drained");
         begin
            declare
               X : constant Unsigned_64 := Soja.Bare.Read_Uint (R);
               pragma Unreferenced (X);
            begin
               Check (False, "read past end must raise");
            end;
         exception
            when Soja.Bare.Bare_Error => null;
         end;
      end;
      declare
         R : Soja.Bare.Reader :=
           Soja.Bare.New_Reader ([Character'Val (16#80#)]);
      begin
         declare
            X : constant Unsigned_64 := Soja.Bare.Read_Uint (R);
            pragma Unreferenced (X);
         begin
            Check (False, "truncated varint must raise");
         end;
      exception
         when Soja.Bare.Bare_Error => null;
      end;
      declare
         R : Soja.Bare.Reader := Soja.Bare.New_Reader ("" & Character'Val (5) & "ab");
      begin
         declare
            X : constant String := Soja.Bare.Read_String (R);
            pragma Unreferenced (X);
         begin
            Check (False, "string longer than data must raise");
         end;
      exception
         when Soja.Bare.Bare_Error => null;
      end;
   end;

   -------------------------------------------------------------------
   --  Message IDs.  (Expected strings computed independently.)
   -------------------------------------------------------------------
   declare
      Net_ID : Long_Long_Integer;
      Target, Rest : Unbounded_String;
      ID : constant String := Format_Msg_ID
        (1, "#c", Msg_ID_Memory, [Character'Val (1)]);
   begin
      Check (ID = "AAICI2MBAQ", "msg id encoding: " & ID);
      Parse_Msg_ID (ID, Net_ID, Target, Rest, Expected => Msg_ID_Memory);
      Check (Net_ID = 1 and then To_String (Target) = "#c"
             and then To_String (Rest) = [Character'Val (1)],
             "msg id parse");
      Parse_Msg_ID (ID, Net_ID, Target, Rest);   --  no type check
      begin
         Parse_Msg_ID (ID, Net_ID, Target, Rest, Expected => Msg_ID_DB);
         Check (False, "wrong type must raise");
      exception
         when E : Store_Error =>
            Check (Index (To_Unbounded_String
                     (Ada.Exceptions.Exception_Message (E)),
                     "invalid internal message ID: got type") = 1,
                   "type mismatch message");
      end;
      begin
         Parse_Msg_ID ("!!!", Net_ID, Target, Rest);
         Check (False, "bad base64 must raise");
      exception
         when Store_Error => null;
      end;
      begin
         Parse_Msg_ID ("AAIC", Net_ID, Target, Rest);   --  truncated
         Check (False, "truncated id must raise");
      exception
         when Store_Error => null;
      end;
      begin
         Parse_Msg_ID (Soja.Base64.Encode
                         ([Character'Val (7), Character'Val (2),
                           Character'Val (0), Character'Val (1)],
                          URL_Safe => True, Padded => False),
                       Net_ID, Target, Rest);
         Check (False, "wrong version must raise");
      exception
         when Store_Error => null;
      end;
      --  Negative network IDs round-trip (BARE int is signed).
      Parse_Msg_ID (Format_Msg_ID (-5, "x", Msg_ID_FS, ""),
                    Net_ID, Target, Rest);
      Check (Net_ID = -5, "negative net id");
   end;

   -------------------------------------------------------------------
   --  The memory store.
   -------------------------------------------------------------------
   declare
      S : constant Store_Access := Soja.Msgstore.Memory.New_Memory_Store;
      Opts : Load_Message_Options;
      Before, A, B, C : Unbounded_String;
      L : Message_Vectors.Vector;
   begin
      Check (Soja.Msgstore.Memory.Is_Memory_Store (S.all), "is memory store");
      Opts.Network := Net;
      Opts.Entity := To_Unbounded_String ("#c");
      Opts.Limit := 10;

      Before := To_Unbounded_String (S.Last_Msg_ID (Net, "#c", Ada.Calendar.Clock));
      Check (To_String (Before) = Format_Msg_ID
               (1, "#c", Msg_ID_Memory, [Character'Val (0)]),
             "empty buffer: last id has seq 0");

      --  Only PRIVMSG/NOTICE are stored.
      Check (S.Append (Net, "#c", Msg ("x", "JOIN")) = "", "JOIN not stored");
      Check (S.Append (Net, "#c", Msg ("x", "TOPIC")) = "", "TOPIC not stored");
      A := To_Unbounded_String (S.Append (Net, "#c", Msg ("one")));
      B := To_Unbounded_String (S.Append (Net, "#c", Msg ("two", "NOTICE")));
      C := To_Unbounded_String (S.Append (Net, "#c", Msg ("three")));
      Check (To_String (A) = Format_Msg_ID
               (1, "#c", Msg_ID_Memory, [Character'Val (1)])
             and then To_String (A) /= To_String (B), "append ids");
      Check (S.Last_Msg_ID (Net, "#c", Ada.Calendar.Clock) = Format_Msg_ID
               (1, "#c", Msg_ID_Memory, [Character'Val (4)]),
             "last id is the next sequence number");

      --  From before the first message: everything, oldest first.
      L := S.Load_Latest_ID (To_String (Before), Opts);
      Check (L.Length = 3 and then Trailing (L (1)) = "one"
             and then Trailing (L (3)) = "three", "load all");
      --  After A (excluded): two, three.
      L := S.Load_Latest_ID (To_String (A), Opts);
      Check (L.Length = 2 and then Trailing (L (1)) = "two", "load after A");
      --  Limit keeps the newest.
      Opts.Limit := 1;
      L := S.Load_Latest_ID (To_String (Before), Opts);
      Check (L.Length = 1 and then Trailing (L (1)) = "three", "limit");
      Opts.Limit := 10;
      --  After the last message: nothing.
      L := S.Load_Latest_ID (To_String (C), Opts);
      Check (L.Is_Empty, "load after last");
      --  Other entity / network: nothing.
      Opts.Entity := To_Unbounded_String ("#other");
      Check (S.Load_Latest_ID (To_String (A), Opts).Is_Empty,
             "unknown entity");
      Opts.Entity := To_Unbounded_String ("#c");
      --  Events unsupported; bad / future / wrong-type ids.
      Opts.Events := True;
      begin
         L := S.Load_Latest_ID (To_String (A), Opts);
         Check (False, "events must raise");
      exception
         when Store_Error => null;
      end;
      Opts.Events := False;
      begin
         L := S.Load_Latest_ID
           (Format_Msg_ID (1, "#c", Msg_ID_Memory, [Character'Val (99)]),
            Opts);
         Check (False, "future sequence must raise");
      exception
         when Store_Error => null;
      end;
      begin
         L := S.Load_Latest_ID
           (Format_Msg_ID (1, "#c", Msg_ID_DB, [Character'Val (1)]), Opts);
         Check (False, "non-memory id must raise");
      exception
         when Store_Error => null;
      end;

      --  Buffers are per network and entity.
      declare
         Net2 : Soja.Database.Network := Net;
      begin
         Net2.ID := 2;
         Check (S.Append (Net2, "#c", Msg ("elsewhere")) /= "", "net 2");
         Check (S.Load_Latest_ID (To_String (Before), Opts).Length = 3,
                "network 1 buffer unaffected");
      end;

      --  The ring keeps only the last 4096 messages.
      declare
         First : Unbounded_String;
      begin
         for I in 1 .. 5000 loop
            declare
               ID : constant String :=
                 S.Append (Net, "#big", Msg (Integer'Image (I)));
            begin
               if I = 1 then
                  First := To_Unbounded_String (ID);
               end if;
            end;
         end loop;
         Opts.Entity := To_Unbounded_String ("#big");
         Opts.Limit := 100_000;
         L := S.Load_Latest_ID (To_String (First), Opts);
         Check (L.Length = 4096, "ring capacity:"
                & Ada.Containers.Count_Type'Image (L.Length));
         Check (Trailing (L (4096)) = " 5000", "newest survives");
         Check (Trailing (L (1)) = " 905", "oldest kept is 5000-4096+1");
      end;

      --  Stored messages are copies.
      declare
         M : Message := Msg ("orig");
         ID : Unbounded_String;
      begin
         ID := To_Unbounded_String (S.Append (Net, "#copy", M));
         M.Params.Replace_Element (2, To_Unbounded_String ("mutated"));
         Opts.Entity := To_Unbounded_String ("#copy");
         L := S.Load_Latest_ID
           (Format_Msg_ID (1, "#copy", Msg_ID_Memory, [Character'Val (0)]),
            Opts);
         Check (L.Length = 1 and then Trailing (L (1)) = "orig",
                "stored message is a copy");
      end;

      S.Close;
      Check (S.Load_Latest_ID (To_String (A), Opts).Is_Empty,
             "closed store is empty");
   end;

   -------------------------------------------------------------------
   --  Core.Append_Log.
   -------------------------------------------------------------------
   declare
      use Soja.Core;
      Log  : aliased Soja.Logging.Standard_Logger;
      Srv  : aliased Soja.Server.Server;
      Cfg  : constant Soja.Server.Server_Config_Access :=
        new Soja.Server.Server_Config;
      Rec  : Soja.Database.User := Soja.Database.New_User ("alice");
      UC   : constant Upstream_Conn_Access := new Upstream_Conn;
      NR   : constant Soja.Database.Network :=
        Soja.Database.New_Network ("irc+insecure://irc.example");
      U    : User_Access;
      Network : Network_Access;
      ID   : Unbounded_String;
      Opts : Load_Message_Options;
      L    : Message_Vectors.Vector;
   begin
      Srv.Initialize (Log'Unchecked_Access);

      --  No store configured: nothing is stored.
      U := New_User (Srv'Unchecked_Access, Rec);
      Check (U.Msg_Store = null, "no store by default");

      Cfg.Msg_Store_Driver := To_Unbounded_String ("memory");
      Srv.Set_Config (Cfg);
      U := New_User (Srv'Unchecked_Access, Rec);
      Check (U.Msg_Store /= null
             and then Soja.Msgstore.Memory.Is_Memory_Store (U.Msg_Store.all),
             "memory store configured");

      Network := New_Network
        (U, NR, Soja.Database.Channel_Lists.Empty_Vector);
      Network.Network_Record.ID := 7;
      UC.Network := Network;
      UC.User := U;
      UC.Logger := Log'Unchecked_Access;

      --  Two clients have receipts for another target.
      Soja.User.Store_ID (Network.Delivered, "#old", "phone", "x");
      Soja.User.Store_ID (Network.Delivered, "#old", "laptop", "y");

      ID := To_Unbounded_String (Append_Log (UC, "#Chan", Msg ("hello")));
      Check (Length (ID) > 0, "message stored");
      --  The first message from a target stored the pre-append last id for
      --  every client.
      declare
         Receipt : constant String :=
           Soja.User.Load_ID (Network.Delivered, "#Chan", "phone");
      begin
         Check (Receipt = Format_Msg_ID
                  (7, "#chan", Msg_ID_Memory, [Character'Val (0)]),
                "delivery receipt: " & Receipt);
         Check (Soja.User.Load_ID (Network.Delivered, "#Chan", "laptop")
                = Receipt, "receipt for every client");
         Opts.Network := Network.Network_Record;
         Opts.Entity := To_Unbounded_String ("#chan");   --  casemapped
         Opts.Limit := 10;
         L := U.Msg_Store.Load_Latest_ID (Receipt, Opts);
         Check (L.Length = 1 and then Trailing (L (1)) = "hello",
                "receipt id leads to the new message");
      end;

      --  Not stored: server masks, NickServ (any case), plain TAGMSG.
      Check (Append_Log (UC, "$*.example", Msg ("x")) = "", "server mask");
      Check (Append_Log (UC, "NickServ", Msg ("password")) = "", "nickserv");
      Check (Append_Log (UC, "NICKSERV", Msg ("password")) = "", "NICKSERV");
      Check (Append_Log (UC, "#t", Parse_Message ("TAGMSG #t")) = "",
             "TAGMSG without a storable tag");
      Check (not Soja.User.Has_Target (Network.Delivered, "#t"),
             "ignored messages leave no receipts");

      --  No store: nothing.
      UC.User := New_User (Srv'Unchecked_Access, Rec);
      UC.User.Msg_Store := null;
      Check (Append_Log (UC, "#Chan", Msg ("x")) = "", "no store");
   end;

   Ada.Text_IO.Put_Line ("ALL PASS");
end Msgstore_Check;
