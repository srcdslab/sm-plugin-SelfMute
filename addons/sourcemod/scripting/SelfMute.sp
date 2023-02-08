#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <adminmenu>
#include <cstrike>
#include <clientprefs>

#include <multicolors>
#include <ccc>
#include <SelfMute>
#include <AdvancedTargeting>
#tryinclude <zombiereloaded>
#tryinclude <voiceannounce_ex>

#define PLUGIN_PREFIX "{green}[Self-Mute]{default} "
#define SmMode_Temp 0
#define SmMode_Perma 1
#define SmMode_Alert 2 

/* Cvar handle*/
ConVar
	g_hCVar_Debug;

/* Database handle */
Database g_hDB;

char
	g_PlayerNames[MAXPLAYERS+1][MAX_NAME_LENGTH]
	, groupsFilters[][] = { "@all", "@ct", "@t", "@spec", "@alive", "@dead", "@friends" };

float RetryTime = 15.0;

bool
	g_Plugin_ccc = false
	, g_Plugin_zombiereloaded = false
	, g_Plugin_voiceannounce_ex = false
	, g_Plugin_AdvancedTargeting = false
	, g_bIsProtoBuf = false
	, g_Ignored[(MAXPLAYERS + 1) * (MAXPLAYERS + 1)]
	, g_bClientTargets[MAXPLAYERS + 1][MAXPLAYERS + 1]
	, g_bClientSavedTargets[MAXPLAYERS + 1][MAXPLAYERS + 1]
	, g_bClientNotSavedTargets[MAXPLAYERS + 1][MAXPLAYERS + 1]
	, g_bClientUnSavedGroups[MAXPLAYERS + 1][65]
	, g_Exempt[MAXPLAYERS + 1][MAXPLAYERS + 1];

int
	g_SpecialMutes[MAXPLAYERS + 1]
	, g_iClientSmMode[MAXPLAYERS + 1] = { 0, ... };

Handle
	g_hSmModeCookie = INVALID_HANDLE
	, g_hBotSmCookie = INVALID_HANDLE;

enum
{
	MUTE_NONE = 0,
	MUTE_SPEC = 1,
	MUTE_CT = 2,
	MUTE_T = 4,
	MUTE_DEAD = 8,
	MUTE_ALIVE = 16,
	MUTE_NOTFRIENDS = 32,
	MUTE_ALL = 64,
	MUTE_LAST = 64
};

public Plugin myinfo =
{
	name 			= "SelfMute",
	author 			= "BotoX, Dolly",
	description 	= "Ignore other players in text and voicechat.",
	version 		= "3.0.1",
	url 			= ""
};

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
	RegPluginLibrary("SelfMute");
	CreateNative("SelfMute_GetSelfMute", Native_GetSelfMute);

	return APLRes_Success;
}

public void OnPluginStart()
{
	LoadTranslations("common.phrases");

	RegConsoleCmd("sm_sm", Command_SelfMute, "Mute player by typing !sm [playername]");
	RegConsoleCmd("sm_su", Command_SelfUnMute, "Unmute player by typing !su [playername]");
	RegConsoleCmd("sm_cm", Command_CheckMutes, "Check who you have self-muted");
	RegConsoleCmd("sm_suall", Command_SelfUnMuteAll, "Unmute all clients/groups");
	RegConsoleCmd("sm_smcookies", Command_SmCookies, "Choose the good cookie");
	SetCookieMenuItem(CookieMenu_Handler, 0, "SelfMute Cookies");

	g_hCVar_Debug = CreateConVar("sm_selfmute_debug_level", "1", "[0 = Disabled | 1 = Errors | 2 = Infos]", FCVAR_REPLICATED);
	AutoExecConfig(true);

	HookEvent("player_team", Event_TeamChange);
	HookEvent("round_start", Event_Round);
	HookEvent("round_end", Event_Round);
	
	g_hSmModeCookie = RegClientCookie("SmMode_Cookie", "selfmute_mode", CookieAccess_Public);
	g_hBotSmCookie = RegClientCookie("SmBot_Cookie", "selfmute_bot", CookieAccess_Public);

	if(GetFeatureStatus(FeatureType_Native, "GetUserMessageType") == FeatureStatus_Available && GetUserMessageType() == UM_Protobuf)
		g_bIsProtoBuf = true;

	UserMsg RadioText = GetUserMessageId("RadioText");
	if(RadioText == INVALID_MESSAGE_ID)
		SetFailState("This game doesn't support RadioText user messages.");

	HookUserMessage(RadioText, Hook_UserMessageRadioText, true);

	UserMsg SendAudio = GetUserMessageId("SendAudio");
	if(SendAudio == INVALID_MESSAGE_ID)
		SetFailState("This game doesn't support SendAudio user messages.");

	HookUserMessage(SendAudio, Hook_UserMessageSendAudio, true);

	ConnectToDB();
	
	for(int i = 1; i <= MaxClients; i++)
	{
		if(IsClientInGame(i))
        {
            if(AreClientCookiesCached(i))
                OnClientCookiesCached(i);

            OnClientPostAdminCheck(i);
        }
	}
}

public void OnAllPluginsLoaded()
{
	g_Plugin_ccc = LibraryExists("ccc");
	g_Plugin_zombiereloaded = LibraryExists("zombiereloaded");
	g_Plugin_voiceannounce_ex = LibraryExists("voiceannounce_ex");
	g_Plugin_AdvancedTargeting = LibraryExists("AdvancedTargeting");
	if (g_hCVar_Debug.IntValue >= 2)
		LogMessage("Self-Mute capabilities:\nProtoBuf: %s\nCCC: %s\nZombieReloaded: %s\nVoiceAnnounce: %s\nAdvancedTargeting: %s",
			(g_bIsProtoBuf ? "yes" : "no"),
			(g_Plugin_ccc ? "loaded" : "not loaded"),
			(g_Plugin_zombiereloaded ? "loaded" : "not loaded"),
			(g_Plugin_voiceannounce_ex ? "loaded" : "not loaded"),
			(g_Plugin_AdvancedTargeting ? "loaded" : "not loaded"));
}

public int Native_GetSelfMute(Handle plugin, int params)
{
	int client =  GetNativeCell(1);
	int target = GetNativeCell(2);

	return g_bClientTargets[client][target];
}

/* Database Setup */

stock void ConnectToDB()
{
	Database.Connect(DB_OnConnect, "SelfMute");
}

public void DB_OnConnect(Database db, const char[] sError, any data)
{
	if(db == null || sError[0])
	{
		/* Failure happen. Do retry with delay */
		CreateTimer(RetryTime, DB_RetryConnection);

		if (RetryTime < 15.0)
			RetryTime = 15.0;
		else if (RetryTime > 60.0)
			RetryTime = 60.0;
		if (g_hCVar_Debug.IntValue >= 1)
			LogError("[Self-Mute] Couldn't connect to database `SelfMute`, retrying in %d seconds. \nError: %s", RetryTime, sError);

		return;
	}

	PrintToServer("[Self-Mute] Successfully connected to database!");
	g_hDB = db;
	DB_Tables();
	g_hDB.SetCharset("utf8");

}

public Action DB_RetryConnection(Handle timer)
{
    if(g_hDB == null)
        ConnectToDB();
    
    return Plugin_Continue;
}

stock void DB_Tables()
{
	if(g_hDB == null)
		return;
	
	char sDriver[32];
	g_hDB.Driver.GetIdentifier(sDriver, sizeof(sDriver));
	if(StrEqual(sDriver, "mysql"))
	{
		Transaction T_mysqlTables = SQL_CreateTransaction();
		
		char sQuery0[1024];		
		g_hDB.Format(sQuery0, sizeof(sQuery0), "CREATE TABLE IF NOT EXISTS `clients_mute`("
												... "`id` int(11) unsigned NOT NULL auto_increment," 
												... "`client_name` varchar(64) NOT NULL," 
												... "`client_steamid` varchar(32) NOT NULL," 
												... "`target_name` varchar(1024) NOT NULL," 
												... "`target_steamid` varchar(32) NOT NULL," 
												... "PRIMARY KEY(`id`)," 
												... "UNIQUE KEY(`target_steamid`))");
																						
		T_mysqlTables.AddQuery(sQuery0);
	
		char sQuery1[1024];	
		g_hDB.Format(sQuery1, sizeof(sQuery1), "CREATE TABLE IF NOT EXISTS `groups_mute`("
												... "`id` int(11) unsigned NOT NULL auto_increment," 
												... "`client_name` varchar(64) NOT NULL," 
												... "`client_steamid` varchar(32) NOT NULL," 
												... "`group_name` varchar(1024) NOT NULL," 
												... "`group_filter` varchar(32) NOT NULL," 
												... "PRIMARY KEY(id))");
												
		T_mysqlTables.AddQuery(sQuery1);
		g_hDB.Execute(T_mysqlTables, DB_mysqlTablesOnSuccess, DB_mysqlTablesOnError, _, DBPrio_High);
	}
	else if(StrEqual(sDriver, "sqlite"))
	{
		Transaction T_sqliteTables = SQL_CreateTransaction();
		
		char sQuery0[1024];		
		g_hDB.Format(sQuery0, sizeof(sQuery0), "CREATE TABLE IF NOT EXISTS `clients_mute`("
												... "`id` INTEGER PRIMARY KEY AUTOINCREMENT," 
												... "`client_name` varchar(64) NOT NULL," 
												... "`client_steamid` varchar(32) NOT NULL," 
												... "`target_name` varchar(1024) NOT NULL," 
												... "`target_steamid` varchar(32) NOT NULL," 
												... "UNIQUE KEY(`target_steamid`))");
																						
		T_sqliteTables.AddQuery(sQuery0);
	
		char sQuery1[1024];	
		g_hDB.Format(sQuery1, sizeof(sQuery1), "CREATE TABLE IF NOT EXISTS `groups_mute`("
												... "`id` INTEGER PRIMARY KEY AUTOINCREMENT," 
												... "`client_name` varchar(64) NOT NULL," 
												... "`client_steamid` varchar(32) NOT NULL," 
												... "`group_name` varchar(1024) NOT NULL," 
												... "`group_filter` varchar(32) NOT NULL)"); 
												
		T_sqliteTables.AddQuery(sQuery1);
		g_hDB.Execute(T_sqliteTables, DB_sqliteTablesOnSuccess, DB_sqliteTablesOnError, _, DBPrio_High);
	}
	else
	{
		if (g_hCVar_Debug.IntValue >= 1)
			LogError("[Self-Mute] Couldn't create tables for an unknown driver");
		return;
	}
}

// Transaction callbacks for tables:
public void DB_mysqlTablesOnSuccess(Database hDatabase, any data, int iNumQueries, Handle[] hResults, any[] QueryData)
{
	LogMessage("[Self-Mute] Database is now ready! (MYSQL)");
	return;
}

