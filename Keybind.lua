-- SkuQuestNearby/Keybind.lua -- the three configurable keys of the quest
-- beacon: one toggles it (Beacon.lua), one faces its target (Turn.lua), one
-- speaks how far it still is (Beacon.lua).
--
-- Deliberately SIMPLER than the sibling addons' keybind files. SkuQuestTarget
-- and SkuGatherRoute need a SecureActionButtonTemplate because what their key
-- does is protected (targeting, casting) and must be driven by a real hardware
-- event. Toggling a beacon is plain Lua with nothing protected in it, so a
-- normal button is enough -- no secure template, no combat lockdown problem,
-- and it keeps working mid-fight, which is exactly when you do not want to be
-- diving into a menu.
--
-- The key still goes through SetOverrideBindingClick rather than
-- SetBinding/SaveBindings, for the same reason documented at length in
-- SkuQuestTarget/Menu.lua: that is the layer Sku's own SKU_KEY_* binds use, it
-- does not fight with the player's saved bindings, and it is re-applied from
-- this addon's own SavedVariable on every login.
local ADDON_NAME, NS = ...
if NS.SkuMissing then return end
local Log, Announce = NS.Log, NS.Announce

-- [2026-08-29] Three keys, described by ONE table instead of three parallel
-- copies of the same arm/capture/reset code. Adding a fourth is one entry.
--
--   toggle   -- switch the beacon on and off              (CTRL-B)
--   turn     -- face the beacon's target                  (CTRL-I)
--   distance -- speak the remaining distance + direction  (CTRL-D)
--
-- All cross-checked free against Sku's own SkuKeyBinds.lua and against every
-- sibling addon's default (SkuQuestTarget CTRL-K, SkuGatherRoute CTRL-SHIFT-N
-- and -R, SkuBagnonBridge CTRL-SHIFT-H and -J, SkuBeastLore CTRL-SHIFT-V).
--
-- CTRL-I is deliberately next to Sku's own "I" (SKU_KEY_TURNTOBEACON), which
-- does the same thing for SkuNav's selected waypoint. Sku's "I" cannot be
-- reused for this: it is keyed on a waypoint NAME and this beacon's target is
-- a resolved position, not a waypoint. See Turn.lua's header.
local BINDS = {
	toggle = {
		buttonName = "SkuQuestNearbyBeaconButton",
		defaultKey = "CTRL-B",
		dbField    = "key",
		run        = function() return NS.ToggleBeacon and NS.ToggleBeacon() end,
	},
	turn = {
		buttonName = "SkuQuestNearbyTurnButton",
		defaultKey = "CTRL-I",
		dbField    = "turnKey",
		run        = function() return NS.TurnToBeaconTarget and NS.TurnToBeaconTarget() end,
	},
	distance = {
		buttonName = "SkuQuestNearbyDistanceButton",
		defaultKey = "CTRL-D",
		dbField    = "distanceKey",
		run        = function() return NS.AnnounceBeaconDistance and NS.AnnounceBeaconDistance() end,
	},
}
NS.BEACON_BUTTON_NAME = BINDS.toggle.buttonName
NS.TURN_BUTTON_NAME = BINDS.turn.buttonName
NS.DISTANCE_BUTTON_NAME = BINDS.distance.buttonName

local tKeyCaptureFrame

local tModifierOnlyKeys = {
	LSHIFT = true, RSHIFT = true, LCTRL = true, RCTRL = true, LALT = true, RALT = true,
	UNKNOWN = true,
}

-- ALT, then CTRL, then SHIFT -- WoW's canonical binding string is
-- "ALT-CTRL-SHIFT-<KEY>" and Sku's own capture routine uses this order. Any
-- other order produces a string the keypress never resolves to.
local function tModifierPrefix()
	local tPrefix = ""
	if IsAltKeyDown() then tPrefix = tPrefix .. "ALT-" end
	if IsControlKeyDown() then tPrefix = tPrefix .. "CTRL-" end
	if IsShiftKeyDown() then tPrefix = tPrefix .. "SHIFT-" end
	return tPrefix
end

local function tSkuOwnBindingOwner(aKey)
	if not SkuOptions or not SkuOptions.SkuKeyBindsCheckBound then return nil end
	local tOk, tResult = pcall(SkuOptions.SkuKeyBindsCheckBound, SkuOptions, aKey)
	if tOk then return tResult end
	return nil
end

-- SkuQuestNearbyKeyDB (SavedVariable, .toc) -- { key, turnKey, distanceKey }. Read and written through a type-check at each access, since this
-- file's own top-level execution runs BEFORE WoW swaps in the real saved table.
local function GetConfiguredKey(aWhich)
	local tSpec = BINDS[aWhich]
	if not tSpec then return nil end
	if type(SkuQuestNearbyKeyDB) == "table" then
		local tVal = SkuQuestNearbyKeyDB[tSpec.dbField]
		if tVal and tVal ~= "" then return tVal end
	end
	return nil
end
NS.GetConfiguredBeaconKey = function(aWhich)
	aWhich = aWhich or "toggle"
	return GetConfiguredKey(aWhich) or (BINDS[aWhich] and BINDS[aWhich].defaultKey) or "?"
end

local function SetConfiguredKey(aWhich, aKey)
	local tSpec = BINDS[aWhich]
	if not tSpec then return end
	if type(SkuQuestNearbyKeyDB) ~= "table" then SkuQuestNearbyKeyDB = {} end
	SkuQuestNearbyKeyDB[tSpec.dbField] = aKey
