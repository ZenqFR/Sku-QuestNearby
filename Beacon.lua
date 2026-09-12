-- SkuQuestNearby/Beacon.lua -- a continuous audio beacon on the nearest
-- unfinished quest objective, which re-aims itself as you play.
--
-- WHY THIS EXISTS. Sighted players chain quests with Questie + TomTom: Questie
-- supplies the data, TomTom draws a "crazy taxi" arrow at the target. TomTom
-- aims at ONE waypoint and does not advance on its own -- Questie pushes it a
-- new one each time. There is no arrow to read here, so the equivalent has to
-- be audio.
--
-- Sku already ships the hard part. SkuBeacon-1.0 (Sku/Libs) is a full
-- positional audio beacon: sound set, ping rate, silence radius, volume,
-- proximity click-clack, max distance, plus reached / distance-changed / ping
-- callbacks. Sku's own SkuQuest already drives it -- but only for two things,
-- verified by reading every call site of its doQuestMarkerBeacons:
--
--     doQuestMarkerBeacons("availableQuests", ...)  -- quest GIVERS
--     doQuestMarkerBeacons("currentQuests", ...)    -- quest TURN-INS
--
-- Nothing aims a beacon at the OBJECTIVE itself -- the place to go kill or
-- collect. That single gap is what this file fills, and it is why this lives
-- in SkuQuestNearby rather than in a new addon: the player-context and
-- distance machinery it needs is already here.
--
-- WHERE it points is decided in Target.lua, from Questie's live objective
-- state. This file only owns the beacon's LIFECYCLE -- create, re-aim, stop --
-- and the loop that keeps asking "what is nearest now".
local ADDON_NAME, NS = ...
if NS.SkuMissing then return end
local Log, Announce = NS.Log, NS.Announce

local BEACON_REF = "SkuOptions"        -- the reference SkuNav/SkuQuest also use
local BEACON_NAME = "SkuQuestNearbyObjective"

-- How often the target is re-evaluated. "Nearest objective across all quests"
-- is a moving answer: it changes as you walk, as objectives tick up, and as
-- quests complete. Re-scanning is not free (it walks the whole quest log
-- through SkuDB), so this is deliberately slow compared to the beacon's own
-- ping rate -- the beacon keeps sounding continuously from the library's own
-- OnUpdate in between, this only decides WHERE it points.
local RETARGET_INTERVAL = 3.0

local tTicker
local tCurrent      -- { questId, title, worldX, worldY, ready }
local tRunning = false

local function tFeatureEnabled()
	local tAddon = NS.SkuQuestNearby
	if tAddon and tAddon.IsEnabled then return tAddon:IsEnabled() end
	return true
end

local function tBeaconLib()
	return SkuOptions and SkuOptions.BeaconLib
end

