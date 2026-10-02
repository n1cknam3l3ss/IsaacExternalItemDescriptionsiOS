# Isaac External Item Descriptions iOS v0.7.2

This release introduces fixes for iOS application suspension state loss and adds visual accessibility alerts.

## What's Changed

- **Preserve Holy Mantle shield & temporary room buffs across iOS app switch / Control Center / screen lock**:
  - Resolves a vanilla iOS Repentance bug where opening iOS Control Center, locking the device, or switching apps triggers an emergency serialize to `gamestate.dat`. Upon pressing «Продолжить» (Continue), the room reloads without firing `OnEnterRoom()`.
  - In single-room encounters (such as The Beast, Ultra Greed, or boss rushes), this caused Holy Mantle charges to reset to 0 (leaving the player permanently shieldless despite possessing item 313), stripped Holy Card / Lost shields, and erased accumulated temporary room buffs (e.g. Eve's Razor Blade, Book of Belial).
  - The mod now captures an exact pre-suspend snapshot on `UIApplicationWillResignActiveNotification` and automatically restores Holy Shield via native `TemporaryEffects::AddCollectibleEffect(313, false, 1)` and re-applies temporary room stat multipliers upon resuming the run.
- **Mom's Hand / Dead Hand Visual Room Alert**:
  - Added real-time NPC entity scanning for `ENTITY_MOMS_HAND` (ID 213) and `ENTITY_MOM_DEAD_HAND` (ID 214).
  - When Mom's Hand appears in the room, the edges of the screen smoothly pulse with a soft white vignette glow (0.4s fade-in, 0.1s hold, 0.9s fade-out), giving a clear visual warning when playing on mute or low volume.