public void DB_mysqlTablesOnError(Database hDatabase, any Data, int iNumQueries, const  char[] sError, int iFailIndex, any[] QueryData)
{
	if (g_hCVar_Debug.IntValue >= 1)
		LogError("[Self-Mute] Couldn't create tables for MYSQL, error: %s", sError);
	return;
}

public void DB_sqliteTablesOnSuccess(Database hDatabase, any data, int iNumQueries, Handle[] hResults, any[] QueryData)
{
	LogMessage("[Self-Mute] Database is now ready! (SQLITE)");
	return;
}

public void DB_sqliteTablesOnError(Database hDatabase, any Data, int iNumQueries, const  char[] sError, int iFailIndex, any[] QueryData)
{
	if (g_hCVar_Debug.IntValue >= 1)
		LogError("[Self-Mute] Couldn't create tables for SQLITE, error: %s", sError);
	return;
}

// end

public void OnClientPostAdminCheck(int client)
{
	if(IsFakeClient(client))
		return;
	
	CreateTimer(2.0, OnClientJoinCheck, GetClientUserId(client));
}

public Action OnClientJoinCheck(Handle timer, int userid)
{   
	int client = GetClientOfUserId(userid);	
	if(client < 1 || client > MaxClients)
		return Plugin_Stop;
		
	if(!IsClientInGame(client))
		return Plugin_Stop;	
        	
	if(g_hDB == null)
		return Plugin_Stop;
		
	char SteamID[32];	
	if(!GetClientAuthId(client, AuthId_Steam2, SteamID, sizeof(SteamID)))
		return Plugin_Stop;
	
	Transaction T_ClientJoin = SQL_CreateTransaction();	
				
	char sQuery0[1024];
	g_hDB.Format(sQuery0, sizeof(sQuery0), "SELECT `target_steamid` FROM `clients_mute` WHERE client_steamid='%s'", SteamID);
	
	char sQuery1[1024];
	g_hDB.Format(sQuery1, sizeof(sQuery1), "SELECT `client_steamid` FROM `clients_mute` WHERE target_steamid='%s'", SteamID);
	
	char sQuery2[1024];
	g_hDB.Format(sQuery2, sizeof(sQuery2), "SELECT `group_filter` FROM `groups_mute` WHERE client_steamid='%s'", SteamID);
	
	T_ClientJoin.AddQuery(sQuery0);
	T_ClientJoin.AddQuery(sQuery1);
	T_ClientJoin.AddQuery(sQuery2);
	g_hDB.Execute(T_ClientJoin, SQL_OnClientJoinSuccess, SQL_OnClientJoinError, userid);
	
	return Plugin_Continue;
}

public void SQL_OnClientJoinSuccess(Database hDatabase, int userid, int iNumQueries, Handle[] hResults, any[] QueryData)
{
	int client = GetClientOfUserId(userid);
	if(client < 1 || client > MaxClients)
		return;
	
	if(hResults[0] == null || hResults[1] == null || hResults[2] == null)
		return;
	
	while(SQL_FetchRow(hResults[0]))
	{
		char SteamID[32];
		SQL_FetchString(hResults[0], 0, SteamID, sizeof(SteamID));
		int target = GetClientFromSteamID(SteamID);
		if(target != -1 && !CheckCommandAccess(target, "sm_admin", ADMFLAG_GENERIC, true))
		{
			Ignore(client, target, true);
		}
	}
	
	while(SQL_FetchRow(hResults[1]))
	{
		char SteamID[32];
		SQL_FetchString(hResults[1], 0, SteamID, sizeof(SteamID));
		int target = GetClientFromSteamID(SteamID);
		if(target != -1 && !CheckCommandAccess(target, "sm_admin", ADMFLAG_GENERIC, true))
		{
			Ignore(target, client, true);
		}
	}

	while(SQL_FetchRow(hResults[2]))
	{
		char sGroup[32];
		SQL_FetchString(hResults[2], 0, sGroup, sizeof(sGroup));
		MuteSpecial(client, sGroup, true);
	}

	UpdateIgnored();
}

public void SQL_OnClientJoinError(Database hDatabase, any Data, int iNumQueries, const  char[] sError, int iFailIndex, any[] QueryData)
{
	if (g_hCVar_Debug.IntValue >= 1)
		LogError("[Self-Mute] Error while getting client data on connect, error: %s", sError);
}

stock void SQL_InsertIntoTable(int client, int target)
{
	if(g_hDB == null)
		return;
	
	char ClientSteamID[32], TargetSteamID[32], ClientName[64], TargetName[64];
	
	if(!GetClientName(client, ClientName, sizeof(ClientName)) || !GetClientName(target, TargetName, sizeof(TargetName)))
		return;
	
	if(!GetClientAuthId(client, AuthId_Steam2, ClientSteamID, sizeof(ClientSteamID)) || !GetClientAuthId(target, AuthId_Steam2, TargetSteamID, sizeof(TargetSteamID)))
		return;

	char sClientName[1024], sTargetName[1024];
	g_hDB.Escape(ClientName, sClientName, sizeof(sClientName));
	g_hDB.Escape(TargetName, sTargetName, sizeof(sTargetName));
	
	char sQuery[3000];
	g_hDB.Format(sQuery, sizeof(sQuery), "INSERT INTO `clients_mute` (`client_name`, `client_steamid`, `target_name`, `target_steamid`) VALUES ('%s', '%s', '%s', '%s') \
                                     ON DUPLICATE KEY UPDATE `client_name`='%s', `client_steamid`='%s', `target_name`='%s', `target_steamid`='%s'",
									sClientName, ClientSteamID, sTargetName, TargetSteamID, sClientName, ClientSteamID, sTargetName, TargetSteamID);							
	g_hDB.Query(SQL_InsertQueryCallback, sQuery);
}

public void SQL_InsertQueryCallback(Database db, DBResultSet result, const char[] sError, any data)
{
	if(sError[0] && g_hCVar_Debug.IntValue >= 1)
		LogError("[Self-Mute] Error while inserting data to database, error: %s", sError);
	else
	{
		if (g_hCVar_Debug.IntValue >= 2)
			LogMessage("[Self-Mute] Successfully inserted data to database");
	}
}

stock void SQL_DeleteFromTable(int client, int target, const char[] SteamID = "")
{
	if(g_hDB == null)
		return;
	
	char ClientSteamID[32];
	if(!GetClientAuthId(client, AuthId_Steam2, ClientSteamID, sizeof(ClientSteamID)))
		return;
		
	Transaction T_Delete = SQL_CreateTransaction();
	
	if(target != -1)
	{
		char TargetSteamID[32];
		if(!GetClientAuthId(target, AuthId_Steam2, TargetSteamID, sizeof(TargetSteamID)))
			return;
			
		char sQuery[1024];
		g_hDB.Format(sQuery, sizeof(sQuery), "DELETE FROM `clients_mute` WHERE `client_steamid`='%s' and target_steamid='%s'", ClientSteamID, TargetSteamID);	
		T_Delete.AddQuery(sQuery);
	}
	else if(target == -1)
	{
		char sQuery[1024];
		g_hDB.Format(sQuery, sizeof(sQuery), "DELETE FROM `clients_mute` WHERE `client_steamid`='%s' and target_steamid='%s'", ClientSteamID, SteamID);	
		T_Delete.AddQuery(sQuery);
	}
	
	g_hDB.Execute(T_Delete, DB_DeleteOnSuccess, DB_DeleteOnError);
}

public void DB_DeleteOnSuccess(Database hDatabase, any data, int iNumQueries, Handle[] hResults, any[] QueryData)
{
	if (g_hCVar_Debug.IntValue >= 2)
		LogMessage("[Self-Mute] Successfully deleted data from database");
}

public void DB_DeleteOnError(Database hDatabase, any Data, int iNumQueries, const  char[] sError, int iFailIndex, any[] QueryData)
{
	if (g_hCVar_Debug.IntValue >= 1)
		LogError("[Self-Mute] Error while deleting data from database, error: %s", sError);
}

stock void InsertGroupToTable(int client, const char[] SteamID, const char[] GroupName, const char[] GroupFilter)
{
	if(g_hDB == null)
		return;
		
	char ClientName[64];
	GetClientName(client, ClientName, sizeof(ClientName));
	char sQuery[1024];
	g_hDB.Format(sQuery, sizeof(sQuery), "INSERT INTO `groups_mute` (`client_name`, `client_steamid`, `group_name`, `group_filter`) VALUES ('%s', '%s', '%s', '%s')",
																	ClientName, SteamID, GroupName, GroupFilter);
	g_hDB.Query(SQL_InsertGroupCallback, sQuery);
}

public void SQL_InsertGroupCallback(Database db, DBResultSet result, const char[] sError, any data)
{
	if(sError[0] && g_hCVar_Debug.IntValue >= 1)
		LogError("[Self-Mute] Error while inserting Group mute to database, error: %s", sError);
	else
	{
		if (g_hCVar_Debug.IntValue >= 2)
			LogMessage("[Self-Mute] Successfully inserted Group mute to database");
	}
}

stock void DeleteGroupFromTable(int client, const char[] SteamID, const char[] GroupFilter)
{
	if(g_hDB == null)
		return;
		
	char sQuery[1024];
	g_hDB.Format(sQuery, sizeof(sQuery), "DELETE FROM `groups_mute` WHERE client_steamid='%s' and group_filter='%s'", SteamID, GroupFilter);
	g_hDB.Query(SQL_DeleteGroupFromTable, sQuery);
}

public void SQL_DeleteGroupFromTable(Database db, DBResultSet result, const char[] error, any data)
{
	if(error[0] && g_hCVar_Debug.IntValue >= 1)
		LogError("[Self-Mute] Error while deleting a group from table. error: %s", error);
	else
	{
		if (g_hCVar_Debug.IntValue >= 2)
			LogMessage("[Self-Mute] Successfully deleted group from database");
	}
}

stock void DeleteAllGroupsFromTable(int client, const char[] SteamID)
{
	if(g_hDB == null)
		return;

	char sQuery[1024];
	g_hDB.Format(sQuery, sizeof(sQuery), "DELETE FROM `groups_mute` WHERE client_steamid='%s'", SteamID);
	g_hDB.Query(SQL_DeleteAllGroupsFromTable, sQuery);
}

public void SQL_DeleteAllGroupsFromTable(Database db, DBResultSet result, const char[] error, any data)
{
	if(error[0] && g_hCVar_Debug.IntValue >= 1)
		LogError("[Self-Mute] Error while deleting all groups from table. error: %s", error);
	else
	{
		if (g_hCVar_Debug.IntValue >= 2)
			LogMessage("[Self-Mute] Successfully deleted all groups from database");
	}
}

stock void DeleteAllClientMutes(int client, bool bGroups)
{
	if(g_hDB == null)
		return;
	
	char SteamID[32];
	if(!GetClientAuthId(client, AuthId_Steam2, SteamID, sizeof(SteamID)))
		return;
		
	if(bGroups)
	{
		DeleteAllGroupsFromTable(client, SteamID);
		return;
	}
	
	int userid = GetClientUserId(client);
	char sQuery[1024];
	g_hDB.Format(sQuery, sizeof(sQuery), "SELECT `target_steamid` FROM `clients_mute` WHERE client_steamid='%s'", SteamID);
	g_hDB.Query(SQL_DeleteClientMute, sQuery, userid);
}

