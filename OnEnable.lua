-- SkuQuestNearby/OnEnable.lua -- final wiring.
local ADDON_NAME, NS = ...
if NS.SkuMissing then return end
local Log, SkuQuestNearby = NS.Log, NS.SkuQuestNearby

function SkuQuestNearby:OnEnable()
	Log("OnEnable start.")

	local tOk, tErr = pcall(NS.InstallMenuEntry)
	if not tOk then Log("InstallMenuEntry THREW: %s", tostring(tErr)) end

	local tOkTrack, tErrTrack = pcall(NS.InstallTrackingToggle)
	if not tOkTrack then Log("InstallTrackingToggle THREW: %s", tostring(tErrTrack)) end

	self:RegisterChatCommand("sqn", "SlashCommand")

	-- [2026-08-22] "assure-toi qu'une version anglaise de chaquns des
	-- addons est disponible" -- this activation line hardcoded the FRENCH
	-- menu path ("Quêtes -> Objectifs de quêtes proches") into ALL THREE
	-- language branches, including the English and German ones. Sku's own
	-- root Quest menu label (confirmed via Sku/locales/*.lua: L["Quests"])
	-- is "Quests" in both DE and EN, "Quêtes" only in FR -- and this
	-- addon's own submenu label is the same `LABEL_OBJECTIVES_ROOT` triple
	-- Menu.lua's own InstallMenuEntry already builds (module-local there,
	-- so rebuilt inline here rather than exported just for this one line).
	local tParentMenu = Sku.deEn and Sku.deEn("Quests", "Quests", "Quêtes") or "Quêtes"
	local tSubName = Sku.deEn and Sku.deEn("Nahe Questziele", "Nearby quest objectives", "Objectifs de quêtes proches") or "Objectifs de quêtes proches"
	print("|cff00ff00SkuQuestNearby|r: " ..
		(Sku.deEn and Sku.deEn(
			"aktiv. Menü: " .. tParentMenu .. " -> " .. tSubName .. ".",
			"active. Menu: " .. tParentMenu .. " -> " .. tSubName .. ".",
			"actif. Menu : " .. tParentMenu .. " -> " .. tSubName .. ".")
		or "actif. Menu : " .. tParentMenu .. " -> " .. tSubName .. "."))
	Log("OnEnable end.")
end

-- /sqn -- for testing/diagnostics: dumps the list sizes to chat without
-- going through the menu.
-- [2026-08-22] Was hardcoded French-only with no Sku.deEn wrapper at all --
-- a real localization gap, found during the same audit as OnEnable's
-- activation-message bug above.
function SkuQuestNearby:SlashCommand(aMsg)
	local tCtx = NS.GetPlayerContext()
	if not tCtx then
		print("|cff80c0ffSkuQuestNearby|r: " .. (Sku.deEn and Sku.deEn(
			"Position unbekannt.", "Unknown position.", "Position inconnue.") or "Position inconnue."))
		return
	end
	local tObjectives = NS.ScanQuestObjectives(tCtx)
	print("|cff80c0ffSkuQuestNearby|r: " .. (Sku.deEn and Sku.deEn(
		string.format("%d Questziel(e) (aktuelle Zone).", #tObjectives),
		string.format("%d quest objective(s) (current zone).", #tObjectives),
		string.format("%d objectif(s) de quête (zone actuelle).", #tObjectives))
	or string.format("%d objectif(s) de quête (zone actuelle).", #tObjectives)))
end

function SkuQuestNearby:OnDisable()
	Log("OnDisable.")
end