end

local tButtons = {}

local function EnsureButton(aWhich)
	local tSpec = BINDS[aWhich]
	if not tSpec then return nil end
	if tButtons[aWhich] then return tButtons[aWhich] end
	local tBtn = CreateFrame("Button", tSpec.buttonName, UIParent)
	tBtn:Hide()
	-- "AnyDown" only. Registering both up and down would run the whole click
	-- sequence TWICE per press -- the exact double-fire that made
	-- SkuQuestTarget play its miss sound right after a successful hit.
	tBtn:RegisterForClicks("AnyDown")
	tBtn:SetScript("OnClick", function()
		if NS.SkuQuestNearby and NS.SkuQuestNearby.IsEnabled and not NS.SkuQuestNearby:IsEnabled() then return end
		local tOk, tErr = pcall(tSpec.run)
		if not tOk then Log("Keybind '%s': handler THREW: %s", aWhich, tostring(tErr)) end
	end)
	tButtons[aWhich] = tBtn
	return tBtn
end

local function ArmOne(aWhich)
	local tSpec = BINDS[aWhich]
	local tBtn = EnsureButton(aWhich)
	if not tBtn or not tSpec then return false end
	pcall(ClearOverrideBindings, tBtn)
	local tKey = GetConfiguredKey(aWhich) or tSpec.defaultKey
	local tOk, tErr = pcall(SetOverrideBindingClick, tBtn, true, tKey, tBtn:GetName())
	if not tOk then
		Log("ArmKeybind[%s]: SetOverrideBindingClick('%s') THREW: %s", aWhich, tKey, tostring(tErr))
		return false
	end
	Log("ArmKeybind[%s]: bound '%s' to %s.", aWhich, tKey, tBtn:GetName())
	return true
end

local function ArmKeybind()
	local tAll = true
	for tWhich in pairs(BINDS) do
		if not ArmOne(tWhich) then tAll = false end
	end
	return tAll
end
NS.ArmBeaconKeybind = ArmKeybind

local function CaptureKeyFor(aWhich, aOnDone)
	-- Back-compat with the single-key call shape: CaptureBeaconKey(callback).
	if type(aWhich) == "function" then aWhich, aOnDone = "toggle", aWhich end
	aWhich = aWhich or "toggle"
	if not BINDS[aWhich] then return end
	if not tKeyCaptureFrame then
		tKeyCaptureFrame = CreateFrame("Frame", nil, UIParent)
		tKeyCaptureFrame:SetPropagateKeyboardInput(false)
		tKeyCaptureFrame:Hide()
	end
	tKeyCaptureFrame:SetScript("OnKeyDown", function(aSelf, aKey)
		if tModifierOnlyKeys[aKey] then return end
		aSelf:EnableKeyboard(false)
		aSelf:Hide()
		if aKey == "ESCAPE" then
			Log("CaptureKeyFor: cancelled.")
			if aOnDone then aOnDone(nil) end
			return
		end
		local tFullKey = tModifierPrefix() .. aKey
		local tSkuOwner = tSkuOwnBindingOwner(tFullKey)
		if tSkuOwner then
			local tSkuOwnerName = (_G["BINDING_NAME_" .. tSkuOwner]) or tSkuOwner
			Log("CaptureKeyFor: '%s' already used by Sku's own '%s' -- refused.", tFullKey, tSkuOwner)
			Announce((Sku.deEn and Sku.deEn("Bereits von Sku belegt: ", "Already used by Sku: ", "Déjà utilisée par Sku : ") or "Déjà utilisée par Sku : ") .. tSkuOwnerName)
			if aOnDone then aOnDone(nil) end
			return
		end
		-- Also refuse a key already taken by THIS addon's other binding --
		-- otherwise one key would fire two different beacon actions at once.
		for tOther, tSpec in pairs(BINDS) do
			if tOther ~= aWhich and (GetConfiguredKey(tOther) or tSpec.defaultKey) == tFullKey then
				Log("CaptureKeyFor: '%s' already used by this addon's '%s' binding -- refused.", tFullKey, tOther)
				Announce(Sku.deEn and Sku.deEn("Taste bereits belegt", "Key already in use", "Touche déjà utilisée") or "Touche déjà utilisée")
				if aOnDone then aOnDone(nil) end
				return
			end
		end
		SetConfiguredKey(aWhich, tFullKey)
		ArmKeybind()
		Log("CaptureKeyFor[%s]: bound '%s'.", aWhich, tFullKey)
		if aOnDone then aOnDone(tFullKey) end
	end)
	tKeyCaptureFrame:EnableKeyboard(true)
	tKeyCaptureFrame:Show()
	Announce(Sku.deEn and Sku.deEn("Neue Taste druecken oder Escape zum Abbrechen", "Press a new key, or Escape to cancel", "Appuyez sur une nouvelle touche, ou Echap pour annuler") or "Appuyez sur une nouvelle touche, ou Echap pour annuler")
end
NS.CaptureBeaconKey = CaptureKeyFor

NS.ResetBeaconKey = function(aWhich)
	aWhich = aWhich or "toggle"
	local tSpec = BINDS[aWhich]
	if not tSpec then return "?" end
	SetConfiguredKey(aWhich, nil)
	ArmKeybind()
	Log("ResetBeaconKey[%s]: back to default (%s).", aWhich, tSpec.defaultKey)
	return tSpec.defaultKey
end
