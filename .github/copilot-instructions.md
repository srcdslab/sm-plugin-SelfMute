# SelfMute Plugin Development Guide

## Repository Overview
This repository contains a SourcePawn plugin for SourceMod that enables players to selectively mute other players in both text and voice chat. The plugin provides sophisticated muting capabilities including individual player muting, group-based muting (by team, status, etc.), and persistent storage of mute preferences.

## Technical Environment
- **Language**: SourcePawn (.sp files)
- **Platform**: SourceMod 1.12+ (latest stable release required)
- **Build System**: Native GitHub Actions (configured via `.github/workflows/ci.yml`)
- **Database**: MySQL or SQLite support for persistent muting
- **Compiler**: SourcePawn compiler (spcomp), installed via `rumblefrog/setup-sp`

## Project Structure
```
addons/sourcemod/
├── scripting/
│   ├── SelfMute.sp              # Main plugin source
│   └── include/
│       └── SelfMute.inc         # Native API definitions
.github/
├── workflows/ci.yml             # CI/CD pipeline
└── dependabot.yml              # Dependency management
```

## Code Style & Standards
- **Indentation**: Tabs (4 spaces)
- **Variables**: camelCase for local variables and parameters
- **Functions**: PascalCase for function names
- **Globals**: PascalCase with "g_" prefix
- **Required pragmas**: `#pragma semicolon 1` and `#pragma newdecls required`
- **Comments**: Minimal - avoid unnecessary headers, document complex logic only
- **Memory Management**: Use `delete` instead of `.Clear()` to prevent memory leaks

## Key Architectural Patterns

### Database Operations
- **ALL SQL queries MUST be asynchronous** using methodmap
- Use transactions for multi-query operations
- Always escape strings and prevent SQL injection
- Support both MySQL and SQLite drivers
- Example pattern:
```sourcepawn
Transaction T_Example = SQL_CreateTransaction();
char sQuery[1024];
g_hDB.Format(sQuery, sizeof(sQuery), "SELECT * FROM table WHERE id='%s'", escapedString);
T_Example.AddQuery(sQuery);
g_hDB.Execute(T_Example, OnSuccess, OnError, data, DBPrio_High);
```

### Memory Management
- Use `delete` directly without null checking (SourceMod handles this)
- Never use `.Clear()` on StringMap/ArrayList - use `delete` and create new instances
- Proper Handle cleanup in callback functions

### Plugin Integration
The plugin integrates with several optional plugins:
- **CCC (Custom Chat Colors)**: Updates ignored array for chat filtering
- **ZombieReloaded**: Team detection for zombie/human muting
- **VoiceAnnounce**: Voice activity detection for menu sorting
- **AdvancedTargeting**: Steam friends detection

### Event-Driven Architecture
- Uses SourceMod's event system (`HookEvent`)
- Implements proper client lifecycle management (`OnClientPostAdminCheck`, `OnClientDisconnect`)
- Cookie-based preference persistence

## Core Features Implementation

### Muting System
- **Individual Muting**: Target specific players by name or ID
- **Group Muting**: Target groups using @ prefixes (@all, @ct, @t, @spec, @alive, @dead, @!friends)
- **Three Modes**: Temporary (session), Permanent (database), Alert (user choice)
- **Exemption System**: Allow specific players to bypass group mutes

### Database Schema
```sql
-- clients_mute table
CREATE TABLE clients_mute (
    id INT AUTO_INCREMENT PRIMARY KEY,
    client_name VARCHAR(64),
    client_steamid VARCHAR(32),
    target_name VARCHAR(1024),
    target_steamid VARCHAR(32) UNIQUE
);

-- groups_mute table  
CREATE TABLE groups_mute (
    id INT AUTO_INCREMENT PRIMARY KEY,
    client_name VARCHAR(64),
    client_steamid VARCHAR(32),
    group_name VARCHAR(1024),
    group_filter VARCHAR(32)
);
```

## Build & Development Workflow

### Building
Builds run via native GitHub Actions (`.github/workflows/ci.yml`): the SourcePawn compiler is
installed with `rumblefrog/setup-sp` (SourceMod 1.12.x), include dependencies are cloned directly
from their source repos, and `spcomp` compiles `SelfMute.sp` into `SelfMute.smx`.

### Dependencies
Cloned directly in CI from their GitHub repos:
- **multicolors**: Chat color formatting (srcdslab/sm-plugin-MultiColors)
- **ccc**: Custom chat colors integration (srcdslab/sm-plugin-CustomChatColors)
- **advancedtargeting**: Friend detection features (srcdslab/sm-plugin-AdvancedTargeting)
- **zombiereloaded**: Zombie mod integration (srcdslab/sm-plugin-zombiereloaded)

### CI/CD Pipeline
- Automated builds on push/PR using GitHub Actions
- Uses `rumblefrog/setup-sp` to install the SourcePawn compiler
- Automatic releases on tags and master/main branch pushes (tagged `latest`)
- Artifact generation for testing

## Development Best Practices

### Performance Considerations
- **Minimize timer usage** - prefer event-driven patterns
- **Cache expensive operations** - avoid repeated string operations in hot paths
- **Optimize complexity** - strive for O(1) over O(n) where possible
- **Consider server tick impact** - be mindful of performance in frequently called functions

### Error Handling
- Always implement error callbacks for async operations
- Use debug levels for logging (1=Errors, 2=Info)
- Graceful degradation when optional plugins unavailable

### Menu System
- Uses SourceMod's Menu API with proper cleanup
- Dynamic menu generation based on player state
- Proper pagination handling for large player lists

### Command Structure
```sourcepawn
RegConsoleCmd("sm_sm", Command_SelfMute, "Mute player by typing !sm [playername]");
RegConsoleCmd("sm_su", Command_SelfUnMute, "Unmute player by typing !su [playername]");
RegConsoleCmd("sm_cm", Command_CheckMutes, "Check who you have self-muted");
RegConsoleCmd("sm_suall", Command_SelfUnMuteAll, "Unmute all clients/groups");
```

## Testing & Validation
- Test plugin functionality on development server before deployment
- Verify database operations work correctly with both MySQL/SQLite
- Check memory usage using SourceMod's built-in profiler
- Validate all SQL queries are asynchronous and injection-safe
- Ensure compatibility with minimum SourceMod version (1.12+)

## Integration Testing
When modifying the plugin, test integration with:
- **Base SourceMod**: Core functionality without optional plugins
- **With CCC**: Chat color filtering
- **With ZombieReloaded**: Team-based muting in zombie mod
- **With AdvancedTargeting**: Friend-based muting features

## Common Pitfalls to Avoid
- **Never use synchronous SQL queries** - all must be async
- **Don't forget to escape SQL strings** - always use `g_hDB.Escape()`
- **Avoid memory leaks** - use `delete` instead of `.Clear()`
- **Don't hardcode values** - use configuration where appropriate
- **Handle client disconnections** - always validate client indices

## File Modification Guidelines
- **SelfMute.sp**: Main plugin logic, database operations, commands, menus
- **SelfMute.inc**: Native function definitions only - document all parameters and return values
- **CI/CD files**: Only modify if changing build process or adding new dependencies

## Debugging & Troubleshooting
- Enable debug logging with `sm_selfmute_debug_level 2`
- Check SourceMod error logs for SQL and plugin errors
- Use SourceMod's memory profiler for leak detection
- Verify plugin load order for dependencies