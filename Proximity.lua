-- SkuQuestNearby/Proximity.lua -- resolves a distance for quest log entries
-- and available-to-accept quests, using Sku's own bundled quest database
-- (SkuDB) and SkuQuest's own public target-resolution method.
local ADDON_NAME, NS = ...
if NS.SkuMissing then return end
local Log = NS.Log

---------------------------------------------------------------------------------------------------------------------------------------
-- Small FR/EN/DE difficulty label table -- deliberately NOT reaching into
-- Sku's own AceLocale-keyed tDifficultyColors (a chunk-local table in
-- SkuQuest/Options.lua, invisible across the addon boundary anyway) to keep
-- this addon self-contained, same reasoning as SkuGatherRoute/
-- SkuBagnonBridge's own local translation tables rather than depending on
-- Sku's internal locale keys existing under names we'd have to keep in sync.
local tDifficultyLabels = {
	QuestDifficulty_Trivial = { "Trivial", "Trivial", "Trivial" },
	QuestDifficulty_Standard = { "Einfach", "Easy", "Facile" },
	QuestDifficulty_Difficult = { "Mittel", "Medium", "Moyenne" },
	QuestDifficulty_VeryDifficult = { "Optimal", "Optimal", "Optimale" },
	QuestDifficulty_Impossible = { "Rot", "Red", "Rouge" },
}

local function DifficultyLabel(aLevel)
	if not aLevel then return nil end
	local tOk, tDiff = pcall(GetQuestDifficultyColor, aLevel)
	if not tOk or not tDiff or not tDiff.font then return nil end
	local tEntry = tDifficultyLabels[tDiff.font]
	if not tEntry then return nil end
	return Sku.deEn and Sku.deEn(tEntry[1], tEntry[2], tEntry[3]) or tEntry[3]
end
NS.DifficultyLabel = DifficultyLabel

---------------------------------------------------------------------------------------------------------------------------------------
-- UNKNOWN_DISTANCE: sentinel for "couldn't resolve a position" -- these
-- entries still get listed (nothing is ever hidden), just sorted to the
-- end, same convention SkuQuest's own GetUnsortedAvailableQuestsTable uses
-- (its own 99999 sentinel) for exactly the same reason.
local UNKNOWN_DISTANCE = 999999
NS.UNKNOWN_DISTANCE = UNKNOWN_DISTANCE

-- [2026-08-19] "Je suis près du donneur ou du livreur, mais l'objectif n'est
-- pas terminé -- la distance la plus proche me montre le PNJ donneur/
-- livreur" -- the quest-giver fallback added in 0.3.0 (see ScanQuestObjectives
-- below) reports a REAL position, but it is NOT the actual unfinished
-- objective -- it's just the closest thing this addon could find ANY
-- position for. Standing near a quest hub (several NPCs at once) made every
-- one of those fallback quests look like "the closest thing to do right
-- now" purely because the giver happens to be nearby, even though nothing
-- can actually be progressed by standing there -- outranking quests with a
-- REAL, resolved, actionable objective distance that happened to be
-- further away. This penalty keeps a fallback-resolved entry sorting BELOW
-- every genuinely-resolved objective/turn-in distance (so real progress
-- opportunities are never buried under misleading "nearby" giver stops),
-- while still sorting well above the fully-unknown sentinel (so it's never
-- silently hidden at the very bottom either). Safely larger than any
-- realistic in-game distance, safely smaller than UNKNOWN_DISTANCE.
local FALLBACK_SORT_PENALTY = 500000
NS.FALLBACK_SORT_PENALTY = FALLBACK_SORT_PENALTY

