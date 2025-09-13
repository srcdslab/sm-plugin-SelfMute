#pragma semicolon 1

#include <sourcemod>
#include <sdktools>
#include <cstrike>
#include <multicolors>
#include <clientprefs>
#include <ccc>

#undef REQUIRE_PLUGIN
#tryinclude <zombiereloaded>
#tryinclude <Voice>
#tryinclude <PlayerManager>
#define REQUIRE_PLUGIN

/* If your server doesn't have zombiereloaded but you have the zombiereloaded include file, then uncomment this: */
/*
#if defined _zr_included
#undef _zr_included
#endif
*/

#pragma newdecls required

#define DB_NAME "SelfMuteV2"

#define PLUGIN_PREFIX "{green}[Self-Mute]{default}"

/* Other plugins library checking variables */
bool g_Plugin_ccc;
bool g_Plugin_zombiereloaded;

/* Late Load */
bool g_bLate;

/* CCC ignoring variable */
bool g_Ignored[(MAXPLAYERS + 1) * (MAXPLAYERS + 1)];

/* Client Boolean variables */
bool g_bClientText[MAXPLAYERS + 1][MAXPLAYERS + 1];
bool g_bClientVoice[MAXPLAYERS + 1][MAXPLAYERS + 1];
bool g_bClientGroupText[MAXPLAYERS + 1][view_as<int>(GROUP_MAX_NUM)];
bool g_bClientGroupVoice[MAXPLAYERS + 1][view_as<int>(GROUP_MAX_NUM)];

/* Permanent selfmute Boolean Variables */
bool g_bClientTargetPerma[MAXPLAYERS + 1][MAXPLAYERS + 1];
bool g_bClientGroupPerma[MAXPLAYERS + 1][view_as<int>(GROUP_MAX_NUM)];

/* ProtoBuf bool */
bool g_bIsProtoBuf = false;

/* Sqlite bool */
bool g_bSQLLite = false;

/* ConVar List */
ConVar g_cvDefaultMuteTypeSettings;
ConVar g_cvDefaultMuteDurationSettings;

/* Radio Last Message Float */
float g_fLastMessageTime;

/* Enums & Structs */
enum MuteType {
	MuteType_Voice = 0,
	MuteType_Text = 1,
	MuteType_All = 2,
	MuteType_AskFirst = 3,
	MuteType_None = 4
};

enum MuteDuration {
	MuteDuration_Temporary = 0,
	MuteDuration_Permanent = 1,
	MuteDuration_AskFirst = 2
};

enum MuteTarget {
	MuteTarget_Client = 0,
	MuteTarget_Group = 1
};

enum GroupFilter {
	GROUP_ALL = 0,
	GROUP_CTS = 1,
	GROUP_TS = 2,
	GROUP_SPECTATORS = 3,
	GROUP_NOSTEAM = 4,
	GROUP_STEAM = 5,
	GROUP_MAX_NUM = 6
};

char g_sGroupsNames[][] = {
	"All Players",
#if defined _zr_included
	"Humans",
	"Zombies",
#else
	"Counter Terrorists",
	"Terrorists",
#endif
	"Spectators",
	"No-Steam Players",
	"Steam Players"
};

char g_sGroupsFilters[][] = {
	"@all",
	"@cts",
	"@ts",
	"@spectators",
	"@nosteam",
	"@steam"
};

enum struct PlayerData {
	char name[32];
	char steamID[20];
	MuteType muteType;
	MuteDuration muteDuration;
	bool addedToDB;

	void Reset() {
		this.Setup(
			"", "", view_as<MuteType>(g_cvDefaultMuteTypeSettings.IntValue),
					view_as<MuteDuration>(g_cvDefaultMuteDurationSettings.IntValue)
		);
	}

	void Setup(char[] nameEx, char[] steamIDEx, MuteType muteTypeEx, MuteDuration muteDurationEx) {
		strcopy(this.name, sizeof(PlayerData::name), nameEx);
		strcopy(this.steamID, sizeof(PlayerData::steamID), steamIDEx);
		this.muteType = muteTypeEx;
		this.muteDuration = muteDurationEx;
		this.addedToDB = false;
	}
}

/* Player Data */
PlayerData g_PlayerData[MAXPLAYERS + 1];

/* Database */
Database g_hDB;

public Plugin myinfo = {
	name 			= "SelfMute V2",
	author 			= "Dolly",
	description 	= "Ignore other players in text and voicechat.",
	version 		= "2.0.0",
	url 			= ""
};

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max) {
	RegPluginLibrary("SelfMuteV2");
	CreateNative("SelfMute_GetTextSelfMute", Native_GetTextSelfMute);
	CreateNative("SelfMute_GetVoiceSelfMute", Native_GetVoiceSelfMute);
	CreateNative("SelfMute_GetSelfMute", Native_GetSelfMute);
	g_bLate = late;
	return APLRes_Success;
}

int Native_GetTextSelfMute(Handle plugin, int params) {
	int client = GetNativeCell(1);
	int target = GetNativeCell(2);
	return g_bClientText[client][target];
}

int Native_GetVoiceSelfMute(Handle plugin, int params) {
	int client = GetNativeCell(1);
	int target = GetNativeCell(2);
	return g_bClientVoice[client][target];
}

int Native_GetSelfMute(Handle plugin, int params) {
	int client = GetNativeCell(1);
	int target = GetNativeCell(2);
	return (g_bClientVoice[client][target] && g_bClientText[client][target]);
}

public void OnPluginStart() {
	/* Translation */
	LoadTranslations("common.phrases");

	/* ConVars */
	g_cvDefaultMuteTypeSettings 		= CreateConVar("sm_selfmute_default_mute_type", "3", "[0 = Self-Mute Voice only | 1 = Self-Mute Text Only | 2 = Self-Mute Both | 3 = Ask First]");
	g_cvDefaultMuteDurationSettings = CreateConVar("sm_selfmute_default_mute_duration", "2", "[0 = Temporary, 1 = Permanent, 2 = Ask First]");

	AutoExecConfig();

	/* Commands */
	RegConsoleCmd("sm_sm", Command_SelfMute, "Mute player by typing !sm [playername]");
	RegConsoleCmd("sm_selfmute", Command_SelfMute, "Mute player by typing !sm [playername]");

	RegConsoleCmd("sm_su", Command_SelfUnMute, "Unmute player by typing !su [playername]");
	RegConsoleCmd("sm_selfunmute", Command_SelfUnMute, "Unmute player by typing !su [playername]");

	RegConsoleCmd("sm_cm", Command_CheckMutes, "Check who you have self-muted");
	RegConsoleCmd("sm_suall", Command_SelfUnMuteAll, "Unmute all clients/groups");
	RegConsoleCmd("sm_smcookies", Command_SmCookies, "Choose the good cookie");

	RegConsoleCmd("sm_psm", Command_PermaSelfMute, "Permanently mute a player");
	RegConsoleCmd("sm_psu", Command_PermaSelfUnMute, "Permanently unmute a player");

	/* Cookie Menu */
	SetCookieMenuItem(CookieMenu_Handler, 0, "SelfMute Cookies");

	/* Events */
	HookEvent("player_team", Event_PlayerTeam);
	HookEvent("round_start", Event_RoundStart);

	/* Connect To DB */
	ConnectToDB();

	/* Prefix */
	CSetPrefix(PLUGIN_PREFIX);

	/* Radio Commands */
	if (GetFeatureStatus(FeatureType_Native, "GetUserMessageType") == FeatureStatus_Available && GetUserMessageType() == UM_Protobuf) {
		g_bIsProtoBuf = true;
	}

	UserMsg msgRadioText = GetUserMessageId("RadioText");
	UserMsg msgSendAudio = GetUserMessageId("SendAudio");

	if (msgRadioText == INVALID_MESSAGE_ID || msgSendAudio == INVALID_MESSAGE_ID) {
		SetFailState("This game doesnt support RadioText or SendAudio");
	}

	HookUserMessage(msgRadioText, Hook_UserMessageRadioText, true);
	HookUserMessage(msgSendAudio, Hook_UserMessageSendAudio, true);

	/* Hook Radio Commands */
	static const char radioMessages[][] = {
		"coverme","takepoint","holdpos","followme","regroup","takingfire","go","fallback","sticktog","stormfront",
		"roger","enemyspot","needbackup","sectorclear","inposition","negative","report","getout","enemydown","reportingin","getinpos"
	};

	for (int i = 0; i < sizeof(radioMessages); i++) {
		AddCommandListener(OnRadioCommand, radioMessages[i]);
	}

	/* Incase of a late load */
	if (g_bLate) {
		LateLoadClients();
	}
}

void LateLoadClients() {
	for (int i = 1; i <= MaxClients; i++) {
		if (!IsClientConnected(i)) {
			continue;
		}

		OnClientConnected(i);

		if (IsClientAuthorized(i)) {
			OnClientPostAdminCheck(i);
		}
	}
}

Action Command_SmCookies(int client, int args) {
	if (!client || !IsClientAuthorized(client)) {
		return Plugin_Handled;
	}

	ShowCookiesMenu(client);
	return Plugin_Handled;
}

void ShowCookiesMenu(int client) {
	Menu menu = new Menu(Menu_ShowCookies);
	menu.SetTitle("[SM] Choose your prefered cookie");

	menu.AddItem("0", "Mute Type, Text | Chat | Both | Ask First");
	menu.AddItem("1", "Mute Duration, Temporary | Permanent | Ask First");

	menu.ExitButton = true;
	menu.Display(client, MENU_TIME_FOREVER);
}

int Menu_ShowCookies(Menu menu, MenuAction action, int param1, int param2) {
	switch(action) {
		case MenuAction_End: {
			delete menu;
		}

		case MenuAction_Select: {
			char option[2];
			menu.GetItem(param2, option, sizeof(option));
			if (StrEqual(option, "0")) {
				ShowCookiesMuteTypeMenu(param1);
			} else {
				ShowCookiesMuteDurationMenu(param1);
			}
		}
	}

	return 1;
}

void ShowCookiesMuteTypeMenu(int client) {
	Menu menu = new Menu(Menu_ShowCookiesMuteTypeMenu);
	menu.SetTitle("[SM] Choose your prefered cookie, how you want to self-mute a player or a group");

	menu.AddItem("0", "Voice Chat", g_PlayerData[client].muteType == view_as<MuteType>(0) ? ITEMDRAW_DISABLED : ITEMDRAW_DEFAULT);
	menu.AddItem("1", "Text Chat", g_PlayerData[client].muteType == view_as<MuteType>(1) ? ITEMDRAW_DISABLED : ITEMDRAW_DEFAULT);
	menu.AddItem("2", "Both Chats", g_PlayerData[client].muteType == view_as<MuteType>(2) ? ITEMDRAW_DISABLED : ITEMDRAW_DEFAULT);
	menu.AddItem("3", "Ask First", g_PlayerData[client].muteType == view_as<MuteType>(3) ? ITEMDRAW_DISABLED : ITEMDRAW_DEFAULT);

	menu.ExitBackButton = true;
	menu.Display(client, MENU_TIME_FOREVER);
}