public void SQL_DeleteClientMute(Database db, DBResultSet result, const char[] error, int userid)
{
	if(result == null)
	{
		if (g_hCVar_Debug.IntValue >= 1)
			LogError("[Self-Mute] Error while deleting all client mutes from table. error: %s", error);
		return;
	}
	
	int client = GetClientOfUserId(userid);
	if(client < 1 || client > MaxClients) // player disconnected
		return;
		
	while(result.FetchRow())
	{
		char SteamID[32];
		result.FetchString(0, SteamID, sizeof(SteamID));
		int target = GetClientFromSteamID(SteamID);	
		if(target != -1)
			continue;
			
		SQL_DeleteFromTable(client, -1, SteamID);
	}
}

stock int GetClientFromSteamID(const char[] SteamID)
{
    for(int i = 1; i <= MaxClients; i++)
    {
        if(IsClientInGame(i))
        {
            char sSteamID[32];
            if(GetClientAuthId(i, AuthId_Steam2, sSteamID, sizeof(sSteamID)))
            {
                if(StrEqual(SteamID, sSteamID, false))
                    return i;
            }
        }
    }

    return -1;
}

//-----Finish Database setup-----

public void OnClientPutInServer(int client)
{
	g_SpecialMutes[client] = MUTE_NONE;

	UpdateSpecialMutesOtherClients(client);
	UpdateIgnored();
}

public void OnClientCookiesCached(int client)
{
    char sValue[10], sBool[10];
    GetClientCookie(client, g_hSmModeCookie, sValue, sizeof(sValue));
    GetClientCookie(client, g_hBotSmCookie, sBool, sizeof(sBool));

    if(!StrEqual(sValue, ""))
        g_iClientSmMode[client] = StringToInt(sValue);
    else
        g_iClientSmMode[client] = SmMode_Alert; 

    if(StrEqual(sBool, "1"))
    {
        for(int i = 1; i <= MaxClients; i++)
        {
		if(!IsClientInGame(i))
			continue;

		if(IsClientSourceTV(i))
		{
		    Ignore(client, i, true);
		    break;
		}
        }
    }
}

public void OnClientDisconnect(int client)
{
	g_SpecialMutes[client] = MUTE_NONE;
	for(int i = 1; i < MAXPLAYERS; i++)
	{
		SetIgnored(client, i, false);
		SetExempt(client, i, false);

		SetIgnored(i, client, false);
		SetExempt(i, client, false);
		
		g_bClientSavedTargets[client][i] = false;
		g_bClientNotSavedTargets[client][i] = false;
		g_bClientSavedTargets[i][client] = false;
		g_bClientNotSavedTargets[i][client] = false;
		g_bClientTargets[client][i] = false;
		g_bClientTargets[i][client] = false;

		g_bClientUnSavedGroups[client][i] = false;

		if(IsClientInGame(i) && !IsFakeClient(i) && i != client)
			SetListenOverride(i, client, Listen_Yes);
	}

	UpdateIgnored();
	g_iClientSmMode[client] = SmMode_Alert;
}

public void Event_Round(Handle event, const char[] name, bool dontBroadcast)
{
	for(int i = 1; i <= MaxClients; i++)
	{
		if(IsClientInGame(i) && !IsFakeClient(i))
			UpdateSpecialMutesThisClient(i);
	}
}

public void Event_TeamChange(Handle event, const char[] name, bool dontBroadcast)
{
	int client = GetClientOfUserId(GetEventInt(event, "userid"));

	UpdateSpecialMutesOtherClients(client);
}

public void ZR_OnClientInfected(int client, int attacker, bool motherInfect, bool respawnOverride, bool respawn)
{
	UpdateSpecialMutesOtherClients(client);
}

public void ZR_OnClientHumanPost(int client, bool respawn, bool protect)
{
	UpdateSpecialMutesOtherClients(client);
}

/*
 * Mutes this client on other players
*/
void UpdateSpecialMutesOtherClients(int client)
{
	bool Alive = IsPlayerAlive(client);
	int Team = GetClientTeam(client);

	for(int i = 1; i <= MaxClients; i++)
	{
		if(i == client || !IsClientInGame(i) || IsFakeClient(i))
			continue;

		int Flags = MUTE_NONE;

		if(g_SpecialMutes[i] & MUTE_SPEC && Team == CS_TEAM_SPECTATOR)
			Flags |= MUTE_SPEC;

#if defined _zr_included
		else if(g_SpecialMutes[i] & MUTE_CT && Alive &&
			((g_Plugin_zombiereloaded && ZR_IsClientHuman(client)) || (!g_Plugin_zombiereloaded && Team == CS_TEAM_CT)))
#else
		else if(g_SpecialMutes[i] & MUTE_CT && Alive && Team == CS_TEAM_CT)
#endif
			Flags |= MUTE_CT;

#if defined _zr_included
		else if(g_SpecialMutes[i] & MUTE_T && Alive &&
			((g_Plugin_zombiereloaded && ZR_IsClientZombie(client)) || (!g_Plugin_zombiereloaded && Team == CS_TEAM_T)))
#else
		else if(g_SpecialMutes[i] & MUTE_T && Alive && Team == CS_TEAM_T)
#endif
			Flags |= MUTE_T;

		else if(g_SpecialMutes[i] & MUTE_DEAD && !Alive)
			Flags |= MUTE_DEAD;

		else if(g_SpecialMutes[i] & MUTE_ALIVE && Alive)
			Flags |= MUTE_ALIVE;

		else if(g_SpecialMutes[i] & MUTE_NOTFRIENDS &&
			g_Plugin_AdvancedTargeting && IsClientFriend(i, client) == 0)
			Flags |= MUTE_NOTFRIENDS;

		else if(g_SpecialMutes[i] & MUTE_ALL)
			Flags |= MUTE_ALL;

		if(Flags && !GetExempt(i, client))
			SetListenOverride(i, client, Listen_No);
		else if(!GetIgnored(i, client))
			SetListenOverride(i, client, Listen_Yes);
	}
}

/*
 * Mutes other players on this client
*/
void UpdateSpecialMutesThisClient(int client)
{
	for(int i = 1; i <= MaxClients; i++)
	{
		if(i == client || !IsClientInGame(i))
			continue;

		bool Alive = IsPlayerAlive(i);
		int Team = GetClientTeam(i);

		int Flags = MUTE_NONE;

		if(g_SpecialMutes[client] & MUTE_SPEC && Team == CS_TEAM_SPECTATOR)
			Flags |= MUTE_SPEC;

#if defined _zr_included
		else if(g_SpecialMutes[client] & MUTE_CT && Alive &&
			((g_Plugin_zombiereloaded && ZR_IsClientHuman(i) || (!g_Plugin_zombiereloaded) && Team == CS_TEAM_CT)))
#else
		else if(g_SpecialMutes[client] & MUTE_CT && Alive && Team == CS_TEAM_CT)
#endif
			Flags |= MUTE_CT;

#if defined _zr_included
		else if(g_SpecialMutes[client] & MUTE_T && Alive &&
			((g_Plugin_zombiereloaded && ZR_IsClientZombie(i) || (!g_Plugin_zombiereloaded) && Team == CS_TEAM_T)))
#else
		else if(g_SpecialMutes[client] & MUTE_T && Alive && Team == CS_TEAM_T)
#endif
			Flags |= MUTE_T;

		else if(g_SpecialMutes[client] & MUTE_DEAD && !Alive)
			Flags |= MUTE_DEAD;

		else if(g_SpecialMutes[client] & MUTE_ALIVE && Alive)
			Flags |= MUTE_ALIVE;

		else if(g_SpecialMutes[client] & MUTE_NOTFRIENDS &&
			g_Plugin_AdvancedTargeting && IsClientFriend(client, i) == 0)
			Flags |= MUTE_NOTFRIENDS;

		else if(g_SpecialMutes[client] & MUTE_ALL)
			Flags |= MUTE_ALL;

		if(Flags && !GetExempt(client, i))
			SetListenOverride(client, i, Listen_No);
		else if(!GetIgnored(client, i))
			SetListenOverride(client, i, Listen_Yes);
	}
}

int GetSpecialMutesFlags(char[] Argument)
{
	int SpecialMute = MUTE_NONE;
	if(StrEqual(Argument, "@spec", false) || (StrContains(Argument, "@spectator", false) == 0)|| StrEqual(Argument, "@!ct", false) || StrEqual(Argument, "@!t", false))
		SpecialMute |= MUTE_SPEC;
	if(StrEqual(Argument, "@ct", false) || StrEqual(Argument, "@cts", false) || StrEqual(Argument, "@!t", false) || StrEqual(Argument, "@!spec", false))
		SpecialMute |= MUTE_CT;
	if(StrEqual(Argument, "@t", false) || StrEqual(Argument, "@ts", false) || StrEqual(Argument, "@!ct", false) || StrEqual(Argument, "@!spec", false))
		SpecialMute |= MUTE_T;
	if(StrEqual(Argument, "@dead", false) || StrEqual(Argument, "@!alive", false))
		SpecialMute |= MUTE_DEAD;
	if(StrEqual(Argument, "@alive", false) || StrEqual(Argument, "@!dead", false))
		SpecialMute |= MUTE_ALIVE;
	if(g_Plugin_AdvancedTargeting && StrEqual(Argument, "@!friends", false))
		SpecialMute |= MUTE_NOTFRIENDS;
	if(StrEqual(Argument, "@all", false))
		SpecialMute |= MUTE_ALL;

	return SpecialMute;
}

void FormatSpecialMutes(int SpecialMute, char[] aBuf, int BufLen)
{
	if(!SpecialMute)
	{
		StrCat(aBuf, BufLen, "none");
		return;
	}

	bool Status = false;
	int MuteCount = RoundFloat(Logarithm(float(MUTE_LAST), 2.0));
	for(int i = 0; i <= MuteCount; i++)
	{
		switch(SpecialMute & RoundFloat(Pow(2.0, float(i))))
		{
			case MUTE_SPEC:
			{
				StrCat(aBuf, BufLen, "Spectators, ");
				Status = true;
			}
			case MUTE_CT:
			{
			#if defined _zr_included
				StrCat(aBuf, BufLen, "Humans, ");
			#else
				StrCat(aBuf, BufLen, "CTs, ");
			#endif
				Status = true;
			}
			case MUTE_T:
			{
			#if defined _zr_included
				StrCat(aBuf, BufLen, "Zombies, ");
			#else
				StrCat(aBuf, BufLen, "Ts, ");
			#endif
				Status = true;
			}
			case MUTE_DEAD:
			{
				StrCat(aBuf, BufLen, "Dead players, ");
				Status = true;
			}
			case MUTE_ALIVE:
			{
				StrCat(aBuf, BufLen, "Alive players, ");
				Status = true;
			}
			case MUTE_NOTFRIENDS:
			{
				StrCat(aBuf, BufLen, "Not Steam friends, ");
				Status = true;
			}
			case MUTE_ALL:
			{
				StrCat(aBuf, BufLen, "Everyone, ");
				Status = true;
			}
		}
	}

	// Cut off last ', '
	if(Status)
		aBuf[strlen(aBuf) - 2] = 0;
}

