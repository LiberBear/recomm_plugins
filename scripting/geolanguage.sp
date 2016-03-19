#pragma semicolon 1

#include <sourcemod>
#include <geoip>
#undef REQUIRE_EXTENSIONS
#include <clientprefs>
#undef REQUIRE_PLUGIN
#include <updater>

#define PLUGIN_NAME 	"GeoIP Language Selection"
#define PLUGIN_VERSION 	"1.3.0"

#define UPDATE_URL	"http://godtony.mooo.com/geolanguage/geolanguage.txt"

new Handle:g_hLangList = INVALID_HANDLE;
new Handle:g_hLangMenu = INVALID_HANDLE;
new Handle:g_hCookie = INVALID_HANDLE;
new Handle:g_OnLangChanged = INVALID_HANDLE;

new bool:g_bLoaded[MAXPLAYERS+1];
new bool:g_bUseCPrefs;

public Plugin:myinfo =
{
	name = PLUGIN_NAME,
	author = "GoD-Tony",
	description = "Automatically assign languages to players geographically",
	version = PLUGIN_VERSION,
	url = "http://www.sourcemod.net/"
};

public APLRes:AskPluginLoad2(Handle:myself, bool:late, String:error[], err_max)
{
	g_OnLangChanged = CreateGlobalForward("GeoLang_OnLanguageChanged", ET_Ignore, Param_Cell, Param_Cell);
	RegPluginLibrary("geolanguage");
	
	return APLRes_Success;
}

public OnPluginStart()
{
	// Convars.
	new Handle:hCvar = CreateConVar("sm_geolanguage_version", PLUGIN_VERSION, PLUGIN_NAME, FCVAR_PLUGIN|FCVAR_NOTIFY|FCVAR_DONTRECORD);
	SetConVarString(hCvar, PLUGIN_VERSION);
	
	// Commands.
	RegConsoleCmd("sm_language", Command_Language);
	
	// Initialize language list and menu.
	Init_GeoLang();
	
	// Ignoring the unlikely event where clientprefs is late-(re)loaded.
	if (LibraryExists("clientprefs"))
	{
		g_hCookie = RegClientCookie("GeoLanguage", "The client's preferred language.", CookieAccess_Protected);
		SetCookieMenuItem(CookieMenu_GeoLanguage, 0, "Language");
		g_bUseCPrefs = true;
	}
	
	// Updater.
	if (LibraryExists("updater"))
	{
		Updater_AddPlugin(UPDATE_URL);
	}
}

public OnLibraryAdded(const String:name[])
{
	if (StrEqual(name, "updater"))
	{
		Updater_AddPlugin(UPDATE_URL);
	}
}

Init_GeoLang()
{
	// Parse KV file into trie of languages.
	decl String:sPath[PLATFORM_MAX_PATH];
	BuildPath(Path_SM, sPath, sizeof(sPath), "configs/geolanguage.txt");
	
	new Handle:hKV = CreateKeyValues("GeoLanguage");
	
	if (!FileToKeyValues(hKV, sPath))
	{
		SetFailState("File missing: %s", sPath);
	}
	
	decl String:sCCode[4], String:sLanguage[32];
	g_hLangList = CreateTrie();
	
	if (KvGotoFirstSubKey(hKV, false))
	{
		do
		{
			KvGetSectionName(hKV, sCCode, sizeof(sCCode));
			KvGetString(hKV, NULL_STRING, sLanguage, sizeof(sLanguage));
			
			SetTrieString(g_hLangList, sCCode, sLanguage);
			
		} while (KvGotoNextKey(hKV, false));
		
		KvGoBack(hKV);
	}
	
	CloseHandle(hKV);
	
	// Create and cache language selection menu.
	new Handle:hLangArray = CreateArray(32);
	decl String:sLangID[4];
	
	new maxLangs = GetLanguageCount();
	for (new i = 0; i < maxLangs; i++)
	{
		GetLanguageInfo(i, _, _, sLanguage, sizeof(sLanguage));
		FormatLanguage(sLanguage);
		PushArrayString(hLangArray, sLanguage);
	}
	
	// Sort languages alphabetically.
	SortADTArray(hLangArray, Sort_Ascending, Sort_String);
	
	// Create and cache the menu.
	g_hLangMenu = CreateMenu(LanguageMenu_Handler, MenuAction_DrawItem);
	SetMenuTitle(g_hLangMenu, "Language:");
	
	maxLangs = GetArraySize(hLangArray);
	for (new i = 0; i < maxLangs; i++)
	{
		GetArrayString(hLangArray, i, sLanguage, sizeof(sLanguage));
		
		// Get language ID.
		IntToString(GetLanguageByName(sLanguage), sLangID, sizeof(sLangID));
		
		// Add to menu.
		AddMenuItem(g_hLangMenu, sLangID, sLanguage);
	}
	
	SetMenuExitButton(g_hLangMenu, true);
	
	CloseHandle(hLangArray);
}