void ShowCookiesMuteDurationMenu(int client) {
	Menu menu = new Menu(Menu_ShowCookiesMuteDurationMenu);
	menu.SetTitle("[SM] Choose your prefered cookie, how you want to self-mute a player or a group");

	menu.AddItem("0", "Temporary", g_PlayerData[client].muteDuration == view_as<MuteDuration>(0) ? ITEMDRAW_DISABLED : ITEMDRAW_DEFAULT);
	menu.AddItem("1", "Permanent", g_PlayerData[client].muteDuration == view_as<MuteDuration>(1) ? ITEMDRAW_DISABLED : ITEMDRAW_DEFAULT);
	menu.AddItem("2", "Ask First", g_PlayerData[client].muteDuration == view_as<MuteDuration>(2) ? ITEMDRAW_DISABLED : ITEMDRAW_DEFAULT);

	menu.ExitBackButton = true;
	menu.Display(client, MENU_TIME_FOREVER);
}

int Menu_ShowCookiesMuteTypeMenu(Menu menu, MenuAction action, int param1, int param2) {
	switch(action) {
		case MenuAction_End: {
			delete menu;
		}

		case MenuAction_Cancel: {
			if (param2 == MenuCancel_ExitBack) {
				ShowCookiesMenu(param1);
			}
		}

		case MenuAction_Select: {
			char option[2];
			menu.GetItem(param2, option, sizeof(option));
			MuteType muteType = view_as<MuteType>(StringToInt(option));
			g_PlayerData[param1].muteType = muteType;
			CPrintToChat(param1, "Cookie Saved!");
			ShowCookiesMuteTypeMenu(param1);
			DB_UpdateClientData(param1, 0); // 0 = mute type
		}
	}

	return 1;
}

int Menu_ShowCookiesMuteDurationMenu(Menu menu, MenuAction action, int param1, int param2) {
	switch(action) {
		case MenuAction_End: {
			delete menu;
		}

		case MenuAction_Cancel: {
			if (param2 == MenuCancel_ExitBack) {
				ShowCookiesMenu(param1);
			}
		}

		case MenuAction_Select: {
			char option[2];
			menu.GetItem(param2, option, sizeof(option));
			MuteDuration muteDuration = view_as<MuteDuration>(StringToInt(option));
			g_PlayerData[param1].muteDuration = muteDuration;
			CPrintToChat(param1, "Cookie Saved!");
			ShowCookiesMuteDurationMenu(param1);
			DB_UpdateClientData(param1, 1); // 1 = mute duration
		}
	}

	return 1;
}
Action Command_CheckMutes(int client, int args) {
	if (!client) {
		return Plugin_Handled;
	}

	ShowSelfMuteTargetsMenu(client);
	return Plugin_Handled;
}

Action Command_SelfUnMuteAll(int client, int args) {
	if (!client) {
		return Plugin_Handled;
	}

	if (!IsClientAuthorized(client)) {
		CReplyToCommand(client, "You need to be authorized to use this command. Please rejoin.");
		return Plugin_Handled;
	}

	for (int i = 1; i <= MaxClients; i++) {
		if (!IsClientInGame(i) || i == client) {
			continue;
		}

		if (g_bClientText[client][i] || g_bClientVoice[client][i]) {
			ApplySelfUnMute(client, i);
		}
	}

	for (int i = 0; i < view_as<int>(GROUP_MAX_NUM); i++) {
		if (g_bClientGroupText[client][i] || g_bClientGroupVoice[client][i]) {
			ApplySelfUnMuteGroup(client, view_as<GroupFilter>(i));
		}
	}

	CReplyToCommand(client, "You have self-unmuted all clients/groups.");
	return Plugin_Handled;
}

Action Command_SelfUnMute(int client, int args) {
	if (!client) {
		return Plugin_Handled;
	}

	if (!IsClientAuthorized(client)) {
		CReplyToCommand(client, "You need to be authorized to use this command. Please rejoin.");
		return Plugin_Handled;
	}

	if (!GetCmdArgs()) {
		OpenSelfMuteMenu(client);
		return Plugin_Handled;
	}

	char arg1[32];
	GetCmdArg(1, arg1, sizeof(arg1));

	if (arg1[0] == '@') {
		HandleGroupSelfUnMute(client, arg1);
		return Plugin_Handled;
	}

	int target = FindTarget(client, arg1, false, false);
	if (target == -1) {
		return Plugin_Handled;
	}

	if (target == client) {
		CReplyToCommand(client, "Silly, you cannot un-mute yourself!");
		return Plugin_Handled;
	}

	if (!g_bClientText[client][target] && !g_bClientVoice[client][target]) {
		CReplyToCommand(client, "You do not have this player self-muted.");
		return Plugin_Handled;
	}

	if (IsFakeClient(target) && !IsClientSourceTV(target)) {
		CReplyToCommand(client, "You cannot target a bot.");
		return Plugin_Handled;
	}

	HandleSelfUnMute(client, target);
	return Plugin_Handled;
}

Action Command_PermaSelfMute(int client, int args) {
	if (!client) {
		return Plugin_Handled;
	}

	if (!IsClientAuthorized(client)) {
		CReplyToCommand(client, "You need to be authorized to use this command. Please rejoin.");
		return Plugin_Handled;
	}

	if (!GetCmdArgs()) {
		ShowSelfMuteTargetsMenu(client);
		CReplyToCommand(client, "Usage: !psm <playername | @group>");
		return Plugin_Handled;
	}

	char arg1[32];
	GetCmdArg(1, arg1, sizeof(arg1));

	if (arg1[0] == '@') {
		HandleGroupSelfMute(client, arg1, MuteType_All, MuteDuration_Permanent);
		return Plugin_Handled;
	}

	int target = FindTarget(client, arg1, false, false);
	if (target == -1) {
		return Plugin_Handled;
	}

	if (target == client) {
		CReplyToCommand(client, "Silly, you cannot mute yourself!");
		return Plugin_Handled;
	}

	if (IsFakeClient(target) && !IsClientSourceTV(target)) {
		CReplyToCommand(client, "You cannot target a bot.");
		return Plugin_Handled;
	}

	HandleClientSelfMute(client, target, MuteType_All, MuteDuration_Permanent);
	return Plugin_Handled;
}

Action Command_PermaSelfUnMute(int client, int args) {
	if (!client) {
		return Plugin_Handled;
	}

	if (!IsClientAuthorized(client)) {
		CReplyToCommand(client, "You need to be authorized to use this command. Please rejoin.");
		return Plugin_Handled;
	}

	if (!GetCmdArgs()) {
		OpenSelfMuteMenu(client);
		CReplyToCommand(client, "Usage: !psu <playername|@group>");
		return Plugin_Handled;
	}

	char arg1[32];
	GetCmdArg(1, arg1, sizeof(arg1));

	if (arg1[0] == '@') {
		HandleGroupSelfUnMute(client, arg1);
		return Plugin_Handled;
	}

	int target = FindTarget(client, arg1, false, false);
	if (target == -1) {
		return Plugin_Handled;
	}

	if (target == client) {
		CReplyToCommand(client, "Silly, you cannot un-mute yourself!");
		return Plugin_Handled;
	}

	if (!g_bClientText[client][target] && !g_bClientVoice[client][target]) {
		CReplyToCommand(client, "You do not have this player permanently self-muted.");
		return Plugin_Handled;
	}

	if (!g_bClientTargetPerma[client][target]) {
		CReplyToCommand(client, "You do not have this player permanently self-muted. Use !su to unmute temporary mutes.");
		return Plugin_Handled;
	}

	HandleSelfUnMute(client, target);
	return Plugin_Handled;
}


void HandleSelfUnMute(int client, int target) {
	ApplySelfUnMute(client, target);

	CPrintToChat(client, "You have {green}self-unmuted {olive}%N", target);

	if (IsClientAdmin(target)) {
		LogAction(client, target, "%L Removed SelfMute on admin. %L", client, target);
	}
}

void OpenSelfMuteMenu(int client) {
	Menu menu = new Menu(Menu_SelfMuteList);
	menu.SetTitle("[SM] Your self-muted Targets list");

	menu.AddItem("0", "Players self-mute List");
	menu.AddItem("1", "Groups self-mute List");

	menu.ExitButton = true;
	menu.Display(client, MENU_TIME_FOREVER);
}

int Menu_SelfMuteList(Menu menu, MenuAction action, int param1, int param2) {
	switch(action) {
		case MenuAction_End: {
			delete menu;
		}

		case MenuAction_Select: {
			char option[2];
			menu.GetItem(param2, option, sizeof(option));
			ShowTargetsMenu(param1, view_as<MuteTarget>(StringToInt(option)));
		}
	}

	return 0;
}

void ShowTargetsMenu(int client, MuteTarget muteTarget) {
	Menu menu = new Menu(Menu_ShowTargets);

	char title[50];
	Format(title, sizeof(title), "%s - self-mute List | X = Muted", (muteTarget == MuteTarget_Client) ? "Players" : "Groups");
	menu.SetTitle(title);

	bool found = false;
	switch(muteTarget) {
		case MuteTarget_Client: {
			for (int i = 1; i <= MaxClients; i++) {
				if (i == client) {
					continue;
				}

				if (!IsClientInGame(i)) {
					continue;
				}

				if (g_bClientText[client][i] || g_bClientVoice[client][i]) {
					bool perma = IsThisMutedPerma(client, i);
					int userid = GetClientUserId(i);

					char itemInfo[12];
					FormatEx(itemInfo, sizeof(itemInfo), "0|%d", userid);
					char itemText[128];

					MuteType checkMuteType = GetMuteType(g_bClientText[client][i], g_bClientVoice[client][i]);

					FormatEx(itemText, sizeof(itemText), "(#%d) %s: Voice[%s] Text[%s] - %s",
														userid,
														g_PlayerData[i].name,
														(checkMuteType == MuteType_All || checkMuteType == MuteType_Voice)
														? "X" : "",
														(checkMuteType == MuteType_All || checkMuteType == MuteType_Text)
														? "X" : "",
														perma ? "Saved" : "Not Saved");
					menu.AddItem(itemInfo, itemText);
					found = true;
				}
			}
		}

		case MuteTarget_Group: {
			for (int i = 0; i < view_as<int>(GROUP_MAX_NUM); i++) {
				if (g_bClientGroupText[client][i] || g_bClientGroupVoice[client][i]) {
					bool perma = IsThisMutedPerma(client, _, g_sGroupsFilters[i]);

					char itemInfo[22];
					FormatEx(itemInfo, sizeof(itemInfo), "1|%s", g_sGroupsFilters[i]);

					char itemText[128];
					MuteType checkMuteType = GetMuteType(g_bClientGroupText[client][i], g_bClientGroupVoice[client][i]);

					FormatEx(itemText, sizeof(itemText), "%s: Voice[%s] Text[%s] - %s",
														g_sGroupsNames[i],
														(checkMuteType == MuteType_All || checkMuteType == MuteType_Voice)
														? "X" : "",
														(checkMuteType == MuteType_All || checkMuteType == MuteType_Text)
														? "X" : "",
														perma ? "Saved" : "Not Saved");
					menu.AddItem(itemInfo, itemText);
					found = true;
				}
			}
		}
	}

	if (!found) {
		menu.AddItem(NULL_STRING, "No result was found!", ITEMDRAW_DISABLED);
	}

	menu.ExitBackButton = true;
	menu.Display(client, MENU_TIME_FOREVER);
}

