# Isaac External Item Descriptions iOS v0.7.7

This release merges all upstream improvements and fixes from `emp0ry` across versions 0.7.0 through 0.7.6 into our fork, alongside all custom fork enhancements.

## Upstream Highlights (v0.7.0 – v0.7.6)

- **Authentic EID Pickup Reachability & Flight Detection (v0.7.6)**:
  - Descriptions for obstructed cards, runes, and pills are now revealed when the player can fly.
  - Native flight status is verified directly from the ARM64 movement byte (`kPlayerCanFlyOffset`), while ground-bound players keep unreachable pickup identities hidden.
- **Updated Repentance Description Database (v0.7.5)**:
  - Bundled EID descriptions updated to source `ee7f463` with the latest fixes and updated Russian localizations.
  - Explicitly targets Repentance `1.7.9b`.
- **Card-Family, Rune & Soul Stone Artwork Parity (v0.7.4)**:
  - Correct inline icons for all 17 Soul Stones, Rune Shard, and Cracked Key.
  - Uses original EID frame indexing (`Card ID - 1`) and removes inaccurate sprite fallbacks.
- **Single-Window Pass-Through Touch Model (v0.7.3)**:
  - Restored reliable touch interaction for LiveContainer.
  - Settings buttons, sliders, language menus, and pause inventory cards receive touches seamlessly while game controls pass through uninterrupted.
- **Startup Overlay & Pill Localization (v0.7.1)**:
  - Overlay attaches only after the app becomes active, preventing virtual movement sticks from sticking at the top-left on startup.
  - Localized unidentified-pill titles across all supported languages, removed redundant `?` lines, and enabled crisp pixel-art icon rasterization at native display scale.
- **Active Item Charge Bars & Scrollable Settings (v0.7.0)**:
  - Renders battery icons and charge numbers for active items.
  - Scrollable settings card with live percentage labels for Scale and Opacity.

## Fork Enhancements

- **RT / Drop Button Frame-Repeat Edge-Detection & Debounce Fix**:
  - Eliminates the vanilla iOS engine bug where holding RT or tapping the touch drop button fired `ACTION_DROP` (Action 11) on *every single frame* (60 FPS), which caused **Schoolbag** and pocket items to rapidly strobe and cycle uncontrollably.
  - Enforces true rising-edge detection and a 100ms debounce interval across all gamepad, touchscreen, and keyboard input drivers. Dropping held trinkets and cards remains smooth and natural.
- **Holy Mantle & Room Buff Suspension Restore**:
  - Automatically restores Holy Mantle shields and temporary room stat buffs when returning to the game after opening Control Center or switching apps.
- **Mom's Hand / Dead Hand Visual Pulse Warning**:
  - Real-time subtle pulse alert when ceiling hand enemies (Mom's Hand ID 213, Dead Hand ID 287) are present in the room.
- **Dynamic Synergies & Consolation Prize Predictions**:
  - Live calculations for **Car Battery** and **Tarot Cloth** synergies appended directly to item descriptions.
  - Real-time stat prediction for **Consolation Prize** based on current player stats.
- **Translucent Rounded Backdrop**:
  - Sleek, unobtrusive semi-transparent background behind EID panels for maximum readability against complex room floors.
- **Dedicated Debug / Testing Build (`IsaacExternalItemDescriptions-Debug`)**:
  - An optional build with an in-game `🛠 Debug` console button in the pause menu for testing pedestal transforms, pill granting, and stat tweaking on floor 1. The standard release build remains completely clean.

## Compatibility

- Supports verified Isaac iOS executable UUID `F4357753-A25F-30EE-BACF-63709F902895`.
- Standalone dylib remains independent of ElleKit, Substrate, libhooker, and jailbreak runtimes.
- Downloads include rootless deb, standalone dylib, LiveContainer framework, embedded package, descriptions database, and checksums.
- No Isaac IPA or copyrighted game bundle is included.