-- Player position + the "area id" Sku's own quest code uses to index
-- SkuDB spawn tables (confirmed by reading SkuQuest:GetUnsortedAvailableQuestsTable
-- and SkuQuest:GetResultingWps directly -- both key spawns by this same
-- value, obtained via GetAreaIdFromUiMapId(GetBestMapForUnit(...)), despite
-- the "UiMap" name in Sku's own local variable -- kept here under a clearer
-- name to avoid perpetuating that confusion in this addon's own code).
local function GetPlayerContext()
	local tRawUiMapId = SkuNav.Geo:GetBestMapForUnit("player")
	if not tRawUiMapId then return nil end
	local tAreaId = SkuNav.Geo:GetAreaIdFromUiMapId(tRawUiMapId)
	local tPlayerX, tPlayerY = UnitPosition("player")
	if not tAreaId or not tPlayerX then return nil end
	-- [important] Round-tripped back through GetUiMapIdFromAreaId rather than
	-- reusing tRawUiMapId directly -- matches SkuQuest:GetUnsortedAvailableQuestsTable's
	-- own exact pattern field-for-field. The two aren't guaranteed identical
	-- (a sub-area's uiMapId can normalize to a different canonical one once
	-- round-tripped through its areaId), and spawn percentage-coordinates in
	-- SkuDB are recorded against THAT canonical uiMapId, not necessarily
	-- whatever GetBestMapForUnit happens to return directly.
	local tUiMapId = SkuNav.Geo:GetUiMapIdFromAreaId(tAreaId)
	if not tUiMapId then return nil end
	-- [2026-08-19] Continent id, for GetSpawnDistance's cross-zone search
	-- below -- same field ("continentId", 3rd return) SkuQuest:GetResultingWps
	-- itself reads off GetAreaData to decide whether a spawn is "same
	-- continent" (a real distance) or "Anderer Kontinent" (a different
	-- coordinate space entirely -- Euclidean distance across continents is
	-- meaningless, not just imprecise).
	local tOkContinent, _, _, tContinentId = pcall(SkuNav.Geo.GetAreaData, SkuNav.Geo, tAreaId)
	return { areaId = tAreaId, uiMapId = tUiMapId, playerX = tPlayerX, playerY = tPlayerY, continentId = tOkContinent and tContinentId or nil }
end
NS.GetPlayerContext = GetPlayerContext

-- Distance from the player (per aCtx, from GetPlayerContext) to the CLOSEST
-- recorded spawn of (aTargetType, aTargetId) -- searches EVERY zone SkuDB
-- has a spawn recorded in, not just the player's current one (the original
-- v0.2.0 same-zone-only scoping made most objectives show no distance at
-- all whenever their target simply wasn't recorded as spawning in whatever
-- zone the player happened to be standing in -- confirmed via the user's
-- own log: "targetType='creature', 1 target id(s), none resolved to a spawn
-- in the current zone" was the single most common failure). A candidate
-- zone is only considered if it's on the SAME CONTINENT as the player --
-- different continents use unrelated coordinate origins, so a straight-line
-- distance across them isn't a real number, not just an imprecise one; that
-- candidate is skipped rather than producing a misleading distance.
-- Returns nil (not 0) when unresolvable, so callers can tell "genuinely
-- unknown" apart from "0 yards away".
local function GetSpawnDistance(aCtx, aTargetType, aTargetId)
	if not aTargetId then return nil end
	local tSpawns
	if aTargetType == "creature" then
		local tData = SkuDB.NpcData.Data[aTargetId]
		tSpawns = tData and tData[SkuDB.NpcData.Keys["spawns"]]
	elseif aTargetType == "object" then
		local tData = SkuDB.objectDataTBC[aTargetId]
		tSpawns = tData and tData[SkuDB.objectKeys["spawns"]]
	else
		-- "waypoint" target types (trigger-end/explore quests) are not
		-- resolved -- SkuQuest:GetTriggerEndWps returns its own pre-built
		-- waypoint name strings, not raw spawn coordinates in SkuDB's usual
		-- shape, and there are very few of these in practice.
		return nil
	end
	if not tSpawns then return nil end

	local tBest
	for tAreaId, tAreaSpawns in pairs(tSpawns) do
		local tSpawnX, tSpawnY = tAreaSpawns and tAreaSpawns[1] and tAreaSpawns[1][1], tAreaSpawns and tAreaSpawns[1] and tAreaSpawns[1][2]
		if tSpawnX and tSpawnX ~= -1 and tSpawnY and tSpawnY ~= -1 then
			local tOkArea, _, _, tAreaContinentId = pcall(SkuNav.Geo.GetAreaData, SkuNav.Geo, tAreaId)
			if tOkArea and aCtx.continentId and tAreaContinentId == aCtx.continentId then
				local tUiMapId = SkuNav.Geo:GetUiMapIdFromAreaId(tAreaId)
				if tUiMapId then
					local tOk, tContinentID, tWorldPos = pcall(C_Map.GetWorldPosFromMapPos, tUiMapId,
						CreateVector2D(tonumber(tSpawnX) / 100, tonumber(tSpawnY) / 100))
					if tOk and tWorldPos then
						local tX, tY = tWorldPos:GetXY()
						if tX then
							local tDist = SkuNav.Geo:Distance(aCtx.playerX, aCtx.playerY, tX, tY)
							if tDist and (not tBest or tDist < tBest) then tBest = tDist end
						end
					end
				end
			end
		end
	end
	return tBest
