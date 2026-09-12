-- SkuQuestNearby/Menu.lua -- injects one entry directly into Sku's own
-- "Quêtes" root menu (the same one hosting "Aktuelle Quests"/
-- "Questdatenbank"): "Objectifs de quêtes proches" (one flat, distance-
-- sorted list -- both in-progress objectives and ready-to-turn-in stops
-- together, per the user's explicit request to simplify away an earlier
-- 3-way split).
--
-- [2026-08-19, SIMPLIFIED] Previously one root entry with three nested
-- sub-lists (en cours / à rendre / à accepter). User feedback: the split
-- itself wasn't working ("j'ai des quêtes à rendre... qui sont dans quêtes
-- en cours"), felt over-complicated, and didn't match Sku's own menu depth.
-- Flattened to two entries (this one plus a since-removed "Quêtes à
-- accepter à proximité", see the 2026-08-22 REMOVED note below), each
-- listing its quests DIRECTLY as children (no intermediate grouping level)
-- -- same depth as Sku's own "Aktuelle Quests" -> "Alle" -> quest, minus
-- the "Alle" grouping step this addon never needed in the first place.
--
-- [2026-08-22, REMOVED] "Quêtes à accepter à proximité" -- user pointed
-- out Sku's own native "Questdatenbank" menu ALREADY has this, distance-
-- sorted, out of the box: SkuQuest/Options.lua's own "Questdatenbank" ->
-- "Start in Zone" -> "By distance" entry sorts `GetUnsortedAvailableQuestsTable()`
-- by distance -- the EXACT SAME function this addon's own (now-removed)
-- `ScanAvailableToAccept`/`BuildAvailableChildren` just wrapped a
-- presentation layer around. Confirmed by reading that Sku code directly,
-- not assumed. Pure duplication, removed rather than kept as a second way
-- to reach the identical list.
--
-- Sku registers that whole menu declaratively: SkuZOptions/SkuMenu.lua does
-- `SkuMenu:RegisterModule("SkuQuest", { ..., build = function(entry)
-- SkuQuest:MenuBuilder(entry) end })`. MenuBuilder accumulates its own
-- entries into a local `tSpecs` table and finishes with one
-- `SkuMenu:Build(aParentEntry, tSpecs)` call -- that local table isn't
-- reachable from outside, so hooksecurefunc can't append to IT. Instead,
-- this hooks MenuBuilder itself (hooksecurefunc runs AFTER the original,
-- once aParentEntry already has its real children from SkuMenu:Build) and
-- adds entries directly onto aParentEntry via SkuOptions:InjectMenuItems --
-- the exact same low-level primitive every list entry in SkuQuest/
-- Options.lua already uses to build its own children, including from
-- BuildChildren callbacks that by definition run well after the parent's
-- own initial construction. If this assumption ever turns out wrong on a
-- Sku update, the whole hook is pcall-guarded and logs instead of erroring
-- Sku's own quest menu.
local ADDON_NAME, NS = ...
if NS.SkuMissing then return end
local Log, DifficultyLabel, Announce = NS.Log, NS.DifficultyLabel, NS.Announce
local UNKNOWN_DISTANCE = NS.UNKNOWN_DISTANCE

local LABEL_OBJECTIVE = Sku.deEn and Sku.deEn("Ziel", "objective", "objectif") or "objectif"
local LABEL_TURNIN = Sku.deEn and Sku.deEn("Abgabe", "turn in", "à rendre") or "à rendre"
-- [2026-08-19] "Je suis près du donneur... mais l'objectif n'est pas
-- terminé... la distance me montre le PNJ donneur" -- the quest-giver
-- fallback (Proximity.lua's own FALLBACK_SORT_PENALTY comment has the full
-- story) reports a REAL position, but it is NOT the actual unfinished
-- objective, just the closest thing this addon could find any position
-- for at all. Said explicitly in the label now so a nearby small distance
-- is never mistaken for "the objective is basically done" when it's really
-- "here's the quest giver, the real objective is still unresolved".
local LABEL_APPROX = Sku.deEn and Sku.deEn("Questgeber, ungefähr", "quest giver, approximate", "PNJ donneur, approximatif") or "PNJ donneur, approximatif"

local function FormatObjectiveLabel(aItem)
	local tParts = {}
	if aItem.distance and aItem.distance < UNKNOWN_DISTANCE then
		tParts[#tParts + 1] = string.format("%dm", math.floor(aItem.distance))
	end
	tParts[#tParts + 1] = aItem.ready and LABEL_TURNIN or LABEL_OBJECTIVE
	if aItem.usedGiverFallback then
		tParts[#tParts + 1] = LABEL_APPROX
	end
	local tDiff = aItem.level and DifficultyLabel(aItem.level)
	if tDiff then tParts[#tParts + 1] = tDiff end
	return aItem.title .. " (" .. table.concat(tParts, ", ") .. ")"
end

-- De-duplicates a label against every label already used in THIS list (two
-- quest chain steps can share the exact same title -- SkuDB's own data has
-- real examples of this, e.g. "Die Volksmiliz" x3) by appending a running
-- counter, same convention Sku's own "Aktuelle Quests"/"Questdatenbank"
-- lists use for the identical reason.
local function Uniquify(aNameCache, aLabel)
	if aNameCache[aLabel] then
		aNameCache[aLabel] = aNameCache[aLabel] + 1
		return aLabel .. " " .. aNameCache[aLabel]
	end
	aNameCache[aLabel] = 0
	return aLabel
end

-- [2026-08-19, ROOT CAUSE] "Shift+flèche du bas fait rien" in Objectifs de
-- quêtes proches, but works fine in Quêtes à accepter à proximité. Traced by
-- reading SkuQuest:GetTTSText's own source (Sku/SkuQuest/Core.lua) and its
-- only two real call sites (Sku/SkuQuest/Options.lua, "Aktuelle Quests"):
-- GetTTSText does NOT take a real quest ID at all -- despite the parameter
-- being misleadingly named aQuestID, it's used as a QUEST LOG INDEX
-- (`SelectQuestLogEntry(questID)` / `GetQuestLogTitle(questID)`, the old
-- Classic/TBC index-based API, 1..GetNumQuestLogEntries()). Sku's own list
-- gets this right for free because it's BUILT by looping
-- `for questLogID = 1, numEntries do ... end` and stashing that loop index
-- as `questLogId` on each entry, passed straight into GetTTSText. This
-- addon's own list is built from SkuDB by REAL quest ID (e.g. 1489), which
-- is always far outside the log's 1..~30 index range -- GetQuestLogTitle on
-- an out-of-range index silently returns nil, GetTTSText hits its own early
-- `if not questLogTitleText then return end` and returns NOTHING, no error,
-- nothing to read -- exactly the silent "does nothing" the user reported.
-- Fixed by resolving each questID's CURRENT log index at OnEnter time (the
-- log can reorder between menu build and the keypress) via FindQuestLogIndex
-- below, then passing THAT into GetTTSText instead of the real questID.
local function FindQuestLogIndex(aQuestID)
	local tNum = GetNumQuestLogEntries()
	for i = 1, tNum do
		local _, _, _, tIsHeader, _, _, _, tId = GetQuestLogTitle(i)
		if not tIsHeader and tId == aQuestID then
			return i
		end
	end
	return nil
end
-- [2026-08-27] Exported for Tracking.lua, which needs the same questID ->
-- log-index resolution: this client's quest-watch API is the Classic
-- index-based one (AddQuestWatch(index)), not the retail questID-based
-- C_QuestLog.* family. Menu.lua loads before Tracking.lua per the .toc.
NS.FindQuestLogIndex = FindQuestLogIndex

local EMPTY_LABEL = Sku.deEn and Sku.deEn("Keine", "None", "Aucune") or "Aucune"
local LABEL_OBJECTIVES_ROOT = Sku.deEn and Sku.deEn("Nahe Questziele", "Nearby quest objectives", "Objectifs de quêtes proches") or "Objectifs de quêtes proches"

local function BuildObjectivesChildren(aParent)
	local tCtx = NS.GetPlayerContext()
	if not tCtx then
		SkuOptions:InjectMenuItems(aParent, { Sku.deEn and Sku.deEn("Position unbekannt", "Position unknown", "Position inconnue") or "Position inconnue" }, SkuGenericMenuItem)
		return
	end
	local tList = NS.ScanQuestObjectives(tCtx)
	if #tList == 0 then
		SkuOptions:InjectMenuItems(aParent, { EMPTY_LABEL }, SkuGenericMenuItem)
		return
	end
	local tNameCache = {}
	for _, tItem in ipairs(tList) do
		local tQuestID = tItem.questId
		local tLabel = Uniquify(tNameCache, FormatObjectiveLabel(tItem))
		local tEntry = SkuOptions:InjectMenuItems(aParent, { tLabel }, SkuGenericMenuItem)
		tEntry.dynamic = true
		-- Same OnEnter Sku's own "Aktuelle Quests" uses for the description
		-- read out on Shift+DownArrow -- every entry here IS a real quest log
		-- entry, so GetTTSText always applies (unlike the not-yet-accepted
		-- list below, which needs a different source).
		-- [2026-08-19, DIAGNOSTIC] "Shift+flèche du bas fait rien" -- was
		-- silently swallowing a GetTTSText failure (pcall's tOk simply never
		-- checked). Now always logs, so a next /reload shows whether OnEnter
		-- fires at all for this entry and, if it does, whether GetTTSText
		-- itself is throwing or just returning something unreadable.
		tEntry.OnEnter = function(self)
			-- [2026-08-19] GetTTSText needs the quest's LOG INDEX, not its
			-- real quest ID -- see the FindQuestLogIndex comment above for
			-- the full root-cause trace. Resolved fresh on every OnEnter
			-- (not cached at build time) since the log's index order can
			-- shift between opening this list and pressing Shift+DownArrow.
			local tLogIndex = FindQuestLogIndex(tQuestID)
			if not tLogIndex then
				Log("BuildObjectivesChildren: OnEnter -- questID=%d not found in the current quest log (index lookup failed).", tQuestID)
				return
			end
			local tOk, tText = pcall(SkuQuest.GetTTSText, SkuQuest, tLogIndex)
			if tOk then
				SkuOptions.currentMenuPosition.textFull = tText
				Log("BuildObjectivesChildren: OnEnter -- GetTTSText for questID=%d (logIndex=%d) returned %s chars.", tQuestID, tLogIndex, tostring(tText and #tText or 0))
			else
				Log("BuildObjectivesChildren: OnEnter -- GetTTSText THREW for questID=%d (logIndex=%d): %s", tQuestID, tLogIndex, tostring(tText))
			end
		end
		-- Same public wrapper SkuQuest's own quest log uses for quest detail
		-- children (Annahme/Ziel/Abgabe/Pre Quests/Share/An Chat schicken) --
		-- identical submenu content to "Quêtes actuelles".
		tEntry.BuildChildren = function(self)
			local tOk, tErr = pcall(SkuQuest.CreateQuestSubmenu, SkuQuest, self, tQuestID)
			if not tOk then Log("BuildObjectivesChildren: CreateQuestSubmenu THREW for questID=%d: %s", tQuestID, tostring(tErr)) end
		end
	end
end

---------------------------------------------------------------------------------------------------------------------------------------
-- [2026-08-29] Quest beacon submenu. Kept to four plain actions rather than a
-- settings tree: the sound set and volume are deliberately NOT duplicated here
-- -- the beacon reuses whatever the player already configured for Sku's own
-- navigation beacons (SkuNav), so there is exactly one place to tune how a
-- beacon sounds instead of two that can disagree.
local LABEL_BEACON_ROOT = Sku.deEn and Sku.deEn("Questbake", "Quest beacon", "Balise de quête") or "Balise de quête"

local function BuildBeaconChildren(aParent)
	local tRunning = NS.BeaconIsRunning and NS.BeaconIsRunning()
	local tToggleLabel = tRunning
		and (Sku.deEn and Sku.deEn("Bake ausschalten", "Turn beacon off", "Éteindre la balise") or "Éteindre la balise")
		or (Sku.deEn and Sku.deEn("Bake einschalten", "Turn beacon on", "Allumer la balise") or "Allumer la balise")

	local tToggle = SkuOptions:InjectMenuItems(aParent, { tToggleLabel }, SkuGenericMenuItem)
	tToggle.OnAction = function() pcall(NS.ToggleBeacon) end

	local tWhere = SkuOptions:InjectMenuItems(aParent, {
		Sku.deEn and Sku.deEn("Aktuelles Ziel ansagen", "Announce current target", "Annoncer la cible actuelle") or "Annoncer la cible actuelle"
	}, SkuGenericMenuItem)
	tWhere.OnAction = function() pcall(NS.AnnounceBeaconDistance) end

	local tTurn = SkuOptions:InjectMenuItems(aParent, {
		Sku.deEn and Sku.deEn("Zum Ziel drehen", "Turn to target", "Se tourner vers la cible") or "Se tourner vers la cible"
	}, SkuGenericMenuItem)
	tTurn.OnAction = function() pcall(NS.TurnToBeaconTarget) end

	-- Both keys get their own rebind + reset row. Built from one table rather
	-- than four hand-written entries so a third binding, if one ever appears,
	-- is one line here.
	local tRows = {
		{ which = "toggle",   label = Sku.deEn and Sku.deEn("Taste: an/aus", "Key: on/off", "Touche : marche/arrêt") or "Touche : marche/arrêt" },
		{ which = "turn",     label = Sku.deEn and Sku.deEn("Taste: drehen", "Key: turn", "Touche : se tourner") or "Touche : se tourner" },
		{ which = "distance", label = Sku.deEn and Sku.deEn("Taste: Entfernung", "Key: distance", "Touche : distance") or "Touche : distance" },
	}
	for _, tRow in ipairs(tRows) do
		local tKey = NS.GetConfiguredBeaconKey and NS.GetConfiguredBeaconKey(tRow.which) or "?"
		local tRebind = SkuOptions:InjectMenuItems(aParent, { tRow.label .. " : " .. tKey }, SkuGenericMenuItem)
		tRebind.OnAction = function()
			if not NS.CaptureBeaconKey then return end
			NS.CaptureBeaconKey(tRow.which, function(aNewKey)
				if aNewKey then
					Announce((Sku.deEn and Sku.deEn("Neue Taste", "New key", "Nouvelle touche") or "Nouvelle touche") .. " " .. aNewKey)
				end
			end)
		end

		local tReset = SkuOptions:InjectMenuItems(aParent, {
			(Sku.deEn and Sku.deEn("Standard", "Default", "Par défaut") or "Par défaut") .. " : " .. tRow.label
		}, SkuGenericMenuItem)
		tReset.OnAction = function()
			if not NS.ResetBeaconKey then return end
			local tDefault = NS.ResetBeaconKey(tRow.which)
			Announce((Sku.deEn and Sku.deEn("Standardtaste", "Default key", "Touche par défaut") or "Touche par défaut") .. " " .. tostring(tDefault))
		end
	end
end

---------------------------------------------------------------------------------------------------------------------------------------
local function InstallMenuEntry()
	if not SkuQuest.MenuBuilder then
		Log("InstallMenuEntry: SkuQuest:MenuBuilder does not exist, skipped.")
		return
	end
	hooksecurefunc(SkuQuest, "MenuBuilder", function(self, aParentEntry)
		if NS.SkuQuestNearby and NS.SkuQuestNearby.IsEnabled and not NS.SkuQuestNearby:IsEnabled() then return end
		if not aParentEntry then return end
		local tOk, tErr = pcall(function()
			local tObjectivesEntry = SkuOptions:InjectMenuItems(aParentEntry, { LABEL_OBJECTIVES_ROOT }, SkuGenericMenuItem)
			tObjectivesEntry.dynamic = true
			tObjectivesEntry.sorting = true
			tObjectivesEntry.BuildChildren = function(self2) BuildObjectivesChildren(self2) end

			-- [2026-08-29] Quest beacon (Beacon.lua). Sits next to the objective
			-- list because it answers the same question -- "where do I go next"
			-- -- just continuously and by ear instead of as a list to read.
			local tBeaconEntry = SkuOptions:InjectMenuItems(aParentEntry, { LABEL_BEACON_ROOT }, SkuGenericMenuItem)
			tBeaconEntry.dynamic = true
			tBeaconEntry.BuildChildren = function(self2) BuildBeaconChildren(self2) end
		end)
		if not tOk then Log("InstallMenuEntry hook: THREW: %s", tostring(tErr)) end
	end)
	Log("InstallMenuEntry: hooked SkuQuest:MenuBuilder.")
end
NS.InstallMenuEntry = InstallMenuEntry
