# SelfMute Plugin v2

## Overview
SelfMute is a SourceMod plugin for CS:S servers that allows players to selectively mute other players in both text and voice chat. It supports individual and group muting, persistent mute preferences, and integration with popular mods like CCC, ZombieReloaded, and AdvancedTargeting.

**Important:** Version 2 (v2) of SelfMute is **not compatible** with version 1 (v1).
Please remove any previous SelfMute v1 installations before upgrading.
The database structure also changed.
You need to have "SelfMuteV2" in your database.cfg

## Features
- Mute individual players by name or SteamID
- Mute groups (e.g., @all, @ct, @t, @spec, @alive, @dead, @!friends)
- Persistent mute preferences (MySQL/SQLite support)
- Exemption system for bypassing group mutes
- Dynamic menu system for easy management
- Integration with CCC, ZombieReloaded, VoiceAnnounce, AdvancedTargeting
- Fully asynchronous SQL operations

## Installation
1. Download the latest release from GitHub or build using SourceKnight.
2. Place `SelfMute.smx` in `addons/sourcemod/plugins/`.
3. Place `SelfMute.inc` in `addons/sourcemod/scripting/include/` (for development).
4. Configure database settings in `databases.cfg` (MySQL or SQLite).
5. Restart your server.

## Commands
- `!sm [playername]` — Mute a player
- `!su [playername]` — Unmute a player
- `!cm` — Check your mute list
- `!suall` — Unmute all clients/groups

## Compatibility
- Requires SourceMod 1.12+
- Optional integration with CCC, ZombieReloaded, AdvancedTargeting

## Development
- SourcePawn code style: tabs, PascalCase for functions, camelCase for variables
- All SQL queries are asynchronous
- See `.github/copilot-instructions.md` for full development guide

## Support
For issues or feature requests, open a GitHub issue or contact the maintainer.