int Menu_ShowTargets(Menu menu, MenuAction action, int param1, int param2) {
	switch(action) {
		case MenuAction_End: {
			delete menu;
		}

		case MenuAction_Cancel: {
			if (param2 == MenuCancel_ExitBack) {
				OpenSelfMuteMenu(param1);
			}
		}

		case MenuAction_Select: {
			char option[24];
			menu.GetItem(param2, option, sizeof(option));

			char options[2][14];
			ExplodeString(option, "|", options, 2, 14);

			MuteTarget muteTarget = view_as<MuteTarget>(StringToInt(options[0]));
			if (muteTarget == MuteTarget_Client) {
				int target = GetClientOfUserId(StringToInt(options[1]));
				if (!target) {
					CPrintToChat(param1, "Player is no longer available");
					return 1;
				}

				HandleSelfUnMute(param1, target);
			} else {
				HandleGroupSelfUnMute(param1, options[1]);
			}


			ShowTargetsMenu(param1, muteTarget);
		}
	}

	return 1;
}

Action Command_SelfMute(int client, int args) {
	if (!client) {
		return Plugin_Handled;
	}

	if (!IsClientAuthorized(client)) {
		CReplyToCommand(client, "You need to be authorized to use this command. Please rejoin.");
		return Plugin_Handled;
	}

	if (!GetCmdArgs()) {
		ShowSelfMuteTargetsMenu(client);
		return Plugin_Handled;
	}

	char arg1[32];
	GetCmdArg(1, arg1, sizeof(arg1));

	if (arg1[0] == '@') {
		HandleGroupSelfMute(client, arg1, g_PlayerData[client].muteType, g_PlayerData[client].muteDuration);
		return Plugin_Handled;
	}

	int target = FindTarget(client, arg1, false, false);
	if (target == -1) {
		return Plugin_Handled;
	}

	if (target == client) {
		CReplyToCommand(client, "Silly, you cannot mute yourself!");
		return Plugin_Handled;
	}

	if (IsFakeClient(target) && !IsClientSourceTV(target)) {
		CReplyToCommand(client, "You cannot target a bot.");
		return Plugin_Handled;
	}

	HandleClientSelfMute(client, target, g_PlayerData[client].muteType, g_PlayerData[client].muteDuration);
	return Plugin_Handled;
}

void ShowSelfMuteTargetsMenu(int client) {
	Menu menu = new Menu(Menu_ShowSelfMuteTargets);
	menu.SetTitle("[SM] Choose who you want to self-mute");

	menu.AddItem("0", "Players self-mute List");
	menu.AddItem("1", "Groups self-mute List");

	menu.ExitButton = true;
	menu.Display(client, MENU_TIME_FOREVER);
}

int Menu_ShowSelfMuteTargets(Menu menu, MenuAction action, int param1, int param2) {
	switch(action) {
		case MenuAction_End: {
			delete menu;
		}

		case MenuAction_Select: {
			char option[2];
			menu.GetItem(param2, option, sizeof(option));

			MuteTarget muteTarget = view_as<MuteTarget>(StringToInt(option));
			ShowSelfMuteSpecificTargets(param1, muteTarget);
		}
	}

	return 1;
}

void ShowSelfMuteSpecificTargets(int client, MuteTarget muteTarget) {
	Menu menu = new Menu(Menu_ShowSelfMuteSpecificTargets);

	char title[75];
	FormatEx(title, sizeof(title), "[SM] %s to self-mute [TEXT CHAT] [VOICE CHAT]", muteTarget == MuteTarget_Client ? "Players" : "Groups");
	menu.SetTitle(title);

	switch(muteTarget) {
		case MuteTarget_Client: {
			for (int i = 1; i <= MaxClients; i++) {
				if (!IsClientInGame(i)) {
					continue;
				}

				if (i == client) {
					continue;
				}

				if (IsFakeClient(i) && !IsClientSourceTV(i)) {
					continue;
				}

				if (!IsClientAuthorized(i)) {
					continue;
				}

				int userid = GetClientUserId(i);

				char itemInfo[12];
				FormatEx(itemInfo, sizeof(itemInfo), "0|%d", userid);

				char itemText[128];
				FormatEx(itemText, sizeof(itemText), "[#%d] %s - [%s] [%s]", userid, g_PlayerData[i].name, g_bClientText[client][i] ? "X" : "",
														g_bClientVoice[client][i] ? "X" : "");

				menu.AddItem(itemInfo, itemText, (g_bClientText[client][i] && g_bClientVoice[client][i]) ? ITEMDRAW_DISABLED : ITEMDRAW_DEFAULT);
			}
		}

		case MuteTarget_Group: {
			for (int i = 0; i < view_as<int>(GROUP_MAX_NUM); i++) {
				char itemInfo[22];
				FormatEx(itemInfo, sizeof(itemInfo), "1|%s", g_sGroupsFilters[i]);

				char itemText[128];
				FormatEx(itemText, sizeof(itemText), "%s - [%s] [%s]", g_sGroupsNames[i], g_bClientGroupText[client][i] ? "X" : "",
														g_bClientGroupVoice[client][i] ? "X" : "");

				menu.AddItem(itemInfo, itemText, (g_bClientGroupText[client][i] && g_bClientGroupVoice[client][i]) ? ITEMDRAW_DISABLED : ITEMDRAW_DEFAULT);
			}
		}
	}

	menu.ExitButton = true;
	menu.Display(client, MENU_TIME_FOREVER);
}

int Menu_ShowSelfMuteSpecificTargets(Menu menu, MenuAction action, int param1, int param2) {
	switch(action) {
		case MenuAction_End: {
			delete menu;
		}

		case MenuAction_Cancel: {
			if (param2 == MenuCancel_ExitBack) {
				ShowSelfMuteTargetsMenu(param1);
			}
		}

		case MenuAction_Select: {
			char option[24];
			menu.GetItem(param2, option, sizeof(option));

			char options[2][14];
			ExplodeString(option, "|", options, 2, 14);

			MuteTarget muteTarget = view_as<MuteTarget>(StringToInt(options[0]));
			if (muteTarget == MuteTarget_Client) {
				int target = GetClientOfUserId(StringToInt(options[1]));
				if (!target) {
					CPrintToChat(param1, "Player is no longer available");
					return 1;
				}

				MuteType muteType = GetMuteType(g_bClientText[param1][target], g_bClientVoice[param1][target]);
				if (muteType == MuteType_All) {
					return 1;
				}

				if (muteType == g_PlayerData[param1].muteType) {
					CPrintToChat(param1, "You have already self-muted this player. If you want to self-mute another type of chat please change your settings in {olive}!smcookies");
					ShowSelfMuteSpecificTargets(param1, muteTarget);
					return 1;
				}

				HandleClientSelfMute(param1, target, g_PlayerData[param1].muteType, g_PlayerData[param1].muteDuration);
			} else {
				GroupFilter groupFilter = GetGroupFilterByChar(options[1]);

				MuteType muteType = GetMuteType(g_bClientGroupText[param1][view_as<int>(groupFilter)], g_bClientGroupVoice[param1][view_as<int>(groupFilter)]);
				if (muteType == MuteType_All) {
					return 1;
				}

				if (muteType == g_PlayerData[param1].muteType) {
					CPrintToChat(param1, "You have already self-muted this group. If you want to self-mute another type of chat please change your settings in {olive}!smcookies");
					ShowSelfMuteSpecificTargets(param1, muteTarget);
					return 1;
				}

				HandleGroupSelfMute(param1, options[1], g_PlayerData[param1].muteType, g_PlayerData[param1].muteDuration);
			}

			if (g_PlayerData[param1].muteType != MuteType_AskFirst && g_PlayerData[param1].muteDuration != MuteDuration_AskFirst) {
				ShowSelfMuteSpecificTargets(param1, muteTarget);
			}
		}
	}

	return 1;
}

void HandleGroupSelfUnMute(int client, const char[] groupFilterC) {
	GroupFilter groupFilter = GROUP_MAX_NUM;
	for (int i = 0; i < sizeof(g_sGroupsFilters); i++) {
		if (strcmp(groupFilterC, g_sGroupsFilters[i], false) == 0 || StrContains(g_sGroupsFilters[i], groupFilterC, false) != -1) {
			groupFilter = view_as<GroupFilter>(i);
			break;
		}
	}

	if (groupFilter == GROUP_MAX_NUM) {
		CPrintToChat(client, "Cannot find the specified group.");
		return;
	}

	if (!g_bClientGroupText[client][view_as<int>(groupFilter)] && !g_bClientGroupVoice[client][view_as<int>(groupFilter)]) {
		CPrintToChat(client, "You do not have this group self-muted.");
		return;
	}

	ApplySelfUnMuteGroup(client, groupFilter);
	CPrintToChat(client, "You have {green}self-unmuted {olive}%s Group", g_sGroupsNames[view_as<int>(groupFilter)]);
}

