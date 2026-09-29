# Isaac External Item Descriptions iOS v0.7.1

This release fixes parity rendering presentation hooks, ensuring dynamic item enrichments (Consolation Prize predictions, weapon overrides, synergies, and warnings) display properly during gameplay.

## What's Changed

- **Fixed dynamic description enrichment hook in parity presentation**: Resolved an issue where method swizzling in `EIDParityPresentation` bypassed `enrichDescription:forPickup:displaySubtype:`, causing dynamic stat predictions and synergy warnings to not appear on screen.
- **Dynamic stat token normalizer & fallbacks**: Mapped `{{Speed}}`, `{{Tears}}`, `{{Damage}}`, `{{Range}}`, etc. to the corresponding atlas icons (`SpeedSmall`, etc.), and added unicode symbol fallbacks (`⚠`, `⚔`, `💧`, `👟`, `↔`, `¢`, `💣`, `🔑`, `↑`, `↓`) to prevent any icon or text dropouts.
- **Improved smelted trinket detection**: Updated native memory probe to support vanilla `std::vector<int32_t>` for swallowed / smelted trinket tracking across Gulp! pills and Smelter activations.
- **Consolation Prize fallback**: Added an informational fallback prediction for Consolation Prize when player memory probe is in transition.