bool MuteSpecial(int client, char[] Argument, bool clientJustJoined = false)
{
	bool RetValue = false;
	int SpecialMute = GetSpecialMutesFlags(Argument);

	if(SpecialMute & MUTE_NOTFRIENDS && g_Plugin_AdvancedTargeting && ReadClientFriends(client) != 1)
	{
		CPrintToChat(client, "%sCould not read your friendslist, your profile must be set to public!", PLUGIN_PREFIX);
		SpecialMute &= ~MUTE_NOTFRIENDS;
		RetValue = true;
	}

	if(SpecialMute)
	{
	    if(g_SpecialMutes[client] & SpecialMute)
	    {
	        CPrintToChat(client, "%sYou have already self-muted this group.", PLUGIN_PREFIX);
	        return true;
	    }
	    else if(g_SpecialMutes[client] == MUTE_ALL)
	    {
	        CPrintToChat(client, "%sYou have muted everyone, do you want to mute another group?", PLUGIN_PREFIX);
	        return true;
	    }
		
	    if(g_iClientSmMode[client] != SmMode_Alert || clientJustJoined)
	    {
		    if(SpecialMute & MUTE_ALL || g_SpecialMutes[client] & MUTE_ALL)
		    {
		    	g_SpecialMutes[client] = MUTE_ALL;
		    	SpecialMute = MUTE_ALL;
		    }
		    else
		    	g_SpecialMutes[client] |= SpecialMute;
	    }

	    char aBuf[128];
	    FormatSpecialMutes(SpecialMute, aBuf, sizeof(aBuf));
	    UpdateSpecialMutesThisClient(client);

	    if(clientJustJoined)
	    	return true;

	    switch(g_iClientSmMode[client])
	    {
	        case SmMode_Temp:
	        {
	    		UpdateSpecialMutesThisClient(client);
		        if(StrEqual(Argument, "@all"))
		        {
		        	for(int i = 1; i <= 64; i++)
		        	{
		        		if(g_bClientUnSavedGroups[client][i])
		        			g_bClientUnSavedGroups[client][i] = false;
		        	}

		        	g_bClientUnSavedGroups[client][SpecialMute] = true;
		        }

		    	g_bClientUnSavedGroups[client][SpecialMute] = true;
				
		    	if(IsClientInGame(client))
		    		CPrintToChat(client, "%sYou have self-muted {olive}%s{default}. (Session)", PLUGIN_PREFIX, aBuf);
	        }
	        case SmMode_Perma:
	        {	
	            char SteamID[32];
	            if(GetClientAuthId(client, AuthId_Steam2, SteamID, sizeof(SteamID)))
	            {
	                if(StrEqual(Argument, "@all"))
	                {
	                    DeleteAllGroupsFromTable(client, SteamID);
	                    InsertGroupToTable(client, SteamID, aBuf, Argument);
	                    if(IsClientInGame(client))
	                        CPrintToChat(client, "%sYou have self-muted {olive}%s{default}. (Permanently)", PLUGIN_PREFIX, aBuf);

	                    return true;
	                }
	                else
	                {
	                    DeleteGroupFromTable(client, SteamID, Argument);
	                    InsertGroupToTable(client, SteamID, aBuf, Argument);
	                    UpdateSpecialMutesThisClient(client);
	                    if(IsClientInGame(client))
	                        CPrintToChat(client, "%sYou have self-muted {olive}%s{default}. (Permanently)", PLUGIN_PREFIX, aBuf);
	                }
	            }
	        }
	        case SmMode_Alert:
	        {
			    DisplayAlertMenu(client, false, -1, Argument);
        	}
	    }

	    RetValue = true;
	}
	return RetValue;
}

bool UnMuteSpecial(int client, char[] Argument)
{
	int SpecialMute = GetSpecialMutesFlags(Argument);

	if(SpecialMute)
	{
		if(g_SpecialMutes[client] == MUTE_NONE)
		{
			CPrintToChat(client, "%sYou don't have any group to self-unmute.", PLUGIN_PREFIX);
			return true;
		}
		else if(!(g_SpecialMutes[client] & SpecialMute))
		{
			CPrintToChat(client, "%sYou don't have that group self-muted.", PLUGIN_PREFIX);
			return true;
		}
		else if(SpecialMute & MUTE_ALL)
		{
			if(g_SpecialMutes[client])
			{
				SpecialMute = g_SpecialMutes[client];
				g_bClientUnSavedGroups[client][SpecialMute] = false;
				g_SpecialMutes[client] = MUTE_NONE;
			}
			else
			{
				for(int i = 1; i <= MaxClients; i++)
				{
					if(IsClientInGame(i))
						UnIgnore(client, i);

					CPrintToChat(client, "%sYou have self-unmuted{olive} all players{default}.", PLUGIN_PREFIX);
					return true;
				}
			}
		}
		else
		{
			g_bClientUnSavedGroups[client][SpecialMute] = false;
			g_SpecialMutes[client] &= ~SpecialMute;
		}

		UpdateSpecialMutesThisClient(client);

		char aBuf[256];
		FormatSpecialMutes(SpecialMute, aBuf, sizeof(aBuf));

		CPrintToChat(client, "%sYou have self-unmuted{olive} %s{default}.", PLUGIN_PREFIX, aBuf);

		char SteamID[32];
		if(GetClientAuthId(client, AuthId_Steam2, SteamID, sizeof(SteamID)))
		{
			DeleteGroupFromTable(client, SteamID, Argument);
		}

		return true;
	}

	return false;
}

void Ignore(int client, int target, bool clientJustJoined = false)
{
	if(client < 1 || target < 1 || client > MaxClients || target > MaxClients)
		return;

	int oldSmMode = g_iClientSmMode[client];
	if(!clientJustJoined)
	{
		if(g_iClientSmMode[client] == SmMode_Perma && CheckCommandAccess(target, "sm_admin", ADMFLAG_GENERIC, true))
			g_iClientSmMode[client] = SmMode_Temp;

		switch(g_iClientSmMode[client])
		{
			case SmMode_Temp:
				g_bClientNotSavedTargets[client][target] = true;

			case SmMode_Perma:
			{
				if(IsClientSourceTV(target))
				{
					SetClientCookie(client, g_hBotSmCookie, "1");
					g_bClientSavedTargets[client][target] = true;
				}
				else
				{
					char SteamID[32];
					if(!GetClientAuthId(client, AuthId_Steam2, SteamID, sizeof(SteamID)) || !GetClientAuthId(target, AuthId_Steam2, SteamID, sizeof(SteamID)))
						return;
			
					g_bClientSavedTargets[client][target] = true;
					SQL_InsertIntoTable(client, target);
				}
			}
			case SmMode_Alert:
			{
				DisplayAlertMenu(client, true, target);
				return;
			}
		}
		g_iClientSmMode[client] = oldSmMode;
	}
	else
	{
		g_bClientSavedTargets[client][target] = true;
	}

	g_bClientTargets[client][target] = true;
	SetIgnored(client, target, true);
	UpdateIgnored();
	SetListenOverride(client, target, Listen_No);
}

void UnIgnore(int client, int target)
{
	if(client < 1 || target < 1 || client > MaxClients || target > MaxClients)
		return;

	SetIgnored(client, target, false);
	UpdateIgnored();
	SetListenOverride(client, target, Listen_Yes);
	g_bClientSavedTargets[client][target] = false;
	g_bClientNotSavedTargets[client][target] = false;
	g_bClientTargets[client][target] = false;
	
	if(IsClientSourceTV(target))
	{
		SetClientCookie(client, g_hBotSmCookie, "0");
		return;
	}

	char SteamID[32];
	if(!GetClientAuthId(client, AuthId_Steam2, SteamID, sizeof(SteamID)) || !GetClientAuthId(target, AuthId_Steam2, SteamID, sizeof(SteamID)))
		return;
    
	SQL_DeleteFromTable(client, target);
}

void Exempt(int client, int target)
{
	SetExempt(client, target, true);
	UpdateSpecialMutesThisClient(client);
}

void UnExempt(int client, int target)
{
	SetExempt(client, target, false);
	UpdateSpecialMutesThisClient(client);
}

/*
 * CHAT COMMANDS
*/
public Action Command_SelfMute(int client, int args)
{
	if(client == 0)
	{
		ReplyToCommand(client, "[SM] Cannot use command from server console.");
		return Plugin_Handled;
	}

	if(args < 1)
	{
		DisplayMuteMenu(client);
		return Plugin_Handled;
	}

	char Argument[65];
	GetCmdArg(1, Argument, sizeof(Argument));

	char Filtered[65];
	strcopy(Filtered, sizeof(Filtered), Argument);
	StripQuotes(Filtered);
	TrimString(Filtered);

	if(MuteSpecial(client, Filtered))
		return Plugin_Handled;

	char sTargetName[MAX_TARGET_LENGTH];
	int aTargetList[MAXPLAYERS];
	int TargetCount;
	bool TnIsMl;

	if((TargetCount = ProcessTargetString(
			Argument,
			client,
			aTargetList,
			MAXPLAYERS,
			COMMAND_FILTER_CONNECTED|COMMAND_FILTER_NO_IMMUNITY,
			sTargetName,
			sizeof(sTargetName),
			TnIsMl)) <= 0)
	{
		ReplyToTargetError(client, TargetCount);
		return Plugin_Handled;
	}

	if(TargetCount == 1)
	{
		if(aTargetList[0] == client)
		{
			CReplyToCommand(client, "%sYou can't mute yourself, don't be silly.", PLUGIN_PREFIX);
			return Plugin_Handled;
		}

		if(GetExempt(client, aTargetList[0]))
		{
			UnExempt(client, aTargetList[0]);

			CReplyToCommand(client, "%sYou have removed exempt from self-mute{olive} %s{default}.", PLUGIN_PREFIX, sTargetName);

			return Plugin_Handled;
		}

		if(g_bClientTargets[client][aTargetList[0]])
		{
			CReplyToCommand(client, "%sYou have already self-muted {olive}%N{default}.", PLUGIN_PREFIX, aTargetList[0]);
			return Plugin_Handled;
		}
	}
	else if(TargetCount > 1)
	{
		if(g_iClientSmMode[client] == SmMode_Alert)
		{
			CReplyToCommand(client, "%sYou cannot target more than one player at time with 'Always let me Select' method.", PLUGIN_PREFIX);
			return Plugin_Handled;
		}
	}

	for(int i = 0; i < TargetCount; i++)
	{
		if(aTargetList[i] == client)
			continue;

		if(g_bClientTargets[client][aTargetList[i]])
			continue;

		Ignore(client, aTargetList[i]);
	}
	UpdateIgnored();

	if(g_iClientSmMode[client] != SmMode_Alert)
		CReplyToCommand(client, "%sYou have self-muted{olive} %s{default}.", PLUGIN_PREFIX, sTargetName);

	return Plugin_Handled;
}

