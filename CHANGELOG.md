# Changelog

## [1.0.1]

### Fixed
- **Disabling this addon from Sku's Features menu now actually stops it.** Both of this addon's integration points are `hooksecurefunc` hooks, which cannot be unhooked, so honouring the toggle has to happen per call. Neither hook checked: the "Objectifs de quêtes proches" entry kept being injected into Sku's quest menu, and so did the track/untrack row inside every quest submenu. Both now return early when the addon is disabled — the same guard, in both places.

## [1.0.0] — first public release

First stable release. Previous versions were developed and published iteratively; this is the consolidated 1.0.0.

### Features
- Adds "Nearby quest objectives" to Sku's own Quests menu: every quest in your log as one distance-sorted list, in-progress and ready-to-turn-in mixed together, so the closest thing to do is always first.
- Distance resolution covers item-collection objectives (traced back to their drop sources) and searches every zone on your continent, not just the one you're standing in.
- Full submenu detail and the same Shift+Down Arrow readout as Sku's native quest list.
- A "Track / stop tracking this quest" toggle in each quest's detail — untracking also removes that quest's minimap markers.
- Fully translated: English, French, German.
