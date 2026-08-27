-- SkuQuestNearby/Core.lua -- foundation file: creates the addon object and
-- the primitives every other file needs. Loaded right after Log.lua.
--
-- Optional companion addon for Sku (screen-reader accessibility addon).
-- Adds an "Objectifs de quêtes proches" entry to Sku's own Shift+F1 menu,
-- alongside its native "Quêtes actuelles" and "Base de données des quêtes":
-- one flat list of your active quest log (quêtes en cours + quêtes à
-- rendre together), sorted by distance to the relevant target (next
-- objective or turn-in NPC) instead of Sku's own default order.
--
-- [2026-08-22, REMOVED] A third list, "quêtes à accepter à proximité", used
-- to live here too -- removed once the user pointed out Sku's OWN native
-- "Questdatenbank" menu already offers the exact same distance-sorted
-- "quests I could pick up nearby" list out of the box (SkuQuest/Options.lua's
-- "Questdatenbank" -> "Start in Zone" -> "By distance", built on the SAME
-- SkuQuest:GetUnsortedAvailableQuestsTable() this addon's own removed
-- ScanAvailableToAccept just wrapped a presentation layer around). Pure
-- duplication -- see Menu.lua's own removal comment for the full trace.
--
-- Built on TOP of Sku's own quest infrastructure rather than duplicating
-- it: this addon reads SkuDB (Sku's own bundled quest/NPC/object database
-- with spawn positions -- confirmed present, no Questie dependency needed)
-- and calls Sku's own PUBLIC methods directly:
--   SkuQuest:GetQuestTargetIds(questID, aList)   -- resolves a
--       startedBy/objectives/finishedBy sub-table into (targetIds, "creature"
--       |"object"|"item"|"waypoint") -- the exact same resolution Sku's own
--       quest detail menu uses.
--   SkuQuest:CreateQuestSubmenu(parent, questID) -- explicitly documented in
--       Sku's own source as "a public wrapper so other modules can build
--       the same quest-detail menu structure (Annahme/Ziel/Abgabe/...) as
--       Sku's own quest log" -- built for exactly this kind of use.
--   SkuQuest:GetTTSText(questID)                 -- same spoken objective
--       text "Aktuelle Quests" uses on OnEnter.
--
-- This addon's OWN job is narrow: for quêtes en cours/à rendre, resolve a
-- distance for each quest log entry (creature/object target only for v1 --
-- item-drop-chain objectives are more involved and left unresolved/sorted
-- last rather than guessed at) and sort accordingly; the actual menu
-- content per quest is Sku's own, unchanged.
local ADDON_NAME, NS = ...
local Log = NS.Log

Log("Core.lua executing. Sku=%s SkuCore=%s SkuQuest=%s SkuDB=%s SkuNav=%s",
	tostring(Sku ~= nil), tostring(SkuCore ~= nil), tostring(SkuQuest ~= nil), tostring(SkuDB ~= nil), tostring(SkuNav ~= nil))

if not Sku or not SkuCore or not SkuQuest or not SkuDB or not SkuNav then
	-- Sku is a hard TOC dependency and SkuQuest/SkuDB/SkuNav are Sku's own
	-- always-loaded modules, so this should be unreachable -- bail cleanly
	-- instead of erroring if load order is ever wrong. NS.SkuMissing is
	-- checked at the top of every other file (a bare `return` here only
	-- aborts THIS file, not the whole addon, since the code is split across
	-- several separately-loaded chunks).
	Log("ABORT: Sku/SkuCore/SkuQuest/SkuDB/SkuNav missing at file-load time -- addon inert this session.")
	NS.SkuMissing = true
	return
end

---------------------------------------------------------------------------------------------------------------------------------------
local SkuQuestNearby = LibStub("AceAddon-3.0"):NewAddon("SkuQuestNearby", "AceConsole-3.0")
Log("AceAddon object created.")

-- [Same root-cause fix as every other addon in this family] AceAddon:NewAddon
-- does not expose the created object as a global -- publish it explicitly so
-- Bindings.xml (if any is added later) and any future cross-file reference
-- via _G both work.
_G.SkuQuestNearby = SkuQuestNearby
NS.SkuQuestNearby = SkuQuestNearby

-- Shows up as "Quêtes proches" in Sku's Features on/off menu (Local -> ... ->
-- Features, same list MinimapScanner/Pont Bagnon etc. register into).
SkuCore:RegisterToggleableAddon("SkuQuestNearby", function()
	return Sku.deEn and Sku.deEn("Nahe Quests", "Nearby quests", "Quêtes proches") or "Quêtes proches"
end)
Log("Registered as toggleable addon with SkuCore.")

---------------------------------------------------------------------------------------------------------------------------------------
-- Speaks through the SAME voice path Sku itself uses.
local function Announce(aText)
	if SkuOptions and SkuOptions.Voice and SkuOptions.Voice.OutputStringBTtts then
		SkuOptions.Voice:OutputStringBTtts(aText, true, true, 0.2)
	else
		print(aText)
	end
end
NS.Announce = Announce