public Action Command_SelfUnMute(int client, int args)
{
	if(client == 0)
	{
		ReplyToCommand(client, "[SM] Cannot use command from server console.");
		return Plugin_Handled;
	}

	if(args < 1)
	{
		DisplayClientMutesMenu(client);
		return Plugin_Handled;
	}

	char Argument[65];
	GetCmdArg(1, Argument, sizeof(Argument));

	char Filtered[65];
	strcopy(Filtered, sizeof(Filtered), Argument);
	StripQuotes(Filtered);
	TrimString(Filtered);

	if(UnMuteSpecial(client, Filtered))
		return Plugin_Handled;

	char sTargetName[MAX_TARGET_LENGTH];
	int aTargetList[MAXPLAYERS];
	int TargetCount;
	bool TnIsMl;

	if((TargetCount = ProcessTargetString(
			Argument,
			client,
			aTargetList,
			MAXPLAYERS,
			COMMAND_FILTER_CONNECTED|COMMAND_FILTER_NO_IMMUNITY,
			sTargetName,
			sizeof(sTargetName),
			TnIsMl)) <= 0)
	{
		ReplyToTargetError(client, TargetCount);
		return Plugin_Handled;
	}

	if(TargetCount == 1)
	{
		if(aTargetList[0] == client)
		{
			CReplyToCommand(client, "%sUnmuting won't work either.", PLUGIN_PREFIX);
			return Plugin_Handled;
		}

		if(!GetIgnored(client, aTargetList[0]))
		{
			Exempt(client, aTargetList[0]);

			CReplyToCommand(client, "%sYou have exempted from self-mute{olive} %s{default}.", PLUGIN_PREFIX, sTargetName);

			return Plugin_Handled;
		}
	
		if(!g_bClientTargets[client][aTargetList[0]])
		{
			CReplyToCommand(client, "%sYou don't have{olive} %N {default}self-muted.", PLUGIN_PREFIX, aTargetList[0]);
			return Plugin_Handled;
		}
	}

	for(int i = 0; i < TargetCount; i++)
	{
		if(aTargetList[i] == client)
			continue;

		if(!g_bClientTargets[client][aTargetList[0]])
			continue;
	        
		UnIgnore(client, aTargetList[i]);
	}
	UpdateIgnored();

	CReplyToCommand(client, "%sYou have self-unmuted{olive} %s{default}.", PLUGIN_PREFIX, sTargetName);

	return Plugin_Handled;
}

public Action Command_SelfUnMuteAll(int client, int args)
{
	if(!client)
		return Plugin_Handled;
	
	if(!AreClientCookiesCached(client))
	{
		CReplyToCommand(client, "%sYou have to be authorized to use this command.", PLUGIN_PREFIX);
		return Plugin_Handled;
	}
	
	// UnMute all groups:
	DeleteAllClientMutes(client, true);
	for(int i = 0; i < sizeof(groupsFilters); i++)
	{
		int SpecialMute = GetSpecialMutesFlags(groupsFilters[i]);
		if(g_SpecialMutes[client] & SpecialMute)
			UnMuteSpecial(client, groupsFilters[i]);
	}
	
	//UnMute all clients:
	DeleteAllClientMutes(client, false);
	for(int i = 1; i <= MaxClients; i++)
	{
		if(!IsClientInGame(i))
			continue;
			
		if(i == client)
			continue;
		
		UnIgnore(client, i);
	}
	
	CReplyToCommand(client, "%sYou have self-unmuted {olive}All Groups/Clients", PLUGIN_PREFIX);
	return Plugin_Handled;
}

public Action Command_CheckMutes(int client, int args)
{
	if(client == 0)
	{
		ReplyToCommand(client, "[SM] Cannot use command from server console.");
		return Plugin_Handled;
	}

	char aMuted[1024];
	char aExempted[1024];
	char aName[MAX_NAME_LENGTH];
	for(int i = 1; i <= MaxClients; i++)
	{
		if(!IsClientInGame(i))
			continue;

		GetClientName(i, aName, sizeof(aName));

		if(GetIgnored(client, i))
		{
			StrCat(aMuted, sizeof(aMuted), aName);
			StrCat(aMuted, sizeof(aMuted), ", ");
		}

		if(GetExempt(client, i))
		{
			StrCat(aExempted, sizeof(aExempted), aName);
			StrCat(aExempted, sizeof(aExempted), ", ");
		}
	}

	if(strlen(aMuted))
	{
		aMuted[strlen(aMuted) - 2] = 0;
		CReplyToCommand(client, "%sYou have self-muted{olive} %s{default}.", PLUGIN_PREFIX, aMuted);
	}

	if(g_SpecialMutes[client] != MUTE_NONE)
	{
		aMuted[0] = 0;
		FormatSpecialMutes(g_SpecialMutes[client], aMuted, sizeof(aMuted));
		CReplyToCommand(client, "%sYou have self-muted %s{default}.", PLUGIN_PREFIX, aMuted);
	}
	else if(!strlen(aMuted) && !strlen(aExempted))
		CReplyToCommand(client, "%sYou have not self-muted anyone.", PLUGIN_PREFIX);

	if(strlen(aExempted))
	{
		aExempted[strlen(aExempted) - 2] = 0;
		CReplyToCommand(client, "%sYou have exempted from self-mute{olive} %s{default}.", PLUGIN_PREFIX, aExempted);
	}

	return Plugin_Handled;
}

public Action Command_SmCookies(int client, int args)
{
    if(!client)
        return Plugin_Handled;
    
    if(!AreClientCookiesCached(client))
    {
        CReplyToCommand(client, "%sYour cookies are not cached yet. Please wait..", PLUGIN_PREFIX);
        return Plugin_Handled;
    }

    DisplayCookiesMenu(client);
    return Plugin_Handled;
}

/*
 * MENUS
*/

void DisplayClientMutesMenu(int client)
{
	Menu menu = new Menu(MenuHandler_ClientMutes);
	menu.SetTitle("[Self-Mute] Select an option");

	menu.AddItem("0", "Players");
	menu.AddItem("1", "Groups");

	menu.ExitButton = true;
	menu.Display(client, MENU_TIME_FOREVER);
}

public int MenuHandler_ClientMutes(Menu menu, MenuAction action, int param1, int param2)
{
	switch(action)
	{
		case MenuAction_End:
			delete menu;
		
		case MenuAction_Select:
		{
			switch(param2)
			{
				case 0:
					DisplayClientClientsMutesMenu(param1);
				case 1:
					DisplayClientGroupsMutesMenu(param1);
			}
		}
	}

	return 0;
}

void DisplayClientClientsMutesMenu(int client)
{
	Menu menu = new Menu(MenuHandler_ClientClientsMutes);
	menu.SetTitle("[Self-Mute] Select players status");

	menu.AddItem("0", "Online Players");
	menu.AddItem("1", "Offline Players", AreClientCookiesCached(client) ? ITEMDRAW_DEFAULT : ITEMDRAW_DISABLED);

	menu.ExitBackButton = true;
	menu.Display(client, MENU_TIME_FOREVER);
}

public int MenuHandler_ClientClientsMutes(Menu menu, MenuAction action, int param1, int param2)
{
	switch(action)
	{
		case MenuAction_End:
			delete menu;
		
		case MenuAction_Cancel:
		{
			if(param2 == MenuCancel_ExitBack)
				DisplayClientMutesMenu(param1);
		}

		case MenuAction_Select:
		{
			switch(param2)
			{
				case 0:
					DisplayClientOnlineClientsMutesMenu(param1);
				
				case 1:
					AddOfflineMutesToMenu(param1);
			}
		}
	}

	return 0;
}

void DisplayClientOnlineClientsMutesMenu(int client)
{
	Menu menu = new Menu(MenuHandler_ClientOnlineClientsMutes);
	menu.SetTitle("[Self-Mute] Online Players self-muted");

	if(GetClientSelfMutedTargetsCount(client) <= 0)
		menu.AddItem("", "None", ITEMDRAW_DISABLED);

	else if(GetClientSelfMutedTargetsCount(client) >= 1)
	{
		for(int i = 1; i <= MaxClients; i++)
		{
			if(IsClientInGame(i))
			{
				if(g_bClientSavedTargets[client][i])
				{
					char item[32], text[64];
					int userid = GetClientUserId(i);
					IntToString(userid, item, sizeof(item));
					Format(text, sizeof(text), "%N (%s)", i, "SAVED");
					menu.AddItem(item, text);
				}
				
				if(g_bClientNotSavedTargets[client][i])
				{
					char item[32], text[64];
					int userid = GetClientUserId(i);
					IntToString(userid, item, sizeof(item));
					Format(text, sizeof(text), "%N (%s)", i, "NOT SAVED");
					menu.AddItem(item, text);
				}
			}
		}
		
		menu.AddItem("all", "Self-UnMute All Online Players");
	}

	menu.ExitBackButton = true;
	menu.Display(client, MENU_TIME_FOREVER);
}

int GetClientSelfMutedTargetsCount(int client)
{
	int count = 0;
	for(int i = 1; i <= MaxClients; i++)
	{
		if(IsClientInGame(i) && g_bClientSavedTargets[client][i] || g_bClientNotSavedTargets[client][i])
			count++;
	}
	
	return count;
}

public int MenuHandler_ClientOnlineClientsMutes(Menu menu, MenuAction action, int param1, int param2)
{
	switch(action)
	{
		case MenuAction_End:
			delete menu;
		
		case MenuAction_Cancel:
		{
			if(param2 == MenuCancel_ExitBack)
				DisplayClientClientsMutesMenu(param1);
		}

		case MenuAction_Select:
		{
			char buffer[32];
			menu.GetItem(param2, buffer, sizeof(buffer));
			if(StrEqual(buffer, "all", false))
			{
				for(int i = 1; i <= MaxClients; i++)
				{
					if(!IsClientInGame(i))
						continue;
						
					if(i == param1)
						continue;
					
					UnIgnore(param1, i);
				}
				
				CPrintToChat(param1, "%sYou have self-unmuted {olive}All Online Players{default}.", PLUGIN_PREFIX);
			}
			else
			{
				int userid = StringToInt(buffer);
				int target = GetClientOfUserId(userid);
	
				if(target < 1) // player disconnected
				{
					CPrintToChat(param1, "%sPlayer no longer available.", PLUGIN_PREFIX);
					return 0;
				}
				
				if(IsClientInGame(target))
				{
					if(g_bClientSavedTargets[param1][target] || g_bClientNotSavedTargets[param1][target])
					{
						UnIgnore(param1, target);
						CPrintToChat(param1, "%sYou have self-unmuted {olive}%N{default}.", PLUGIN_PREFIX, target);
					}
					else
					{
						CPrintToChat(param1, "%sYou don't have that player self-muted.", PLUGIN_PREFIX);
					}
				}
				else
				{
					CPrintToChat(param1, "%sPlayer is no longer in game.", PLUGIN_PREFIX);
				}
			}
			
			DisplayClientOnlineClientsMutesMenu(param1);
		}
	}

	return 0;
}

