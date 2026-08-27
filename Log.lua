-- SkuQuestNearby/Log.lua -- self-diagnostic log, same proven pattern as
-- SkuGatherRoute and SkuBagnonBridge's own Log.lua.
--
-- SkuQuestNearbyLog (SavedVariable, declared in the .toc). Every meaningful
-- decision point across this addon's files writes a timestamped,
-- pcall-guarded entry here, so ground truth can be read straight off disk
-- after a single relog --
--   WTF\Account\<account>\SavedVariables\SkuQuestNearbyLog.lua
-- -- or in-game via /sqnlog, without depending on the user noticing/copying
-- chat output.
--
-- CAVEAT (same one every other addon in this family documents): WoW
-- restores a SavedVariable's table AFTER this file finishes executing, so
-- anything written to the SkuQuestNearbyLog global DURING this file's own
-- top-level execution would be silently discarded a moment later when the
-- real saved table replaces it. Entries logged before that swap are
-- buffered locally and flushed on this addon's own ADDON_LOADED.
local ADDON_NAME, NS = ...

local tLogBuffer = {}
local tLogFlushed = false

-- [2026-08-27] The log slash-command output was the last French-only
-- user-facing text in this addon family -- accent-stripped ASCII at that.
-- Localized like everything else. Guarded on Sku existing, because this
-- code loads BEFORE Core.lua's own Sku-presence check.
local function tLogL(aDe, aEn, aFr)
	return (Sku and Sku.deEn and Sku.deEn(aDe, aEn, aFr)) or aFr
end

local function Log(aFmt, ...)
	local tOk, tMsg = pcall(string.format, aFmt, ...)
	if not tOk then tMsg = tostring(aFmt) end
	local tLine = "[" .. ((date and date("%H:%M:%S")) or "?") .. "] " .. tMsg
	if tLogFlushed then
		table.insert(SkuQuestNearbyLog, tLine)
		while #SkuQuestNearbyLog > 500 do table.remove(SkuQuestNearbyLog, 1) end
	else
		table.insert(tLogBuffer, tLine)
	end
end
NS.Log = Log

local tLogFrame = CreateFrame("Frame")
tLogFrame:RegisterEvent("ADDON_LOADED")
tLogFrame:SetScript("OnEvent", function(self, aEvent, aName)
	if aEvent == "ADDON_LOADED" and aName == ADDON_NAME then
		SkuQuestNearbyLog = (type(SkuQuestNearbyLog) == "table") and SkuQuestNearbyLog or {}
		for _, tLine in ipairs(tLogBuffer) do
			table.insert(SkuQuestNearbyLog, tLine)
		end
		tLogBuffer = {}
		tLogFlushed = true
		while #SkuQuestNearbyLog > 500 do table.remove(SkuQuestNearbyLog, 1) end
		self:UnregisterEvent("ADDON_LOADED")
	end
end)

SLASH_SQNLOG1 = "/sqnlog"
SlashCmdList["SQNLOG"] = function(aMsg)
	aMsg = (aMsg or ""):lower():match("^%s*(.-)%s*$")
	local tLog = (tLogFlushed and SkuQuestNearbyLog) or tLogBuffer
	if aMsg == "clear" then
		if tLogFlushed then
			for i = #SkuQuestNearbyLog, 1, -1 do SkuQuestNearbyLog[i] = nil end
		else
			tLogBuffer = {}
		end
		DEFAULT_CHAT_FRAME:AddMessage("|cff80c0ffSkuQuestNearby|r: " .. tLogL("Log geleert.", "Log cleared.", "Journal effacé."))
		return
	end
	local tN = #tLog
	if tN == 0 then
		DEFAULT_CHAT_FRAME:AddMessage("|cff80c0ffSkuQuestNearby|r: " .. tLogL("Keine Eintraege.", "No entries.", "Aucune entrée."))
		return
	end
	local tCount = tonumber(aMsg) or 20
	local tStart = math.max(1, tN - tCount + 1)
	DEFAULT_CHAT_FRAME:AddMessage("|cff80c0ffSkuQuestNearby|r: " .. string.format(tLogL("%d Eintraege, zeige %d bis %d:", "%d entries, showing %d to %d:", "%d entrée(s), affichage de %d à %d :"), tN, tStart, tN))
	for i = tStart, tN do
		DEFAULT_CHAT_FRAME:AddMessage(tLog[i])
	end
end