FormatLanguage(String:language[])
{
	// Format the input language.
	new length = strlen(language);
	
	if (length <= 1)
		return;
	
	// Capitalize first letter.
	language[0] = CharToUpper(language[0]);
	
	// Lower case the rest.
	for (new i = 1; i < length; i++)
	{
		language[i] = CharToLower(language[i]);
	}
}

public OnClientPutInServer(client)
{
	if (IsFakeClient(client))
		return;
	
	if (g_bUseCPrefs)
	{
		// If they aren't cached yet then we'll catch them on the cookie forward.
		if (AreClientCookiesCached(client) && !g_bLoaded[client])
		{
			LoadCookies(client);
		}
	}
	else if (GetClientLanguage(client) == 0)
	{
		// CPrefs disabled. Set language without displaying help text.
		SetClientLanguageByGeoIP(client);
	}
}

public OnClientCookiesCached(client)
{
	if (IsFakeClient(client))
		return;
	
	// If they aren't in-game yet then we'll catch them on the PutInServer forward.
	if (IsClientInGame(client) && !g_bLoaded[client])
	{
		LoadCookies(client);
	}
}

public OnClientDisconnect(client)
{
	g_bLoaded[client] = false;
}

public Action:Command_Language(client, args)
{
	/* The language command has been invoked. */
	if (client == 0)
	{
		ReplyToCommand(client, "[SM] This command is for players only.");
		return Plugin_Handled;
	}
	
	// Usage: sm_language
	if (args < 1)
	{
		DisplayMenu(g_hLangMenu, client, MENU_TIME_FOREVER);
		return Plugin_Handled;
	}
	
	// Usage: sm_language <name>
	decl String:sLanguage[32], String:sLangCode[4];
	GetCmdArg(1, sLanguage, sizeof(sLanguage));
	new iLangID = GetLanguageByName(sLanguage);
	
	if (iLangID < 0)
	{
		ReplyToCommand(client, "[SM] Language not found: %s", sLanguage);
		return Plugin_Handled;
	}
	
	GetLanguageInfo(iLangID, sLangCode, sizeof(sLangCode), sLanguage, sizeof(sLanguage));
	SetClientLanguage2(client, iLangID);
	
	if (g_bUseCPrefs)
	{
		SetClientCookie(client, g_hCookie, sLangCode);
	}
	
	FormatLanguage(sLanguage);
	ReplyToCommand(client, "[SM] Language changed to \"%s\".", sLanguage);
	
	return Plugin_Handled;
}

public Action:Timer_LanguageHelp(Handle:timer, any:userid)
{
	/* Tell the client that their language has been automatically set. */
	new client = GetClientOfUserId(userid);
	
	if (client == 0)
		return Plugin_Stop;
	
	decl String:sLanguage[32];
	GetLanguageInfo(GetClientLanguage(client), _, _, sLanguage, sizeof(sLanguage));
	
	FormatLanguage(sLanguage);
	PrintToChat(client, "[SM] Your language has been set to \"%s\". Type !language to change your language.", sLanguage);
	
	return Plugin_Stop;
}