void HandleGroupSelfMute(int client, const char[] groupFilterC, MuteType muteType, MuteDuration muteDuration) {
	#if defined _Voice_included
		if (strcmp(groupFilterC, "@talking", false) == 0) {
			bool found = false;
			for (int i = 1; i <= MaxClients; i++) {
				if (!IsClientInGame(i)) {
					continue;
				}

				if (!IsClientTalking(i)) {
					continue;
				}

				found = true;
				HandleClientSelfMute(client, i, MuteType_Voice, MuteDuration_Temporary);
			}

			if (!found) {
				CPrintToChat(client, "No player was found.");
				return;
			}

			return;
		}
	#endif

	GroupFilter groupFilter = GROUP_MAX_NUM;
	for (int i = 0; i < sizeof(g_sGroupsFilters); i++) {
		if (strcmp(groupFilterC, g_sGroupsFilters[i], false) == 0 || StrContains(g_sGroupsFilters[i], groupFilterC, false) != -1) {
			groupFilter = view_as<GroupFilter>(i);
			break;
		}
	}

	if (groupFilter == GROUP_MAX_NUM) {
		CPrintToChat(client, "Cannot find the specified group.");
		return;
	}

	/* we need to check if this client has selfmuted this target before */
	if ((g_bClientGroupText[client][view_as<int>(groupFilter)] && !g_bClientGroupVoice[client][view_as<int>(groupFilter)])
		&& (muteType == MuteType_Voice || muteType == MuteType_All)) {
		bool perma = IsThisMutedPerma(client, _, g_sGroupsFilters[view_as<int>(groupFilter)]);
		muteDuration = (perma) ? MuteDuration_Permanent:MuteDuration_Temporary;
		StartSelfMuteGroup(client, groupFilter, MuteType_Voice, muteDuration);
		return;
	}

	if ((!g_bClientGroupText[client][view_as<int>(groupFilter)] && g_bClientGroupVoice[client][view_as<int>(groupFilter)]) && (muteType == MuteType_Text || muteType == MuteType_All)) {
		bool perma = IsThisMutedPerma(client, _, g_sGroupsFilters[view_as<int>(groupFilter)]);
		muteDuration = (perma) ? MuteDuration_Permanent:MuteDuration_Temporary;
		StartSelfMuteGroup(client, groupFilter, MuteType_Text, muteDuration);
		return;
	}

	MuteType muteTypeEx = GetMuteType(g_bClientGroupText[client][view_as<int>(groupFilter)], g_bClientGroupVoice[client][view_as<int>(groupFilter)]);
	if (muteTypeEx == muteType) {
		CPrintToChat(client, "You have already self-muted this group for either voice or text chats or both!");
		return;
	}

	if (g_bClientGroupText[client][view_as<int>(groupFilter)] && g_bClientGroupVoice[client][view_as<int>(groupFilter)]) {
		CPrintToChat(client, "You have already self-muted this group for its voice and text chats!");
		return;
	}

	if (muteType != MuteType_AskFirst) {
		if ((g_bClientGroupText[client][view_as<int>(GROUP_ALL)] && muteType == MuteType_Text)
			|| (g_bClientGroupVoice[client][view_as<int>(GROUP_ALL)] && muteType == MuteType_Voice)
			|| (g_bClientGroupText[client][view_as<int>(GROUP_ALL)] && g_bClientGroupVoice[client][view_as<int>(GROUP_ALL)]
			&& muteType == MuteType_All)) {
			CPrintToChat(client, "You have already self-muted All Players Group, why do you want to self-mute any other group dummy.");
			return;
		}

		StartSelfMuteGroup(client, groupFilter, muteType, muteDuration);
		return;
	}

	ShowMuteTypeMenuGroup(client, groupFilter);
}

void HandleClientSelfMute(int client, int target, MuteType muteType, MuteDuration muteDuration) {
	/* we need to check if this client has selfmuted this target before */
	if ((g_bClientText[client][target] && !g_bClientVoice[client][target]) && (muteType == MuteType_Voice || muteType == MuteType_All)) {
		bool perma = IsThisMutedPerma(client, target);
		muteDuration = (perma) ? MuteDuration_Permanent:MuteDuration_Temporary;
		StartSelfMute(client, target, MuteType_Voice, muteDuration);
		return;
	}

	if ((!g_bClientText[client][target] && g_bClientVoice[client][target]) && (muteType == MuteType_Text || muteType == MuteType_All)) {
		bool perma = IsThisMutedPerma(client, target);
		muteDuration = (perma) ? MuteDuration_Permanent:MuteDuration_Temporary;
		StartSelfMute(client, target, MuteType_Text, muteDuration);
		return;
	}

	if (g_bClientText[client][target] && g_bClientVoice[client][target]) {
		CPrintToChat(client, "You have already self-muted this player for their voice and text chats!");
		return;
	}

	if (muteType != MuteType_AskFirst) {
		StartSelfMute(client, target, muteType, muteDuration);
		return;
	}

	ShowMuteTypeMenu(client, target);
}

void ShowMuteTypeMenu(int client, int target) {
	MuteType muteType = GetMuteType(g_bClientText[client][target], g_bClientVoice[client][target]);

	Menu menu = new Menu(Menu_ShowMuteType);

	char title[128];
	FormatEx(title, sizeof(title), "[SM] Choose how you want to self-mute %N", target);
	menu.SetTitle(title);

	int userid = GetClientUserId(target);

	char data[12];

	int flags = ITEMDRAW_DEFAULT;
	if (muteType == MuteType_Voice) {
		flags = ITEMDRAW_DISABLED;
	}

	FormatEx(data, sizeof(data), "0|%d", userid);
	menu.AddItem(data, "Voice Chat Only", flags);

	if (muteType == MuteType_Text) {
		flags = ITEMDRAW_DISABLED;
	}

	FormatEx(data, sizeof(data), "1|%d", userid);
	menu.AddItem(data, "Text Chat Only", flags);

	FormatEx(data, sizeof(data), "2|%d", userid);
	menu.AddItem(data, "Both Text and Voice Chats");

	menu.ExitButton = true;
	menu.Display(client, MENU_TIME_FOREVER);
}

int Menu_ShowMuteType(Menu menu, MenuAction action, int param1, int param2) {
	switch(action) {
		case MenuAction_End: {
			delete menu;
		}

		case MenuAction_Select: {
			char option[24];
			menu.GetItem(param2, option, sizeof(option));

			char data[2][12];
			ExplodeString(option, "|", data, sizeof(data), sizeof(data[]));

			int target = GetClientOfUserId(StringToInt(data[1]));
			if (!target) {
				CPrintToChat(param1, "Player is no longer available.");
				return -1;
			}

			MuteType muteType = view_as<MuteType>(StringToInt(data[0]));
			HandleClientSelfMute(param1, target, muteType, g_PlayerData[param1].muteDuration);
		}
	}

	return 1;
}

void StartSelfMute(int client, int target, MuteType muteType, MuteDuration muteDuration) {
	switch(muteDuration) {
		case MuteDuration_Temporary: {
			if (IsClientAdmin(target)) {
				CPrintToChat(client, "You are using SelfMute on an admin, be careful!");
				LogAction(client, target, "%L Self-Muted an admin. %L", client, target);
			}

			ApplySelfMute(client, target, muteType);
			MuteType muteTypeEx = GetMuteType(g_bClientText[client][target], g_bClientVoice[client][target]);

			CPrintToChat(client, "You have {green}self-muted {olive}%N\n{default}Voice Chat: {olive}%s\n{default}Text Chat: {olive}%s", target,
						(muteTypeEx==MuteType_Voice||muteTypeEx==MuteType_All)?"Yes":"No",
						(muteTypeEx==MuteType_Text||muteTypeEx==MuteType_All)?"Yes":"No");
		}

		case MuteDuration_Permanent: {
			ApplySelfMute(client, target, muteType);
			MuteType muteTypeEx = GetMuteType(g_bClientText[client][target], g_bClientVoice[client][target]);

			CPrintToChat(client, "You have {green}self-muted {olive}%N\n{default}Voice Chat: {olive}%s\n{default}Text Chat: {olive}%s", target,
						(muteTypeEx==MuteType_Voice||muteTypeEx==MuteType_All)?"Yes":"No",
						(muteTypeEx==MuteType_Text||muteTypeEx==MuteType_All)?"Yes":"No");

			SaveSelfMuteClient(client, target);
			CPrintToChat(client, "The {olive}self-mute {default}has been saved!");
		}

		case MuteDuration_AskFirst: {
			ShowAlertMenu(client, target, muteType);
		}
	}
}

void ShowAlertMenu(int client, int target, MuteType muteType) {
	Menu menu = new Menu(Menu_ShowAlertMenu);

	char title[128];
	FormatEx(title, sizeof(title), "[SM] Choose how you want to self-mute %N", target);
	menu.SetTitle(title);

	int userid = GetClientUserId(target);

	char data[12];

	FormatEx(data, sizeof(data), "%d|0|%d", view_as<int>(muteType), userid);
	menu.AddItem(data, "Temporarily");

	FormatEx(data, sizeof(data), "%d|1|%d", view_as<int>(muteType), userid);
	menu.AddItem(data, "Permanently");

	menu.ExitButton = true;
	menu.Display(client, MENU_TIME_FOREVER);
}

int Menu_ShowAlertMenu(Menu menu, MenuAction action, int param1, int param2) {
	switch(action) {
		case MenuAction_End: {
			delete menu;
		}

		case MenuAction_Select: {
			char option[24];
			menu.GetItem(param2, option, sizeof(option));

			char data[3][12];
			ExplodeString(option, "|", data, sizeof(data), sizeof(data[]));

			int target = GetClientOfUserId(StringToInt(data[2]));
			if (!target) {
				CPrintToChat(param1, "Player is no longer available.");
				return -1;
			}

			MuteType muteType = view_as<MuteType>(StringToInt(data[0]));
			MuteDuration muteDuration = view_as<MuteDuration>(StringToInt(data[1]));
			HandleClientSelfMute(param1, target, muteType, muteDuration);
		}
	}

	return 1;
}

void ShowMuteTypeMenuGroup(int client, GroupFilter groupFilter) {
	MuteType muteType = GetMuteType(g_bClientGroupText[client][view_as<int>(groupFilter)], g_bClientGroupVoice[client][view_as<int>(groupFilter)]);

	Menu menu = new Menu(Menu_ShowMuteTypeGroup);

	char title[128];
	FormatEx(title, sizeof(title), "[SM] Choose how you want to self-mute %s Group", g_sGroupsNames[view_as<int>(groupFilter)]);
	menu.SetTitle(title);

	int id = view_as<int>(groupFilter);

	char data[12];

	int flags = ITEMDRAW_DEFAULT;
	if (muteType == MuteType_Voice) {
		flags = ITEMDRAW_DISABLED;
	}

	FormatEx(data, sizeof(data), "0|%d", id);
	menu.AddItem(data, "Voice Chat Only", flags);

	flags = ITEMDRAW_DEFAULT;
	if (muteType == MuteType_Text) {
		flags = ITEMDRAW_DISABLED;
	}

	FormatEx(data, sizeof(data), "1|%d", id);
	menu.AddItem(data, "Text Chat Only", flags);

	FormatEx(data, sizeof(data), "2|%d", id);
	menu.AddItem(data, "Both Text and Voice Chats");

	menu.ExitButton = true;
	menu.Display(client, MENU_TIME_FOREVER);
}