end

-- Item objectives ("collect N of X") don't have a spawn location of their
-- own -- the item drops from creatures/objects/vendors instead, recorded on
-- the ITEM's own SkuDB entry (npcDrops/objectDrops/vendors -- itemDrops,
-- item-from-item chains, are skipped as too indirect to mean much here).
-- Tries every recorded source and keeps the closest, same "closest of
-- several acceptable options" reasoning as ResolveClosestDistance itself.
local function ResolveItemDistance(aCtx, aItemId)
	local tItemData = SkuDB.itemDataTBC and SkuDB.itemDataTBC[aItemId]
	if not tItemData then return nil end
	local tBest
	local function tConsider(aType, aIds)
		if not aIds then return end
		for _, tId in ipairs(aIds) do
			local tDist = GetSpawnDistance(aCtx, aType, tId)
			if tDist and (not tBest or tDist < tBest) then tBest = tDist end
		end
	end
	tConsider("object", tItemData[SkuDB.itemKeys["objectDrops"]])
	tConsider("creature", tItemData[SkuDB.itemKeys["npcDrops"]])
	tConsider("creature", tItemData[SkuDB.itemKeys["vendors"]])
	return tBest
end

-- Resolves the CLOSEST distance across every target SkuQuest:GetQuestTargetIds
-- finds in aSubTable (a quest's own startedBy/objectives/finishedBy
-- sub-table) -- e.g. an objective offering several acceptable kill targets,
-- or several spawn-bearing entries in a list, all get considered, and the
-- nearest one wins. Returns (distance, reason) -- reason is nil on success,
-- a short diagnostic string on failure ("no sub-table" / "no targetType" /
-- "N target(s), 0 resolved" / ...) so a failure can be told apart from a
-- genuine long distance in the log, instead of both silently collapsing
-- into the same nil.
local function ResolveClosestDistance(aCtx, aQuestID, aSubTable)
	if not aSubTable then return nil, "no sub-table" end
	local tOk, tTargets, tTargetType = pcall(SkuQuest.GetQuestTargetIds, SkuQuest, aQuestID, aSubTable)
	if not tOk then return nil, "GetQuestTargetIds threw: " .. tostring(tTargets) end
	if not tTargetType then return nil, "GetQuestTargetIds resolved no targetType" end
	if not tTargets or #tTargets == 0 then return nil, "targetType='" .. tostring(tTargetType) .. "' but 0 target ids" end

	local tBest
	for _, tTargetId in ipairs(tTargets) do
		local tDist = (tTargetType == "item") and ResolveItemDistance(aCtx, tTargetId) or GetSpawnDistance(aCtx, tTargetType, tTargetId)
		if tDist and (not tBest or tDist < tBest) then
			tBest = tDist
		end
	end
	if not tBest then
		return nil, string.format("targetType='%s', %d target id(s), none resolved to a same-continent spawn", tTargetType, #tTargets)
	end
	return tBest, nil
end
NS.ResolveClosestDistance = ResolveClosestDistance

---------------------------------------------------------------------------------------------------------------------------------------
-- [2026-08-19, SIMPLIFIED per direct user feedback] Used to split into two
-- separate lists ("en cours" / "à rendre") -- the user reported quests
-- ready to turn in showing up under "en cours" regardless, found the split
-- itself unhelpful, and asked for ONE flat list of "the next thing to do
-- for each quest", sorted purely by distance ("juste tu fait des objectifs
-- quêtes en cours, suivi de par distance"). One entry per active quest log
-- quest: its turn-in location if ready (isComplete==1), otherwise its
-- nearest unresolved objective -- `ready` is kept on each entry so the
-- label can still say which kind of stop it is, without it affecting where
-- the entry sorts. Skips header rows and any questID SkuDB's own database
-- doesn't know about (logged, not errored -- data coverage gaps must
-- degrade gracefully, same principle as every other addon in this family).
local function ScanQuestObjectives(aCtx)
	local tList = {}
	local tNumEntries = GetNumQuestLogEntries() or 0
	for tQuestLogID = 1, tNumEntries do
		local tTitle, tLevel, tSuggestedGroup, tIsHeader, tIsCollapsed, tIsComplete, tFrequency, tQuestID =
			GetQuestLogTitle(tQuestLogID)
		if not tIsHeader and tQuestID and tQuestID > 0 then
			local tOk, tErr = pcall(function()
				local tData = SkuDB.questDataTBC[tQuestID]
				if not tData then
					Log("ScanQuestObjectives: questID=%d ('%s') not in SkuDB, skipped.", tQuestID, tostring(tTitle))
					return
				end
				local tReady = (tIsComplete == 1)
				local tSubTable = tReady and tData[SkuDB.questKeys["finishedBy"]] or tData[SkuDB.questKeys["objectives"]]
				local tDist, tWhy = ResolveClosestDistance(aCtx, tQuestID, tSubTable)
				-- [2026-08-19] "Je veux qu'à chaque fois la distance soit
				-- affichée" -- when the objective itself can't be resolved at
				-- all (a pure "return to NPC" quest with no separate kill/
				-- interact target, or an item whose sources SkuDB doesn't
				-- know either), fall back to the QUEST GIVER's own position
				-- as a still-genuinely-relevant "next place to go" rather
				-- than showing nothing -- doesn't change `ready`/the label
				-- (still shown as "objectif", the quest genuinely isn't
				-- done), just borrows a position. Not attempted for already-
				-- complete quests -- finishedBy is already the primary
				-- source there, nothing left to fall back to.
				local tUsedFallback = false
				if not tDist and not tReady then
					local tFallbackDist, tFallbackWhy = ResolveClosestDistance(aCtx, tQuestID, tData[SkuDB.questKeys["startedBy"]])
					if tFallbackDist then
						tDist = tFallbackDist
						tUsedFallback = true
						tWhy = "objective unresolved (" .. tostring(tWhy) .. "), used quest-giver fallback"
					else
						tWhy = tostring(tWhy) .. "; quest-giver fallback also failed (" .. tostring(tFallbackWhy) .. ")"
					end
				end
				-- [2026-08-19, DIAGNOSTIC] "les distances sont pas optimisées" --
				-- logged EVERY resolution attempt, success or not.
				-- [2026-08-27] Narrowed to failures only. The success case ran
				-- once per quest per scan (~35 lines per open with a full log)
				-- and rolled the 500-entry cap, taking real diagnostics with
				-- it. A resolved distance is visible in the menu itself, so
				-- logging it added nothing; an UNRESOLVED one is invisible to
				-- the player and is exactly what this line exists to explain,
				-- so that case still logs, with its reason.
				if not tDist then
					Log("ScanQuestObjectives: questID=%d ('%s') ready=%s unresolved%s", tQuestID, tostring(tTitle), tostring(tReady),
						tWhy and (" (" .. tWhy .. ")") or "")
				end
				local tDistance = tDist or UNKNOWN_DISTANCE
				-- [2026-08-19] usedGiverFallback quests sort behind every REAL
				-- objective/turn-in distance -- see FALLBACK_SORT_PENALTY's own
				-- comment above. distance (shown/spoken) stays the true value;
				-- sortDistance (sort key only) is the one with the penalty.
				local tSortDistance = tUsedFallback and (tDistance + FALLBACK_SORT_PENALTY) or tDistance
				table.insert(tList, { questId = tQuestID, title = tTitle, level = tLevel, distance = tDistance, sortDistance = tSortDistance, ready = tReady, usedGiverFallback = tUsedFallback })
			end)
			if not tOk then Log("ScanQuestObjectives: questID=%d THREW: %s", tQuestID, tostring(tErr)) end
		end
	end
	table.sort(tList, function(a, b) return a.sortDistance < b.sortDistance end)
	Log("ScanQuestObjectives: %d quest(s) total.", #tList)
	return tList
end
NS.ScanQuestObjectives = ScanQuestObjectives

-- [2026-08-22, REMOVED] ScanAvailableToAccept (backed a "Quêtes à accepter
-- à proximité" menu entry) -- user pointed out Sku's own native
-- "Questdatenbank" menu already has this, distance-sorted, out of the box
-- (SkuQuest/Options.lua's "Questdatenbank" -> "Start in Zone" -> "By
-- distance" sorts the EXACT SAME SkuQuest:GetUnsortedAvailableQuestsTable()
-- this function just wrapped a presentation layer around). Confirmed by
-- reading that Sku code directly, not assumed. Pure duplication -- see
-- Menu.lua's own removal comment for the full story.
