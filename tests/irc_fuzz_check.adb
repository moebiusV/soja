pragma Ada_2022;

with Ada.Exceptions;
with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;
with Ada.Text_IO;
with GNAT.OS_Lib;

with Irc_Oracle;
with Soja.Irc.Messages; use Soja.Irc.Messages;

--  The grammar against the hand-written reading of the same lines, on lines
--  built from the delimiters (and bytes that are not UTF-8): they must agree
--  on every one, errors included.
procedure Irc_Fuzz_Check is
   use type Param_Vectors.Vector;

   Alphabet : constant String :=
     "@:  !=;\ab#xC" & ASCII.CR & ASCII.LF & Character'Val (16#E9#)
     & Character'Val (16#C3#) & Character'Val (16#A9#) & Character'Val (16#FF#);

   --  A small deterministic generator (a linear congruential one).
   Seed : Long_Long_Integer := 12345;
   function Next (N : Positive) return Natural is
   begin
      Seed := (Seed * 1_103_515_245 + 12_345) mod 2_147_483_648;
      return Natural ((Seed / 65_536) mod Long_Long_Integer (N));
   end Next;

   function Same (A, B : Message) return Boolean is
      Names_Equal : Boolean := Tag_Count (A.Tags) = Tag_Count (B.Tags);
   begin
      for C in A.Tags.Data.Iterate loop
         Names_Equal := Names_Equal
           and then Has_Tag (B.Tags, Tag_Maps.Key (C))
           and then Get_Tag (B.Tags, Tag_Maps.Key (C))
                    = Tag_Maps.Element (C);
      end loop;
      return Names_Equal
        and then A.Command = B.Command
        and then A.Params = B.Params
        and then A.Prefix.all = B.Prefix.all;
   end Same;

   function Show (S : String) return String is
      R : Unbounded_String;
   begin
      for C of S loop
         Append (R, (if Character'Pos (C) in 32 .. 126 then "" & C
                     else "\x" & Character'Pos (C)'Image));
      end loop;
      return To_String (R);
   end Show;

   Failures : Natural := 0;
   Lines    : constant := 120_000;

   procedure Compare (Line : String) is
      Got, Want : Message;
      Got_Failed, Want_Failed : Boolean := False;
   begin
      begin
         Got := Parse_Message (Line);
      exception
         when Parse_Error => Got_Failed := True;
      end;
      begin
         Want := Irc_Oracle.Parse_Message_By_Hand (Line);
      exception
         when Parse_Error => Want_Failed := True;
      end;
      if Got_Failed /= Want_Failed
        or else (not Got_Failed and then not Same (Got, Want))
      then
         Failures := Failures + 1;
         if Failures <= 8 then
            Ada.Text_IO.Put_Line
              ("DIFFERENT on [" & Show (Line) & "]: grammar "
               & (if Got_Failed then "refused" else Show (Image (Got)))
               & ", by hand "
               & (if Want_Failed then "refused" else Show (Image (Want))));
         end if;
      end if;
   end Compare;

   procedure Compare_Tags (Text : String) is
      use type Tag_Map;
      Same_Tags : Boolean := False;
   begin
      declare
         Got  : constant Tag_Map := Parse_Tags (Text);
         Want : constant Tag_Map := Irc_Oracle.Parse_Tags_By_Hand (Text);
      begin
         Same_Tags := Tag_Count (Got) = Tag_Count (Want);
         for C in Got.Data.Iterate loop
            Same_Tags := Same_Tags
              and then Has_Tag (Want, Tag_Maps.Key (C))
              and then Get_Tag (Want, Tag_Maps.Key (C)) = Tag_Maps.Element (C);
         end loop;
      end;
      if not Same_Tags then
         Failures := Failures + 1;
         if Failures <= 8 then
            Ada.Text_IO.Put_Line ("DIFFERENT tags [" & Show (Text) & "]");
         end if;
      end if;
   exception
      when Parse_Error =>
         Failures := Failures + 1;
         if Failures <= 8 then
            Ada.Text_IO.Put_Line ("tags refused [" & Show (Text) & "]");
         end if;
   end Compare_Tags;

   procedure Compare_Prefix (Text : String) is
      Got  : constant Prefix := Parse_Prefix (Text);
      Want : constant Prefix := Irc_Oracle.Parse_Prefix_By_Hand (Text);
   begin
      if Got /= Want then
         Failures := Failures + 1;
         if Failures <= 8 then
            Ada.Text_IO.Put_Line ("DIFFERENT prefix [" & Show (Text) & "]");
         end if;
      end if;
   exception
      when Parse_Error =>
         Failures := Failures + 1;
         if Failures <= 8 then
            Ada.Text_IO.Put_Line ("prefix refused [" & Show (Text) & "]");
         end if;
   end Compare_Prefix;

   --  Real lines, to start from.
   Samples : constant array (Positive range <>) of access constant String :=
     [new String'("PRIVMSG #chan :hello world"),
      new String'(":nick!user@host PRIVMSG #chan :hi there"),
      new String'("@time=2026-01-01T00:00:00.000Z;+draft/x=a\sb :n!u@h TAGMSG #c"),
      new String'("@a;b=;c=1 PING :x"), new String'(":srv 001 me :Welcome"),
      new String'("JOIN #a,#b key"), new String'("CAP LS 302"),
      new String'("@+x=\:\\\r\n NOTICE * :a"), new String'("  :x y"),
      new String'("A :"), new String'("A  :b :c"), new String'(":a"),
      new String'("@a"), new String'(":a b"), new String'("x"), new String'("")];
begin
   for S of Samples loop
      Compare (S.all);
      Compare_Tags (S.all);
      Compare_Prefix (S.all);
   end loop;

   for N in 1 .. Lines loop
      declare
         Len  : constant Natural := Next (24);
         Line : String (1 .. Len);
      begin
         for I in Line'Range loop
            Line (I) := Alphabet (Alphabet'First + Next (Alphabet'Length));
         end loop;
         Compare (Line);
         if N mod 4 = 0 then
            Compare_Tags (Line);
            Compare_Prefix (Line);
         end if;
      end;
   end loop;

   if Failures > 0 then
      Ada.Text_IO.Put_Line ("FAILED:" & Failures'Image & " lines differ");
      GNAT.OS_Lib.OS_Exit (1);
   end if;
   Ada.Text_IO.Put_Line ("ALL PASS");
exception
   when E : others =>
      Ada.Text_IO.Put_Line
        ("FAILED: " & Ada.Exceptions.Exception_Information (E));
      GNAT.OS_Lib.OS_Exit (1);
end Irc_Fuzz_Check;