public CookieMenu_GeoLanguage(client, CookieMenuAction:action, any:info, String:buffer[], maxlen)
{
	/* Menu when accessed through !settings. */
	switch (action)
	{
		case CookieMenuAction_DisplayOption:
		{
			Format(buffer, maxlen, "Language");
		}
		case CookieMenuAction_SelectOption:
		{
			DisplayMenu(g_hLangMenu, client, MENU_TIME_FOREVER);
		}
	}
}

public LanguageMenu_Handler(Handle:menu, MenuAction:action, client, item)
{
	/* Handle the language selection menu. */
	switch (action)
	{
		case MenuAction_DrawItem:
		{
			// Disable selection for currently used language.
			decl String:sLangID[4];
			GetMenuItem(menu, item, sLangID, sizeof(sLangID));
			
			if (StringToInt(sLangID) == GetClientLanguage(client))
			{
				return ITEMDRAW_DISABLED;
			}
			
			return ITEMDRAW_DEFAULT;
		}
		
		case MenuAction_Select:
		{
			decl String:sLangID[4], String:sLanguage[32];
			GetMenuItem(menu, item, sLangID, sizeof(sLangID), _, sLanguage, sizeof(sLanguage));
			
			new iLangID = StringToInt(sLangID);
			SetClientLanguage2(client, iLangID);
			
			if (g_bUseCPrefs)
			{
				decl String:sLangCode[6];
				GetLanguageInfo(iLangID, sLangCode, sizeof(sLangCode));
				SetClientCookie(client, g_hCookie, sLangCode);
			}
			
			PrintToChat(client, "[SM] Language changed to \"%s\".", sLanguage);
		}
	}
	
	return 0;
}

LoadCookies(client)
{
	/* Load the language selection data for this client. */
	decl String:sCookie[4];
	sCookie[0] = '\0';
	
	GetClientCookie(client, g_hCookie, sCookie, sizeof(sCookie));
	
	if (sCookie[0] != '\0')
	{
		// Set the saved preference.
		SetClientLanguageByCode(client, sCookie);
	}
	else if (GetClientLanguage(client) == 0)
	{
		// Only act on clients that haven't changed Steam's default language.
		SetClientLanguageByGeoIP(client);
		
		CreateTimer(15.0, Timer_LanguageHelp, GetClientUserId(client), TIMER_FLAG_NO_MAPCHANGE);
	}
	
	g_bLoaded[client] = true;
}

SetClientLanguageByCode(client, const String:code[])
{
	/* Set a client's language based on the language code. */
	new iLangID = GetLanguageByCode(code);
	
	if (iLangID >= 0)
	{
		SetClientLanguage2(client, iLangID);
	}
}

SetClientLanguageByGeoIP(client)
{
	/* Set a client's language relative to their country. */
	decl String:ip[17], String:ccode[4];
	
	if (!GetClientIP(client, ip, sizeof(ip)))
		return;
	
	if (!GeoipCode3(ip, ccode))
		return;
	
	new iLangID = GetLanguageByGeoIP(ccode);
	SetClientLanguage2(client, iLangID);
}

GetLanguageByGeoIP(const String:ccode[])
{
	/*
	* Retrieve the most popular language spoken in a given country.
	*
	* Defaults to English (0) if the language doesn't exist in languages.cfg
	* or if there is a problem retrieving the language.
	*/
	decl String:sLanguage[32];
	
	if (GetTrieString(g_hLangList, ccode, sLanguage, sizeof(sLanguage)))
	{
		new iLangID = GetLanguageByName(sLanguage);
		
		if (iLangID >= 0)
			return iLangID;
	}
	
	return 0;
}

SetClientLanguage2(client, language)
{
	// Set language.
	SetClientLanguage(client, language);
	
	// forward GeoLang_OnLanguageChanged(client, language);
	Call_StartForward(g_OnLangChanged);
	Call_PushCell(client);
	Call_PushCell(language);
	Call_Finish();
}
