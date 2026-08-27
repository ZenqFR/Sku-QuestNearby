# SkuQuestNearby

Optional companion addon for **[Sku](https://github.com/ZenqFR/Sku-WoW-Addon-TBC)** (a screen-reader/accessibility addon for World of Warcraft, TBC Classic) that adds a distance-sorted "what's nearby" quest menu on top of Sku's own quest data — built entirely on Sku's own public quest-log/quest-database APIs, no other addon required.

Sku already has "Quêtes actuelles" (your quest log, unsorted) and "Questdatenbank → Start in Zone → By distance" (quests you can accept, sorted by distance — but only those). Nothing in Sku sorts your **already-accepted** quests by how close their objective or turn-in actually is. This addon fills that one gap.

## What it does

One new entry, right next to Sku's own "Quêtes actuelles" / "Questdatenbank" in the Quêtes menu:

- **"Objectifs de quêtes proches"** — every quest currently in your log, one entry each, sorted by distance to whatever matters right now: the nearest unresolved objective for a quest still in progress, or the turn-in NPC/object for one that's ready to hand in. In-progress and ready-to-turn-in quests are mixed into one single list (not split into separate categories) so the closest thing to do is always at the top, whatever kind of "thing" it is. Each entry's label says which kind it is and how far ("1315m, objectif" / "82m, à rendre").
- **Full sub-menu detail**, identical to "Quêtes actuelles": Annahme/Ziel/Abgabe, pre-requisite quests, sharing, sending to chat.
- **Shift+DownArrow reads the quest description**, exactly like "Quêtes actuelles" does.
- Distance resolution is broad, not just "objective in your current zone": item-collection objectives are traced back to their drop sources (creature/object/vendor), creature/object targets are searched across every zone on your current continent (not just the one you're standing in), and a quest whose real objective genuinely can't be located falls back to showing distance to the quest giver instead of nothing at all.

*(An earlier version also added a second "Quêtes à accepter à proximité" entry — removed, since Sku's own `Questdatenbank → Start in Zone → By distance` already does exactly that, out of the box, with no addon needed.)*

**"Suivre cette quête" / "Ne plus suivre cette quête"** — a toggle added to every quest's detail submenu, not just this addon's own list: Sku's own "Quêtes actuelles" gets it too. Untracking a quest is WoW's own way to remove its markers from the minimap and world map (and drop it from the on-screen objective tracker) — Sku itself had no accessible way to reach that toggle at all.

## How it works

- Toggle from Sku's own **Features** menu (Local → Settings → Module → Features → "Quêtes proches"). Inert with zero effect if disabled.
- Built almost entirely on `SkuQuest`'s own public methods rather than reimplementing quest-data parsing: `GetQuestTargetIds` (resolve a quest's objective/turn-in/giver into a target type + ids), `CreateQuestSubmenu` (the exact same Annahme/Ziel/Abgabe detail menu "Quêtes actuelles" builds), `GetTTSText` (the same spoken description text). Positions come from Sku's own bundled `SkuDB` quest/NPC/object database (a translated, schema-compatible data port — no dependency on Questie or GatherMate2).
- Injects its menu entry directly into Sku's own "Quêtes" root menu via `hooksecurefunc(SkuQuest, "MenuBuilder", ...)`, run right after Sku's own menu has built itself — additive only, never touches or replaces anything Sku already puts there.
- The track/untrack toggle hooks `SkuQuest:CreateQuestSubmenu` the same way, so it lands in every quest-detail view across Sku, not just this addon's own — backed directly by Blizzard's own `C_QuestLog.AddQuestWatch`/`RemoveQuestWatch`/`GetQuestWatchType`.
- Ships a self-diagnostic log (`/sqnlog`) and a `SkuQuestNearbyLog` SavedVariable, plus `/sqn` for a quick chat-only summary of the list size without opening the menu.

## Requirements

- [Sku](https://github.com/ZenqFR/Sku-WoW-Addon-TBC)

## Status

Built and tested for a single user's own setup (TBC Classic Anniversary realms). Not submitted upstream to Sku — kept as a separate, optional companion addon.

---

Built with [Claude Code](https://claude.com/claude-code).
