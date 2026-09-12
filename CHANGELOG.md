# Changelog

## [1.2.0]

### Changed
- **Ctrl+I and Ctrl+D serve whichever beacon is active.** With the quest beacon off and SkuAllyBeacon following a group member, Ctrl+I turns you toward the ally and Ctrl+D speaks their distance and direction — the same keys, the same maths, a different target. Built for: *"On va conserver Ctrl+I … une seule balise à la fois, la balise quête ou la balise allié."*
- **One beacon at a time.** Starting the quest beacon switches the ally beacon off (and says so); SkuAllyBeacon does the reverse. Exposed for it on the addon object: `SkuQuestNearby:BeaconIsRunning()` and `SkuQuestNearby:StopBeacon()` — the two addons share no namespace.

## [1.1.0]

### Added
- **A continuous audio beacon on your next quest stop, on a configurable key (`Ctrl+B` by default).** It points at the nearest quest objective you still have to do — or at the turn-in NPC once a quest is complete — and re-aims itself every few seconds as you play, so finishing one objective moves it to the next one and then on to the next quest without touching anything. This is the part sighted players get from TomTom's arrow fed by Questie, except TomTom aims at one waypoint and does not advance on its own.
- The beacon is Sku's own `SkuBeacon` library, the same engine behind Sku's quest-giver and turn-in beacons, and it reuses the sound set and volume already configured for Sku's navigation beacons rather than adding a second set of audio settings that could disagree with the first.
- **A second key (`Ctrl+I` by default) turns your character to face the beacon's target**, the way Sku's own `I` faces its selected waypoint. Sku's key could not simply be reused: `SKU_KEY_TURNTOBEACON` calls `GameWorldObjectsTurnToWp`, which is keyed on a waypoint *name* and looks its position up in SkuNav's database — this beacon's target is a position resolved from Questie, so there is no name to hand it. Creating a throwaway SkuNav waypoint on every retarget just to borrow that key would have written junk into the player's own waypoint database, so the turn maths is reproduced against coordinates instead, faithfully including the parts that matter: the signed angle from `SkuNav.Geo:GetDirectionTo`, the temporary `cameraYawMoveSpeed` override *and its restoration*, and the `SetView(2)` snap only when Sku's own standard camera mode is active so a deliberately decoupled camera is never yanked.
- **A third key (`Ctrl+D` by default) speaks the remaining distance and the direction**, e.g. "Le Grand Chasseur, 240m, 3 heures". The distance is measured live against your current position rather than reusing the value cached at the last re-aim, which can be up to three seconds stale — while running that is enough to be noticeably wrong and would make the readout feel laggy. The direction uses `SkuNav.Geo:GetDirectionToAsString`, the same clock-face phrasing Sku's own Ctrl+Alt readout uses, rather than inventing a second vocabulary for the same idea.
- Menu at Quests → Quest beacon: turn it on/off, turn to the target, announce distance, and rebind or reset any of the three keys. Rebinding refuses a key already taken by Sku *or* by one of this addon's own other bindings.

### Fixed
- **The beacon could aim at a quest's turn-in NPC while the quest was still unfinished.** Target selection went through Questie's `DistanceUtils.GetNearestSpawnForQuest`, which short-circuits to the finisher whenever `quest:IsComplete() == 1`. `QuestieDB.IsComplete` ends with an `or` chain whose last term is a bare `1`, so a quest whose objectives are not in Questie's `QuestLogCache` *yet* — it is filled asynchronously, a normal transient state after login or right after accepting — and which has a source item falls through every earlier term and is reported COMPLETE. Questie's reasoning ("no objectives means a talk-to-an-NPC quest") is right for those quests and wrong for any other caught mid-cache-fill. The completion decision is now taken from WoW's own `GetQuestLogTitle` flag, which is authoritative, and Questie is asked only for *positions* — the finisher when WoW says complete, the unfinished objectives otherwise, using Questie's own `Needed ~= Collected` filter so the beacon still matches what Questie draws on the map. When WoW says a quest is unfinished and no objective resolves to a position, that quest is skipped entirely rather than falling back to its turn-in. The same flag now also drives the spoken "objectif"/"à rendre", so the words can never disagree with where the beacon points.
- **The beacon was inaudible at any realistic quest distance.** SkuBeacon picks its sample from an index it derives itself — `floor((distance + 5) / 6)`, capped at 30, shifted by the configured volume — and the sound packs ship `;1.mp3` (loudest) through `;30.mp3` (faintest), with no `;0.mp3` at all. At the default volume that curve gives 1 at 5m, 17 at 100m, and **30 from 200m onward**. Sku's own beacons mark a waypoint you are walking onto, so they live in the loud part of it; a quest objective is essentially always past 200m when you set off, pinning it at the most attenuated sample in the pack forever. Simply raising the configured volume is not the fix either — at volume 200 the same formula drives short distances to index 0, whose file does not exist, so the beacon goes genuinely silent exactly when you arrive. The volume handed to the library is now computed per re-aim to land the index in a usable band (2 near, 20 far), which keeps a real loudness gradient instead of a flat wall, and the player's own SkuNav beacon volume still shifts that whole band so their preference is honoured rather than overridden.
- The beacon is now re-aimed on every pass rather than only when the target changes — the distance compensation depends on where *you* are, which changes as you walk even when the objective has not moved.
- Disabling the addon from Sku's Features menu now also stops the beacon and releases its key. A beacon left pinging with no menu able to stop it would have been the worst possible failure mode for an audio cue.

### Diagnostics
- `/sqn beacon` prints what SkuBeacon would actually play right now: sound set, the volume sent, the compressed distance, the resulting sample index (and what it would have been without compensation), and the exact `.mp3` path. Playback happens inside the library's own `OnUpdate`, where nothing is logged, so "beacon on, no sound" was otherwise invisible.

### Notes on the data source
- Target selection reads **Questie's live objective state**, not SkuDB. SkuDB's quest data is static and does not record which objectives you have already completed, so a SkuDB-driven beacon would happily send you back to the boars you already killed on a "kill 10 boars, collect 8 hides" quest. Questie's `DistanceUtils.GetNearestSpawnForQuest` skips any objective whose `Collected` already equals its `Needed`, and switches to the quest's finisher as soon as the quest is complete — and it is the same data Questie draws on the world map and minimap, so the beacon and the map agree by construction.
- Questie supplies the target; **Sku supplies the geometry.** Questie's zone coordinates are converted with Sku's own `SkuNav.Geo:GetUiMapIdFromAreaId` + `C_Map.GetWorldPosFromMapPos` path rather than trusting Questie's HereBeDragons world space to match the one `UnitPosition("player")` reports, which is the space the beacon actually needs.
- Without Questie the beacon still works, falling back to this addon's own SkuDB resolution — with the completed-objective limitation above, stated in the log every time that path is used.

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
