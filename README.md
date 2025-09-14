Overview:
NetNanny is an in-game moderation system that detects and responds
to inappropriate behavior inside your Roblox experience while
maintaining transparency and alignment with Roblox Terms of Service.
(Read TOS references below — see "TOS References".)

----------------------------------------
Quick summary
----------------------------------------
- Ban Strikes
  - Triggered from **in-game chat** violations and are used to
    escalate toward bans when NNDataStore thresholds are exceeded.
  - Configured in: **NNDataStore ModuleScript**
  - (See TOS References for data/notice requirements.)

- Solo Strikes
  - Triggered by profile/friends/groups/badges checks and other
    flagged metadata used for routing repeat offenders into
    a private Solo Experience (private server). These **do not**
    count toward ban thresholds.
  - Configured in: **NetNanny ServerScript**
  - (See TOS References for Solo Experience best practices.)

- BKSH Protection
  - Detects when a player is persistently targeted from inappropriate
    rear-facing angles and applies a quick, harmless response.
  - Designed to reduce inappropriate actions in gameplay.
  - Configured in: **NetNanny ServerScript**
  - (See Key Functions & Flow for BKSH handling.)

----------------------------------------
...
----------------------------------------
Key Functions & Flow (developer quick-map)
----------------------------------------
1. `inspectProfileAndMaybeSolo(player)`
   - Checks username/displayName/description.
   - Adds **Solo Strikes** (ServerScript).

2. `inspectFriendsAndMaybeSolo(player)`
   - Checks friend profiles up to `MaxFriendChecks`.
   - Adds **Solo Strikes** per matched friend.

3. `inspectBadgesAndMaybeSolo(player)`
   - Checks recent badges; adds Solo Strikes on match.

4. `inspectGroupsAndMaybeSolo(player)`
   - Checks user groups; adds Solo Strikes on match.

5. `handleBan(player)`
   - Uses **NNDataStore** to determine bans and reasons; only chat-based strikes (ban strikes) are escalated here.

6. `sendToSoloServer(player)`
   - Teleports flagged player to PRIVATE_PLACE_ID (Solo Experience).
   - Ensure PRIVATE_PLACE_ID does not Deny Access; check place permissions.

7. `applyBkshProtection(player, attacker)`
   - Evaluates attacker’s position and facing relative to the player.
   - Resets the attacker if thresholds are exceeded.
   - Configurable via constants inside **NetNanny ServerScript**.

Notes:
- In-game chat violations add **Ban Strikes** via NNDataStore only; they do NOT increment Solo strike counters.
- Solo strikes are intentionally separated so profile-based issues do not immediately ban a player.
- bksh protection is independent of chat/profile checks; it strictly evaluates in-game positional targeting.

----------------------------------------
...
----------------------------------------
Customization & Configuration
----------------------------------------
- ServerScript CONFIG keys to check:
    - DebugPrints (bool)
    - MaxFriendChecks (int)
    - FriendFetchAttempts (int)
    - FriendFlaggingEnabled (bool)
    - SoloStrikesThreshold (int)  <-- Solo strikes threshold lives here
    - BkshProtectionEnabled (bool)  <-- enable/disable bksh tracking
- NNDataStore ModuleScript keys to check:
    - BanThreshold (int)
- Fuzzy matching:
    - FUZZY_THRESHOLD controls fuzzy/leet tolerance.
    - FRIEND_PROFILE_CACHE_TTL and FRIEND_PROFILE_MAX_CONCURRENCY manage fetch performance.

----------------------------------------
...
----------------------------------------
Usage (install)
----------------------------------------
1. Place NetNanny ServerScript and NNDataStore ModuleScript in ServerScriptService.
   Optional: Place NNChatNotification in StarterPlayerScripts to inform players their UserIDs
   may be stored for moderation purposes. (See TOS References.)

2. Ensure `PRIVATE_PLACE_ID` (ServerScript) points to a place in your game that does not
   deny players service. This ensures flagged users are teleported to a Solo Experience
   without being blocked from the game.

3. Adjust `FLAGGED_WORDS` for community rules. Avoid overly common words to reduce false positives.

4. Important:
   - **Ban Strikes**: in-game chat violations; configured in **NNDataStore ModuleScript**.
   - **Solo Strikes**: profile/badge/group/friend matches; configured via **NetNanny ServerScript**.
     (See "TOS References" and "Player Notice & Privacy".)