void AddOfflineMutesToMenu(int client)
{
	if(g_hDB != null)
	{
		char SteamID[32];
		if(GetClientAuthId(client, AuthId_Steam2, SteamID, sizeof(SteamID)))
		{
			int userid = GetClientUserId(client);
			
			char sQuery[1024];
			g_hDB.Format(sQuery, sizeof(sQuery), "SELECT `target_steamid`, `target_name` FROM `clients_mute` WHERE client_steamid='%s'", SteamID);
			SQL_TQuery(g_hDB, SQL_AddMutesToMenu, sQuery, userid);
		}
	}
}

public void SQL_AddMutesToMenu(Handle hDataBase, Handle query, const char[] error, int userid)
{
	if(query == null)
		return;

	int client = GetClientOfUserId(userid);
	if(client < 1 || client > MaxClients)
		return; 
		
	if(!IsClientInGame(client))
		return;
	
	Menu menu = new Menu(MenuHandler_ClientOfflineClientsMutes);
	menu.SetTitle("[Self-Mute] Offline players self-muted");

	int iCount = 0;
	while(SQL_FetchRow(query))
	{
		char TargetSteamID[32], sName[64], text[128];
		SQL_FetchString(query, 0, TargetSteamID, sizeof(TargetSteamID));
		SQL_FetchString(query, 1, sName, sizeof(sName));
		int target = GetClientFromSteamID(TargetSteamID);
		if(target == -1)
		{
			Format(text, sizeof(text), "%s - %s", sName, TargetSteamID);
			menu.AddItem(TargetSteamID, text);
			iCount++;
		}
	}

	if(iCount > 0)
		menu.AddItem("all", "Unmute All players (Offline)");
		
	if(iCount <= 0)
		menu.AddItem("", "None", ITEMDRAW_DISABLED);

	menu.ExitBackButton = true;
	menu.Display(client, MENU_TIME_FOREVER);
}

public int MenuHandler_ClientOfflineClientsMutes(Menu menu, MenuAction action, int param1, int param2)
{
	switch(action)
	{
		case MenuAction_End:
			delete menu;
		
		case MenuAction_Cancel:
		{
			if(param2 == MenuCancel_ExitBack)
				DisplayClientClientsMutesMenu(param1);
		}

		case MenuAction_Select:
		{
			char SteamID[32];
			menu.GetItem(param2, SteamID, sizeof(SteamID));
			if(StrEqual(SteamID, "all"))
			{
				DeleteAllClientMutes(param1, false);
				CPrintToChat(param1, "%sYou have self-unmuted {olive}All Offline Players{default}.", PLUGIN_PREFIX);
			}
			else
			{
				int target = GetClientFromSteamID(SteamID);
				if(target == -1)
				{
					SQL_DeleteFromTable(param1, -1, SteamID);
					CPrintToChat(param1, "%sYou have self-unmuted {olive}%s{default}.", PLUGIN_PREFIX, SteamID);
				}
				else if(target != -1)
				{
					UnIgnore(param1, target);
					CPrintToChat(param1, "%sYou have self-unmuted %N.", target);
				}
			}
			
			AddOfflineMutesToMenu(param1);
		}
	}

	return 0;
}

void DisplayClientGroupsMutesMenu(int client)
{
	Menu menu = new Menu(MenuHandler_ClientGroupsMutes);
	menu.SetTitle("[Self-Mute] Groups type");

	if(g_SpecialMutes[client] == MUTE_NONE)
		menu.AddItem("", "None", ITEMDRAW_DISABLED);
	else
	{
		menu.AddItem("0", "Permanently muted", AreClientCookiesCached(client) ? ITEMDRAW_DEFAULT : ITEMDRAW_DISABLED);
		menu.AddItem("1", "Session only");
	}

	menu.ExitBackButton = true;
	menu.Display(client, MENU_TIME_FOREVER);
}

public int MenuHandler_ClientGroupsMutes(Menu menu, MenuAction action, int param1, int param2)
{
	switch(action)
	{
		case MenuAction_End:
			delete menu;
		
		case MenuAction_Cancel:
		{
			if(param2 == MenuCancel_ExitBack)
				DisplayClientMutesMenu(param1);
		}

		case MenuAction_Select:
		{
			switch(param2)
			{
				case 0:
					AddSavedGroupsToMenu(param1);
				case 1:
					DisplayUnSavedGroupsMuteMenu(param1);
			}
		}
	}
	
	return 0;
}

void AddSavedGroupsToMenu(int client)
{
	if(g_hDB != null)
	{
		char SteamID[32];
		if(GetClientAuthId(client, AuthId_Steam2, SteamID, sizeof(SteamID)))
		{
			int userid = GetClientUserId(client);
			char sQuery[1024];
			g_hDB.Format(sQuery, sizeof(sQuery), "SELECT `group_filter`, `group_name` FROM `groups_mute` WHERE client_steamid='%s'", SteamID);
			SQL_TQuery(g_hDB, SQL_GroupsMenu, sQuery, userid);
		}
	}
}

public void SQL_GroupsMenu(Handle hDatabase, Handle query, const char[] error, int userid)
{
	int client = GetClientOfUserId(userid);
	if(client < 1 || client > MaxClients)
		return;
	
	if(query == null)
		return;
	
	if(IsClientInGame(client))
	{
		Menu menu = new Menu(MenuHandler_SavedGroups);
		menu.SetTitle("[Self-Mute] Permanently muted Groups");

		int iCount = 0;
		while(SQL_FetchRow(query))
		{
			char sGroupFilter[64], sGroupName[64];
			SQL_FetchString(query, 0, sGroupFilter, sizeof(sGroupFilter));
			SQL_FetchString(query, 1, sGroupName, sizeof(sGroupName));
			char text[80];
			Format(text, sizeof(text), sGroupName);
			menu.AddItem(sGroupFilter, sGroupName);
			iCount++;
		}

		if(iCount > 0)
			menu.AddItem("all", "Unmute All Permanent Groups");
			
		if(iCount <= 0)
			menu.AddItem("", "None", ITEMDRAW_DISABLED);

		menu.ExitBackButton = true;
		menu.Display(client, MENU_TIME_FOREVER);
	}
}

public int MenuHandler_SavedGroups(Menu menu, MenuAction action, int param1, int param2)
{
	switch(action)
	{
		case MenuAction_End:
			delete menu;
		
		case MenuAction_Cancel:
		{
			if(param2 == MenuCancel_ExitBack)
				DisplayClientGroupsMutesMenu(param1);
		}

		case MenuAction_Select:
		{
			char buffer[32];
			menu.GetItem(param2, buffer, sizeof(buffer));
			if(StrEqual(buffer, "all", false))
			{
				for(int i = 0; i < sizeof(groupsFilters); i++)
				{
					int SpecialMute = GetSpecialMutesFlags(groupsFilters[i]);
					if(g_SpecialMutes[param1] & SpecialMute)
						UnMuteSpecial(param1, groupsFilters[i]);
				}
			}
			else
				UnMuteSpecial(param1, buffer);
				
			AddSavedGroupsToMenu(param1);
		}
	}
	
	return 0;
}

void DisplayUnSavedGroupsMuteMenu(int client)
{
	Menu menu = new Menu(MenuHandler_UnSavedGroups);
	menu.SetTitle("[Self-Mute] Session Groups muted");

	if(GetClientUnSavedGroupsCount(client) >= 1)
	{
		for(int i = 1; i <= 64; i++)
		{
			if(g_bClientUnSavedGroups[client][i])
			{
				if(i == 1)
					menu.AddItem("@spec", "Spectators");
				else if(i == 2)
			#if defined _zr_included
					menu.AddItem("@ct", "Humans");
			#else
					menu.AddItem("@ct", "CTs");
			#endif
				else if(i == 4)
			#if defined _zr_included
					menu.AddItem("@t", "Zombies");
			#else
					menu.AddItem("@t", "Ts");
			#endif
				else if(i == 8)
					menu.AddItem("@dead", "Dead Players");
				else if(i == 16)
					menu.AddItem("@alive", "Alive Players");
				else if(i == 32)
					menu.AddItem("@!friends", "Not Steam Friends");
				else if(i == 64)
					menu.AddItem("@all", "Everyone");
			}
		}
		
		menu.AddItem("all", "Unmute All Session Groups");
	}
	else if(GetClientUnSavedGroupsCount(client) <= 0)
		menu.AddItem("", "None", ITEMDRAW_DISABLED);

	menu.ExitBackButton = true;
	menu.Display(client, MENU_TIME_FOREVER);
}

int GetClientUnSavedGroupsCount(int client)
{
	int count = 0;
	for(int i = 1; i <= 64; i++)
	{
		if(g_bClientUnSavedGroups[client][i])
			count++;
	}

	return count;
}

public int MenuHandler_UnSavedGroups(Menu menu, MenuAction action, int param1, int param2)
{
	switch(action)
	{
		case MenuAction_End:
			delete menu;
		
		case MenuAction_Cancel:
		{
			if(param2 == MenuCancel_ExitBack)
				DisplayClientGroupsMutesMenu(param1);
		}

		case MenuAction_Select:
		{
			char buffer[32];
			menu.GetItem(param2, buffer, sizeof(buffer));
			if(StrEqual(buffer, "all", false))
			{
				for(int i = 0; i < sizeof(groupsFilters); i++)
				{
					int SpecialMute = GetSpecialMutesFlags(groupsFilters[i]);
					if(g_SpecialMutes[param1] & SpecialMute)
						UnMuteSpecial(param1, groupsFilters[i]);
				}
			}
			else
				UnMuteSpecial(param1, buffer);
				
			DisplayUnSavedGroupsMuteMenu(param1);
		}
	}
	
	return 0;
}

