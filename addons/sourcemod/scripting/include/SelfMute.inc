// *************************************************************************
// This is the include file for SelfMute
//
// To check that SelfMute is installed and running, verify that the "SelfMute" library exists
//
// *************************************************************************

#if defined _SelfMute_included_
  #endinput
#endif
#define _SelfMute_included_

public SharedPlugin __pl_SelfMute = 
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
public void __pl_SelfMute_SetNTVOptional()
{
    MarkNativeAsOptional("SelfMute_GetSelfMute");
}
#endif

/*********************************************************
 * Check if client has that target selfmuted
 * 
 * @return     true if client has that target selfmuted, false otherwise
 *********************************************************/
native bool SelfMute_GetSelfMute(int client, int target);