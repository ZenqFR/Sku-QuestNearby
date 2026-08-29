-- SkuQuestNearby/Tracking.lua -- [2026-08-22] "une option pour arrêter le
-- suivi de certaines quêtes et ne plus avoir les infos questes sur la
-- minimap" -- WoW's own quest-tracking system (`AddQuestWatch` /
-- `RemoveQuestWatch`) controls both the on-screen objective tracker AND the
-- minimap/world-map quest POI markers for a given quest -- untracking a
-- quest is exactly what removes its markers from the minimap, no extra
-- addon-side hiding logic needed. Sku itself has no accessible way to reach
-- this toggle at all (confirmed by grepping its whole source for
-- "QuestWatch" -- zero hits), so it's added here.
--
-- Injected into the quest-detail submenu (Annahme/Ziel/Abgabe) via
-- `hooksecurefunc(SkuQuest, "CreateQuestSubmenu", ...)`.
--
-- [2026-08-27, SCOPE CORRECTED] This header used to claim Sku's own
-- "Quêtes actuelles" got the toggle "for free" as well. That was wrong, and
-- checking Sku's source settles it: the real builder is a CHUNK-LOCAL
-- `CreateQuestSubmenu` (Sku/SkuQuest/Options.lua:1632) and every one of
-- Sku's own call sites (lines 2140, 2159, 2278, 2338, 2388) calls that
-- local DIRECTLY. `SkuQuest:CreateQuestSubmenu` (:1781) is only a thin
-- public wrapper, and the sole caller that actually goes through it is this
-- addon's own Menu.lua. A hook on the wrapper therefore reaches THIS
-- ADDON'S list only -- which is still the useful case, but it is not the
-- addon-wide reach previously claimed. Do not re-advertise it as such.
--
-- "Questdatenbank" (not-yet-accepted quests) is deliberately excluded -- a
-- quest not in your log yet has no watch state to toggle, checked via the
-- log-index lookup before ever injecting the entry.
local ADDON_NAME, NS = ...
if NS.SkuMissing then return end
local Log, Announce = NS.Log, NS.Announce

local LABEL_TRACK = Sku.deEn and Sku.deEn("Diese Quest verfolgen", "Track this quest", "Suivre cette quête") or "Suivre cette quête"
local LABEL_UNTRACK = Sku.deEn and Sku.deEn("Diese Quest nicht mehr verfolgen", "Stop tracking this quest", "Ne plus suivre cette quête") or "Ne plus suivre cette quête"
local SAY_TRACKED = Sku.deEn and Sku.deEn("Quest wird verfolgt", "Now tracking this quest", "Quête suivie") or "Quête suivie"
local SAY_UNTRACKED = Sku.deEn and Sku.deEn("Quest wird nicht mehr verfolgt", "No longer tracking this quest", "Quête plus suivie") or "Quête plus suivie"

