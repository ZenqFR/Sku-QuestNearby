-- SkuQuestNearby/Target.lua -- decides WHERE the quest beacon points.
--
-- [2026-08-29, SOURCE CHANGED ON PURPOSE] The first cut of this fed the beacon
-- from SkuDB, through this addon's own Proximity.lua. That was wrong, and the
-- user caught it before it shipped: **SkuDB's `objectives` sub-table is static
-- quest data. It does not know which objectives you have already finished.**
-- On a "kill 10 boars, collect 8 hides" quest with the boars already done, the
-- SkuDB path would happily aim the beacon back at the boars.
--
-- Questie does know. DistanceUtils.GetNearestSpawnForQuest walks
-- quest.Objectives AND quest.SpecialObjectives and skips any objective where
-- `Needed == Collected`, and short-circuits to the quest's Finisher as soon as
-- `quest:IsComplete() == 1`. That is exactly "an objective still to do, or a
-- quest to hand in, never something already done" -- and it is the same data
-- Questie draws on the world map and minimap, so the beacon and the map now
-- agree by construction instead of by coincidence.
--
-- COORDINATE SPACE -- the one real trap here. Questie returns zone-relative
-- coordinates (0-100) plus an AreaId, and measures distance with its own
-- HereBeDragons copy. SkuBeacon wants world coordinates in the space
-- UnitPosition("player") reports. Rather than assume HBD's world space and
-- Blizzard's agree, the conversion is done with SKU'S OWN path --
-- SkuNav.Geo:GetUiMapIdFromAreaId + C_Map.GetWorldPosFromMapPos -- the exact
-- call Proximity.lua already uses to produce coordinates it then compares
-- against the player's own position. Data from Questie, geometry from Sku.
--
-- Falls back to the SkuDB path when Questie is absent or not finished loading,
-- so the beacon still works (less precisely) rather than refusing to start.
local ADDON_NAME, NS = ...
if NS.SkuMissing then return end
local Log = NS.Log

-- Questie's public functions are DOT functions (QuestieDB.GetQuest,
-- DistanceUtils.GetNearestSpawnForQuest). Calling them with a colon passes the
-- module table as the first argument and silently breaks the call -- Sku's own
-- SkuQuest/Options.lua documents this exact trap. Every call below is a dot
-- call inside a pcall, so a Questie API change degrades to the fallback rather
-- than erroring into the beacon loop.
local function tQuestieModules()
	if not SkuQuest or not SkuQuest.QuestieModule or not SkuQuest.QuestieReady then return nil end
	if not SkuQuest:QuestieReady() then return nil end
	local tDU = SkuQuest:QuestieModule("DistanceUtils")
	local tQDB = SkuQuest:QuestieModule("QuestieDB")
	if not tDU or not tQDB then return nil end
	-- The two LOWER-LEVEL entry points are what this file uses, not
	-- GetNearestSpawnForQuest -- see tNearestStopForQuest below for why.
	if type(tDU.GetNearestObjective) ~= "function" then return nil end
	if type(tDU.GetNearestFinisherOrStarter) ~= "function" then return nil end
	if type(tQDB.GetQuest) ~= "function" then return nil end
	return tDU, tQDB
end

