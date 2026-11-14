pragma Ada_2022;

--  IRC numeric reply codes, translated from gopkg.in/irc.v4's numerics.go.
--  Only the codes soju references are included; the rest can be filled in as
--  more of soju is translated.
package Soja.Irc.Numerics is

   --  Errors
   ERR_NOSUCHNICK        : constant String := "401";
   ERR_NOSUCHSERVER      : constant String := "402";
   ERR_NOSUCHCHANNEL     : constant String := "403";
   ERR_BADMASK           : constant String := "415";
   ERR_UNKNOWNCOMMAND    : constant String := "421";
   ERR_NOMOTD            : constant String := "422";
   ERR_NONICKNAMEGIVEN   : constant String := "431";
   ERR_ERRONEUSNICKNAME  : constant String := "432";
   ERR_NICKNAMEINUSE     : constant String := "433";
   ERR_NICKCOLLISION     : constant String := "436";
   ERR_UNAVAILRESOURCE   : constant String := "437";
   ERR_NEEDMOREPARAMS    : constant String := "461";
   ERR_ALREADYREGISTERED : constant String := "462";
   ERR_NOPERMFORHOST     : constant String := "463";
   ERR_PASSWDMISMATCH    : constant String := "464";
   ERR_YOUREBANNEDCREEP  : constant String := "465";
   ERR_CHANNELISFULL     : constant String := "471";
   ERR_INVITEONLYCHAN    : constant String := "473";
   ERR_BANNEDFROMCHAN    : constant String := "474";
   ERR_BADCHANNELKEY     : constant String := "475";
   ERR_BADCHANMASK       : constant String := "476";
   ERR_USERSDONTMATCH    : constant String := "502";
   ERR_MONLISTFULL       : constant String := "734";
   ERR_NICKLOCKED        : constant String := "902";
   ERR_SASLFAIL          : constant String := "904";
   ERR_SASLTOOLONG       : constant String := "905";
   ERR_SASLABORTED       : constant String := "906";

   --  soju-specific numerics (soju's xirc/xirc.go), not in irc.v4.
   ERR_UNKNOWNERROR      : constant String := "400";
   ERR_INVALIDCAPCMD     : constant String := "410";

   --  soju-specific replies (soju's xirc/xirc.go), not in irc.v4.
   RPL_STATSPING       : constant String := "246";
   RPL_LOCALUSERS      : constant String := "265";
   RPL_GLOBALUSERS     : constant String := "266";
   RPL_WHOISCERTFP     : constant String := "276";
   RPL_WHOISREGNICK    : constant String := "307";
   RPL_WHOISSPECIAL    : constant String := "320";
   RPL_CREATIONTIME    : constant String := "329";
   RPL_WHOISACCOUNT    : constant String := "330";
   RPL_TOPICWHOTIME    : constant String := "333";
   RPL_WHOISBOT        : constant String := "335";
   RPL_WHOISACTUALLY   : constant String := "338";
   RPL_WHOSPCRPL       : constant String := "354";
   RPL_WHOISHOST       : constant String := "378";
   RPL_WHOISMODES      : constant String := "379";
   RPL_VISIBLEHOST     : constant String := "396";
   RPL_WHOISSECURE     : constant String := "671";

   --  Replies
   RPL_WELCOME         : constant String := "001";
   RPL_YOURHOST        : constant String := "002";
   RPL_CREATED         : constant String := "003";
   RPL_MYINFO          : constant String := "004";
   RPL_ISUPPORT        : constant String := "005";
   RPL_UMODEIS         : constant String := "221";
   RPL_STATSVLINE      : constant String := "240";
   RPL_STATSBLINE      : constant String := "247";
   RPL_STATSDLINE      : constant String := "250";
   RPL_LUSERCLIENT     : constant String := "251";
   RPL_LUSEROP         : constant String := "252";
   RPL_LUSERUNKNOWN    : constant String := "253";
   RPL_LUSERCHANNELS   : constant String := "254";
   RPL_LUSERME         : constant String := "255";
   RPL_TRYAGAIN        : constant String := "263";
   RPL_AWAY            : constant String := "301";
   RPL_UNAWAY          : constant String := "305";
   RPL_NOWAWAY         : constant String := "306";
   RPL_WHOISUSER       : constant String := "311";
   RPL_WHOISSERVER     : constant String := "312";
   RPL_WHOISOPERATOR   : constant String := "313";
   RPL_ENDOFWHO        : constant String := "315";
   RPL_WHOISIDLE       : constant String := "317";
   RPL_ENDOFWHOIS      : constant String := "318";
   RPL_WHOISCHANNELS   : constant String := "319";
   RPL_LISTSTART       : constant String := "321";
   RPL_LIST            : constant String := "322";
   RPL_LISTEND         : constant String := "323";
   RPL_CHANNELMODEIS   : constant String := "324";
   RPL_NOTOPIC         : constant String := "331";
   RPL_TOPIC           : constant String := "332";
   RPL_INVITING        : constant String := "341";
   RPL_INVITELIST      : constant String := "346";
   RPL_ENDOFINVITELIST : constant String := "347";
   RPL_EXCEPTLIST      : constant String := "348";
   RPL_ENDOFEXCEPTLIST : constant String := "349";
   RPL_WHOREPLY        : constant String := "352";
   RPL_NAMREPLY        : constant String := "353";
   RPL_ENDOFNAMES      : constant String := "366";
   RPL_BANLIST         : constant String := "367";
   RPL_ENDOFBANLIST    : constant String := "368";
   RPL_INFO            : constant String := "371";
   RPL_MOTD            : constant String := "372";
   RPL_ENDOFINFO       : constant String := "374";
   RPL_MOTDSTART       : constant String := "375";
   RPL_ENDOFMOTD       : constant String := "376";
   RPL_KEYVALUE        : constant String := "761";
   RPL_METADATASUBOK   : constant String := "770";
   RPL_METADATAUNSUBOK : constant String := "771";
   RPL_METADATASUBS    : constant String := "772";
   RPL_MONONLINE       : constant String := "730";
   RPL_MONOFFLINE      : constant String := "731";
   RPL_MONLIST         : constant String := "732";
   RPL_ENDOFMONLIST    : constant String := "733";
   RPL_LOGGEDIN        : constant String := "900";
   RPL_LOGGEDOUT       : constant String := "901";
   RPL_SASLSUCCESS     : constant String := "903";

end Soja.Irc.Numerics;