void DisplayAlertMenu(int client, bool hasTarget, int target, char[] Argument = "")
{
	if(g_hDB == null)
	{
		g_iClientSmMode[client] = SmMode_Temp;
		if(hasTarget && target != -1)
		{
			Ignore(client, target);
			CPrintToChat(client, "%sYou have self-muted{olive} %N{default}.", PLUGIN_PREFIX, target);
		}
		else if(!hasTarget)
			MuteSpecial(client, Argument);
		
		g_iClientSmMode[client] = SmMode_Alert;
		return;
	}
	
	Menu menu = new Menu(MenuHandler_Alert);
	int SpecialMute = GetSpecialMutesFlags(Argument);
	char aBuf[64];
	
	FormatSpecialMutes(SpecialMute, aBuf, sizeof(aBuf));
	
	char sTitle[128];
	hasTarget ? Format(sTitle, sizeof(sTitle), "[Self-Mute] Select a duration for %N?", target) : Format(sTitle, sizeof(sTitle), "[Self-Mute] Select a duration for @%s", aBuf);
	menu.SetTitle(sTitle);
	
	char sItem[64], sText[120], sText1[120];
	int userid;
	if(target != -1)
	    userid = GetClientUserId(target);
	    
	int targetEx = GetClientOfUserId(userid);
		
	char buffer[32];
	Format(buffer, sizeof(buffer), "%d", userid);
	if(hasTarget)
	{
		if(targetEx < 1)
			return;
			
		Format(sItem, sizeof(sItem), buffer);
		Format(sText, sizeof(sText), "Permanently");
		Format(sText1, sizeof(sText1), "Session");
	}
	else
	{
		Format(sItem, sizeof(sItem), Argument);
		Format(sText, sizeof(sText), "Permanently");
		Format(sText1, sizeof(sText1), "Session");
	}
	
	menu.AddItem(sItem, sText);
	menu.AddItem(sItem, sText1);
	
	menu.ExitButton = true;
	menu.Display(client, MENU_TIME_FOREVER);
}

public int MenuHandler_Alert(Menu menu, MenuAction action, int param1, int param2)
{
    switch(action)
    {
        case MenuAction_End:
            delete menu;

        case MenuAction_Select:
        {
            if(param2 == 0)
            {
				//if client chose to save the mute then:

                char buffer[128];
                menu.GetItem(param2, buffer, sizeof(buffer));

                if(buffer[0] == '@')
                {
                    int SpecialMute = GetSpecialMutesFlags(buffer);
                    char aBuf[64];
                    FormatSpecialMutes(SpecialMute, aBuf, sizeof(aBuf));

					// We should change the mode before and after running the MuteSpecial function
                    g_iClientSmMode[param1] = SmMode_Perma;
                    MuteSpecial(param1, buffer);
                    g_iClientSmMode[param1] = SmMode_Alert;
                }
                else
                {
					int userid = StringToInt(buffer);
					// We should change the mode before and after running the MuteSpecial function
					int target = GetClientOfUserId(userid);
					if(target < 1)
					{
						CPrintToChat(param1, "%sThe specified target is not in game anymore.", PLUGIN_PREFIX);
						return 0;
					}
					
					g_iClientSmMode[param1] = SmMode_Perma;
					Ignore(param1, target);
					g_iClientSmMode[param1] = SmMode_Alert;
					CPrintToChat(param1, "%sYou have self-muted{olive} %N{default}.", PLUGIN_PREFIX, target);
                }
            }
            else if(param2 == 1)
            {
				//if client chose to not save the selfmute

                char buffer[128];
                menu.GetItem(param2, buffer, sizeof(buffer));

                if(buffer[0] == '@')
                {
					int SpecialMute = GetSpecialMutesFlags(buffer);
					char aBuf[64];
					FormatSpecialMutes(SpecialMute, aBuf, sizeof(aBuf));

					g_iClientSmMode[param1] = SmMode_Temp;
					MuteSpecial(param1, buffer);
					g_iClientSmMode[param1] = SmMode_Alert;
                }
                else
                {
                    int userid = StringToInt(buffer);
                    int target = GetClientOfUserId(userid);
                    if(target < 1)
                    {
                    	CPrintToChat(param1, "%sThe specified target is not in game anymore.", PLUGIN_PREFIX);
                    	return 0;
                    }
					
                    g_iClientSmMode[param1] = 0; 
                    Ignore(param1, target);
                    g_iClientSmMode[param1] = 2;
                    CPrintToChat(param1, "%sYou have self-muted{olive} %N{default}.", PLUGIN_PREFIX, target);
                }
            }
        }
    }

    return 0;
}

void DisplayMuteMenu(int client)
{
	Menu menu = new Menu(MenuHandler_MuteMenu, MenuAction_Select|MenuAction_Cancel|MenuAction_End|MenuAction_DrawItem|MenuAction_DisplayItem);
	menu.ExitButton = true;

	int[] aClients = new int[MaxClients + 1];

	#if defined _voiceannounceex_included_
	if(g_Plugin_voiceannounce_ex)
	{
		// Count talking players and insert id's into aClients array
		int CurrentlyTalking = 0;
		for(int i = 1; i <= MaxClients; i++)
		{
			if(i != client && IsClientInGame(i) && !IsFakeClient(i) && IsClientSpeaking(i))
				aClients[CurrentlyTalking++] = i;
		}

		if(CurrentlyTalking > 0)
		{
			// insert player names into g_PlayerNames array
			for(int i = 0; i < CurrentlyTalking; i++)
				GetClientName(aClients[i], g_PlayerNames[aClients[i]], sizeof(g_PlayerNames[]));

			// sort aClients array by player name
			SortCustom1D(aClients, CurrentlyTalking, SortByPlayerName);

			// insert players sorted
			char aBuf[12];
			for(int i = 0; i < CurrentlyTalking; i++)
			{
				IntToString(GetClientUserId(aClients[i]), aBuf, sizeof(aBuf));
				menu.AddItem(aBuf, g_PlayerNames[aClients[i]]);
			}

			// insert spacers
			int Entries = 7 - CurrentlyTalking % 7;
			while(Entries--)
				menu.AddItem("", "", ITEMDRAW_RAWLINE);
		}
	}
	#endif

	menu.AddItem("@all", "Everyone");
	menu.AddItem("@spec", "Spectators");
#if defined _zr_included
	menu.AddItem("@ct", "Humans");
#else
	menu.AddItem("@ct", "Counter-Terrorists");
#endif
#if defined _zr_included
	menu.AddItem("@t", "Zombies");
#else
	menu.AddItem("@t", "Terrorists");
#endif
	menu.AddItem("@dead", "Dead players");
	menu.AddItem("@alive", "Alive players");
	if(g_Plugin_AdvancedTargeting)
		menu.AddItem("@!friends", "Not Steam friend");
	else
		menu.AddItem("", "", ITEMDRAW_RAWLINE);

	// Count valid players and insert id's into aClients array
	int Players = 0;
	for(int i = 1; i <= MaxClients; i++)
	{
		if(i != client && IsClientInGame(i) && !IsFakeClient(i))
			aClients[Players++] = i;
	}

	// insert player names into g_PlayerNames array
	for(int i = 0; i < Players; i++)
		GetClientName(aClients[i], g_PlayerNames[aClients[i]], sizeof(g_PlayerNames[]));

	// sort aClients array by player name
	SortCustom1D(aClients, Players, SortByPlayerName);

	// insert players sorted
	char aBuf[12];
	for(int i = 0; i < Players; i++)
	{
		IntToString(GetClientUserId(aClients[i]), aBuf, sizeof(aBuf));
		menu.AddItem(aBuf, g_PlayerNames[aClients[i]]);
	}

	menu.Display(client, MENU_TIME_FOREVER);
}

public int MenuHandler_MuteMenu(Menu menu, MenuAction action, int param1, int param2)
{
	switch(action)
	{
		case MenuAction_End:
		{
			if(param1 != MenuEnd_Selected)
				CloseHandle(menu);
		}
		case MenuAction_Select:
		{
			int Style;
			char aItem[32];
			char aDisp[MAX_NAME_LENGTH + 4];
			menu.GetItem(param2, aItem, sizeof(aItem), Style, aDisp, sizeof(aDisp));

			if(Style != ITEMDRAW_DEFAULT || !aItem[0])
			{
				if (g_hCVar_Debug.IntValue >= 1)
					PrintToChat(param1, "%sInternal error: aItem[0] -> %d | Style -> %d", PLUGIN_PREFIX, aItem[0], Style);
				else
					PrintToChat(param1, "%sInternal error. Please try again.", PLUGIN_PREFIX);
				return 0;
			}

			if(aItem[0] == '@')
			{
				int Flag = GetSpecialMutesFlags(aItem);
				if(Flag && g_SpecialMutes[param1] & Flag)
					UnMuteSpecial(param1, aItem);
				else
					MuteSpecial(param1, aItem);

				if(g_iClientSmMode[param1] != SmMode_Alert)
					menu.DisplayAt(param1, GetMenuSelectionPosition(), MENU_TIME_FOREVER);

				return 0;
			}

			int UserId = StringToInt(aItem);
			int client = GetClientOfUserId(UserId);
			if(!client)
			{
				CPrintToChat(param1, "%sPlayer no longer available.", PLUGIN_PREFIX);
				menu.DisplayAt(param1, GetMenuSelectionPosition(), MENU_TIME_FOREVER);
				return 0;
			}

			if(GetIgnored(param1, client))
			{
				UnIgnore(param1, client);
				CPrintToChat(param1, "%sYou have self-unmuted{olive} %N{default}.", PLUGIN_PREFIX, client);
			}
			else if(GetExempt(param1, client))
			{
				UnExempt(param1, client);
				CPrintToChat(param1, "%sYou have removed exempt from self-mute{olive} %N{default}.", PLUGIN_PREFIX, client);
			}
			else
			{
				Ignore(param1, client);
				CPrintToChat(param1, "%sYou have self-muted{olive} %N{default}.", PLUGIN_PREFIX, client);
			}

			if(g_iClientSmMode[param1] != SmMode_Alert)
				menu.DisplayAt(param1, GetMenuSelectionPosition(), MENU_TIME_FOREVER);

			return 0;
		}
		case MenuAction_DrawItem:
		{
			int Style;
			char aItem[32];
			menu.GetItem(param2, aItem, sizeof(aItem), Style);

			if(!aItem[0])
				return ITEMDRAW_DISABLED;

			if(aItem[0] == '@')
			{
				int Flag = GetSpecialMutesFlags(aItem);
				if(Flag & MUTE_ALL)
					return Style;
				else if(g_SpecialMutes[param1] & MUTE_ALL)
					return ITEMDRAW_DISABLED;

				return Style;
			}

			int UserId = StringToInt(aItem);
			int client = GetClientOfUserId(UserId);
			if(!client) // Player disconnected
				return ITEMDRAW_DISABLED;

			return Style;
		}
		case MenuAction_DisplayItem:
		{
			int Style;
			char aItem[32];
			char aDisp[MAX_NAME_LENGTH + 4];
			menu.GetItem(param2, aItem, sizeof(aItem), Style, aDisp, sizeof(aDisp));

			// Start of current page
			if((param2 + 1) % 7 == 1)
			{
				if(aItem[0] == '@')
					menu.SetTitle("[Self-Mute] Groups");
				else if(param2 == 0)
					menu.SetTitle("[Self-Mute] Talking players");
				else
					menu.SetTitle("[Self-Mute] All players");
			}

			if(!aItem[0])
				return 0;

			if(aItem[0] == '@')
			{
				int Flag = GetSpecialMutesFlags(aItem);
				if(Flag && g_SpecialMutes[param1] & Flag)
				{
					char aBuf[32] = "[M] ";
					FormatSpecialMutes(Flag, aBuf, sizeof(aBuf));
					if(!StrEqual(aDisp, aBuf))
						return RedrawMenuItem(aBuf);
				}

				return 0;
			}

			int UserId = StringToInt(aItem);
			int client = GetClientOfUserId(UserId);
			if(!client) // Player disconnected
			{
				char aBuf[MAX_NAME_LENGTH + 4] = "[D] ";
				StrCat(aBuf, sizeof(aBuf), aDisp);
				if(!StrEqual(aDisp, aBuf))
					return RedrawMenuItem(aBuf);
			}

			if(GetIgnored(param1, client))
			{
				char aBuf[MAX_NAME_LENGTH + 4] = "[M] ";
				GetClientName(client, g_PlayerNames[client], sizeof(g_PlayerNames[]));
				StrCat(aBuf, sizeof(aBuf), g_PlayerNames[client]);
				if(!StrEqual(aDisp, aBuf))
					return RedrawMenuItem(aBuf);
			}
			else if(GetExempt(param1, client))
			{
				char aBuf[MAX_NAME_LENGTH + 4] = "[E] ";
				GetClientName(client, g_PlayerNames[client], sizeof(g_PlayerNames[]));
				StrCat(aBuf, sizeof(aBuf), g_PlayerNames[client]);
				if(!StrEqual(aDisp, aBuf))
					return RedrawMenuItem(aBuf);
			}
			else
			{
				GetClientName(client, g_PlayerNames[client], sizeof(g_PlayerNames[]));
				if(!StrEqual(aDisp, g_PlayerNames[client]))
					return RedrawMenuItem(g_PlayerNames[client]);
			}

			return 0;
		}
	}

	return 0;
}