-- [2026-08-29, ROOT CAUSE of "la balise s'est mise sur rendre la quête alors
-- qu'elle n'est pas finie"] This used to call
-- DistanceUtils.GetNearestSpawnForQuest, which opens with:
--
--     if quest:IsComplete() == 1 then
--         return DistanceUtils.GetNearestFinisherOrStarter(quest.Finisher)
--     end
--
-- and QuestieDB.IsComplete ends with an `or` chain whose LAST term is a bare
-- `1`:
--
--     questLogEntry and (questLogEntry.isComplete
--         or (questLogEntry.objectives[1] and 0)
--         or (#questLogEntry.objectives == 0 and noQuestItem and 0)
--         or 1) or 0
--
-- When Questie's QuestLogCache has no objectives for a quest yet -- it is
-- filled asynchronously, so this is a normal transient state after login or
-- right after accepting -- and the quest has a source item, every earlier term
-- is falsy and the chain falls through to `1`: COMPLETE. Questie's own
-- reasoning is "no objectives means a talk-to-an-NPC quest, which is complete
-- on pickup", which is right for those quests and wrong for every other quest
-- caught mid-cache-fill. The beacon then aims at the turn-in NPC for a quest
-- with work still to do.
--
-- WoW's own GetQuestLogTitle already tells us the truth, and it is
-- authoritative. So the completion decision is taken HERE, from that flag, and
-- Questie is asked only for POSITIONS -- the finisher when WoW says complete,
-- the unfinished objectives otherwise. The unfinished filter
-- (`Needed ~= Collected`) is Questie's own, copied from GetNearestSpawnForQuest
-- so behaviour matches what Questie draws on the map.
--
-- If WoW says the quest is NOT complete and no objective resolves to a
-- position, this returns nothing for that quest rather than falling back to
-- the finisher. Pointing at the turn-in for unfinished work is precisely the
-- bug being fixed; a silent skip lets another quest win instead.
-- [2026-08-29, SECOND ROOT CAUSE -- my own regression] The filter above was
-- first written against the quest object returned by QuestieDB.GetQuest. That
-- is the STATIC database entry: its objectives carry no progress at all.
-- Collected / Needed / Completed are written by QuestieQuest's own Update onto
-- the LIVE object kept in QuestiePlayer.currentQuestlog[questId].
--
-- On a static object `Needed` is nil, so `(not objective.Needed)` is TRUE and
-- every objective passed the filter -- finished ones included. The exact
-- defect this whole file exists to avoid, reintroduced one layer down.
--
-- So: live object or nothing. If Questie has no live entry for a quest (during
-- its database rebuild, or before it has processed the log) we deliberately
-- report failure and let the caller fall back, rather than answering from data
-- that cannot tell done from not-done. "source=questie" now always means the
-- answer was based on real progress.
--
-- currentQuestlog is also type-checked: Questie has a branch that stores a
-- NUMBER there instead of the quest table (its own source comment marks it
-- "TODO FIX LATER"), and indexing that would throw.
local function tLiveQuest(aQDB, aQuestID)
	local tPlayer = SkuQuest and SkuQuest.QuestieModule and SkuQuest:QuestieModule("QuestiePlayer")
	if tPlayer and type(tPlayer.currentQuestlog) == "table" then
		local tQ = tPlayer.currentQuestlog[aQuestID]
		if type(tQ) == "table" and type(tQ.Objectives) == "table" then
			return tQ
		end
	end
	return nil
end

-- Prefers Questie's own `Completed` boolean, which it computes as
-- "Needed == Collected and Needed > 0", plus a documented hack for objectives
-- the API marks finished with no counter. Falls back to comparing the counters
-- only when both are present -- never treats "no data" as "unfinished".
local function tObjectiveUnfinished(aObjective)
	if aObjective.Completed == true then return false end
	if aObjective.Needed and aObjective.Collected and aObjective.Needed == aObjective.Collected then
		return false
	end
	return true
end

local function tNearestStopForQuest(aDU, aQuest, aWowIsComplete)
	if aWowIsComplete then
		return aDU.GetNearestFinisherOrStarter(aQuest.Finisher)
	end

	local tBestDist, tBestSpawn, tBestZone, tBestName
	local function tConsider(aObjectiveList)
		for _, tObjective in pairs(aObjectiveList or {}) do
			if tObjective.spawnList and tObjectiveUnfinished(tObjective) then
				local tSpawn, tZone, tName, tDist = aDU.GetNearestObjective(tObjective.spawnList)
				if tSpawn and tDist and ((not tBestDist) or tDist < tBestDist) then
					tBestDist, tBestSpawn, tBestZone, tBestName = tDist, tSpawn, tZone, tName
				end
			end
		end
	end
	tConsider(aQuest.Objectives)
	tConsider(aQuest.SpecialObjectives)

	return tBestSpawn, tBestZone, tBestName, tBestDist
end

-- Questie AreaId + 0-100 zone coordinates -> Sku world coordinates.
local function tToWorld(aAreaId, aX, aY)
	if not aAreaId or not aX or not aY then return nil end
	if aX == -1 or aY == -1 then return nil end
	local tUiMapId = SkuNav.Geo:GetUiMapIdFromAreaId(aAreaId)
	if not tUiMapId then return nil end
	local tOk, tContinentId, tWorldPos = pcall(C_Map.GetWorldPosFromMapPos, tUiMapId,
		CreateVector2D(tonumber(aX) / 100, tonumber(aY) / 100))
	if not tOk or not tWorldPos then return nil end
	local tWx, tWy = tWorldPos:GetXY()
	if not tWx or not tWy then return nil end
	return tWx, tWy, tContinentId
end

---------------------------------------------------------------------------------------------------------------------------------------
---------------------------------------------------------------------------------------------------------------------------------------
-- [2026-08-29] Resolve ONE quest's next stop, exported so the MENU LIST uses
-- the same answer as the beacon.
--
-- Reported: the "Objectifs de quêtes proches" list showed 400m for a quest
-- whose turn-in NPC was 10m away and which was not finished. Two different
-- numbers for the same quest, from the same addon, because the two features
-- had drifted onto different data:
--
--   * the beacon reads Questie, which knows which objectives are already
--     collected;
--   * the menu list read SkuDB through Proximity.lua, which is STATIC quest
--     data and cannot tell a finished objective from an unfinished one.
--
-- Fixing only the beacon left the addon contradicting itself. Both now go
-- through here first, and only fall back to the SkuDB path when Questie is
-- absent or not finished loading.
--
-- Returns (distance, worldX, worldY, targetName) or nil plus a reason.
function NS.ResolveQuestStopViaQuestie(aCtx, aQuestID, aWowIsComplete)
	if not aCtx then return nil, "no context" end
	local tDU, tQDB = tQuestieModules()
	if not tDU then return nil, "Questie not ready" end

	-- Live object required for the objective path -- see tLiveQuest. For a
	-- COMPLETE quest only the Finisher is read, which is static data, so the
	-- DB entry is enough there.
	local tQuest = tLiveQuest(tQDB, aQuestID)
	if not tQuest then
		if not aWowIsComplete then
			return nil, "no live Questie entry (progress unknown)"
		end
		local tOkQ, tDbQuest = pcall(tQDB.GetQuest, aQuestID)
		if not tOkQ or not tDbQuest then return nil, "quest not in QuestieDB" end
		tQuest = tDbQuest
	end

	local tOk, tSpawn, tZone, tName = pcall(tNearestStopForQuest, tDU, tQuest, aWowIsComplete)
	if not tOk then return nil, "resolver threw: " .. tostring(tSpawn) end
	if not tSpawn or not tZone then return nil, "no unfinished objective with a position" end

	local tWx, tWy, tContinentId = tToWorld(tZone, tSpawn[1], tSpawn[2])
	if not tWx then return nil, "coordinates unusable" end
	if aCtx.continentId and tContinentId and tContinentId ~= aCtx.continentId then
		return nil, "other continent"
	end

	local tOkD, tDist = pcall(SkuNav.Geo.Distance, SkuNav.Geo, aCtx.playerX, aCtx.playerY, tWx, tWy)
	if not tOkD or not tDist then return nil, "distance failed" end
	return tDist, tWx, tWy, tName
end

---------------------------------------------------------------------------------------------------------------------------------------
-- [2026-08-29] Per-quest dump, because this corner has now produced two wrong
-- diagnoses in a row and guessing a third time is not a method.
--
-- Reported symptom: the beacon aimed 8m away, at the quest's TURN-IN NPC, for
-- a quest the log itself recorded as `ready=false`. The completion flag was
-- therefore NOT the problem -- something in the objective resolution returned
-- the finisher's position anyway. This prints every input that decision is
-- made from, for one quest, so the next answer is read rather than inferred.
function NS.DiagnoseQuest(aQuestID)
	local tOut = function(aFmt, ...)
		local tOk, tMsg = pcall(string.format, aFmt, ...)
		DEFAULT_CHAT_FRAME:AddMessage("|cff80c0ffQuete|r: " .. (tOk and tMsg or tostring(aFmt)))
	end

	local tCtx = NS.GetPlayerContext and NS.GetPlayerContext()
	if not tCtx then tOut("pas de contexte joueur") return end

	if not aQuestID then
		local tCur = NS.BeaconCurrentTarget and NS.BeaconCurrentTarget()
		aQuestID = tCur and tCur.questId
	end
	if not aQuestID then tOut("aucune quete indiquee et aucune cible active") return end

	local tTitle, tWowComplete
	for i = 1, (GetNumQuestLogEntries() or 0) do
		local tT, _, _, tIsHeader, _, tIsComplete, _, tQid = GetQuestLogTitle(i)
		if not tIsHeader and tQid == aQuestID then
			tTitle, tWowComplete = tT, (tIsComplete == 1)
		end
	end
	tOut("questID=%d '%s'", aQuestID, tostring(tTitle))
	tOut("WoW dit complete = %s", tostring(tWowComplete))

	local tDU, tQDB = tQuestieModules()
	if not tDU then tOut("Questie indisponible") return end

	local tQuest = tLiveQuest(tQDB, aQuestID)
	tOut("entree VIVANTE dans currentQuestlog = %s", tostring(tQuest ~= nil))
	if not tQuest then
		local tOkQ, tDb = pcall(tQDB.GetQuest, aQuestID)
		tQuest = tOkQ and tDb or nil
		tOut("repli fiche statique = %s (aucune progression dedans)", tostring(tQuest ~= nil))
	end
	if not tQuest then return end

	local function tDistanceTo(aSpawn, aZone)
		if not aSpawn or not aZone then return nil end
		local tWx, tWy = tToWorld(aZone, aSpawn[1], aSpawn[2])
		if not tWx then return nil end
		local tOkD, tD = pcall(SkuNav.Geo.Distance, SkuNav.Geo, tCtx.playerX, tCtx.playerY, tWx, tWy)
		return tOkD and tD or nil
	end

	local function tDumpList(aLabel, aList)
		local tN = 0
		for tIdx, tObj in pairs(aList or {}) do
			tN = tN + 1
			local tState = tObjectiveUnfinished(tObj) and "A FAIRE" or "termine"
			local tWhere = "pas de spawns"
			if tObj.spawnList then
				local tSpawn, tZone, tName = tDU.GetNearestObjective(tObj.spawnList)
				local tD = tDistanceTo(tSpawn, tZone)
				tWhere = tD and string.format("'%s' a %dm", tostring(tName), math.floor(tD)) or "spawns non resolus"
			end
			tOut("  %s[%s] %s  Needed=%s Collected=%s Completed=%s  %s",
				aLabel, tostring(tIdx), tState,
				tostring(tObj.Needed), tostring(tObj.Collected), tostring(tObj.Completed), tWhere)
		end
		if tN == 0 then tOut("  %s: aucun", aLabel) end
	end
	tDumpList("Objectif", tQuest.Objectives)
	tDumpList("Special", tQuest.SpecialObjectives)

	-- The finisher, for comparison: this is the position that must NOT be
	-- chosen while the quest is unfinished.
	if tQuest.Finisher then
		local tSpawn, tZone, tName = tDU.GetNearestFinisherOrStarter(tQuest.Finisher)
		local tD = tDistanceTo(tSpawn, tZone)
		tOut("LIVRAISON: '%s' a %sm", tostring(tName), tD and math.floor(tD) or "?")
	end

	local tDist, _, _, tName = NS.ResolveQuestStopViaQuestie(tCtx, aQuestID, tWowComplete)
	tOut("=> le resolveur choisit: '%s' a %sm", tostring(tName), tDist and math.floor(tDist) or "RIEN")
end

---------------------------------------------------------------------------------------------------------------------------------------
-- Nearest still-to-do stop across the whole quest log, using Questie.
-- Returns a target table shaped like ScanQuestObjectives' entries so Beacon.lua
-- does not care which source produced it.
-- [2026-08-29] This used to duplicate the whole per-quest resolution inline.
-- That duplication is exactly how the two features drifted apart in the first
-- place -- one copy was fixed, the other kept the bug. It now walks the log and
-- defers every quest to the single exported resolver, so the beacon and the
-- menu list cannot answer differently: there is only one implementation left.
local function PickFromQuestie(aCtx)
	local tDU = tQuestieModules()
	if not tDU then return nil, "Questie not ready" end

	local tBest, tConsidered, tUnresolved = nil, 0, 0
	local tNum = GetNumQuestLogEntries() or 0
	for tLogId = 1, tNum do
		local tTitle, tLevel, _, tIsHeader, _, tIsComplete, _, tQuestID = GetQuestLogTitle(tLogId)
		if not tIsHeader and tQuestID and tQuestID > 0 then
			tConsidered = tConsidered + 1
			-- WoW's flag, not Questie's IsComplete -- see tNearestStopForQuest.
			local tWowComplete = (tIsComplete == 1)
			local tDist, tWx, tWy, tName = NS.ResolveQuestStopViaQuestie(aCtx, tQuestID, tWowComplete)
			if tDist then
				if not tBest or tDist < tBest.distance then
					tBest = {
						questId = tQuestID,
						title = tTitle,
						level = tLevel,
						distance = tDist,
						-- Same flag that chose the position, so the spoken
						-- "objectif"/"à rendre" can never disagree with where the
						-- beacon actually points.
						ready = tWowComplete,
						worldX = tWx,
						worldY = tWy,
						targetName = tName,
						source = "questie",
					}
				end
			else
				tUnresolved = tUnresolved + 1
			end
		end
	end

	if not tBest then
		return nil, string.format("Questie: %d quest(s) considered, %d unresolved", tConsidered, tUnresolved)
	end
	return tBest
end

---------------------------------------------------------------------------------------------------------------------------------------
-- Fallback: this addon's own SkuDB resolution (Proximity.lua). Kept because it
-- is the only thing available without Questie, but it CANNOT tell a finished
-- objective from an unfinished one, so it is used only when Questie is not
-- there. That limitation is stated in the log every time it is used, rather
-- than quietly pretending the two sources are equivalent.
local function PickFromSkuDB(aCtx)
	local tList = NS.ScanQuestObjectives(aCtx)
	for _, tItem in ipairs(tList) do
		if tItem.worldX and tItem.worldY then
			tItem.source = "skudb"
			return tItem
		end
	end
	return nil, (#tList == 0) and "quest log empty" or "no entry resolved to coordinates"
end

---------------------------------------------------------------------------------------------------------------------------------------
local tWarnedNoQuestie = false

function NS.PickBeaconTarget()
	local tCtx = NS.GetPlayerContext and NS.GetPlayerContext()
	if not tCtx then return nil, "no player context" end

	local tTarget, tWhy = PickFromQuestie(tCtx)
	if tTarget then
		tWarnedNoQuestie = false
		return tTarget
	end

	if not tWarnedNoQuestie then
		Log("PickBeaconTarget: Questie path unavailable (%s) -- falling back to SkuDB, which CANNOT skip already-completed objectives.", tostring(tWhy))
		tWarnedNoQuestie = true
	end
	local tFallback, tFallbackWhy = PickFromSkuDB(tCtx)
	if tFallback then return tFallback end
	return nil, string.format("%s; SkuDB fallback: %s", tostring(tWhy), tostring(tFallbackWhy))
end
