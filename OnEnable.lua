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

	-- [2026-08-29] Quest beacon keybind. Armed on every OnEnable because
	-- SetOverrideBindingClick does NOT persist across reload/relogin the way
	-- SetBinding+SaveBindings does -- the chosen key lives in this addon's own
	-- SkuQuestNearbyKeyDB and is re-applied from there each session.
	local tOkKb, tErrKb = pcall(NS.ArmBeaconKeybind)
	if not tOkKb then Log("ArmBeaconKeybind THREW: %s", tostring(tErrKb)) end

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
	-- [2026-08-29] "/sqn beacon" -- prints what SkuBeacon would actually play
	-- for the current target. Playback lives inside the library's own OnUpdate
	-- where nothing is logged, so "beacon on, no sound" is otherwise invisible.
	if (aMsg or ""):lower():match("^%s*beacon%s*$") then
		local tOk, tErr = pcall(NS.BeaconDiagnose)
		if not tOk then print("|cff80c0ffSkuQuestNearby|r: diagnose THREW: " .. tostring(tErr)) end
		return
	end

	-- "/sqn quete" (or "quest", or with an explicit id) -- dumps everything the
	-- target resolution is decided from for ONE quest: whether Questie has live
	-- progress for it, each objective's Needed/Collected/Completed and nearest
	-- spawn, the turn-in position for comparison, and what the resolver picks.
	-- With no id it inspects whatever the beacon is currently aiming at.
	-- Prefix is "qu", not "que" and not a [eê] character class. Lua patterns
	-- match BYTES: "quête" is q,u,\195\170,t,e, so its third byte is not "e"
	-- at all -- both a literal "que" and a class like [eê] fail on it, and
	-- "/sqn quête" would silently fall through to the generic branch. Same
	-- byte-wise trap as the menu search fix earlier today.
	local tQuestArg = (aMsg or ""):lower():match("^%s*qu%S*%s*(%d*)%s*$")
	if tQuestArg then
		local tOk, tErr = pcall(NS.DiagnoseQuest, tonumber(tQuestArg))
		if not tOk then print("|cff80c0ffSkuQuestNearby|r: DiagnoseQuest THREW: " .. tostring(tErr)) end
		return
	end

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

-- [2026-08-29] Real teardown. A beacon left running after the addon is
-- switched off from Sku's Features menu would keep pinging with nothing able
-- to stop it from the menu -- the worst possible failure mode for an audio
-- cue. The override binding is released too, so the key stops responding
-- rather than silently re-arming a beacon from a disabled addon.
--
-- Both hooksecurefunc hooks (Menu.lua, Tracking.lua) cannot be unhooked at
-- all; they check IsEnabled() per call instead. See their own guards.
function SkuQuestNearby:OnDisable()
	local tOk, tErr = pcall(NS.StopBeacon)
	if not tOk then Log("OnDisable: StopBeacon THREW: %s", tostring(tErr)) end

	for _, tName in ipairs({ NS.BEACON_BUTTON_NAME, NS.TURN_BUTTON_NAME, NS.DISTANCE_BUTTON_NAME }) do
		local tBtn = tName and _G[tName]
		if tBtn then
			local tOkBind, tErrBind = pcall(ClearOverrideBindings, tBtn)
			if not tOkBind then Log("OnDisable: ClearOverrideBindings(%s) THREW: %s", tostring(tName), tostring(tErrBind)) end
		end
	end
	Log("OnDisable: beacon stopped, all three keybinds released.")
end
