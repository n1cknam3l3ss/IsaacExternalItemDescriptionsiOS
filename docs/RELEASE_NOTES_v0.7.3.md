# Isaac External Item Descriptions iOS v0.7.3

This release resolves a critical iOS input engine bug affecting gamepad triggers and touchscreen controls, alongside upstream interface touch handling improvements.

## Upstream Fixes

- Restores the proven single-window pass-through overlay architecture used by v0.6.1.
- EID settings, sliders, language selection, pause inventory, rows, and close buttons receive touches again.
- Touches outside visible EID controls continue directly to Isaac.
- Does not create a second `UIWindow` and does not insert EID views into the game controller hierarchy.

## Fork Fixes

- **Fix RT / Right Trigger & On-Screen Drop Button Rapid-Fire Repeat Bug**:
  - In the vanilla iOS port of *The Binding of Isaac: Repentance*, holding or tapping the Right Trigger (RT / R2 on physical gamepads) or the on-screen touch drop button (`⬇` / `⏬`) caused the engine input layer to report `ACTION_DROP` (Action 11) as `IsActionTriggered = true` continuously on *every single frame* (60 times per second) instead of only on the rising edge of a press.
  - This made it practically impossible to use **Schoolbag (Item 534)** or cycle cards and pills with **Starter Deck (Item 251)**, **Little Baggy (Item 252)**, or **Deep Pockets**, as items would strobe and cycle 60 times a second back and forth.
  - The mod now hooks `DeviceBase::IsActionTriggered` across all active input device vtables (`DeviceGamepad`, `DeviceiOS`, `DeviceKeyboard`, `InputDeviceBase`) in `__DATA_CONST`:
    - Enforces true rising-edge detection (only fires on the initial frame of a new physical press or screen tap).
    - Enforces a 100ms debounce interval between distinct taps to eliminate mechanical and capacitive touch flutter.
    - While held down, `IsActionTriggered` returns `false` (keeping active items and pocket items stable), while `IsActionPressed` continues to return `true` so holding to drop held trinkets and cards works completely naturally and smoothly.

## Compatibility

- Supports the verified Isaac iOS executable UUID `F4357753-A25F-30EE-BACF-63709F902895`.
- The standalone dylib remains independent of ElleKit, Substrate, libhooker, and other jailbreak-only runtimes.
- Release downloads include the rootless package, standalone dylib, LiveContainer framework, embedded package, complete description database, and checksums.
- No Isaac IPA or copyrighted game bundle is included.