int Menu_ShowMuteTypeGroup(Menu menu, MenuAction action, int param1, int param2) {
	switch(action) {
		case MenuAction_End: {
			delete menu;
		}

		case MenuAction_Select: {
			char option[24];
			menu.GetItem(param2, option, sizeof(option));

			char data[2][12];
			ExplodeString(option, "|", data, sizeof(data), sizeof(data[]));

			MuteType muteType = view_as<MuteType>(StringToInt(data[0]));
			HandleGroupSelfMute(param1, g_sGroupsFilters[StringToInt(data[1])], muteType, g_PlayerData[param1].muteDuration);
		}
	}

	return 1;
}

void StartSelfMuteGroup(int client, GroupFilter groupFilter, MuteType muteType, MuteDuration muteDuration) {
	switch(muteDuration) {
		case MuteDuration_Temporary: {
			ApplySelfMuteGroup(client, g_sGroupsFilters[view_as<int>(groupFilter)], muteType);
			MuteType muteTypeEx = GetMuteType(g_bClientGroupText[client][view_as<int>(groupFilter)], g_bClientGroupVoice[client][view_as<int>(groupFilter)]);

			CPrintToChat(client, "You have {green}self-muted {olive}%s Group\n{default}Voice Chat: {olive}%s\n{default}Text Chat: {olive}%s", g_sGroupsNames[view_as<int>(groupFilter)],
						(muteTypeEx==MuteType_Voice||muteTypeEx==MuteType_All)?"Yes":"No",
						(muteTypeEx==MuteType_Text||muteTypeEx==MuteType_All)?"Yes":"No");
		}

		case MuteDuration_Permanent: {
			ApplySelfMuteGroup(client, g_sGroupsFilters[view_as<int>(groupFilter)], muteType);
			MuteType muteTypeEx = GetMuteType(g_bClientGroupText[client][view_as<int>(groupFilter)], g_bClientGroupVoice[client][view_as<int>(groupFilter)]);

			CPrintToChat(client, "You have {green}self-muted {olive}%s Group\n{default}Voice Chat: {olive}%s\n{default}Text Chat: {olive}%s", g_sGroupsNames[view_as<int>(groupFilter)],
						(muteTypeEx==MuteType_Voice||muteTypeEx==MuteType_All)?"Yes":"No",
						(muteTypeEx==MuteType_Text||muteTypeEx==MuteType_All)?"Yes":"No");

			SaveSelfMuteGroup(client, groupFilter);
			CPrintToChat(client, "The {olive}self-mute {default}has been saved!");
		}

		case MuteDuration_AskFirst: {
			ShowAlertMenuGroup(client, groupFilter, muteType);
		}
	}
}

void ShowAlertMenuGroup(int client, GroupFilter groupFilter, MuteType muteType) {
	Menu menu = new Menu(Menu_ShowAlertMenuGroup);

	char title[128];
	FormatEx(title, sizeof(title), "[SM] Choose how you want to self-mute %s Group", g_sGroupsNames[view_as<int>(groupFilter)]);
	menu.SetTitle(title);

	int id = view_as<int>(groupFilter);

	char data[12];

	FormatEx(data, sizeof(data), "%d|0|%d", view_as<int>(muteType), id);
	menu.AddItem(data, "Temporarily");

	FormatEx(data, sizeof(data), "%d|1|%d", view_as<int>(muteType), id);
	menu.AddItem(data, "Permanently");

	menu.ExitButton = true;
	menu.Display(client, MENU_TIME_FOREVER);
}

int Menu_ShowAlertMenuGroup(Menu menu, MenuAction action, int param1, int param2) {
	switch(action) {
		case MenuAction_End: {
			delete menu;
		}

		case MenuAction_Select: {
			char option[24];
			menu.GetItem(param2, option, sizeof(option));

			char data[3][12];
			ExplodeString(option, "|", data, sizeof(data), sizeof(data[]));

			GroupFilter groupFilter = view_as<GroupFilter>(StringToInt(data[2]));
			MuteType muteType = view_as<MuteType>(StringToInt(data[0]));
			MuteDuration muteDuration = view_as<MuteDuration>(StringToInt(data[1]));
			HandleGroupSelfMute(param1, g_sGroupsFilters[view_as<int>(groupFilter)], muteType, muteDuration);
		}
	}

	return 1;
}
public void OnAllPluginsLoaded() {
	g_Plugin_ccc = LibraryExists("ccc");
	g_Plugin_zombiereloaded = LibraryExists("zombiereloaded");
}

void Event_PlayerTeam(Event event, const char[] name, bool dontBroadcast) {
	for (int i = 1; i <= MaxClients; i++) {
		if (!IsClientInGame(i) || IsFakeClient(i)) {
			continue;
		}

		SelfUnMutePreviousGroup(i);

		for (int j = 0; j < view_as<int>(GROUP_MAX_NUM); j++) {
			if (g_bClientGroupText[i][j] || g_bClientGroupVoice[i][j]) {
				UpdateSelfMuteGroup(i, view_as<GroupFilter>(j));
			}
		}
	}
}

void Event_RoundStart(Event event, const char[] name, bool dontBroadcast) {
	g_fLastMessageTime = 0.0;
}

/* Database Setup */
void ConnectToDB() {
	Database.Connect(DB_OnConnect, DB_NAME);
}

public void DB_OnConnect(Database db, const char[] error, any data) {
	if (db == null || error[0]) {
		/* Failure happen. Do retry with delay */
		CreateTimer(15.0, DB_RetryConnection);
		LogError("[Self-Mute] Couldn't connect to database `%s`, retrying in 15 seconds. \nError: %s", DB_NAME, error);
		return;
	}

	PrintToServer("[Self-Mute] Successfully connected to database!");
	g_hDB = db;
	DB_Tables();
	g_hDB.SetCharset("utf8");

	if (g_bLate) {
		LateLoadClients();
	}
}

public Action DB_RetryConnection(Handle timer)
{
	if (g_hDB == null)
		ConnectToDB();

	return Plugin_Continue;
}

void DB_Tables() {
	if (g_hDB == null) {
		return;
	}

	char driver[32];
	g_hDB.Driver.GetIdentifier(driver, sizeof(driver));
	if (strcmp(driver, "mysql", false) == 0) {
		Transaction T_mysqlTables = SQL_CreateTransaction();

		char query0[1024];
		g_hDB.Format(query0, sizeof(query0), "CREATE TABLE IF NOT EXISTS `clients_data`("
												... "`client_steamid` INT UNSIGNED NOT NULL,"
												... "`mute_type` TINYINT NOT NULL,"
												... "`mute_duration` TINYINT NOT NULL,"
												... "PRIMARY KEY(`client_steamid`))");

		T_mysqlTables.AddQuery(query0);

		g_hDB.Format(query0, sizeof(query0), "CREATE TABLE IF NOT EXISTS `clients_mute`("
												... "`client_steamid` INT UNSIGNED NOT NULL,"
												... "`target_steamid` INT UNSIGNED NOT NULL,"
												... "`text_chat` TINYINT NOT NULL,"
												... "`voice_chat` TINYINT NOT NULL,"
												... "PRIMARY KEY (`client_steamid`, `target_steamid`))");

		T_mysqlTables.AddQuery(query0);

		g_hDB.Format(query0, sizeof(query0), "CREATE TABLE IF NOT EXISTS `groups_mute`("
												... "`client_steamid` INT UNSIGNED NOT NULL,"
												... "`group_filter` VARCHAR(20) NOT NULL,"
												... "`text_chat` TINYINT NOT NULL,"
												... "`voice_chat` TINYINT NOT NULL,"
												... "PRIMARY KEY (`client_steamid`, `group_filter`))");

		T_mysqlTables.AddQuery(query0);

		g_hDB.Format(query0, sizeof(query0), "CREATE INDEX `idx_client_steamid` ON `clients_data` (`client_steamid`)");
		T_mysqlTables.AddQuery(query0);

		g_hDB.Format(query0, sizeof(query0), "CREATE INDEX `idx_clients_client_steamid` ON `clients_mute` (`client_steamid`)");
		T_mysqlTables.AddQuery(query0);

		g_hDB.Format(query0, sizeof(query0), "CREATE INDEX `idx_clients_target_steamid` ON `clients_mute` (`target_steamid`)");
		T_mysqlTables.AddQuery(query0);

		g_hDB.Format(query0, sizeof(query0), "CREATE INDEX `idx_groups_client_steamid` ON `groups_mute` (`client_steamid`)");
		T_mysqlTables.AddQuery(query0);

		g_hDB.Format(query0, sizeof(query0), "CREATE INDEX `idx_both1` ON `clients_mute` (`client_steamid`, `target_steamid`)");
		T_mysqlTables.AddQuery(query0);

		g_hDB.Format(query0, sizeof(query0), "CREATE INDEX `idx_both2` ON `groups_mute` (`client_steamid`, `group_filter`)");

		T_mysqlTables.AddQuery(query0);

		g_hDB.Execute(T_mysqlTables, DB_mysqlTablesOnSuccess, DB_mysqlTablesOnError, _, DBPrio_High);
	} else if (strcmp(driver, "sqlite", false) == 0) {
		g_bSQLLite = true;
		Transaction T_sqliteTables = SQL_CreateTransaction();

		char query0[1024];
		g_hDB.Format(query0, sizeof(query0), "CREATE TABLE IF NOT EXISTS `clients_data`("
												... "`client_steamid` INTEGER PRIMARY KEY NOT NULL,"
												... "`mute_type` INTEGER NOT NULL,"
												... "`mute_duration` INTEGER NOT NULL)");

		T_sqliteTables.AddQuery(query0);

		char query1[1024];
		g_hDB.Format(query1, sizeof(query1), "CREATE TABLE IF NOT EXISTS `clients_mute`("
												... "`client_steamid` INTEGER NOT NULL,"
												... "`target_steamid` INTEGER NOT NULL,"
												... "`text_chat` INTEGER NOT NULL,"
												... "`voice_chat` INTEGER NOT NULL,"
												... "PRIMARY KEY (client_steamid, target_steamid))");

		T_sqliteTables.AddQuery(query1);

		char query2[1024];
		g_hDB.Format(query2, sizeof(query2), "CREATE TABLE IF NOT EXISTS `groups_mute`("
												... "`client_steamid` INTEGER NOT NULL,"
												... "`group_filter` TEXT NOT NULL,"
												... "`text_chat` INTEGER NOT NULL,"
												... "`voice_chat` INTEGER NOT NULL,"
												... "PRIMARY KEY (client_steamid, group_filter))");

		T_sqliteTables.AddQuery(query2);
		g_hDB.Execute(T_sqliteTables, DB_sqliteTablesOnSuccess, DB_sqliteTablesOnError, _, DBPrio_High);
	} else {
			LogError("[Self-Mute] Couldn't create tables: unsupported database driver '%s'. Only 'mysql' and 'sqlite' are supported.", driver);
		return;
	}
}

