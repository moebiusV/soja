pragma Ada_2022;

with Ada.Calendar;
with Ada.Containers;
with Ada.Exceptions;
with Ada.Strings;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;
with Ada.Text_IO;

with Soja.Downstream;
with Soja.Irc.Case_Mapping;
with Soja.Irc.Genmsg;
with Soja.Irc.Helpers;
with Soja.Irc.Members;
with Soja.Irc.Messages;
with Soja.Irc.Modes;
with Soja.Irc.Xirc;

procedure Helpers_Check is
   use Soja.Irc.Helpers;
   use Soja.Irc.Members;
   use Soja.Irc.Messages;
   use Soja.Irc.Modes;
   use Soja.Irc.Genmsg;
   use type Ada.Containers.Count_Type;
   use type Soja.Irc.Case_Mapping.Kind;

   function Trim (S : String) return String is
     (Ada.Strings.Fixed.Trim (S, Ada.Strings.Both));

   procedure Check (Cond : Boolean; What : String) is
   begin
      if not Cond then
         raise Program_Error with What;
      end if;
   end Check;

   function SV (A : String := ""; B : String := ""; C : String := "";
                D : String := "") return String_Vectors.Vector
   is
      V : String_Vectors.Vector;
   begin
      if A /= "" then V.Append (A); end if;
      if B /= "" then V.Append (B); end if;
      if C /= "" then V.Append (C); end if;
      if D /= "" then V.Append (D); end if;
      return V;
   end SV;

   --  Like SV but keeps empty strings (parallel key lists).
   function KV (A, B, C : String) return String_Vectors.Vector is
      V : String_Vectors.Vector;
   begin
      V.Append (A); V.Append (B); V.Append (C);
      return V;
   end KV;

   function Args (A : String := ""; B : String := "")
      return Param_Vectors.Vector
   is
      V : Param_Vectors.Vector;
   begin
      if A /= "" then V.Append (To_Unbounded_String (A)); end if;
      if B /= "" then V.Append (To_Unbounded_String (B)); end if;
      return V;
   end Args;

   Available : Membership_Vectors.Vector;
