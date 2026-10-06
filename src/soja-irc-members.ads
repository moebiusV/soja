pragma Ada_2022;

with Ada.Containers.Vectors;

--  xirc.go's channel membership and channel status types.
package Soja.Irc.Members is

   --  Membership: a channel member rank (Mode is the mode letter, Prefix its
   --  status prefix).
   type Membership is record
      Mode   : Character;
      Prefix : Character;
   end record;

   package Membership_Vectors is
     new Ada.Containers.Vectors (Positive, Membership);

   --  Add inserts New_M into MS at its rank position in Available's order;
   --  it is a no-op if already present.
   procedure Add (MS : in out Membership_Vectors.Vector;
                  Available : Membership_Vectors.Vector;
                  New_M : Membership);
   procedure Remove (MS : in out Membership_Vectors.Vector; M : Membership);

   --  stdMemberships, from highest to lowest rank.
   Std_Memberships : constant array (1 .. 5) of Membership :=
     [1 => ('q', '~'),   --  founder
      2 => ('a', '&'),   --  protected
      3 => ('o', '@'),   --  operator
      4 => ('h', '%'),   --  halfop
      5 => ('v', '+')];  --  voice

   --  stdChannelTypes: the channel name prefixes.
   Std_Channel_Types : constant String := "#&+!";

   --  ChannelStatus: a channel's visibility ('=' public, '@' secret, '*'
   --  private).
   type Channel_Status is (Channel_Public, Channel_Secret, Channel_Private);

   function Code (S : Channel_Status) return Character;
   function Parse_Channel_Status (S : String; Success : out Boolean)
      return Channel_Status;

end Soja.Irc.Members;