// Transaction callbacks for tables:
public void DB_mysqlTablesOnSuccess(Database database, any data, int queries, Handle[] results, any[] queryData) {
	LogMessage("[Self-Mute] Database is now ready! (MYSQL)");
	return;
}

public void DB_mysqlTablesOnError(Database database, any data, int queries, const char[] error, int failIndex, any[] queryData)
{
	LogError("[Self-Mute] Couldn't create tables for MYSQL, error: %s", error);
	return;
}

public void DB_sqliteTablesOnSuccess(Database database, any data, int queries, Handle[] results, any[] queryData)
{
	LogMessage("[Self-Mute] Database is now ready! (SQLITE)");
	return;
}

public void DB_sqliteTablesOnError(Database database, any data, int queries, const char[] error, int failIndex, any[] queryData)
{
	LogError("[Self-Mute] Couldn't create tables for SQLITE, error: %s", error);
	return;
}

/* Connections Check */
public void OnClientConnected(int client) {
	if (!IsClientSourceTV(client)) {
		return;
	}

	char clientName[32];
	if (!GetClientName(client, clientName, sizeof(clientName))) {
		strcopy(clientName, sizeof(clientName), "Source TV");
	}

	g_PlayerData[client].Setup(clientName, "Console", MuteType_None, MuteDuration_Permanent); // whatever values but name and steamid are the important
}

public void OnClientPostAdminCheck(int client) {
	if (IsFakeClient(client)) {
		return;
	}

	/* Get Client Data */
	int steamID = GetSteamAccountID(client);
	if (!steamID) {
		return;
	}

	char steamIDStr[20];
	IntToString(steamID, steamIDStr, sizeof(steamIDStr));

	char clientName[MAX_NAME_LENGTH];
	if (!GetClientName(client, clientName, sizeof(clientName))) {
		return;
	}

	MuteType muteType = view_as<MuteType>(g_cvDefaultMuteTypeSettings.IntValue);
	MuteDuration muteDuration = view_as<MuteDuration>(g_cvDefaultMuteDurationSettings.IntValue);

	g_PlayerData[client].Setup(clientName, steamIDStr, muteType, muteDuration);

	if (g_hDB == null) {
		return;
	}

	char query[1024];
	FormatEx(query, sizeof(query), "SELECT `mute_type`,`mute_duration` FROM `clients_data` WHERE `client_steamid`=%d", steamID);
	g_hDB.Query(DB_OnGetClientData, query, GetClientUserId(client), DBPrio_Normal);
}

void DB_OnGetClientData(Database db, DBResultSet results, const char[] error, int userid) {
	if (error[0]) {
		LogError("[Self-Mute] Could not revert client data, error: %s", error);
		return;
	}

	int client = GetClientOfUserId(userid);
	if (!client) {
		return;
	}

	int steamID = StringToInt(g_PlayerData[client].steamID);

	if (results == null) {
		return;
	}

	if (results.FetchRow()) {
		g_PlayerData[client].addedToDB = true;

		g_PlayerData[client].muteType = view_as<MuteType>(results.FetchInt(0));
		g_PlayerData[client].muteDuration = view_as<MuteDuration>(results.FetchInt(1));

	}

	/*
	* Now get mute list duh, get both the client as a client and as a target
	* We will select 5 fields of each table, though not all fields are required, NULL will be given
	* 0. `is_target`		-> if NULL given, then it means the specific part of query has the `client_steamid` as WHERE clause, `target_stemaid` otherwise
	* 1. `tar_id`			-> Target (player) steamID (int)
	* 2. `grp_id`			-> Group Filter char (string)
	* 3. `text_chat`		-> Target (player & group) Text Chat Status (tinyint or int(2))
	* 4. `voice_chat`		-> Target (player & group) Voice Chat Status (tinyint or int(2))
	*/
	char query[1024];
	FormatEx(query, sizeof(query),
					"SELECT NULL AS `is_target`, `target_steamid` AS `tar_id`, NULL AS `grp_id`,"
				...	"`text_chat` AS `text_chat`, `voice_chat` AS `voice_chat` "
				... "FROM `clients_mute` WHERE `client_steamid`=%d "
				... "UNION ALL "
				... "SELECT NULL AS `is_target`, NULL AS `tar_id`, `group_filter` AS `grp_id`,"
				... "`text_chat` AS `text_chat`, `voice_chat` AS `voice_chat` "
				... "FROM `groups_mute` WHERE `client_steamid`=%d "
				... "UNION ALL "
				... "SELECT 1 AS `is_target`, `client_steamid` AS `tar_id`, NULL AS `grp_id`,"
				... "`text_chat` AS `text_chat`, `voice_chat` AS `voice_chat` "
				... "FROM `clients_mute` WHERE `target_steamid`=%d",
				steamID, steamID, steamID
	);

	g_hDB.Query(DB_OnGetClientTargets, query, userid, DBPrio_Normal);
}

void DB_OnGetClientTargets(Database db, DBResultSet results, const char[] error, int userid) {
	if (!results || error[0]) {
		LogError("[Self-Mute] Error while getting client's client/target mutes, error: %s", error);
		return;
	}

	if (!results.RowCount) {
		return;
	}


	int desiredClient = GetClientOfUserId(userid);
	if (!desiredClient || !IsClientInGame(desiredClient)) {
		return;
	}

	while(results.FetchRow()) {
		bool isGroup = results.IsFieldNull(1);

		bool text = view_as<bool>(results.FetchInt(3));
		bool voice = view_as<bool>(results.FetchInt(4));
		MuteType muteType = GetMuteType(text, voice);

		if (!isGroup) {
			int targetSteamID = results.FetchInt(1);
			char steamIDStr[20];

			// Special handling for SourceTV (SteamID = 0)
			if (targetSteamID == 0) {
				for (int i = 1; i <= MaxClients; i++) {
					if (!IsClientConnected(i)) {
						continue;
					}
					if (IsClientSourceTV(i)) {
						g_bClientTargetPerma[desiredClient][i] = true;
						ApplySelfMute(desiredClient, i, muteType);
						break;
					}
				}
			} else {
				IntToString(targetSteamID, steamIDStr, sizeof(steamIDStr));

				int target = GetClientBySteamID(steamIDStr);
				if (target == -1) {
					continue;
				}

				if (results.IsFieldNull(0)) { // desiredClient here is the client
					g_bClientTargetPerma[desiredClient][target] = true;
					ApplySelfMute(desiredClient, target, muteType);
				} else { // desiredClient here is the target
					g_bClientTargetPerma[target][desiredClient] = true;
					ApplySelfMute(target, desiredClient, muteType);
				}
			}
		} else {
			char groupFilter[20];
			results.FetchString(2, groupFilter, sizeof(groupFilter));

			GroupFilter groupFilterInt = GetGroupFilterByChar(groupFilter);
			g_bClientGroupPerma[desiredClient][view_as<int>(groupFilterInt)] = true;

			ApplySelfMuteGroup(desiredClient, groupFilter, muteType);
		}
	}
}

public void OnClientDisconnect(int client) {
	if (IsFakeClient(client)) {
		return;
	}

	g_PlayerData[client].Reset();

	for (int i = 1; i <= MaxClients; i++) {
		g_bClientText[i][client] = false;
		g_bClientVoice[i][client] = false;
		g_bClientText[client][i] = false;
		g_bClientVoice[client][i] = false;

		g_bClientTargetPerma[client][i] = false;
		g_bClientTargetPerma[i][client] = false;

		SetIgnored(i, client, false);
		SetIgnored(client, i, false);

		if (IsClientConnected(i)) {
			SetListenOverride(i, client, Listen_Yes);
			SetListenOverride(client, i, Listen_Yes);
		}
	}

	for (int i = 0; i < view_as<int>(GROUP_MAX_NUM); i++) {
		g_bClientGroupText[client][i] = false;
		g_bClientGroupVoice[client][i] = false;
		g_bClientGroupPerma[client][i] = false;
	}

	UpdateIgnored();
}

public void CookieMenu_Handler(int client, CookieMenuAction action, any info, char[] buffer, int maxlen)
{
	if (action == CookieMenuAction_DisplayOption) {
		Format(buffer, maxlen, "Self-Mute Settings");
	}

	if (action == CookieMenuAction_SelectOption) {
		ShowCookiesMenu(client);
	}
}

void UpdateIgnored() {
	if (g_Plugin_ccc)
		CCC_UpdateIgnoredArray(g_Ignored);
}

bool GetIgnored(int client, int target) {
	return g_Ignored[(client * (MAXPLAYERS + 1) + target)];
}

void SetIgnored(int client, int target, bool ignored) {
	g_Ignored[(client * (MAXPLAYERS + 1) + target)] = ignored;
}

void ApplySelfMute(int client, int target, MuteType muteType) {
	switch(muteType) {
		case MuteType_Text: {
			SetIgnored(client, target, true);
			UpdateIgnored();
			g_bClientText[client][target] = true;
		}

		case MuteType_Voice: {
			SetListenOverride(client, target, Listen_No);
			g_bClientVoice[client][target] = true;
		}

		case MuteType_All: {
			SetIgnored(client, target, true);
			UpdateIgnored();
			SetListenOverride(client, target, Listen_No);

			g_bClientText[client][target] = true;
			g_bClientVoice[client][target] = true;
		}
	}
}

void ApplySelfMuteGroup(int client, const char[] groupFilterC, MuteType muteType) {
	GroupFilter groupFilter = GetGroupFilterByChar(groupFilterC);
	int groupFilterIndex = view_as<int>(groupFilter);

	switch(muteType) {
		case MuteType_Text: {
			g_bClientGroupText[client][groupFilterIndex] = true;
		}

		case MuteType_Voice: {
			g_bClientGroupVoice[client][groupFilterIndex] = true;
		}

		case MuteType_All: {
			g_bClientGroupText[client][groupFilterIndex] = true;
			g_bClientGroupVoice[client][groupFilterIndex] = true;
		}
	}

	UpdateSelfMuteGroup(client, groupFilter);
}

void ApplySelfUnMute(int client, int target) {
	if (g_bClientText[client][target]) {
		SetIgnored(client, target, false);
		UpdateIgnored();
		g_bClientText[client][target] = false;
	}

	if (g_bClientVoice[client][target]) {
		SetListenOverride(client, target, Listen_Yes);
		g_bClientVoice[client][target] = false;
	}

	DeleteMuteFromDatabase(client, target);
}