begin
   for M of Std_Memberships loop
      Available.Append (M);
   end loop;

   -------------------------------------------------------------------
   --  Format_Member_Prefix / Strip_Member_Prefixes
   -------------------------------------------------------------------
   declare
      MS : Membership_Vectors.Vector;
   begin
      Check (Format_Member_Prefix (MS, False) = "", "empty prefix");
      Check (Format_Member_Prefix (MS, True) = "", "empty prefix multi");
      Add (MS, Available, ('v', '+'));
      Add (MS, Available, ('o', '@'));
      Check (Format_Member_Prefix (MS, False) = "@", "top prefix only");
      Check (Format_Member_Prefix (MS, True) = "@+", "multi-prefix");
   end;
   Check (Strip_Member_Prefixes ("H@+x", Available) = "Hx", "strip prefixes");
   Check (Strip_Member_Prefixes ("H*", Available) = "H*", "strip leaves *");

   -------------------------------------------------------------------
   --  Parse_Message_Params / Copy_Client_Tags
   -------------------------------------------------------------------
   declare
      Msg : Message := Parse_Message ("JOIN #a");
      R   : Params_Result;
   begin
      R := Parse_Message_Params (Msg, 1);
      Check (R.Ok, "1 param present");
      R := Parse_Message_Params (Msg, 2);
      Check (not R.Ok, "2 params missing");
      Check (Soja.Downstream.Image (R.Err) = "461 JOIN :Not enough parameters"
             or else Soja.Downstream.Image (R.Err)'Length > 0,
             "need-more-params error");
   end;
   declare
      Tags : Tag_Map;
   begin
      Set_Tag (Tags, "+draft/reply", "x");
      Set_Tag (Tags, "time", "t");
      Set_Tag (Tags, "+typing", "");
      declare
         C : constant Tag_Map := Copy_Client_Tags (Tags);
      begin
         Check (Tag_Count (C) = 2, "client tags only");
         Check (Has_Tag (C, "+typing") and then not Has_Tag (C, "time"),
                "client tag set");
      end;
   end;

   -------------------------------------------------------------------
   --  Is_Highlight / Is_URI_Prefix / word boundary
   -------------------------------------------------------------------
   Check (Is_Highlight ("hello bob!", "bob"), "plain highlight");
   Check (Is_Highlight ("bob", "bob"), "whole text");
   Check (Is_Highlight ("bob: hi", "bob"), "colon boundary");
   Check (not Is_Highlight ("bobby", "bob"), "no highlight inside word");
   Check (not Is_Highlight ("my-bob", "bob"), "- is not a boundary");
   Check (not Is_Highlight ("bob_", "bob"), "_ is not a boundary");
   Check (not Is_Highlight ("a|bob", "bob"), "| is not a boundary");
   Check (Is_Highlight ("bobby bob", "bob"), "second occurrence");
   Check (not Is_Highlight ("see https://bob.example", "bob"),
          "URI host is not a highlight");
   Check (Is_Highlight ("https://x.example bob", "bob"),
          "word after URI is a highlight");
   --  Unicode letters are not boundaries.
   Check (not Is_Highlight ("ébob", "bob"), "UTF-8 letter before");
   Check (not Is_Highlight ("bobé", "bob"), "UTF-8 letter after");
   Check (Is_Highlight ("«bob»", "bob"), "UTF-8 punctuation boundary");
   --  Go quirk: the left context is relative to the re-sliced remainder.
   Check (Is_Highlight ("bobbob", "bob"), "adjacent match after a miss");
   begin
      declare
         B : constant Boolean := Is_Highlight ("x", "");
         pragma Unreferenced (B);
      begin
         Check (False, "empty nick must raise");
      end;
   exception
      when Program_Error => null;
   end;
   Check (Is_URI_Prefix ("go to http://"), "URI prefix");
   Check (Is_URI_Prefix ("ircs+x.y-z://"), "URI scheme chars");
   Check (not Is_URI_Prefix ("go to ://"), "no scheme");
   Check (not Is_URI_Prefix ("nothing"), "no ://");
   Check (not Is_URI_Prefix ("a http://x b"), "space after URI");

   -------------------------------------------------------------------
   --  Parse_Chat_History_Bound / Is_Numeric / Generate_Away_Reply
   -------------------------------------------------------------------
   declare
      Ok : Boolean;
      T  : Ada.Calendar.Time;
      use type Ada.Calendar.Time;
   begin
      T := Parse_Chat_History_Bound
        ("timestamp=2024-02-29T13:45:09.123Z", Ok);
      Check (Ok, "valid timestamp");
      Check (Soja.Irc.Xirc.Format_Server_Time (T)
             = "2024-02-29T13:45:09.123Z", "timestamp round trip");
      T := Parse_Chat_History_Bound
        ("timestamp=2024-02-29T3:45:09.000Z", Ok);
      Check (Ok, "1-digit hour accepted, like Go");
      T := Parse_Chat_History_Bound ("timestamp=2023-02-29T13:45:09.123Z", Ok);
      Check (not Ok, "Feb 29 in a non-leap year");
      T := Parse_Chat_History_Bound ("timestamp=2024-02-29T24:00:00.000Z", Ok);
      Check (not Ok, "hour 24");
      T := Parse_Chat_History_Bound ("timestamp=2024-02-29T13:45:09Z", Ok);
      Check (not Ok, "missing fraction");
      T := Parse_Chat_History_Bound
        ("timestamp=2024-02-29T13:45:09.123Z ", Ok);
      Check (not Ok, "trailing text");
      T := Parse_Chat_History_Bound ("msgid=abc", Ok);
      Check (not Ok, "non-timestamp bound");
      T := Parse_Chat_History_Bound ("timestamp", Ok);
      Check (not Ok, "no =");
      pragma Unreferenced (T);
   end;
   Check (Is_Numeric ("001") and then Is_Numeric ("999"), "numeric");
   Check (not Is_Numeric ("01") and then not Is_Numeric ("0a1")
          and then not Is_Numeric ("0001"), "non-numeric");
   declare
      A : constant Message := Generate_Away_Reply (True);
      B : constant Message := Generate_Away_Reply (False);
   begin
      Check (Image (A) = "306 * :You have been marked as being away",
             "away reply: " & Image (A));
      Check (Image (B) = "305 * :You are no longer marked as being away",
             "unaway reply: " & Image (B));
   end;
   Check (Std_Case_Mapping = Soja.Irc.Case_Mapping.Case_RFC1459,
          "std casemapping");

   -------------------------------------------------------------------
   --  UTF-8 decoding
   -------------------------------------------------------------------
   declare
      R : Wide_Wide_Character;
      W : Natural;
      WP : Positive;
   begin
      Decode_Rune ("é", 1, R, WP);
      Check (Wide_Wide_Character'Pos (R) = 16#E9# and then WP = 2, "decode 2-byte");
      Decode_Rune ("€", 1, R, WP);
      Check (Wide_Wide_Character'Pos (R) = 16#20AC# and then WP = 3,
             "decode 3-byte");
      Decode_Rune (ASCII.ESC & ASCII.NUL, 1, R, WP);
      Check (WP = 1, "ascii width");
      Decode_Rune ([Character'Val (16#C0#), Character'Val (16#80#)],
                   1, R, WP);
      Check (Wide_Wide_Character'Pos (R) = 16#FFFD# and then WP = 1,
             "overlong rejected");
      Decode_Last_Rune ("ab€", R, W);
      Check (Wide_Wide_Character'Pos (R) = 16#20AC# and then W = 3,
             "decode last 3-byte");
      Decode_Last_Rune ("", R, W);
      Check (Wide_Wide_Character'Pos (R) = 16#FFFD# and then W = 0,
             "decode last empty");
      Decode_Last_Rune ("a" & Character'Val (16#80#), R, W);
      Check (Wide_Wide_Character'Pos (R) = 16#FFFD# and then W = 1,
             "decode last stray continuation");
   end;

   -------------------------------------------------------------------
   --  Channel modes
   -------------------------------------------------------------------
   declare
      Modes   : Channel_Modes := (Known => True, others => <>);
      Members : Member_Maps.Map :=
        Member_Maps.New_Map (Soja.Irc.Case_Mapping.Case_RFC1459);
      Alice   : constant Membership_Set_Access :=
        new Membership_Vectors.Vector;
      Std     : constant Mode_Type_Maps.Map := Std_Channel_Modes;
      MS      : Unbounded_String;
      P       : Param_Vectors.Vector;
   begin
      Members.Set ("Alice", Alice);

      Apply_Channel_Modes (Available, Std, Members, Modes, "+ntk",
                           Args ("sekrit"));
      Format (Modes, MS, P);
      Check (To_String (MS) = "+knt" and then P.Length = 1
             and then To_String (P (1)) = "sekrit",
             "format after +ntk: " & To_String (MS));

      Apply_Channel_Modes (Available, Std, Members, Modes, "+l-n", Args ("5"));
      Format (Modes, MS, P);
      Check (To_String (MS) = "+klt" and then P.Length = 2
             and then To_String (P (1)) = "sekrit"
             and then To_String (P (2)) = "5",
             "format after +l-n: " & To_String (MS));

      --  -l takes no argument; -k takes one.
      Apply_Channel_Modes (Available, Std, Members, Modes, "-lk", Args ("x"));
      Format (Modes, MS, P);
      Check (To_String (MS) = "+t" and then P.Is_Empty, "after -lk");

      --  List modes consume an argument but record nothing.
      Apply_Channel_Modes (Available, Std, Members, Modes, "+b",
                           Args ("*!*@bad"));
      Format (Modes, MS, P);
      Check (To_String (MS) = "+t", "list mode not recorded");

      --  Membership modes update Members; unknown nicks are ignored.
      Apply_Channel_Modes (Available, Std, Members, Modes, "+ov",
                           Args ("alice", "ghost"));
      Check (Format_Member_Prefix (Alice.all, True) = "@",
             "alice is op (case-insensitive lookup)");
      Apply_Channel_Modes (Available, Std, Members, Modes, "+v+v",
                           Args ("ALICE", "alice"));
      Check (Format_Member_Prefix (Alice.all, True) = "@+",
             "alice op+voice, no duplicate");
      Apply_Channel_Modes (Available, Std, Members, Modes, "-o",
                           Args ("alice"));
      Check (Format_Member_Prefix (Alice.all, True) = "+", "alice -o");

      --  Errors.
      begin
         Apply_Channel_Modes (Available, Std, Members, Modes, "n", Args);
         Check (False, "missing +/- must raise");
      exception
         when Mode_Error => null;
      end;
      begin
         Apply_Channel_Modes (Available, Std, Members, Modes, "+o", Args);
         Check (False, "missing member argument must raise");
      exception
         when E : Mode_Error =>
            Check (Ada.Exceptions.Exception_Message (E)
                   = "malformed modestring ""+o"": missing mode argument "
                     & "for +o", "error text");
      end;

      --  An unknown (Known = False) mode table records nothing.
      declare
         Unk : Channel_Modes;
      begin
         Apply_Channel_Modes (Available, Std, Members, Unk, "+nk",
                              Args ("key"));
         Check (Unk.Values.Is_Empty, "unknown modes stay unrecorded");
      end;

      --  RPL_CHANNELMODEIS may omit a sensitive argument.
      Apply_Channel_Modes (Available, Std, Members, Modes, "+k", Args);
      Format (Modes, MS, P);
      Check (To_String (MS) = "+kt" and then P.Is_Empty,
             "+k without argument is valueless");
   end;

   -------------------------------------------------------------------
   --  Genmsg
   -------------------------------------------------------------------
   declare
      Msgs : Message_Vector;
   begin
      --  JOIN: keyed channels first, then alphabetical.
      Msgs := Generate_Join (SV ("#b", "#a", "#c"), KV ("", "", "k"));
      Check (Natural (Msgs.Length) = 1
             and then Image (Msgs (1)) = "JOIN #c,#a,#b k",
             "join: " & Image (Msgs (1)));
      Msgs := Generate_Join (SV ("#a", "#b"), SV ("k1", "k2"));
      Check (Image (Msgs (1)) = "JOIN #a,#b k1,k2", "join keys");
      Check (Generate_Join (String_Vectors.Empty_Vector,
                            String_Vectors.Empty_Vector).Is_Empty,
             "join empty");

      --  JOIN splits at the line limit.
      declare
         Chans, Keys : String_Vectors.Vector;
      begin
         for I in 1 .. 100 loop
            Chans.Append ("#channel-number-" & Trim (Integer'Image (1000 + I)));
            Keys.Append ("");
         end loop;
         Msgs := Generate_Join (Chans, Keys);
         Check (Msgs.Length > 1, "join must split");
         for M of Msgs loop
            Check (Image (M)'Length <= 512, "join line length");
         end loop;
      end;

      --  ISUPPORT: 13 tokens per message, encoded.
      declare
         T : String_Vectors.Vector;
      begin
         for I in 1 .. 14 loop
            T.Append ("T" & Trim (Integer'Image (I)));
         end loop;
         T.Replace_Element (1, "A B\C");
         Msgs := Generate_Isupport (T);
         Check (Natural (Msgs.Length) = 2, "isupport split");
         Check (Natural (Msgs (1).Params.Length) = 15, "isupport 15 params");
         Check (To_String (Msgs (1).Params (2)) = "A\x20B\x5CC",
                "isupport encoding");
         Check (To_String (Msgs (1).Params (15)) = "are supported",
                "isupport trailer");
         Check (Natural (Msgs (2).Params.Length) = 3, "isupport remainder");
         Check (Generate_Isupport (String_Vectors.Empty_Vector).Is_Empty,
                "isupport empty");
      end;

      --  MOTD.
      Msgs := Generate_MOTD ("l1" & ASCII.LF & "l2");
      Check (Natural (Msgs.Length) = 4, "motd count");
      Check (Image (Msgs (1)) = "375 * :- Message of the Day -", "motd start");
      Check (Image (Msgs (2)) = "372 * l1", "motd line 1: " & Image (Msgs (2)));
      Check (Image (Msgs (4)) = "376 * :End of /MOTD command.", "motd end");
      Check (Natural (Generate_MOTD ("").Length) = 3, "empty motd");

      --  MONITOR.
      Msgs := Generate_Monitor ("+", SV ("a", "b", "c"));
      Check (Natural (Msgs.Length) = 1
             and then Image (Msgs (1)) = "MONITOR + a,b,c", "monitor");
      Check (Generate_Monitor ("-", String_Vectors.Empty_Vector).Is_Empty,
             "monitor empty");

      --  NAMES.
      Msgs := Generate_Names_Reply ("#c", Channel_Public, SV ("@a", "b"));
      Check (Natural (Msgs.Length) = 2, "names count");
      Check (Image (Msgs (1)) = "353 * = #c :@a b", "names: "
             & Image (Msgs (1)));
      Check (Image (Msgs (2)) = "366 * #c :End of /NAMES list", "endofnames");
      Msgs := Generate_Names_Reply ("#c", Channel_Secret,
                                    String_Vectors.Empty_Vector);
      Check (Natural (Msgs.Length) = 1, "names of empty channel");
      declare
         Names : String_Vectors.Vector;
      begin
         for I in 1 .. 200 loop
            Names.Append ("nick" & Trim (Integer'Image (1000 + I)));
         end loop;
         Msgs := Generate_Names_Reply ("#big", Channel_Public, Names);
         Check (Msgs.Length > 2, "names must split");
         for M of Msgs loop
            Check (Image (M)'Length <= 512, "names line length");
         end loop;
      end;

      --  SASL: PLAIN payload, padded base64.
      Msgs := Generate_SASL (ASCII.NUL & "user" & ASCII.NUL & "pass");
      Check (Natural (Msgs.Length) = 1
             and then Image (Msgs (1)) = "AUTHENTICATE AHVzZXIAcGFzcw==",
             "sasl plain: " & Image (Msgs (1)));
      Msgs := Generate_SASL ("");
      Check (Natural (Msgs.Length) = 1
             and then Image (Msgs (1)) = "AUTHENTICATE +", "sasl empty");
      --  300 bytes -> exactly 400 base64 chars -> chunk + final "+".
      Msgs := Generate_SASL ([1 .. 300 => 'a']);
      Check (Natural (Msgs.Length) = 2
             and then To_String (Msgs (2).Params (1)) = "+",
             "sasl exact-multiple needs a final +");
      Msgs := Generate_SASL ([1 .. 301 => 'a']);
      Check (Natural (Msgs.Length) = 2
             and then To_String (Msgs (2).Params (1))'Length = 4,
             "sasl second chunk");
   end;

   -------------------------------------------------------------------
   --  Xirc
   -------------------------------------------------------------------
   declare
      Cmd, Params : Unbounded_String;
      Ok : Boolean;
   begin
      Soja.Irc.Xirc.Parse_CTCP_Message
        (Parse_Message ("PRIVMSG #c :" & ASCII.SOH & "action waves"
                        & ASCII.SOH), Cmd, Params, Ok);
      Check (Ok and then To_String (Cmd) = "ACTION"
             and then To_String (Params) = "waves", "ctcp action");
      Soja.Irc.Xirc.Parse_CTCP_Message
        (Parse_Message ("PRIVMSG #c :" & ASCII.SOH & "VERSION"
                        & ASCII.SOH), Cmd, Params, Ok);
      Check (Ok and then To_String (Cmd) = "VERSION"
             and then To_String (Params) = "", "ctcp without params");
      Soja.Irc.Xirc.Parse_CTCP_Message
        (Parse_Message ("PRIVMSG #c :hello"), Cmd, Params, Ok);
      Check (not Ok, "not ctcp");
      Soja.Irc.Xirc.Parse_CTCP_Message
        (Parse_Message ("JOIN #c :" & ASCII.SOH & "x"), Cmd, Params, Ok);
      Check (not Ok, "not a PRIVMSG/NOTICE");
      Soja.Irc.Xirc.Parse_CTCP_Message
        (Parse_Message ("PRIVMSG #c"), Cmd, Params, Ok);
      Check (not Ok, "too few params");
   end;

   Ada.Text_IO.Put_Line ("ALL PASS");
end Helpers_Check;