-- SkuBeacon:CreateBeacon REFUSES to create anything when the sound set name is
-- not registered (`if not gSoundsetRepo[aSoundSet] then return end`), so the
-- set has to be a real one. Rather than hardcode a name that may not exist in
-- a given install, reuse whatever the player already hears for Sku's own
-- navigation beacons, and fall back to the first registered set.
-- NOTE ON GetSoundSets(): it returns the library's internal `gSoundsetRepo`,
-- which is KEYED BY SET NAME (name -> soundset data) -- it is not a list of
-- names. Iterating its VALUES yields soundset tables, not strings, so the
-- lookups below deliberately walk the KEYS. Getting this wrong silently
-- produced "no sound set available" and the beacon simply never started.
local function tSoundSet()
	local tLib = tBeaconLib()
	if not tLib then return nil end
	local tSets
	local tOkSets, tRes = pcall(tLib.GetSoundSets, tLib)
	if tOkSets and type(tRes) == "table" then tSets = tRes end
	if not tSets then return nil end

	local tOk, tConfigured = pcall(function()
		return SkuSettings and SkuSettings:Sub("SkuNav") and SkuSettings:Sub("SkuNav").beaconSoundSetNarrow
	end)
	-- Prefer whatever the player already hears for Sku's own navigation
	-- beacons, so this feature does not introduce a second, unfamiliar tone.
	if tOk and tConfigured and tSets[tConfigured] then
		return tConfigured
	end
	-- Otherwise any registered set, chosen deterministically (pairs order is
	-- not stable in Lua, and a beacon that picks a different tone on each
	-- login would be its own small usability bug).
	local tNames = {}
	for tName in pairs(tSets) do
		if type(tName) == "string" then tNames[#tNames + 1] = tName end
	end
	if #tNames == 0 then return nil end
	table.sort(tNames)
	return tNames[1]
end

-- [2026-08-29] Read through SkuSettings:Sub("SkuNav"), which is exactly what
-- SkuNav's own CreateBeacon call uses (SkuNav/Core.lua:3106). The first cut
-- read SkuOptions.db.profile["SkuNav"] instead -- same value in practice, but
-- there is no reason to reach past the accessor Sku itself uses.
local function tVolume()
	local tOk, tVal = pcall(function()
		return SkuSettings and SkuSettings:Sub("SkuNav") and SkuSettings:Sub("SkuNav").beaconVolume
	end)
	if tOk and type(tVal) == "number" then return tVal end
	return 100
end
NS.BeaconVolume = tVolume
NS.BeaconSoundSet = function() return tSoundSet() end
NS.BeaconCurrentTarget = function() return tCurrent end
NS.BeaconRefName = function() return BEACON_REF, BEACON_NAME end

---------------------------------------------------------------------------------------------------------------------------------------
-- DISTANCE COMPENSATION -- why this exists, because it is not obvious.
--
-- SkuBeacon picks which sample to play from an index it derives itself:
--
--     compressed = floor((distance + 5) / 6)      capped at the pack's 30
--     index      = floor(compressed + (100 - volume) / 10)   clamped 0..30
--     file       = "<set>;<direction>;<index>.mp3"
--
-- The packs ship ";1.mp3" (loudest) through ";30.mp3" (faintest). There is no
-- ";0.mp3" at all. Working it through at the default volume of 100:
--
--     5m -> 1     30m -> 5     100m -> 17     150m -> 25     200m+ -> 30
--
-- Sku's own beacons mark a waypoint you are walking onto, tens of yards out,
-- so they sit in the loud part of that curve. A QUEST OBJECTIVE is essentially
-- always past 200m when you set off, which pins the index at 30 forever -- the
-- most attenuated sample in the pack, played at a constant faint level with no
-- sense of getting closer. That is the "beacon on, no sound" report, and it is
-- a design mismatch rather than a bug in the library.
--
-- Raising the configured volume is NOT the fix: at volume 200 the same formula
-- drives short distances to index 0, whose file does not exist, so the beacon
-- goes genuinely silent exactly when you arrive.
--
-- So the volume passed to the library is computed per re-aim to land the index
-- in a usable band, keeping a real (if compressed) loudness gradient instead of
-- a flat wall:
--
--     20m or less -> index 2      400m or more -> index 20
--
-- The player's own SkuNav beaconVolume still matters: it shifts that whole band
-- (every +10 over 100 moves one index louder), so their preference is honoured
-- rather than overridden.
local IDX_NEAR, IDX_FAR = 2, 20
local DIST_NEAR, DIST_FAR = 20, 400

local function tCompressedDistance(aDist)
	local tD = math.floor(((aDist or 0) + 4 + 1) / 6)
	if tD < 0 then tD = 0 end
	if tD > 30 then tD = 30 end
	return tD
end

local function tVolumeForDistance(aDist)
	aDist = aDist or 0
	local tSpan = DIST_FAR - DIST_NEAR
	local tRatio = (aDist - DIST_NEAR) / tSpan
	if tRatio < 0 then tRatio = 0 end
	if tRatio > 1 then tRatio = 1 end
	local tDesired = math.floor(IDX_NEAR + tRatio * (IDX_FAR - IDX_NEAR) + 0.5)

	-- Player preference: +10 over the default 100 = one index louder.
	--
	-- [2026-08-29] The preference may make it LOUDER, never quieter than the
	-- far-end floor. Real capture from a live log:
	--
	--     vol=130 -> sample index 27 at 403m
	--
	-- The player's SkuNav beaconVolume was ~30, which is a perfectly good
	-- setting for what it was tuned on -- SkuNav waypoints sit at index 1-5, so
	-- 30 lands them around 8-12, comfortably audible. Applied to a beacon
	-- 400m out it shifts SEVEN indices toward silence and lands on 27, right
	-- back in the dead zone the distance compensation exists to escape. The
	-- preference was undoing the fix.
	--
	-- Clamping the far end at IDX_FAR keeps both halves working: the setting
	-- still quietens near pings (index 9 at 8m in that same capture, exactly as
	-- intended), but it can no longer push a distant beacon past the point
	-- where it stops being a signal at all.
	tDesired = tDesired - math.floor((tVolume() - 100) / 10)
	if tDesired < 1 then tDesired = 1 end          -- never 0: that file does not exist
	if tDesired > IDX_FAR then tDesired = IDX_FAR end

	local tVol = 100 - 10 * (tDesired - tCompressedDistance(aDist))
	-- The library skips playback entirely when volume is not > 0.
	if tVol < 1 then tVol = 1 end
	return tVol, tDesired
end
NS.BeaconVolumeForDistance = tVolumeForDistance

---------------------------------------------------------------------------------------------------------------------------------------
-- Target selection lives in Target.lua: it reads QUESTIE's live objective
-- state (which objectives are already collected, whether the quest is ready to
-- hand in) rather than SkuDB's static quest data, so the beacon never points
-- at something already finished. See that file's header for why the source
-- was changed and how Questie's zone coordinates are converted with Sku's own
-- geometry rather than Questie's.
local function PickTarget()
	return NS.PickBeaconTarget()
end

local function DestroyBeacon()
	local tLib = tBeaconLib()
	if not tLib then return end
	pcall(function()
		if tLib:GetBeaconStatus(BEACON_REF, BEACON_NAME) then
			tLib:DestroyBeacon(BEACON_REF, BEACON_NAME)
		end
	end)
end

-- Moves the beacon to aTarget, creating it if needed. UpdateBeacon is preferred
-- over destroy+create so the tone does not restart on every re-aim -- a beacon
-- that stutters every 3 seconds is worse than no beacon.
local function AimAt(aTarget)
	local tLib = tBeaconLib()
	if not tLib then return false end
	local tSet = tSoundSet()
	if not tSet then
		Log("Beacon: no registered beacon sound set available, cannot start.")
		return false
	end

	local tExists = false
	pcall(function() tExists = tLib:GetBeaconStatus(BEACON_REF, BEACON_NAME) and true or false end)

	-- Volume is recomputed on EVERY re-aim, not fixed at creation: it is the
	-- distance compensation described above, and the distance changes as you
	-- walk. This is also why the retarget loop keeps running even when the
	-- target itself has not changed.
	local tVol, tIdx = tVolumeForDistance(aTarget.distance)

	if tExists then
		local tOk, tErr = pcall(tLib.UpdateBeacon, tLib, BEACON_REF, BEACON_NAME, tSet,
			aTarget.worldX, aTarget.worldY, -3, 0, tVol, true)
		if not tOk then
			Log("Beacon: UpdateBeacon THREW: %s", tostring(tErr))
			return false
		end
		return true
	end

	-- Rate -3 and silenceRange 0 mirror what SkuQuest's own sample beacon uses
	-- (SkuQuest/Options.lua), so this sounds like the rest of Sku rather than
	-- inventing its own cadence. Callbacks are intentionally minimal: the
	-- 3-second retarget loop below is the single place that decides where the
	-- beacon points, so a callback that also re-aimed would race with it.
	local tCreated = false
	local tOk, tErr = pcall(function()
		tCreated = tLib:CreateBeacon(BEACON_REF, BEACON_NAME, tSet,
			aTarget.worldX, aTarget.worldY,
			-3,                 -- rate
			0,                  -- silence range
			tVol,
			5,                  -- click-clack range
			99999,              -- max distance: never self-destruct on distance
			nil, nil, nil, nil)
	end)
	if not tOk then
		Log("Beacon: CreateBeacon THREW: %s", tostring(tErr))
		return false
	end
	if not tCreated then
		Log("Beacon: CreateBeacon refused (sound set '%s' not registered?).", tostring(tSet))
		return false
	end
	pcall(tLib.StartBeacon, tLib, BEACON_REF, BEACON_NAME)
	Log("Beacon: created with set='%s' vol=%d -> sample index %d at %dm.", tostring(tSet), tVol, tIdx or -1, math.floor(aTarget.distance or 0))
	return true
end

---------------------------------------------------------------------------------------------------------------------------------------
local function Retarget()
	if not tRunning then return end
	if not tFeatureEnabled() then
		NS.StopBeacon()
		return
	end

	local tTarget, tWhy = PickTarget()
	if not tTarget then
		-- Keep the loop alive: a quest handed in, a zone change or a not-yet-
		-- loaded SkuDB chunk can all make this momentarily empty, and silently
		-- giving up would look like the feature broke.
		if tCurrent then
			Log("Beacon: no target available (%s), beacon stopped until one is.", tostring(tWhy))
			DestroyBeacon()
			tCurrent = nil
		end
		return
	end

	-- Standing on it: announce and let the next pass pick the following stop.
	-- ScanQuestObjectives re-sorts every pass, so simply skipping this one is
	-- not needed -- once the objective completes it leaves the list on its own.
	-- Re-aim EVERY pass, not only when the target changed. The volume passed to
	-- the library is distance-compensated (see tVolumeForDistance), and the
	-- distance changes as YOU move even when the target has not moved at all --
	-- so skipping the update while the target is unchanged would freeze the
	-- beacon at whatever loudness it had when you were furthest away.
	local tQuestChanged = (not tCurrent)
		or tCurrent.questId ~= tTarget.questId
		or tCurrent.ready ~= tTarget.ready

	if AimAt(tTarget) then
		-- Speak only when the QUEST changes. Announcing every re-aim would talk
		-- over everything else every three seconds.
		if tQuestChanged then
			local tWhat = tTarget.ready
				and (Sku.deEn and Sku.deEn("Abgabe", "turn in", "à rendre") or "à rendre")
				or (Sku.deEn and Sku.deEn("Ziel", "objective", "objectif") or "objectif")
			Announce(string.format("%s : %s, %dm", tWhat, tostring(tTarget.title), math.floor(tTarget.distance or 0)))
			Log("Beacon: now aimed at questID=%d ('%s') ready=%s dist=%dm source=%s",
				tTarget.questId, tostring(tTarget.title), tostring(tTarget.ready),
				math.floor(tTarget.distance or 0), tostring(tTarget.source))
		end
		tCurrent = tTarget
	end
end

---------------------------------------------------------------------------------------------------------------------------------------
function NS.StartBeacon()
	if tRunning then return true end
	if not tBeaconLib() then
		Announce(Sku.deEn and Sku.deEn("Bakenmodul fehlt", "Beacon module missing", "Module de balise absent") or "Module de balise absent")
		Log("StartBeacon: SkuOptions.BeaconLib missing.")
		return false
	end
	-- [2026-09-04] "Une seule balise à la fois" -- two beacons pinging from
	-- two directions is noise, not guidance. Starting this one switches the
	-- ally beacon (SkuAllyBeacon) off, and says so; the reverse lives there.
	local tAlly = _G.SkuAllyBeacon
	if tAlly and tAlly.IsFollowing and tAlly:IsFollowing() then
		pcall(tAlly.StopFollowing, tAlly, true)
		Announce(Sku.deEn and Sku.deEn("Verbuendeten-Bake aus", "Ally beacon off", "Balise d'allié éteinte") or "Balise d'allié éteinte")
		Log("StartBeacon: ally beacon was running, stopped it.")
	end
	tRunning = true
	Retarget()
	if not tCurrent then
		tRunning = false
		Announce(Sku.deEn and Sku.deEn("Kein Questziel gefunden", "No quest objective found", "Aucun objectif de quête trouvé") or "Aucun objectif de quête trouvé")
		Log("StartBeacon: no target on first pass, not started.")
		return false
	end
	if tTicker then pcall(function() tTicker:Cancel() end) end
	tTicker = C_Timer.NewTicker(RETARGET_INTERVAL, Retarget)
	Announce(Sku.deEn and Sku.deEn("Questbake an", "Quest beacon on", "Balise de quête activée") or "Balise de quête activée")
	Log("StartBeacon: running, retarget every %.1fs.", RETARGET_INTERVAL)
	return true
end

function NS.StopBeacon()
	tRunning = false
	if tTicker then
		pcall(function() tTicker:Cancel() end)
		tTicker = nil
	end
	DestroyBeacon()
	tCurrent = nil
	Log("StopBeacon: stopped and beacon destroyed.")
end

function NS.ToggleBeacon()
	if tRunning then
		NS.StopBeacon()
		Announce(Sku.deEn and Sku.deEn("Questbake aus", "Quest beacon off", "Balise de quête désactivée") or "Balise de quête désactivée")
		return false
	end
	return NS.StartBeacon()
end

function NS.BeaconIsRunning()
	return tRunning
end

-- [2026-09-04] Public, on the addon object, for SkuAllyBeacon: the two
-- addons share no namespace, and "one beacon at a time" needs each to be
-- able to ask -- and switch off -- the other.
function NS.SkuQuestNearby:BeaconIsRunning() return tRunning end
function NS.SkuQuestNearby:StopBeacon() NS.StopBeacon() end

---------------------------------------------------------------------------------------------------------------------------------------
-- [2026-08-29] "balise activée, aucun son". The beacon was created and started
-- (that is what the spoken confirmation means), so the failure is in PLAYBACK,
-- not in target selection -- and playback happens entirely inside SkuBeacon's
-- own OnUpdate, where nothing is logged.
--
-- Rather than keep guessing, this reproduces SkuBeacon's own arithmetic for
-- the CURRENT target and prints the exact .mp3 path it would try to play, so
-- the answer is a fact instead of a theory. Three things can each produce
-- total silence and are each checked explicitly:
--
--   * volume index 0 -- the packs ship ";1.mp3" through ";30.mp3" and there is
--     NO ";0.mp3", so an index of 0 asks for a file that does not exist.
--   * direction 185 -- the library computes (floor(deg/5)+1)*5, which yields
--     185 for a target at exactly 180 degrees, one step past the ";180" files.
--   * volume index 30 -- the file EXISTS but it is the most attenuated sample
--     in the set. At a typical quest-objective range this is where the maths
--     lands, and "inaudible" is easy to mistake for "silent".
local function tRate3VolumeIndex(aRawDistance, aVolume)
	-- Mirrors CONST_DYNAME_PING_RATE3 in SkuBeacon-1.0's OnUpdate.
	local tD = aRawDistance + 4
	tD = math.floor((tD + 1) / 6)
	if tD < 0 then tD = 0 end
	if tD > 30 then tD = 30 end        -- soundSet.maxDistance is 30 in every shipped pack
	local tIdx = math.floor(tD + ((100 - (aVolume or 100)) / 10))
	if tIdx < 0 then tIdx = 0 end
	if tIdx > 30 then tIdx = 30 end
	return tIdx, tD
end
NS.BeaconRate3VolumeIndex = tRate3VolumeIndex

function NS.BeaconDiagnose()
	local tOut = function(aFmt, ...)
		local tOk, tMsg = pcall(string.format, aFmt, ...)
		DEFAULT_CHAT_FRAME:AddMessage("|cff80c0ffBalise|r: " .. (tOk and tMsg or tostring(aFmt)))
	end

	tOut("active=%s", tostring(tRunning))
	local tLib = tBeaconLib()
	tOut("BeaconLib=%s", tostring(tLib ~= nil))
	if not tLib then return end

	local tSet = tSoundSet()
	tOut("jeu de sons=%s", tostring(tSet))
	local tVol = tVolume()
	tOut("volume reglé=%s", tostring(tVol))

	local tStatus
	pcall(function() tStatus = tLib:GetBeaconStatus(BEACON_REF, BEACON_NAME) end)
	tOut("balise existe=%s", tostring(tStatus and true or false))

	if not tCurrent then
		tOut("aucune cible courante")
		return
	end

	local tPx, tPy = UnitPosition("player")
	local tDist = tCurrent.distance or 0
	if tPx and tCurrent.worldX then
		local tOkD, tD = pcall(SkuNav.Geo.Distance, SkuNav.Geo, tPx, tPy, tCurrent.worldX, tCurrent.worldY)
		if tOkD and tD then tDist = tD end
	end
	tOut("cible='%s' distance=%dm source=%s", tostring(tCurrent.title), math.floor(tDist), tostring(tCurrent.source))

	local tCompensated, tDesired = tVolumeForDistance(tDist)
	local tIdx, tCompressed = tRate3VolumeIndex(tDist, tCompensated)
	tOut("volume envoyé à la lib=%d (compensé), distance compressée=%d", tCompensated, tCompressed)
	tOut("index d'echantillon=%d, visé=%d (1=fort, 30=le plus faible)", tIdx, tDesired)
	tOut("sans compensation ce serait %d", (tRate3VolumeIndex(tDist, tVol)))
	if tIdx == 0 then
		tOut("|cffff8080PROBLEME|r: index 0, aucun fichier ';0.mp3' n'existe -> silence total")
	elseif tIdx >= 29 then
		tOut("|cffffcc00ATTENTION|r: index %d = l'echantillon le plus attenue du pack -> quasi inaudible", tIdx)
	end

	local tSets
	pcall(function() tSets = tLib:GetSoundSets() end)
	local tData = tSets and tSet and tSets[tSet]
	if tData then
		tOut("fichier attendu: %s\\%s;<direction>;%d.mp3", tostring(tData.path), tostring(tData.fileName), tIdx)
		tOut("portee du pack=%s pas angulaire=%s", tostring(tData.maxDistance), tostring(tData.degreesStep))
	else
		tOut("|cffff8080PROBLEME|r: le jeu de sons '%s' n'est pas enregistre", tostring(tSet))
	end
end

-- Spoken on demand: how far the target still is, and which way. Measured LIVE
-- against the player's current position rather than reusing the distance
-- cached at the last retarget -- that value can be up to RETARGET_INTERVAL
-- seconds stale, which while running is enough to be wrong by a noticeable
-- margin and would make the readout feel laggy.
--
-- Direction comes from SkuNav.Geo:GetDirectionToAsString, the same clock-face
-- phrasing ("3 heures") Sku's own Ctrl+Alt distance readout uses, so this
-- sounds like the rest of Sku instead of inventing a second vocabulary for
-- the same idea.
function NS.AnnounceBeaconDistance()
	if not tRunning or not tCurrent then
		-- [2026-09-04] Ctrl+D serves whichever beacon is active: with the
		-- quest beacon off and the ally beacon on, it speaks the ally.
		local tAlly = _G.SkuAllyBeacon
		if tAlly and tAlly.IsFollowing and tAlly:IsFollowing() and tAlly.AnnounceAllyDistance then
			tAlly:AnnounceAllyDistance()
			return
		end
		Announce(Sku.deEn and Sku.deEn("Bake aus", "Beacon off", "Balise éteinte") or "Balise éteinte")
		return
	end

	local tPx, tPy = UnitPosition("player")
	local tDist = tCurrent.distance or 0
	if tPx and tCurrent.worldX then
		local tOk, tD = pcall(SkuNav.Geo.Distance, SkuNav.Geo, tPx, tPy, tCurrent.worldX, tCurrent.worldY)
		if tOk and tD then tDist = tD end
	end

	local tDirection = ""
	if tCurrent.worldX then
		local tOkDir, tDir = pcall(SkuNav.Geo.GetDirectionToAsString, SkuNav.Geo, tCurrent.worldX, tCurrent.worldY)
		if tOkDir and tDir and tDir ~= "" then tDirection = ", " .. tDir end
	end

	Announce(string.format("%s, %dm%s", tostring(tCurrent.title), math.floor(tDist), tDirection))
	Log("AnnounceBeaconDistance: '%s' %dm%s", tostring(tCurrent.title), math.floor(tDist), tDirection)
end

-- Kept under its original name too: Menu.lua's "announce current target" row
-- and any existing binding both point here, and the two ideas ("what is it"
-- and "how far is it") are answered by the same sentence.
NS.AnnounceBeaconTarget = NS.AnnounceBeaconDistance