void ApplySelfUnMuteGroup(int client, GroupFilter groupFilter) {
	int target = view_as<int>(groupFilter);
	if (g_bClientGroupText[client][target]) {
		for (int i = 1; i <= MaxClients; i++) {
			if (!IsClientInGame(i) || g_bClientText[client][i] || !IsClientInGroup(i, groupFilter)) {
				continue;
			}

			SetIgnored(client, i, false);
		}

		UpdateIgnored();
	}

	if (g_bClientGroupVoice[client][target]) {
		for (int i = 1; i <= MaxClients; i++) {
			if (!IsClientInGame(i) || g_bClientVoice[client][i] || !IsClientInGroup(i, groupFilter)) {
				continue;
			}

			SetListenOverride(client, i, Listen_Yes);
		}
	}

	g_bClientGroupText[client][target] = false;
	g_bClientGroupVoice[client][target] = false;

	SelfUnMutePreviousGroup(client);

	for (int i = 0; i < view_as<int>(GROUP_MAX_NUM); i++) {
		if (g_bClientGroupText[client][i] || g_bClientGroupVoice[client][i]) {
			UpdateSelfMuteGroup(client, view_as<GroupFilter>(i));
		}
	}

	DeleteMuteFromDatabase(client, _, g_sGroupsFilters[target]);
}

void DeleteMuteFromDatabase(int client, int target = -1, const char[] groupFilterC = "") {
	if (!IsThisMutedPerma(client, target, groupFilterC, true)) {
		return;
	}

	int clientSteamID = StringToInt(g_PlayerData[client].steamID);
	if (!clientSteamID) {
		return;
	}

	char query[256];
	if (target != -1) {
		int targetSteamID;
		if (IsClientSourceTV(target)) {
			targetSteamID = 0; // SourceTV
		} else {
			targetSteamID = StringToInt(g_PlayerData[target].steamID);
		}

		FormatEx(query, sizeof(query), "DELETE FROM `clients_mute` WHERE `client_steamid`=%d AND `target_steamid`=%d",
			clientSteamID, targetSteamID);
	} else {
		char escapedGroupFilter[42];
		if (!g_hDB.Escape(groupFilterC, escapedGroupFilter, sizeof(escapedGroupFilter))) {
			return;
		}

		FormatEx(query, sizeof(query), "DELETE FROM `groups_mute` WHERE `client_steamid`=%d AND `group_filter`='%s'",
			clientSteamID, escapedGroupFilter);
	}

	g_hDB.Query(DB_OnRemove, query, _, DBPrio_Normal);
}

void DB_OnRemove(Database db, DBResultSet results, const char[] error, any data) {
	if (!results || error[0]) {
		LogError("[Self-Mute] Could not delete mute from database, error: %s", error);
	}
}

bool IsThisMutedPerma(int client, int target = -1, const char[] groupFilterC = "", bool remove = false) {
	/* For clients: */
	if (target != -1) {
		if (g_bClientTargetPerma[client][target]) {
			if (remove) {
				g_bClientTargetPerma[client][target] = false;
			}

			return true;
		}

		return false;
	}

	/* For Groups: */
	GroupFilter groupFilter = GetGroupFilterByChar(groupFilterC);
	int index = view_as<int>(groupFilter);

	if (g_bClientGroupPerma[client][index]) {
		if (remove) {
			g_bClientGroupPerma[client][index] = false;
		}

		return true;
	}

	return false;
}

void SaveSelfMuteClient(int client, int target) {
	int clientSteamID = StringToInt(g_PlayerData[client].steamID);

	int targetSteamID;
	if (IsClientSourceTV(target)) {
		targetSteamID = 0; // Use 0 for SourceTV
	} else {
		targetSteamID = StringToInt(g_PlayerData[target].steamID);
	}

	if (!clientSteamID) {
		return;
	}

	char query[512];
	if (!g_bSQLLite) {
		FormatEx(query, sizeof(query), "INSERT INTO `clients_mute` (`client_steamid`, `target_steamid`,"
										... "`text_chat`, `voice_chat`) VALUES (%d, %d, %d, %d)"
										... "ON DUPLICATE KEY UPDATE "
										... "`text_chat`=VALUES(`text_chat`), `voice_chat`=VALUES(`voice_chat`)",
										clientSteamID, targetSteamID,
										view_as<int>(g_bClientText[client][target]),
										view_as<int>(g_bClientVoice[client][target]));
	} else {
		FormatEx(query, sizeof(query), "INSERT INTO clients_mute (client_steamid, target_steamid,"
										... "text_chat, voice_chat) VALUES (%d, %d, %d, %d)"
										... " ON CONFLICT(client_steamid, target_steamid) DO UPDATE SET "
										... "text_chat=excluded.text_chat, voice_chat=excluded.voice_chat",
										clientSteamID, targetSteamID,
										view_as<int>(g_bClientText[client][target]),
										view_as<int>(g_bClientVoice[client][target]));
	}

	g_hDB.Query(DB_OnInsertData, query, _, DBPrio_High);

	g_bClientTargetPerma[client][target] = true;
}

void SaveSelfMuteGroup(int client, GroupFilter groupFilter) {
	char groupFilterC[20 * 2 + 1];

	if (!g_hDB.Escape(g_sGroupsFilters[view_as<int>(groupFilter)], groupFilterC, sizeof(groupFilterC))) {
		return;
	}

	int clientSteamID = StringToInt(g_PlayerData[client].steamID);
	if (!clientSteamID) {
		return;
	}

	char query[512];
	if (!g_bSQLLite) {
		FormatEx(query, sizeof(query), "INSERT INTO `groups_mute` (`client_steamid`, `group_filter`,"
										... "`text_chat`, `voice_chat`) VALUES (%d, '%s', %d, %d)"
										... "ON DUPLICATE KEY UPDATE "
										... "`text_chat`=VALUES(`text_chat`), `voice_chat`=VALUES(`voice_chat`)",
										clientSteamID,
										groupFilterC, view_as<int>(g_bClientGroupText[client][view_as<int>(groupFilter)]),
										view_as<int>(g_bClientGroupVoice[client][view_as<int>(groupFilter)]));
	} else {
		FormatEx(query, sizeof(query), "INSERT INTO groups_mute (client_steamid, group_filter,"
										... "text_chat, voice_chat) VALUES (%d, '%s', %d, %d)"
										... " ON CONFLICT(client_steamid, group_filter) DO UPDATE SET "
										... "text_chat=excluded.text_chat, voice_chat=excluded.voice_chat",
										clientSteamID,
										groupFilterC, view_as<int>(g_bClientGroupText[client][view_as<int>(groupFilter)]),
										view_as<int>(g_bClientGroupVoice[client][view_as<int>(groupFilter)]));
	}

	g_hDB.Query(DB_OnInsertData, query, _, DBPrio_High);

	g_bClientGroupPerma[client][view_as<int>(groupFilter)] = true;
}

void DB_OnInsertData(Database db, DBResultSet results, const char[] error, any data) {
	if (!results || error[0]) {
		LogError("[Self-Mute] Could not insert data into the database, error: %s", error);
	}
}

void DB_UpdateClientData(int client, int mode) {
	if (g_hDB == null) {
		return;
	}

	int steamID = StringToInt(g_PlayerData[client].steamID);
	if (!steamID) {
		return;
	}

	if (!g_PlayerData[client].addedToDB) {
		char query[512];
		if (!g_bSQLLite) {
			FormatEx(query, sizeof(query), "INSERT INTO `clients_data` ("
											... "`client_steamid`, `mute_type`, `mute_duration`)"
											... "VALUES (%d, %d, %d) "
											... "ON DUPLICATE KEY UPDATE `mute_type`=VALUES(`mute_type`), `mute_duration`=VALUES(`mute_duration`)",
											steamID,
											view_as<int>(g_PlayerData[client].muteType),
											view_as<int>(g_PlayerData[client].muteDuration));
		} else {
			FormatEx(query, sizeof(query), "INSERT INTO clients_data ("
											... "client_steamid, mute_type, mute_duration)"
											... " VALUES (%d, %d, %d)"
											... " ON CONFLICT(client_steamid) DO UPDATE SET "
											... " mute_type=excluded.mute_type, mute_duration=excluded.mute_duration",
											steamID,
											view_as<int>(g_PlayerData[client].muteType),
											view_as<int>(g_PlayerData[client].muteDuration));
		}

		g_hDB.Query(DB_OnAddData, query, _, DBPrio_Normal);

		g_PlayerData[client].addedToDB = true;

		DataPack pack = new DataPack();
		pack.WriteCell(GetClientUserId(client));
		pack.WriteCell(mode);
		CreateTimer(1.0, UpdateClientData_Timer, pack);
		return;
	}

	if (g_PlayerData[client].steamID[0]) {
		/* Update client data in sql */
		char query[256];
		FormatEx(query, sizeof(query), "UPDATE `clients_data` SET `%s`=%d WHERE `client_steamid`=%d",
										(mode == 0) ? "mute_type" : "mute_duration",
										(mode == 0) ? view_as<int>(g_PlayerData[client].muteType) : view_as<int>(g_PlayerData[client].muteDuration),
										steamID);

		g_hDB.Query(DB_OnUpdateData, query, _, DBPrio_Normal);
	}
}

Action UpdateClientData_Timer(Handle timer, DataPack pack) {
	pack.Reset();

	int client = GetClientOfUserId(pack.ReadCell());
	if (!client) {
		delete pack;
		return Plugin_Stop;
	}

	int mode = pack.ReadCell();
	DB_UpdateClientData(client, mode);

	delete pack;
	return Plugin_Stop;
}

void DB_OnAddData(Database db, DBResultSet results, const char[] error, any data) {
	if (error[0]) {
		LogError("[Self-Mute] Error while inserting client's data, error: %s", error);
		return;
	}
}

void DB_OnUpdateData(Database db, DBResultSet results, const char[] error, any data) {
	if (error[0]) {
		LogError("[SM] Error while updating client data, error: %s", error);
	}
}

bool IsClientAdmin(int client) {
	return CheckCommandAccess(client, "sm_admin", ADMFLAG_GENERIC, true);
}

MuteType GetMuteType(bool text, bool voice) {
	if (text && voice) {
		return MuteType_All;
	} else if (text && !voice) {
		return MuteType_Text;
	} else if (!text && voice) {
		return MuteType_Voice;
	}

	return MuteType_None;
}

GroupFilter GetGroupFilterByChar(const char[] groupFilterC) {
	for (int i = 0; i < sizeof(g_sGroupsFilters); i++) {
		if (strcmp(g_sGroupsFilters[i], groupFilterC) == 0) {
			return view_as<GroupFilter>(i);
		}
	}

	return GROUP_ALL;
}