public void CookieMenu_Handler(int client, CookieMenuAction action, any info, char[] buffer, int maxlen)
{
    if(action == CookieMenuAction_DisplayOption)
        Format(buffer, maxlen, "Self-Mute Settings");
    
    if(action == CookieMenuAction_SelectOption)
        DisplayCookiesMenu(client);
}

void DisplayCookiesMenu(int client)
{
    Menu menu = new Menu(MenuHandler_Cookies);
    menu.SetTitle("[Self-Mute] Saving method");

    menu.AddItem("0", "Session only", g_iClientSmMode[client] == SmMode_Temp ? ITEMDRAW_DISABLED : ITEMDRAW_DEFAULT);
    menu.AddItem("1", "Permanently", g_iClientSmMode[client] == SmMode_Perma ? ITEMDRAW_DISABLED : ITEMDRAW_DEFAULT);
    menu.AddItem("2", "Always let me select", g_iClientSmMode[client] == SmMode_Alert ? ITEMDRAW_DISABLED : ITEMDRAW_DEFAULT);

    menu.ExitBackButton = true;
    menu.Display(client, MENU_TIME_FOREVER);
}

public int MenuHandler_Cookies(Menu menu, MenuAction action, int param1, int param2)
{
    switch(action)
    {
        case MenuAction_End:
            delete menu;
        
        case MenuAction_Select:
        {
            char buffer[32];
            menu.GetItem(param2, buffer, sizeof(buffer));
            int mode = StringToInt(buffer);
            g_iClientSmMode[param1] = mode;
            switch(mode)
            {
                case SmMode_Temp:
                    CPrintToChat(param1, "%sMethod saved to: {olive}Session only{default}.", PLUGIN_PREFIX);
                case SmMode_Perma:
                    CPrintToChat(param1, "%sMethod saved to: {olive}Permanently{default}.", PLUGIN_PREFIX);
                case SmMode_Alert:
                    CPrintToChat(param1, "%sMethod saved to: {olive}Always let me select{default}.", PLUGIN_PREFIX);
            }

            char sValue[10];
            IntToString(mode, sValue, sizeof(sValue));
            SetClientCookie(param1, g_hSmModeCookie, sValue);
            DisplayCookiesMenu(param1);
        }

        case MenuAction_Cancel:
        {
            if(param2 == MenuCancel_ExitBack)
                ShowCookieMenu(param1);
        }
    }

    return 0;
}
/*
 * HOOKS
*/
int g_MsgDest;
int g_MsgClient;
char g_MsgName[256];
char g_MsgParam1[256];
char g_MsgParam2[256];
char g_MsgParam3[256];
char g_MsgParam4[256];
char g_MsgRadioSound[256];
int g_MsgPlayersNum;
int g_MsgPlayers[MAXPLAYERS + 1];

public Action Hook_UserMessageRadioText(UserMsg msg_id, Handle bf, const int[] players, int playersNum, bool reliable, bool init)
{
	if(g_bIsProtoBuf)
	{
		g_MsgDest = PbReadInt(bf, "msg_dst");
		g_MsgClient = PbReadInt(bf, "client");
		PbReadString(bf, "msg_name", g_MsgName, sizeof(g_MsgName));
		PbReadString(bf, "params", g_MsgParam1, sizeof(g_MsgParam1), 0);
		PbReadString(bf, "params", g_MsgParam2, sizeof(g_MsgParam2), 1);
		PbReadString(bf, "params", g_MsgParam3, sizeof(g_MsgParam3), 2);
		PbReadString(bf, "params", g_MsgParam4, sizeof(g_MsgParam4), 3);
	}
	else
	{
		g_MsgDest = BfReadByte(bf);
		g_MsgClient = BfReadByte(bf);
		BfReadString(bf, g_MsgName, sizeof(g_MsgName), false);
		BfReadString(bf, g_MsgParam1, sizeof(g_MsgParam1), false);
		BfReadString(bf, g_MsgParam2, sizeof(g_MsgParam2), false);
		BfReadString(bf, g_MsgParam3, sizeof(g_MsgParam3), false);
		BfReadString(bf, g_MsgParam4, sizeof(g_MsgParam4), false);
	}

	// Check which clients need to be excluded.
	g_MsgPlayersNum = 0;
	for(int i = 0; i < playersNum; i++)
	{
		int client = players[i];
		if(!GetIgnored(client, g_MsgClient))
			g_MsgPlayers[g_MsgPlayersNum++] = client;
	}

	// No clients were excluded.
	if(g_MsgPlayersNum == playersNum)
	{
		g_MsgClient = -1;
		return Plugin_Continue;
	}
	else if(g_MsgPlayersNum == 0) // All clients were excluded and there is no need to broadcast.
	{
		g_MsgClient = -2;
		return Plugin_Handled;
	}

	return Plugin_Handled;
}

public Action Hook_UserMessageSendAudio(UserMsg msg_id, Handle bf, const int[] players, int playersNum, bool reliable, bool init)
{
	if(g_MsgClient == -1)
		return Plugin_Continue;
	else if(g_MsgClient == -2)
		return Plugin_Handled;

	if(g_bIsProtoBuf)
		PbReadString(bf, "radio_sound", g_MsgRadioSound, sizeof(g_MsgRadioSound));
	else
		BfReadString(bf, g_MsgRadioSound, sizeof(g_MsgRadioSound), false);

	if(StrEqual(g_MsgRadioSound, "radio.locknload"))
		return Plugin_Continue;

	DataPack pack = new DataPack();
	pack.WriteCell(g_MsgDest);
	pack.WriteCell(g_MsgClient);
	pack.WriteString(g_MsgName);
	pack.WriteString(g_MsgParam1);
	pack.WriteString(g_MsgParam2);
	pack.WriteString(g_MsgParam3);
	pack.WriteString(g_MsgParam4);
	pack.WriteString(g_MsgRadioSound);
	pack.WriteCell(g_MsgPlayersNum);

	for(int i = 0; i < g_MsgPlayersNum; i++)
		pack.WriteCell(g_MsgPlayers[i]);

	RequestFrame(OnPlayerRadio, pack);

	return Plugin_Handled;
}

public void OnPlayerRadio(DataPack pack)
{
	pack.Reset();
	g_MsgDest = pack.ReadCell();
	g_MsgClient = pack.ReadCell();
	pack.ReadString(g_MsgName, sizeof(g_MsgName));
	pack.ReadString(g_MsgParam1, sizeof(g_MsgParam1));
	pack.ReadString(g_MsgParam2, sizeof(g_MsgParam2));
	pack.ReadString(g_MsgParam3, sizeof(g_MsgParam3));
	pack.ReadString(g_MsgParam4, sizeof(g_MsgParam4));
	pack.ReadString(g_MsgRadioSound, sizeof(g_MsgRadioSound));
	g_MsgPlayersNum = pack.ReadCell();

	int playersNum = 0;
	for(int i = 0; i < g_MsgPlayersNum; i++)
	{
		int client_ = pack.ReadCell();
		if(IsClientInGame(client_))
			g_MsgPlayers[playersNum++] = client_;
	}
	CloseHandle(pack);

	Handle RadioText = StartMessage("RadioText", g_MsgPlayers, playersNum, USERMSG_RELIABLE);
	if(g_bIsProtoBuf)
	{
		PbSetInt(RadioText, "msg_dst", g_MsgDest);
		PbSetInt(RadioText, "client", g_MsgClient);
		PbSetString(RadioText, "msg_name", g_MsgName);
		PbSetString(RadioText, "params", g_MsgParam1, 0);
		PbSetString(RadioText, "params", g_MsgParam2, 1);
		PbSetString(RadioText, "params", g_MsgParam3, 2);
		PbSetString(RadioText, "params", g_MsgParam4, 3);
	}
	else
	{
		BfWriteByte(RadioText, g_MsgDest);
		BfWriteByte(RadioText, g_MsgClient);
		BfWriteString(RadioText, g_MsgName);
		BfWriteString(RadioText, g_MsgParam1);
		BfWriteString(RadioText, g_MsgParam2);
		BfWriteString(RadioText, g_MsgParam3);
		BfWriteString(RadioText, g_MsgParam4);
	}
	EndMessage();

	Handle SendAudio = StartMessage("SendAudio", g_MsgPlayers, playersNum, USERMSG_RELIABLE);
	if(g_bIsProtoBuf)
		PbSetString(SendAudio, "radio_sound", g_MsgRadioSound);
	else
		BfWriteString(SendAudio, g_MsgRadioSound);
	EndMessage();
}

/*
 * HELPERS
*/
void UpdateIgnored()
{
	if(g_Plugin_ccc)
		CCC_UpdateIgnoredArray(g_Ignored);
}

public int SortByPlayerName(int elem1, int elem2, const int[] array, Handle hndl)
{
	return strcmp(g_PlayerNames[elem1], g_PlayerNames[elem2], false);
}

bool GetIgnored(int client, int target)
{
	return g_Ignored[(client * (MAXPLAYERS + 1) + target)];
}

void SetIgnored(int client, int target, bool ignored)
{
	g_Ignored[(client * (MAXPLAYERS + 1) + target)] = ignored;
}

bool GetExempt(int client, int target)
{
	return g_Exempt[client][target];
}

void SetExempt(int client, int target, bool exempt)
{
	g_Exempt[client][target] = exempt;
}
