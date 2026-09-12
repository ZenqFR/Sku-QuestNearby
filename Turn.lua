-- SkuQuestNearby/Turn.lua -- turn the character to face the beacon's target,
-- the same way Sku's own "I" key faces its selected waypoint.
--
-- WHY THIS IS NOT JUST A CALL TO SKU'S OWN FUNCTION. Sku's key is
-- SKU_KEY_TURNTOBEACON (default "I"/"T"), handled in SkuNav/Core.lua, and it
-- calls SkuCore.GameWorldObjects:GameWorldObjectsTurnToWp(aWaypointName). That
-- function is keyed on a WAYPOINT NAME: it looks the name up with
-- SkuNav:GetWaypointData2 and reads .worldX/.worldY off the result. This
-- addon's beacon target is not a SkuNav waypoint -- it is a position resolved
-- from Questie -- so there is no name to hand it.
--
-- The alternative would have been to create a real SkuNav waypoint for every
-- objective and select it, which would make "I" work for free but would write
-- throwaway entries into the player's own waypoint database on every retarget.
-- Not worth it. The turn maths below is a faithful reproduction of Sku's, with
-- coordinates in place of the lookup -- including the details that are easy to
-- get wrong and that make the difference between a smooth turn and a spin:
--
--   * the turn angle comes from SkuNav.Geo:GetDirectionTo's THIRD return, a
--     signed degree that is already relative to where the player faces;
--   * cameraYawMoveSpeed is temporarily overridden so the turn takes a known
--     amount of time, then RESTORED -- leaving it changed would quietly alter
--     how the player's own camera behaves forever after;
--   * MoveViewLeftStart/MoveViewRightStart are started and stopped on a timer,
--     since there is no "turn to angle" API;
--   * the trailing MouselookStart/MouselookStop pair settles the camera, which
--     Sku's own version does for the same reason.
--
-- Sku's version also calls SetView(2) to snap back to the standard camera, but
-- only when its own "SkuStandard" camera mode is active. That check is
-- preserved: without it, this would yank the camera of a player who has
-- deliberately decoupled it.
local ADDON_NAME, NS = ...
if NS.SkuMissing then return end
local Log, Announce = NS.Log, NS.Announce

local FULL_TURN_TIME = 0.5   -- seconds for a 180 degree turn, same as Sku's

function NS.TurnToBeaconTarget()
	if NS.SkuQuestNearby and NS.SkuQuestNearby.IsEnabled and not NS.SkuQuestNearby:IsEnabled() then return end

	local tTarget = NS.BeaconCurrentTarget and NS.BeaconCurrentTarget()
	if not tTarget or not tTarget.worldX or not tTarget.worldY then
		-- [2026-09-04] "CTRL+I va donc me tourner dans la direction de la
		-- balise" -- ONE turn key for whichever beacon is active. With the
		-- quest beacon off and SkuAllyBeacon following someone, the turn is
		-- handed to it (same maths, its own target).
		local tAlly = _G.SkuAllyBeacon
		if tAlly and tAlly.IsFollowing and tAlly:IsFollowing() and tAlly.TurnToAlly then
			tAlly:TurnToAlly()
			return
		end
		Announce(Sku.deEn and Sku.deEn("Keine Bake aktiv", "No beacon active", "Aucune balise active") or "Aucune balise active")
		Log("TurnToBeaconTarget: no current target.")
		return
	end

	local tOk, tErr = pcall(function()
		local tPx, tPy = UnitPosition("player")
		if not tPx then
			Log("TurnToBeaconTarget: UnitPosition returned nil (loading screen?), skipped.")
			return
		end

		local _, _, tDegree = SkuNav.Geo:GetDirectionTo(tPx, tPy, tTarget.worldX, tTarget.worldY)
		if not tDegree then
			Log("TurnToBeaconTarget: GetDirectionTo returned no degree.")
			return
		end

		-- Only snap the view when Sku's own standard camera is in charge --
		-- exactly the guard Sku's own turn uses.
		if not SkuCore.CameraSkuStandardActive or SkuCore:CameraSkuStandardActive() then
			SetView(2)
		end

		local tOldYawSpeed = GetCVar("cameraYawMoveSpeed")
		local tOneDegreeTime = FULL_TURN_TIME / 180
		SetCVar("cameraYawMoveSpeed", 180 * (1 / FULL_TURN_TIME))

		-- The 5 degree nudge is Sku's: MoveView* has a small start-up lag, and
		-- without it short turns consistently stop just short of the target.
		if tDegree < 0 then tDegree = tDegree - 5 else tDegree = tDegree + 5 end
		local tDuration = tOneDegreeTime * tDegree

		if tDuration < 0 then
			MoveViewRightStart(4)
			tDuration = tDuration * -1
		else
			MoveViewLeftStart(4)
		end

		C_Timer.After(tDuration / 4, function()
			MoveViewRightStop()
			MoveViewLeftStop()
			SetCVar("cameraYawMoveSpeed", tOldYawSpeed)
			MouselookStart()
			MouselookStop()
		end)

		Log("TurnToBeaconTarget: turned %.0f degrees toward '%s'.", tDegree, tostring(tTarget.title))
	end)
	if not tOk then Log("TurnToBeaconTarget THREW: %s", tostring(tErr)) end
end