void SelfUnMutePreviousGroup(int client) {
	bool shouldUpdateIgnored;
	for (int i = 1; i <= MaxClients; i++) {
		if (i == client) {
			continue;
		}

		if (!IsClientConnected(i)) {
			continue;
		}

		if (GetIgnored(client, i) && !g_bClientText[client][i]) {
			shouldUpdateIgnored = true;
			SetIgnored(client, i, false);
		}

		if (GetListenOverride(client, i) == Listen_No && !g_bClientVoice[client][i]) {
			SetListenOverride(client, i, Listen_Yes);
		}
	}

	if (shouldUpdateIgnored) {
		UpdateIgnored();
	}
}

void UpdateSelfMuteGroup(int client, GroupFilter groupFilter) {
	bool shouldUpdateIgnored;
	for (int i = 1; i <= MaxClients; i++) {
		if (i == client) {
			continue;
		}

		if (!IsClientConnected(i)) {
			continue;
		}

		if (!IsClientInGroup(i, groupFilter)) {
			continue;
		}

		if (g_bClientGroupText[client][view_as<int>(groupFilter)]) {
			shouldUpdateIgnored = true;
			SetIgnored(client, i, true);
		}

		if (g_bClientGroupVoice[client][view_as<int>(groupFilter)]) {
			SetListenOverride(client, i, Listen_No);
		}
	}

	if (shouldUpdateIgnored) {
		UpdateIgnored();
	}
}

bool IsClientInGroup(int client, GroupFilter groupFilter) {
	if (!client) {
		return false;
	}

	if (!IsClientInGame(client)) {
		return false;
	}

	int team = GetClientTeam(client);
	switch(groupFilter) {
		case GROUP_ALL: {
			return true;
		}

		case GROUP_CTS: {
			if (g_Plugin_zombiereloaded) {
				if (!IsPlayerAlive(client) || !ZR_IsClientHuman(client)) {
					return false;
				}
			} else {
				if (team != CS_TEAM_CT) {
					return false;
				}
			}

			return true;
		}

		case GROUP_TS: {
			if (g_Plugin_zombiereloaded) {
				if (!IsPlayerAlive(client) || !ZR_IsClientZombie(client)) {
					return false;
				}
			} else {
				if (team != CS_TEAM_T) {
					return false;
				}
			}

			return true;
		}

		case GROUP_SPECTATORS: {
			if (team != CS_TEAM_SPECTATOR && team != CS_TEAM_NONE) {
				return false;
			}

			return true;
		}

		case GROUP_NOSTEAM: {
			#if defined _PlayerManager_included
			if (!IsFakeClient(client) && !PM_IsPlayerSteam(client)) {
				return true;
			}
			#endif

			return false;
		}

		case GROUP_STEAM: {
			#if defined _PlayerManager_included
			if (!IsFakeClient(client) && PM_IsPlayerSteam(client)) {
				return true;
			}
			#endif

			return false;
		}

		default: {
			return false;
		}
	}
}

int GetClientBySteamID(const char[] steamID) {
	for (int i = 1; i <= MaxClients; i++) {
		if (!IsClientInGame(i)) {
			continue;
		}

		if (IsClientSourceTV(i) && strcmp("Console", steamID) == 0) {
			return i;
		}

		if (IsFakeClient(i)) {
			continue;
		}

		if (strcmp(g_PlayerData[i].steamID, steamID, false) == 0) {
			return i;
		}
	}

	return -1;
}

/* Thanks to Botox Original Self-Mute plugin for the radio commands part */
int g_MsgClient = -1;

Action OnRadioCommand(int client, const char[] command, int argc) {
	float currentTime = GetGameTime();

	if (g_fLastMessageTime > 0.0 && g_fLastMessageTime+0.2 > currentTime) {
		return Plugin_Handled;
	}

	g_MsgClient = client;
	g_fLastMessageTime = GetGameTime();

	return Plugin_Continue;
}

public Action Hook_UserMessageRadioText(UserMsg msg_id, Handle userMessage, const int[] players, int playersNum, bool reliable, bool init) {
	int msg_dst;
	int msg_client;
	char msg_name[256];
	char msg_params[4][256];

	if (g_bIsProtoBuf) {
		Protobuf pb = UserMessageToProtobuf(userMessage);
		msg_dst = pb.ReadInt("msg_dst");
		msg_client = pb.ReadInt("client");
		pb.ReadString("msg_name", msg_name, sizeof(msg_name));
		for (int i = 0; i < 4; i++) {
			pb.ReadString("params", msg_params[i], sizeof(msg_params[]), i);
		}
	} else {
		BfRead bf = UserMessageToBfRead(userMessage);
		msg_dst = bf.ReadByte();
		msg_client = bf.ReadByte();
		bf.ReadString(msg_name, sizeof(msg_name), false);
		for (int i = 0; i < 4; i++) {
			bf.ReadString(msg_params[i], sizeof(msg_params[]), false);
		}
	}

	// Check which clients need to be excluded.
	int newPlayersNum = 0;
	int newPlayers[MAXPLAYERS + 1];

	for (int i = 0; i < playersNum; i++) {
		int client = players[i];
		if (GetIgnored(client, msg_client) || GetListenOverride(client, msg_client) == Listen_No) {
			continue;
		}

		newPlayers[newPlayersNum] = client;
		newPlayersNum++;
	}

	// No clients were excluded.
	if (newPlayersNum == playersNum) {
		return Plugin_Continue;
	} else if (newPlayersNum == 0) { // All clients were excluded and there is no need to broadcast.
		return Plugin_Stop;
	}

	DataPack pack = new DataPack();
	pack.WriteCell(msg_client);
	pack.WriteCell(msg_dst);
	pack.WriteString(msg_name);
	for (int i = 0; i < 4; i++) {
		pack.WriteString(msg_params[i]);
	}

	pack.WriteCell(newPlayersNum);

	for (int i = 0; i < newPlayersNum; i++) {
		pack.WriteCell(newPlayers[i]);
	}

	RequestFrame(OnPlayerRadioText, pack);
	return Plugin_Stop;
}

void OnPlayerRadioText(DataPack pack) {
	pack.Reset();

	int msg_client = pack.ReadCell();
	if (!IsClientInGame(msg_client)) {
		delete pack;
		return;
	}

	int msg_dst;
	char msg_name[256];
	char msg_params[4][256];

	msg_dst = pack.ReadCell();
	pack.ReadString(msg_name, sizeof(msg_name));
	for (int i = 0; i < 4; i++) {
		pack.ReadString(msg_params[i], sizeof(msg_params[]));
	}

	int newPlayersNum = pack.ReadCell();
	int[] newPlayers = new int[newPlayersNum];

	int newPlayersNum2 = 0;
	for (int i = 0; i < newPlayersNum; i++) {
		int client = pack.ReadCell();
		if (IsClientInGame(client)) {
			newPlayers[newPlayersNum2] = client;
			newPlayersNum2++;
		}
	}

	delete pack;

	Handle RadioText = StartMessage("RadioText", newPlayers, newPlayersNum2, USERMSG_RELIABLE);
	if (g_bIsProtoBuf) {
		Protobuf pb = UserMessageToProtobuf(RadioText);
		pb.SetInt("msg_dst", msg_dst);
		pb.SetInt("client", msg_client);
		pb.SetString("msg_name", msg_name);
		for (int i = 0; i < 4; i++) {
			pb.SetString("params", msg_params[i], i);
		}
	} else {
		BfWrite bf = UserMessageToBfWrite(RadioText);
		bf.WriteByte(msg_dst);
		bf.WriteByte(msg_client);
		bf.WriteString(msg_name);
		for (int i = 0; i < 4; i++) {
			bf.WriteString(msg_params[i]);
		}
	}

	EndMessage();
}

public Action Hook_UserMessageSendAudio(UserMsg msg_id, Handle userMessage, const int[] players, int playersNum, bool reliable, bool init) {
	char radioSound[256];
	if (g_bIsProtoBuf) {
		UserMessageToProtobuf(userMessage).ReadString("radio_sound", radioSound, sizeof(radioSound));
	} else {
		UserMessageToBfRead(userMessage).ReadString(radioSound, sizeof(radioSound), false);
	}

	if (strcmp(radioSound, "radio.locknload") == 0) {
		return Plugin_Continue;
	}

	if (g_MsgClient < 0 && StrContains(radioSound, "FireInTheHole", false) != -1) {
		return Plugin_Continue;
	}

	if (g_MsgClient <= 0) {
		return Plugin_Continue;
	}

	if (!IsClientInGame(g_MsgClient)) {
		return Plugin_Continue;
	}

	// Check which clients need to be excluded.
	int newPlayersNum = 0;
	int newPlayers[MAXPLAYERS + 1];

	for (int i = 0; i < playersNum; i++) {
		int client = players[i];
		if (!IsClientInGame(client)) {
			continue;
		}

		if (GetIgnored(client, g_MsgClient) || GetListenOverride(client, g_MsgClient) == Listen_No) {
			continue;
		}

		newPlayers[newPlayersNum] = client;
		newPlayersNum++;
	}

	if (newPlayersNum == playersNum) {
		return Plugin_Continue;
	} else if (newPlayersNum == 0) { // All clients were excluded and there is no need to broadcast.
		return Plugin_Stop;
	}

	DataPack pack = new DataPack();

	pack.WriteString(radioSound);
	pack.WriteCell(newPlayersNum);
	for (int i = 0; i < newPlayersNum; i++) {
		pack.WriteCell(newPlayers[i]);
	}

	RequestFrame(OnPlayerRadio, pack);

	return Plugin_Stop;
}

void OnPlayerRadio(DataPack pack) {
	pack.Reset();

	if (!IsClientInGame(g_MsgClient)) {
		delete pack;
		return;
	}

	char radioSound[256];
	pack.ReadString(radioSound, sizeof(radioSound));

	int newPlayersNum = pack.ReadCell();
	int[] newPlayers = new int[newPlayersNum];

	int newPlayersNum2 = 0;
	for (int i = 0; i < newPlayersNum; i++) {
		int client = pack.ReadCell();
		if (IsClientInGame(client)) {
			newPlayers[newPlayersNum2] = client;
			newPlayersNum2++;
		}
	}

	delete pack;

	Handle SendAudio = StartMessage("SendAudio", newPlayers, newPlayersNum2, USERMSG_RELIABLE);
	if (g_bIsProtoBuf) {
		UserMessageToProtobuf(SendAudio).SetString("radio_sound", radioSound);
	} else {
		UserMessageToBfWrite(SendAudio).WriteString(radioSound);
	}

	EndMessage();
}
