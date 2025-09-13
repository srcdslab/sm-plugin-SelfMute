#if defined _SelfMute_V2_included
 #endinput
#endif
#define _SelfMute_V2_included

/**
* Check if client has target selfmuted in text chat

* @param client        Client Index
* @param target        Target Index


* @return            True if selfmute was placed, False otherwise
**/
native bool SelfMute_GetTextSelfMute(int client, int target);

/**
* Check if client has target selfmuted in voice chat

* @param client        Client Index
* @param target        Target Index


* @return            True if selfmute was placed, False otherwise
**/
native bool SelfMute_GetVoiceSelfMute(int client, int target);

/**
* Check if client has target selfmuted in voice chat and text chat

* @param client        Client Index
* @param target        Target Index


* @return            True if selfmute was placed, False otherwise
**/
native bool SelfMute_GetSelfMute(int client, int target);

public SharedPlugin __pl_SelfMuteV2 =
{
    name = "SelfMute",
    file = "SelfMute.smx",
#if defined REQUIRE_PLUGIN
    required = 1
#else
    required = 0
#endif
}

#if !defined REQUIRE_PLUGIN
public void __pl_SelfMuteV2_SetNTVOptional()
{
    MarkNativeAsOptional("SelfMute_GetTextSelfMute");
    MarkNativeAsOptional("SelfMute_GetVoiceSelfMute");
    MarkNativeAsOptional("SelfMute_GetSelfMute");
}
#endif