-- Same refresh-in-place technique the sibling addons already use for their
-- own toggle-style entries ([[sku-bagnon-bridge-addon]]'s Transfer.lua,
-- [[sku-gather-route-addon]]'s multi-select checklist): SkuGenericMenuItem's
-- own OnUpdate matches the acted-on entry back up by NAME against the
-- freshly-rebuilt list, so `.name` has to be set to the POST-toggle label
-- BEFORE calling OnUpdate, or the cursor silently snaps back to the top.
local function TryRefreshCurrentMenuList()
	local tOk = pcall(function()
		local tPos = SkuOptions and SkuOptions.currentMenuPosition
		if not tPos or not tPos.parent then return end
		if type(tPos.parent.BuildChildren) ~= "function" then return end
		if tPos.OnUpdate then tPos:OnUpdate() end
	end)
	if not tOk then Log("TryRefreshCurrentMenuList: threw, ignored.") end
end

-- [2026-08-27, ROOT CAUSE -- this feature had NEVER worked] The first cut
-- was written against `C_QuestLog.AddQuestWatch/RemoveQuestWatch/
-- GetQuestWatchType/GetLogIndexForQuestID` -- the Shadowlands-era RETAIL
-- API. None of those exist on this TBC-Anniversary client, so the guard
-- below tripped on every login and the whole feature silently did nothing.
-- Proven from this player's own log, not deduced:
--     "InstallTrackingToggle: C_QuestLog watch API not found on this
--      client, skipped."
-- The correct API here is the Classic one: plain GLOBALS taking a QUEST LOG
-- INDEX, not a questID -- `AddQuestWatch(index)`, `RemoveQuestWatch(index)`,
-- `IsQuestWatched(index)`. Confirmed in active use by Questie on this exact
-- install (Questie/Modules/Tracker/QuestieTracker.lua), which is the same
-- kind of cross-check that settled the GetTTSText log-index question in
-- Menu.lua. The questID -> index resolution reuses Menu.lua's own already-
-- proven FindQuestLogIndex rather than a second copy.
local function InstallTrackingToggle()
	if not SkuQuest.CreateQuestSubmenu then
		Log("InstallTrackingToggle: SkuQuest:CreateQuestSubmenu does not exist, skipped.")
		return
	end
	if type(_G.AddQuestWatch) ~= "function" or type(_G.RemoveQuestWatch) ~= "function" or type(_G.IsQuestWatched) ~= "function" then
		Log("InstallTrackingToggle: Classic quest-watch API (AddQuestWatch/RemoveQuestWatch/IsQuestWatched) not found, skipped.")
		return
	end
	hooksecurefunc(SkuQuest, "CreateQuestSubmenu", function(self, aParent, aQuestID)
		-- hooksecurefunc cannot be undone, so honouring Sku's Features toggle
		-- has to happen here, per call -- same guard Menu.lua's MenuBuilder
		-- hook uses. Without it, disabling this addon still injected the
		-- tracking entry into Sku's own quest submenu.
		if NS.SkuQuestNearby and NS.SkuQuestNearby.IsEnabled and not NS.SkuQuestNearby:IsEnabled() then return end
		if not aParent or not aQuestID then return end
		local tOk, tErr = pcall(function()
			-- Resolved fresh on every menu build AND again inside OnAction --
			-- the log can reorder (a quest turned in shifts every index after
			-- it), so an index captured at build time can go stale before the
			-- player actually presses the entry.
			local tLogIndex = NS.FindQuestLogIndex and NS.FindQuestLogIndex(aQuestID)
			if not tLogIndex then
				return -- not in the player's current log -- nothing to toggle
			end

			local function tCurrentLabel()
				local tIdx = NS.FindQuestLogIndex and NS.FindQuestLogIndex(aQuestID)
				if not tIdx then return LABEL_TRACK, false end
				local tOkWatch, tIsWatched = pcall(_G.IsQuestWatched, tIdx)
				tIsWatched = tOkWatch and tIsWatched == true
				return (tIsWatched and LABEL_UNTRACK or LABEL_TRACK), tIsWatched
			end

			local tLabel = tCurrentLabel()
			local tEntry = SkuOptions:InjectMenuItems(aParent, { tLabel }, SkuGenericMenuItem)
			tEntry.OnAction = function(self2)
				local _, tWasWatched = tCurrentLabel()
				local tIdx = NS.FindQuestLogIndex and NS.FindQuestLogIndex(aQuestID)
				if not tIdx then
					Log("TrackingToggle: questID=%d no longer in the quest log, ignored.", aQuestID)
					return
				end
				local tOkToggle, tErrToggle = pcall(function()
					if tWasWatched then
						_G.RemoveQuestWatch(tIdx)
					else
						_G.AddQuestWatch(tIdx)
					end
				end)
				if not tOkToggle then
					Log("TrackingToggle: OnAction THREW for questID=%d (index=%d): %s", aQuestID, tIdx, tostring(tErrToggle))
					return
				end
				local tNewLabel, tNowWatched = tCurrentLabel()
				self2.name = tNewLabel
				Announce(tNowWatched and SAY_TRACKED or SAY_UNTRACKED)
				Log("TrackingToggle: questID=%d (index=%d) now watched=%s.", aQuestID, tIdx, tostring(tNowWatched))
				TryRefreshCurrentMenuList()
			end
		end)
		if not tOk then Log("InstallTrackingToggle hook: THREW for questID=%s: %s", tostring(aQuestID), tostring(tErr)) end
	end)
	Log("InstallTrackingToggle: hooked SkuQuest:CreateQuestSubmenu (Classic quest-watch API).")
end
NS.InstallTrackingToggle = InstallTrackingToggle
