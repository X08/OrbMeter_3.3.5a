--[[
    OrbMeter: visual layer
    Made by X08 | Dreamwind (ChromieCraft-EU).  WoW 3.3.5a, Lua 5.1.

    Two independent visual layers sharing one orb, mirroring GCDDot's
    own dot+ring layering:

    - The core orb (inner circle + number) shows dps or healing,
      whichever mode is currently selected. Mode auto-selects by
      talent-tree majority + stance/form override (see
      RecalculateAutoMode/DetectRole in OrbMeter_core.lua), with
      left-click cycling dps <-> healing manually. Color ramp: blue
      (low relative to group top) -> red for dps, or -> green for
      healing, so red never means "healing a lot," only ever dps or
      threat. Solo play is forced to neutral - see ComputeMeterDisplay
      below for why.

    - The outer ring is an always-on threat gauge, independent of the
      inner orb's mode entirely - shown for anyone with a valid
      target/threat table, not just tanks. It fills clockwise (blue ->
      red) as the player's own threat climbs toward whoever currently
      holds top threat, reaching a full red ring exactly at the point
      of actually pulling aggro - see PollThreatTarget below.

    Hovering the orb shows your top abilities in whichever mode the orb is in
    (damage or healing): the fight in progress, flagged (Current); otherwise
    the last completed fight (Last), or the total since reset (Total) if you
    chose that. The mode follows what you cast: three damage (or three healing)
    spells in a row switch it (/om adaptive turns that off); a left-click pins
    it by hand. Spec and form only set the starting mode, and only out of combat.

    Right-click opens a menu: Personal Stats > Damage / Healing prints the
    full breakdown locally (current fight while one is going, then the last
    fight, then total), Report To posts a top-5 Damage Done or Effective
    Healing list (with each member's share of the group) to Say / Party / Raid
    / Guild, Options opens the settings window, and Reset Logs wipes the data.

    Reuses GCDDot's piewheel.tga atlas for its clean anti-aliased
    circular shape (the core orb's fill is held static at 100%, just
    for the shape; the ring's fill is the real dynamic pie-wipe) and
    GCDDot's soft-texture/color pattern for the dim backing circles.
    The atlas ships in this addon's own media folder.

    FadeOut integration (optional): when the FadeOut addon is installed, the
    orb registers with it as "Orb Meter". FadeOut then owns the orb's alpha
    (idle opacity out of combat, full on combat/mouseover, its own
    post-combat delay) and the built-in dim-out-of-combat below stands down.
    Untick it in /fadeout to go back to the built-in behavior. Without
    FadeOut nothing changes.

    Slash commands (/orbmeter or /om) - all of these settings are also in the
    options window (right-click menu > Options, or /om options):
      /om options         open the options window
      /om adaptive [on|off]  the orb follows what you cast (damage <-> healing)
      /om hover last|total   what the hover overview shows
      /om unlock          show the border and let you drag the orb
      /om lock            lock it again
      /om size <28-96>    orb size (28 is the default and the minimum)
      /om reset           reset the recorded logs (same as the menu's Reset Logs)
      /om combat          toggle the built-in dimming out of combat
      /om alpha <0-100>   opacity (%) the orb dims to out of combat
      /om debug           print the tracking core's raw numbers
    combat and alpha only apply while FadeOut is NOT managing the orb.
--]]

--------------------------------------------------------------------------
-- Defaults
--------------------------------------------------------------------------

local ADDON_NAME = "OrbMeter"
local ADDON_VERSION = GetAddOnMetadata(ADDON_NAME, "Version") or "1.0" -- from the .toc
local PIE_TEXTURE = "Interface\\AddOns\\OrbMeter\\media\\piewheel.tga"
local PIE_FRAMES = 64
local PIE_GRID = 8
local SOFT_TEXTURE = "Interface\\CharacterFrame\\TempPortraitAlphaMask"

local defaults = {
	point = "CENTER",
	relPoint = "CENTER",
	x = 0,
	y = -200,
	size = 28,
	locked = true,
	hideOutOfCombat = true,  -- see UpdateVisibility: this *dims*, it never Hide()s -
	                         -- the right-click menu has to stay reachable out of combat
	outOfCombatAlpha = 0.25,
	adaptive = true,         -- orb follows what you cast (damage <-> healing); a left-click pins the mode
	hoverScope = "last",     -- hover overview shows the "last" fight or the "total" since reset
}

local db

local function CopyDefaults(dst, src)
	for k, v in pairs(src) do
		if dst[k] == nil then
			dst[k] = v
		end
	end
	return dst
end

local function Print(msg)
	DEFAULT_CHAT_FRAME:AddMessage("|cff40d9ffOrbMeter|r: " .. msg)
end

local function SetPieFraction(tex, frac)
	if frac < 0 then frac = 0 elseif frac > 1 then frac = 1 end
	local idx = math.floor(frac * (PIE_FRAMES - 1) + 0.5)
	local col = idx % PIE_GRID
	local row = math.floor(idx / PIE_GRID)
	local u0, u1 = col / PIE_GRID, (col + 1) / PIE_GRID
	local v0, v1 = row / PIE_GRID, (row + 1) / PIE_GRID
	tex:SetTexCoord(u0, u1, v0, v1)
end

--------------------------------------------------------------------------
-- Frame / visuals
--------------------------------------------------------------------------
-- Button, not Frame: needed for RegisterForClicks/OnClick (left-click mode
-- cycle, right-click menu). Drag-to-move still works the same way on a
-- Button as it does on GCDDot's plain Frame.

-- RING_SCALE mirrors GCDDot's own swing-ring sizing (it used 1.55) -
-- the ring's diameter relative to the core orb's. The clickable frame
-- itself is sized to the ring's extent (not just the core orb), same
-- as GCDDot's frame being sized to its ring, so dragging/clicking
-- works anywhere across the full visual footprint, ring included.
local RING_SCALE = 1.6

local frame = CreateFrame("Button", "OrbMeterFrame", UIParent)
frame:SetFrameStrata("HIGH")
frame:SetClampedToScreen(true)
frame:SetMovable(true)
frame:EnableMouse(true) -- always on, so clicks register even while locked
frame:RegisterForClicks("LeftButtonUp", "RightButtonUp")

-- Threat ring - BACKGROUND layer, so it draws behind the core
-- orb/fill (ARTWORK/OVERLAY below) without needing a separate child
-- frame the way GCDDot used distinct frame levels for its ring vs dot
-- (not needed here since nothing about the ring is independently
-- clickable). ringBase is a faint always-dim backdrop so the ring's
-- position is visible even near 0 fill; ringFill is the actual
-- dynamic pie-wipe, driven every tick by the player's threat ratio.
-- Both stay hidden whenever there's no target/threat table to read.
local ringBase = frame:CreateTexture(nil, "BACKGROUND")
ringBase:SetTexture(SOFT_TEXTURE)
ringBase:SetPoint("CENTER", frame, "CENTER")

local ringFill = frame:CreateTexture(nil, "BACKGROUND", nil, 1) -- sublevel 1: above ringBase, still behind ARTWORK
ringFill:SetTexture(PIE_TEXTURE)
ringFill:SetPoint("CENTER", frame, "CENTER")

-- Hidden until the first OnUpdate tick actually finds a target/threat
-- table to show - avoids a flash of a full/empty ring before that.
ringBase:Hide()
ringFill:Hide()

local core = frame:CreateTexture(nil, "ARTWORK")
core:SetTexture(SOFT_TEXTURE)
core:SetPoint("CENTER", frame, "CENTER")

local fill = frame:CreateTexture(nil, "OVERLAY")
fill:SetTexture(PIE_TEXTURE)
fill:SetPoint("CENTER", frame, "CENTER")
SetPieFraction(fill, 1) -- always a full circle - just reusing the atlas's clean shape

local number = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
number:SetPoint("CENTER", frame, "CENTER")
number:SetText("")

-- unlocked-mode helper visuals (border + label), hidden while locked
local border = CreateFrame("Frame", nil, frame)
border:SetPoint("TOPLEFT", frame, "TOPLEFT", -4, 4)
border:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", 4, -4)
border:SetBackdrop({
	edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
	edgeSize = 8,
})
border:SetBackdropBorderColor(1, 1, 1, 0.6)
border:Hide()

local label = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
label:SetPoint("BOTTOM", frame, "TOP", 0, 6)
label:SetText("Orb Meter (drag me)")
label:Hide()

-- Color (cold -> hot lerp, ratio 0..1)
-- The cold/low anchor (GCDDot's base blue) is shared by every mode.
-- The hot/high end differs by mode: red is reserved for dps and
-- threat, so it unambiguously always means "dps/aggro is high" -
-- healing uses green at its hot end instead, so a glance at the color
-- alone (not just the number) tells you which mode you're looking at,
-- and red never means "healing a lot."

local COLOR_LOW = { 0.4, 0.85, 1.0 }   -- GCDDot's base blue - shared cold end
local COLOR_HOT_RED = { 1.0, 0.15, 0.15 }    -- dps / threat hot end
local COLOR_HOT_GREEN = { 0.25, 0.95, 0.35 } -- healing hot end

local function LerpColor(ratio, hotColor)
	hotColor = hotColor or COLOR_HOT_RED
	if ratio < 0 then ratio = 0 elseif ratio > 1 then ratio = 1 end
	local r = COLOR_LOW[1] + (hotColor[1] - COLOR_LOW[1]) * ratio
	local g = COLOR_LOW[2] + (hotColor[2] - COLOR_LOW[2]) * ratio
	local b = COLOR_LOW[3] + (hotColor[3] - COLOR_LOW[3]) * ratio
	return r, g, b
end

local function ApplyRatioColor(ratio, hotColor)
	local r, g, b = LerpColor(ratio, hotColor)
	core:SetVertexColor(r, g, b, 0.35)
	fill:SetVertexColor(r, g, b, 0.95)
end

-- The ring's hot end is always red (threat/aggro, never dps/healing),
-- regardless of whatever mode the inner orb happens to be showing.
local function ApplyRingColor(ratio)
	local r, g, b = LerpColor(ratio, COLOR_HOT_RED)
	ringBase:SetVertexColor(r, g, b, 0.3)
	ringFill:SetVertexColor(r, g, b, 0.9)
end

-- Sizing / position / lock state

-- defaults.size (28) doubles as the floor: the orb can't be sized
-- smaller than its own default, so the text never shrinks past
-- legibility.
local MIN_SIZE = defaults.size
local MAX_SIZE = 96

-- Font path/flags/size are read from the font string's own template
-- (GameFontNormalSmall) once, before any resizing happens, so this is
-- whatever that template actually resolves to (around 10pt) rather
-- than an arbitrary hardcoded number or ratio. baseFontSize anchors
-- the scale: at MIN_SIZE (the default orb size), the font stays
-- exactly what the template gave it originally - it only grows
-- proportionally larger as the orb is sized up beyond that.
local baseFontPath, baseFontSize, baseFontFlags = number:GetFont()
baseFontSize = baseFontSize or 10

local function ApplySize(size)
	size = math.max(MIN_SIZE, math.min(MAX_SIZE, size))
	db.size = size

	-- The clickable frame is sized to the RING's extent (matching
	-- GCDDot's own frame-sized-to-its-ring approach), so the core
	-- orb/fill/number stay at "size" while the frame itself - and the
	-- ring textures - are larger, at size * RING_SCALE.
	local ringSize = size * RING_SCALE
	frame:SetSize(ringSize, ringSize)
	ringBase:SetSize(ringSize, ringSize)
	ringFill:SetSize(ringSize, ringSize)
	core:SetSize(size, size)
	fill:SetSize(size, size)

	local fontSize = math.max(6, math.floor(baseFontSize * (size / MIN_SIZE) + 0.5))
	number:SetFont(baseFontPath or "Fonts\\FRIZQT__.TTF", fontSize, baseFontFlags)
end

local function ApplyPosition()
	frame:ClearAllPoints()
	frame:SetPoint(db.point, UIParent, db.relPoint, db.x, db.y)
end

local function ApplyLockState()
	if db.locked then
		frame:RegisterForDrag() -- no drag buttons while locked
		border:Hide()
		label:Hide()
	else
		frame:RegisterForDrag("LeftButton")
		border:Show()
		label:Show()
	end
end

--------------------------------------------------------------------------
-- Logic
--------------------------------------------------------------------------

-- ---- Out-of-combat visibility ----
-- Deliberately NOT a GCDDot-style hard Hide() out of combat: GCDDot is
-- pure display, so vanishing is free. OrbMeter has a right-click
-- report menu you specifically want out of combat (that's when you
-- check what the last pull did) - a Hide()'d frame can't receive
-- clicks at all, so hiding it would make the menu unreachable exactly
-- when you want it most. The frame therefore stays Shown always (which
-- also lets FadeOut animate it).
--
-- Built-in behavior: dim to db.outOfCombatAlpha (still fully clickable -
-- alpha doesn't affect hit-testing in this client) and brighten back to
-- full on mouseover, so it's unobtrusive at rest but easy to find and
-- right-click without ever actually disappearing. Unlocked and in-combat
-- are always full alpha, same as GCDDot's own unlocked/combat behavior.
--
-- FadeOut integration. If the FadeOut addon is loaded, OrbMeter registers
-- its frame with it (it appears as "Orb Meter" in /fadeout) and FadeOut owns
-- the alpha: idle opacity out of combat, full on combat or mouseover, with
-- FadeOut's own post-combat delay. While FadeOut manages the orb, the
-- built-in dim / mouseover / grace logic below stands down. Untick "Orb
-- Meter" in /fadeout, or run without FadeOut, and the built-in behavior
-- takes over again. Same mechanism GCDDot uses.
local FADEOUT_KEY = "orbmeter"
local FADEOUT_LABEL = "Orb Meter"

local function IsFadeOutManaged()
	return FadeOut and FadeOut.IsManaged and FadeOut.IsManaged(FADEOUT_KEY)
end

local isMouseOver = false

-- Grace period: stays at full alpha for this long after combat ends
-- before it starts dimming, instead of dimming the instant combat
-- drops - gives you a few unobtrusive seconds to glance at what the
-- pull just did before it fades back. Separate from (and shorter than)
-- LAST_FIGHT_LINGER_SECONDS in OrbMeter_core.lua, which controls when
-- the number itself resets to 0 - this only affects visibility.
local OUT_OF_COMBAT_GRACE_SECONDS = 5
local combatEndTime = nil

local function UpdateVisibility()
	frame:Show() -- OrbMeter never Hide()s itself - see note above

	if not db.locked then
		frame:SetAlpha(1) -- always full while unlocked (FadeOut stands down too)
		return
	end

	if IsFadeOutManaged() then
		return -- alpha belongs to FadeOut; never touch it here
	end

	if isMouseOver then
		frame:SetAlpha(1)
		return
	end

	local inCombat = OrbMeter_InCombat and OrbMeter_InCombat() or false
	local inGrace = (not inCombat) and combatEndTime
		and (GetTime() - combatEndTime) < OUT_OF_COMBAT_GRACE_SECONDS

	if not db.hideOutOfCombat or inCombat or inGrace then
		frame:SetAlpha(1)
	else
		frame:SetAlpha(db.outOfCombatAlpha)
	end
end

-- ---- Right-click menu ----
-- Personal Stats > Damage | Healing prints your own breakdown locally: the
-- fight in progress (only while one is), then the last completed fight, then
-- the total (totals, share of the group, per-ability numbers).
-- Report To > <channel> > <list> posts a top-5 to chat, ranked by total
-- damage done or effective healing, with each member's share of the group.

local menuFrame = CreateFrame("Frame", "OrbMeterMenuFrame", UIParent, "UIDropDownMenuTemplate")

-- SAY is always valid; PARTY/RAID/GUILD just silently no-op via the
-- client's own chat system if you're not in the relevant group - same as
-- typing /p, /ra, /g yourself with nothing to send it to.
local REPORT_DESTINATIONS = {
	{ text = "Say", channel = "SAY" },
	{ text = "Party", channel = "PARTY" },
	{ text = "Raid", channel = "RAID" },
	{ text = "Guild", channel = "GUILD" },
}

local ToggleOptions -- the options window; defined further down

local CURRENT_LISTS = { -- only offered while a fight is going on
	{ text = "Current Fight - Top 5 Damage Done", scope = "current", mode = "damage" },
	{ text = "Current Fight - Top 5 Effective Healing", scope = "current", mode = "healing" },
}

local REPORT_LISTS = {
	{ text = "Last Fight - Top 5 Damage Done", scope = "last", mode = "damage" },
	{ text = "Last Fight - Top 5 Effective Healing", scope = "last", mode = "healing" },
	{ text = "Total - Top 5 Damage Done", scope = "total", mode = "damage" },
	{ text = "Total - Top 5 Effective Healing", scope = "total", mode = "healing" },
}

-- Your own breakdown, printed locally: the last fight first, then the total.
local function PrintPersonalStats(kind)
	local function stats(scope) return OrbMeter_GetStatsLines and OrbMeter_GetStatsLines(scope, kind) end
	local inFight = OrbMeter_InCombat and OrbMeter_InCombat()
	local current = inFight and stats("current") or nil
	local last, total = stats("last"), stats("total")
	if not current and not last and not total then
		Print("nothing to report yet.")
		return
	end
	for _, lines in ipairs({ current or false, last or false, total or false }) do
		if lines then
			for i, line in ipairs(lines) do
				-- the first line of each block (Last Fight / Total) is yellow, for structure
				Print(i == 1 and ("|cffffd100" .. line .. "|r") or line)
			end
		end
	end
end

local function PostTopReport(channel, scope, mode)
	local lines = OrbMeter_GetTopReportLines and OrbMeter_GetTopReportLines(scope, mode, 5)

	if not lines then
		Print("nothing to report yet.")
		return
	end

	for _, line in ipairs(lines) do
		SendChatMessage(line, channel)
	end
end

local function IsReportChannel(value)
	for _, dest in ipairs(REPORT_DESTINATIONS) do
		if dest.channel == value then return true end
	end
	return false
end

local function OrbMeterMenu_Initialize(self, level)
	level = level or 1

	if level == 1 then
		local info = UIDropDownMenu_CreateInfo()
		info.notCheckable = true

		info.text = "Personal Stats"
		info.hasArrow = true
		info.value = "PERSONAL_STATS"
		UIDropDownMenu_AddButton(info, level)

		info = UIDropDownMenu_CreateInfo()
		info.notCheckable = true
		info.text = "Report To"
		info.hasArrow = true
		info.value = "REPORT_TO"
		UIDropDownMenu_AddButton(info, level)

		info = UIDropDownMenu_CreateInfo()
		info.notCheckable = true
		info.text = "Options"
		info.func = function() if ToggleOptions then ToggleOptions() end end
		UIDropDownMenu_AddButton(info, level)

		info = UIDropDownMenu_CreateInfo()
		info.notCheckable = true
		info.text = "Reset Logs"
		info.func = function()
			if OrbMeter_ResetLogs then OrbMeter_ResetLogs() end
			Print("logs reset.")
		end
		UIDropDownMenu_AddButton(info, level)

	elseif level == 2 and UIDROPDOWNMENU_MENU_VALUE == "PERSONAL_STATS" then
		for _, m in ipairs({ { "Damage", "damage" }, { "Healing", "healing" } }) do
			local info = UIDropDownMenu_CreateInfo()
			info.notCheckable = true
			info.text = m[1]
			info.func = function() PrintPersonalStats(m[2]) end
			UIDropDownMenu_AddButton(info, level)
		end

	elseif level == 2 and UIDROPDOWNMENU_MENU_VALUE == "REPORT_TO" then
		for _, dest in ipairs(REPORT_DESTINATIONS) do
			local info = UIDropDownMenu_CreateInfo()
			info.notCheckable = true
			info.text = dest.text
			info.hasArrow = true
			info.value = dest.channel
			UIDropDownMenu_AddButton(info, level)
		end

	elseif level == 3 and IsReportChannel(UIDROPDOWNMENU_MENU_VALUE) then
		-- The channel is resolved here, when the submenu opens, and the
		-- report itself is built at click time (see PostTopReport).
		local channel = UIDROPDOWNMENU_MENU_VALUE
		local lists = REPORT_LISTS
		if OrbMeter_InCombat and OrbMeter_InCombat() then
			-- the fight in progress is its own entry, so "Last Fight" never means it
			lists = {}
			for _, l in ipairs(CURRENT_LISTS) do table.insert(lists, l) end
			for _, l in ipairs(REPORT_LISTS) do table.insert(lists, l) end
		end
		for _, list in ipairs(lists) do
			local info = UIDropDownMenu_CreateInfo()
			info.notCheckable = true
			info.text = list.text
			info.func = function()
				PostTopReport(channel, list.scope, list.mode)
			end
			UIDropDownMenu_AddButton(info, level)
		end
	end
end

UIDropDownMenu_Initialize(menuFrame, OrbMeterMenu_Initialize, "MENU")

-- ---- Number display (polls the tracking core) ----

-- Once the linger window expires (LAST_FIGHT_LINGER_SECONDS in
-- OrbMeter_core.lua), the number/color don't snap to 0/neutral - they
-- decay there over DECAY_DURATION, eased to start slow and accelerate
-- (quadratic ease-in), so it reads as settling rather than vanishing.
-- Tracked per mode (dps/healing both decay independently) since only
-- one is on screen at a time but either could be mid-decay if you
-- cycle modes right as it happens.
local DECAY_DURATION = 2

local decayState = {
	dps = { active = false, fromValue = 0, fromRatio = 0, startTime = 0, lastValue = 0, lastRatio = 0 },
	healing = { active = false, fromValue = 0, fromRatio = 0, startTime = 0, lastValue = 0, lastRatio = 0 },
}

local function EaseIn(t)
	if t < 0 then t = 0 elseif t > 1 then t = 1 end
	return t * t
end

-- Color ratio against the group's top value. Solo (no roster tracked) is
-- forced to 0 explicitly - without this guard a solo player is trivially
-- their own top performer and would always read ratio=1 (full red), which
-- is wrong per the agreed solo behavior (plain neutral, no gradient).
local function GroupRatio(value, top)
	if OrbMeter_GetRosterCount and OrbMeter_GetRosterCount() > 0 and top > 0 then
		return value / top
	end
	return 0
end

-- Shared by dps and healing mode, which are computed identically (live
-- in combat, last-fight snapshot out of combat, decaying to 0/neutral
-- once the linger window passes, color ratio against the group's top
-- value) and only differ in which accessor functions they poll.
local function ComputeMeterDisplay(mode, getCurrentFn, getTopFn, getLastFn, getLastTopFn)
	local state = decayState[mode]
	local value, ratio

	if OrbMeter_InCombat and OrbMeter_InCombat() then
		state.active = false -- a new fight started - cancel any decay in progress
		local v = getCurrentFn and getCurrentFn() or 0
		local top = getTopFn and getTopFn() or 0
		value = v
		ratio = GroupRatio(v, top)

	elseif OrbMeter_IsLastFightExpired and OrbMeter_IsLastFightExpired() then
		if not state.active then
			-- Just expired this tick - start the decay from whatever
			-- was actually last on screen (the held last-fight number),
			-- not from some arbitrary value.
			state.active = true
			state.fromValue = state.lastValue or 0
			state.fromRatio = state.lastRatio or 0
			state.startTime = GetTime()
		end

		local t = (DECAY_DURATION > 0) and ((GetTime() - state.startTime) / DECAY_DURATION) or 1
		local eased = EaseIn(t)
		value = state.fromValue * (1 - eased)
		ratio = state.fromRatio * (1 - eased)

		if t >= 1 then
			state.active = false
			value, ratio = 0, 0
		end

	else
		state.active = false
		local v = getLastFn and getLastFn() or 0
		local top = getLastTopFn and getLastTopFn() or 0
		value = v
		ratio = GroupRatio(v, top)
	end

	state.lastValue, state.lastRatio = value, ratio

	local text
	if OrbMeter_FormatNumber then
		text = OrbMeter_FormatNumber(value)
	else
		text = tostring(math.floor(value))
	end

	return text, ratio
end

-- ---- Threat ring ----
-- Independent of the inner orb's mode entirely - always
-- driven by the player's own threat ratio whenever there's a valid
-- target/threat table to read, hidden otherwise (mirrors GCDDot's
-- swing ring staying hidden until there's something to show).
-- scaledPercent/100 is already clamped to 0..1 inside GetThreatDisplay,
-- so "full ring" lines up exactly with actually holding top threat -
-- there's no further escalation past that; it just holds full red.
--
-- The fill doesn't snap straight to the new value - it eases there
-- (slow-fast-slow, via smoothstep) over THREAT_ANIM_DURATION, so a
-- threat swing reads as a sweep rather than an instant jump. The poll
-- for the real ratio still only happens every UPDATE_INTERVAL (no
-- need to ask the combat log math every frame); the eased render runs
-- every OnUpdate frame underneath that, independent of the throttle.
local THREAT_ANIM_DURATION = 0.35

local threatRingVisible = false  -- true once the ring has shown at least once since last hidden
local threatAnimFrom, threatAnimTo, threatAnimStart = 0, 0, 0

local function SmoothStep(t)
	if t < 0 then t = 0 elseif t > 1 then t = 1 end
	return t * t * (3 - 2 * t)
end

-- Polled every UPDATE_INTERVAL: reads the real ratio and sets the
-- animation's target, or hides the ring if there's nothing to show.
local function PollThreatTarget()
	-- NOT "X and X()" here - and/or always truncate their operand to a
	-- single value, even when that operand is a function call that
	-- would otherwise return multiple values, so the second return
	-- (ratio) would silently come back nil every time. This was the
	-- actual bug behind the ring never appearing.
	local ratio
	if OrbMeter_GetThreatDisplay then
		local _, r = OrbMeter_GetThreatDisplay()
		ratio = r
	end

	if not ratio then
		threatRingVisible = false
		ringBase:Hide()
		ringFill:Hide()
		return
	end

	if not threatRingVisible then
		-- First appearance (or returning after being hidden) - snap
		-- straight to it instead of sweeping up from 0, which would
		-- misleadingly read as "threat building from nothing."
		threatAnimFrom, threatAnimTo, threatAnimStart = ratio, ratio, GetTime()
		threatRingVisible = true
		ringBase:Show()
		ringFill:Show()
		return
	end

	local now = GetTime()
	local t = (THREAT_ANIM_DURATION > 0) and ((now - threatAnimStart) / THREAT_ANIM_DURATION) or 1
	local current = threatAnimFrom + (threatAnimTo - threatAnimFrom) * SmoothStep(t)
	threatAnimFrom, threatAnimTo, threatAnimStart = current, ratio, now
end

-- Runs every frame: renders the eased value between threatAnimFrom and
-- threatAnimTo, regardless of the data-poll throttle above.
local function RenderThreatRing()
	if not threatRingVisible then return end

	local t = (THREAT_ANIM_DURATION > 0) and ((GetTime() - threatAnimStart) / THREAT_ANIM_DURATION) or 1
	local displayRatio = threatAnimFrom + (threatAnimTo - threatAnimFrom) * SmoothStep(t)

	SetPieFraction(ringFill, displayRatio)
	ApplyRingColor(displayRatio)
end

--------------------------------------------------------------------------
-- Events
--------------------------------------------------------------------------

frame:SetScript("OnDragStart", function(self)
	if not db.locked then self:StartMoving() end
end)
frame:SetScript("OnDragStop", function(self)
	self:StopMovingOrSizing()
	local point, _, relPoint, x, y = self:GetPoint()
	db.point, db.relPoint, db.x, db.y = point, relPoint, x, y
end)

--------------------------------------------------------------------------
-- Hover panel: your top abilities for the last (or current) fight
--------------------------------------------------------------------------
-- Follows the orb's mode (damage or healing). One row per ability: icon,
-- name, a bar showing its share of your output, and "value  share%". Kept to
-- the last fight on purpose - the full breakdown is in the menu.
local PANEL_ROWS = 8
local PANEL_MIN_W = 150  -- the panel is as wide as its content needs, within these limits
local PANEL_MAX_W = 300
local MAX_NAME_W = 150
local ROW_H = 16
local PANEL_PAD = 6
local ICON = 14
local BAR_COLOR = { 0.20, 0.45, 0.90, 0.70 } -- blue: last fight

local panel = CreateFrame("Frame", "OrbMeterPanel", UIParent)
panel:SetFrameStrata("TOOLTIP")
panel:SetClampedToScreen(true)
panel:SetWidth(PANEL_MIN_W)
panel:Hide()

local panelBg = panel:CreateTexture(nil, "BACKGROUND")
panelBg:SetAllPoints(panel)
panelBg:SetTexture(0, 0, 0, 0.75)

-- Heading ("Damage Done" / "Effective Healing") in plain outline, same as the
-- scope and numbers beside it.
local panelTitle = panel:CreateFontString(nil, "OVERLAY")
panelTitle:SetFont(STANDARD_TEXT_FONT, 11, "OUTLINE")
panelTitle:SetPoint("TOPLEFT", panel, "TOPLEFT", PANEL_PAD, -PANEL_PAD + 1)
panelTitle:SetJustifyH("LEFT")
local panelInfo = panel:CreateFontString(nil, "OVERLAY")
panelInfo:SetFont(STANDARD_TEXT_FONT, 11, "OUTLINE")
panelInfo:SetPoint("LEFT", panelTitle, "RIGHT", 6, 0)
panelInfo:SetJustifyH("LEFT")
panel.titleLabel = panelTitle
panel.titleInfo = panelInfo

local panelRows = {}
for i = 1, PANEL_ROWS do
	local row = CreateFrame("Frame", "OrbMeterPanelRow" .. i, panel)
	row:SetWidth(PANEL_MIN_W - 2 * PANEL_PAD)
	row:SetHeight(ROW_H)
	row:SetPoint("TOPLEFT", panel, "TOPLEFT", PANEL_PAD, -(PANEL_PAD + 17 + (i - 1) * ROW_H))

	row.bar = row:CreateTexture(nil, "BACKGROUND")
	row.bar:SetTexture("Interface\\TargetingFrame\\UI-StatusBar")
	row.bar:SetVertexColor(BAR_COLOR[1], BAR_COLOR[2], BAR_COLOR[3], BAR_COLOR[4])
	row.bar:SetPoint("TOPLEFT", row, "TOPLEFT", ICON + 2, 0)
	row.bar:SetHeight(ROW_H - 2)

	row.icon = row:CreateTexture(nil, "ARTWORK")
	row.icon:SetWidth(ICON)
	row.icon:SetHeight(ICON)
	row.icon:SetPoint("TOPLEFT", row, "TOPLEFT", 0, -1)

	row.nameText = row:CreateFontString(nil, "OVERLAY")
	row.nameText:SetFont(STANDARD_TEXT_FONT, 10, "OUTLINE")
	row.nameText:SetPoint("LEFT", row, "LEFT", ICON + 5, 0)
	row.nameText:SetJustifyH("LEFT")
	row.nameText:SetHeight(12)

	row.valueText = row:CreateFontString(nil, "OVERLAY")
	row.valueText:SetFont(STANDARD_TEXT_FONT, 10, "OUTLINE")
	row.valueText:SetPoint("RIGHT", row, "RIGHT", -2, 0)
	row.valueText:SetJustifyH("RIGHT")

	row:Hide()
	panelRows[i] = row
end

local function PlacePanel()
	panel:ClearAllPoints()
	local _, cy = frame:GetCenter()
	local screenH = UIParent:GetHeight()
	if cy and screenH and cy < screenH / 2 then
		panel:SetPoint("BOTTOM", frame, "TOP", 0, 4)  -- orb low on screen: open upward
	else
		panel:SetPoint("TOP", frame, "BOTTOM", 0, -4) -- otherwise open downward
	end
end

-- Sizes the panel to its content: widest of the title and the rows
-- (icon + name + gap + value), clamped to the limits above. Bars are scaled
-- to whatever width results.
local function FitPanel(shownRows)
	local need = panelTitle:GetStringWidth() + 6 + panelInfo:GetStringWidth()
	for i = 1, shownRows do
		local row = panelRows[i]
		row.nameText:SetWidth(0) -- unconstrained, so it reports its real width
		local nameW = math.min(row.nameText:GetStringWidth(), MAX_NAME_W)
		row.nameText:SetWidth(nameW)
		need = math.max(need, ICON + 5 + nameW + 14 + row.valueText:GetStringWidth() + 2)
	end
	local w = math.max(PANEL_MIN_W, math.min(PANEL_MAX_W, math.ceil(need) + 2 * PANEL_PAD))
	panel:SetWidth(w)
	for i = 1, PANEL_ROWS do panelRows[i]:SetWidth(w - 2 * PANEL_PAD) end
	return w - 2 * PANEL_PAD - ICON - 2 -- room for a full-length bar
end

local function RefreshPanel()
	local mode = OrbMeter_GetCurrentMode and OrbMeter_GetCurrentMode() or "dps"
	local kind = (mode == "healing") and "healing" or "damage"
	-- "Last" setting: the fight in progress (flagged as Current) while there is
	-- one, otherwise the last completed fight.
	local scope = "last"
	if db and db.hoverScope == "total" then
		scope = "total"
	elseif OrbMeter_InCombat and OrbMeter_InCombat() then
		scope = "current"
	end
	local rows, own, duration
	if OrbMeter_GetAbilityRows then rows, own, duration = OrbMeter_GetAbilityRows(kind, PANEL_ROWS, scope) end

	local scopeName = (scope == "total") and "(Total)" or (scope == "current") and "(Current)" or "(Last)"
	panelTitle:SetText((kind == "healing") and "Effective Healing" or "Damage Done")
	if not rows then
		panelInfo:SetText(scopeName .. " no data yet")
		for i = 1, PANEL_ROWS do panelRows[i]:Hide() end
		FitPanel(0)
		panel:SetHeight(PANEL_PAD * 2 + 17)
		return
	end

	local fmt = OrbMeter_FormatNumber or tostring
	panelInfo:SetText(string.format("%s %s - %s %s", scopeName, fmt(own), fmt(own / duration), (kind == "healing") and "HPS" or "DPS"))

	for i = 1, PANEL_ROWS do
		local row, r = panelRows[i], rows[i]
		if r then
			row.nameText:SetText(r.name)
			row.valueText:SetText(string.format("%s  %.0f%%", fmt(r.value), r.share))
			row.icon:SetTexture(r.icon or "Interface\\Icons\\INV_Misc_QuestionMark")
		end
	end
	local barMax = FitPanel(#rows)
	for i = 1, PANEL_ROWS do
		local row, r = panelRows[i], rows[i]
		if r then
			row.bar:SetWidth(math.max(1, barMax * r.share / 100))
			row:Show()
		else
			row:Hide()
		end
	end
	panel:SetHeight(PANEL_PAD * 2 + 17 + #rows * ROW_H)
end

local function ShowPanel()
	PlacePanel()
	RefreshPanel()
	panel:Show()
end

frame:SetScript("OnEnter", function(self)
	isMouseOver = true
	UpdateVisibility()
	ShowPanel()
end)
frame:SetScript("OnLeave", function(self)
	isMouseOver = false
	UpdateVisibility()
	panel:Hide()
end)

frame:RegisterEvent("PLAYER_REGEN_DISABLED") -- entering combat
frame:RegisterEvent("PLAYER_REGEN_ENABLED")  -- leaving combat
frame:SetScript("OnEvent", function(self, event)
	if event == "PLAYER_REGEN_DISABLED" then
		combatEndTime = nil
		UpdateVisibility()
	elseif event == "PLAYER_REGEN_ENABLED" then
		combatEndTime = GetTime()
		UpdateVisibility()
	end
end)

-- Left: mode cycle (dps <-> healing) for the inner orb only - the
-- threat ring isn't part of this cycle, it's always-on
-- Right: the menu above
frame:SetScript("OnClick", function(self, button)
	if button == "LeftButton" then
		if OrbMeter_CycleMode then
			local newMode = OrbMeter_CycleMode()
			Print("mode: " .. newMode .. " (pinned - /om adaptive makes it follow your casts again)")
		end
	elseif button == "RightButton" then
		ToggleDropDownMenu(1, nil, menuFrame, "cursor", 0, 0)
	end
end)

local updateAccum = 0
local UPDATE_INTERVAL = 0.2

frame:SetScript("OnUpdate", function(self, elapsed)
	updateAccum = updateAccum + elapsed
	if updateAccum >= UPDATE_INTERVAL then
		updateAccum = 0

		-- Re-evaluated here (not just on the regen events) so the
		-- OUT_OF_COMBAT_GRACE_SECONDS window actually expires and dims
		-- the orb on its own, without needing a further combat event.
		UpdateVisibility()

		PollThreatTarget()

		if panel:IsShown() then RefreshPanel() end

		local mode = OrbMeter_GetCurrentMode and OrbMeter_GetCurrentMode() or "dps"

		if mode == "healing" then
			local text, ratio = ComputeMeterDisplay(
				"healing",
				OrbMeter_GetCurrentFightHPS, OrbMeter_GetTopFightHPS,
				OrbMeter_GetLastFightHPS, OrbMeter_GetLastFightTopHPS
			)
			number:SetText(text)
			ApplyRatioColor(ratio, COLOR_HOT_GREEN)
		else -- dps
			local text, ratio = ComputeMeterDisplay(
				"dps",
				OrbMeter_GetCurrentFightDPS, OrbMeter_GetTopFightDPS,
				OrbMeter_GetLastFightDPS, OrbMeter_GetLastFightTopDPS
			)
			number:SetText(text)
			ApplyRatioColor(ratio)
		end
	end

	RenderThreatRing()
end)

--------------------------------------------------------------------------
-- Settings (shared by the slash commands and the options window)
--------------------------------------------------------------------------

local RefreshOptions -- defined with the window below

local function SetLocked(on)
	db.locked = on and true or false
	ApplyLockState()
	UpdateVisibility()
	RefreshOptions()
end

local function SetDimOutOfCombat(on)
	db.hideOutOfCombat = on and true or false
	UpdateVisibility()
	RefreshOptions()
end

local function SetOutOfCombatAlpha(pct)
	db.outOfCombatAlpha = pct / 100
	UpdateVisibility()
	RefreshOptions()
end

local function SetOrbSize(n)
	ApplySize(n)
	RefreshOptions()
end

local function SetAdaptiveOption(on)
	db.adaptive = on and true or false
	if OrbMeter_SetAdaptive then OrbMeter_SetAdaptive(db.adaptive) end
	RefreshOptions()
end

local function SetHoverScope(scope)
	db.hoverScope = (scope == "total") and "total" or "last"
	if panel:IsShown() then RefreshPanel() end
	RefreshOptions()
end

--------------------------------------------------------------------------
-- Options window
--------------------------------------------------------------------------
-- Built the first time it is opened. Every control calls the same setter
-- the matching slash command uses, and RefreshOptions() (called by every
-- setter) keeps the window in step when a setting is changed by a command.

local optionsFrame
local optionControls = {}
local refreshingOptions = false

local OPT_W = 320
local OPT_INNER = 272 -- width of sliders and the button
local GREY = { 0.5, 0.5, 0.5 }
local WHITE = { 1, 1, 1 }

local function MakeLabel(parent, text, x, y)
	local fs = parent:CreateFontString(nil, "OVERLAY")
	fs:SetFont(STANDARD_TEXT_FONT, 11, "")
	fs:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
	fs:SetJustifyH("LEFT")
	fs:SetText(text)
	return fs
end

local function MakeCheck(name, x, y, text, onChange, tipTitle, tipText)
	local cb = CreateFrame("CheckButton", name, optionsFrame, "UICheckButtonTemplate")
	cb:SetPoint("TOPLEFT", optionsFrame, "TOPLEFT", x, y)
	cb:SetWidth(24)
	cb:SetHeight(24)
	cb.label = MakeLabel(optionsFrame, text, x + 28, y - 6)
	-- the label is part of the click target, like any other checkbox
	cb:SetHitRectInsets(0, -(cb.label:GetStringWidth() + 8), 0, 0)
	cb:SetScript("OnClick", function(self)
		if not refreshingOptions then onChange(self:GetChecked() and true or false) end
	end)
	if tipText then -- hover explanation (the label is part of the hit area too)
		cb.tipTitle, cb.tipText = tipTitle, tipText
		cb:SetScript("OnEnter", function(self)
			GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
			GameTooltip:SetText(self.tipTitle, 1, 1, 1)
			GameTooltip:AddLine(self.tipText, 1, 0.82, 0, 1)
			GameTooltip:Show()
		end)
		cb:SetScript("OnLeave", function() GameTooltip:Hide() end)
	end
	return cb
end

local function MakeSlider(name, y, minV, maxV, step, lowText, highText, onChange)
	local sl = CreateFrame("Slider", name, optionsFrame, "OptionsSliderTemplate")
	sl:SetPoint("TOPLEFT", optionsFrame, "TOPLEFT", 24, y)
	sl:SetWidth(OPT_INNER)
	sl:SetHeight(16)
	sl:SetMinMaxValues(minV, maxV)
	sl:SetValueStep(step)
	sl.label = MakeLabel(optionsFrame, "", 24, y + 16)
	-- the template's own end labels say "Low"/"High"; show the real range instead
	local low, high = rawget(_G, name .. "Low"), rawget(_G, name .. "High")
	if low then low:SetText(lowText) end
	if high then high:SetText(highText) end
	sl:SetScript("OnValueChanged", function(self, value)
		if not refreshingOptions then onChange(math.floor(value / step + 0.5) * step) end
	end)
	return sl
end

-- Greys a control out (and makes it unclickable) or restores it.
local function SetControlEnabled(control, enabled)
	control.optEnabled = enabled and true or false
	local color = enabled and WHITE or GREY
	if control.label then control.label:SetTextColor(color[1], color[2], color[3]) end
	if control.Enable then -- checkbuttons
		if enabled then control:Enable() else control:Disable() end
	end
	control:EnableMouse(enabled and true or false)
	control:SetAlpha(enabled and 1 or 0.5)
end

local function BuildOptions()
	optionsFrame = CreateFrame("Frame", "OrbMeterOptions", UIParent)
	optionsFrame:SetWidth(OPT_W)
	optionsFrame:SetHeight(406)
	local pos = db.optionsPos
	if pos then
		optionsFrame:SetPoint(pos[1], UIParent, pos[2], pos[3], pos[4])
	else
		optionsFrame:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
	end
	optionsFrame:SetFrameStrata("DIALOG")
	optionsFrame:SetMovable(true)
	optionsFrame:EnableMouse(true)
	optionsFrame:SetClampedToScreen(true)
	optionsFrame:RegisterForDrag("LeftButton")
	optionsFrame:SetScript("OnDragStart", function(self) self:StartMoving() end)
	optionsFrame:SetScript("OnDragStop", function(self)
		self:StopMovingOrSizing()
		local point, _, relPoint, x, y = self:GetPoint()
		db.optionsPos = { point, relPoint, x, y } -- reopens where you left it
	end)
	optionsFrame:SetScript("OnShow", function() RefreshOptions() end)
	optionsFrame:SetBackdrop({
		bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
		edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
		tile = true, tileSize = 32, edgeSize = 32,
		insets = { left = 11, right = 12, top = 12, bottom = 11 },
	})
	if UISpecialFrames then table.insert(UISpecialFrames, "OrbMeterOptions") end -- Esc closes it

	local title = optionsFrame:CreateFontString(nil, "OVERLAY")
	title:SetFont(STANDARD_TEXT_FONT, 14, "")
	title:SetPoint("TOP", optionsFrame, "TOP", 0, -16)
	title:SetText("OrbMeter")

	-- "?" next to the title: what the addon is, and who made it
	local help = CreateFrame("Button", "OrbMeterOptionsHelp", optionsFrame, "UIPanelButtonTemplate")
	help:SetWidth(20)
	help:SetHeight(20)
	help:SetPoint("LEFT", title, "RIGHT", 8, 0)
	help:SetText("?")
	help:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		GameTooltip:SetText("OrbMeter", 1, 1, 1)
		GameTooltip:AddLine("A small orb showing your damage or healing per second, coloured by how you rank in the group, with a ring for threat. Hover it for an ability overview, left-click to switch Damage/Healing, right-click for reports and stats.", 1, 0.82, 0, 1)
		GameTooltip:AddLine("Made by X08 | Dreamwind (ChromieCraft-EU)", 0.6, 0.8, 1)
		GameTooltip:AddLine("Version " .. ADDON_VERSION, 0.6, 0.6, 0.6)
		GameTooltip:Show()
	end)
	help:SetScript("OnLeave", function() GameTooltip:Hide() end)

	local close = CreateFrame("Button", "OrbMeterOptionsClose", optionsFrame, "UIPanelCloseButton")
	close:SetPoint("TOPRIGHT", optionsFrame, "TOPRIGHT", -4, -4)

	local c = optionControls
	c.lock = MakeCheck("OrbMeterOptLock", 22, -44, "Lock position", SetLocked)
	c.dim = MakeCheck("OrbMeterOptDim", 22, -70, "Dim out of combat", SetDimOutOfCombat)
	c.adaptive = MakeCheck("OrbMeterOptAdaptive", 22, -96, "Adaptive Tracking (Damage/Healing)", SetAdaptiveOption,
		"Adaptive Tracking",
		"Switches the orb between Damage and Healing while you fight: three damage spells (or three healing spells) in a row and it follows what you cast. Your spec and form only set the starting mode, out of combat.")

	-- the two hover choices are tabbed in under their heading
	c.hoverHeading = MakeLabel(optionsFrame, "Hover overview shows", 26, -130)
	c.hoverHeading:SetTextColor(1, 0.82, 0)
	c.hoverLast = MakeCheck("OrbMeterOptHoverLast", 44, -146, "Last Fight", function() SetHoverScope("last") end)
	c.hoverTotal = MakeCheck("OrbMeterOptHoverTotal", 44, -170, "Total", function() SetHoverScope("total") end)

	c.size = MakeSlider("OrbMeterOptSize", -222, MIN_SIZE, MAX_SIZE, 1, tostring(MIN_SIZE), tostring(MAX_SIZE), SetOrbSize)
	c.alpha = MakeSlider("OrbMeterOptAlpha", -272, 0, 100, 5, "0%", "100%", SetOutOfCombatAlpha)

	-- A plain note (no checkbox), empty unless the FadeOut addon is installed.
	c.fade = MakeLabel(optionsFrame, "", 26, -320)
	c.fade:SetTextColor(1, 0.82, 0)
	optionsFrame.fadeNote = c.fade

	c.reset = CreateFrame("Button", "OrbMeterOptReset", optionsFrame, "UIPanelButtonTemplate")
	c.reset:SetWidth(OPT_INNER)
	c.reset:SetHeight(22)
	c.reset:SetPoint("TOPLEFT", optionsFrame, "TOPLEFT", 24, -354)
	c.reset:SetText("Reset Logs")
	local ver = optionsFrame:CreateFontString(nil, "OVERLAY")
	ver:SetFont(STANDARD_TEXT_FONT, 10, "")
	ver:SetPoint("BOTTOM", optionsFrame, "BOTTOM", 0, 16)
	ver:SetTextColor(0.6, 0.6, 0.6)
	ver:SetText("Version " .. ADDON_VERSION)
	optionsFrame.versionText = ver
	c.reset:SetScript("OnClick", function()
		if OrbMeter_ResetLogs then OrbMeter_ResetLogs() end
		Print("logs reset.")
	end)
end

RefreshOptions = function()
	if not optionsFrame then return end
	local c = optionControls
	refreshingOptions = true
	c.lock:SetChecked(db.locked)
	c.dim:SetChecked(db.hideOutOfCombat)
	c.adaptive:SetChecked(db.adaptive)
	c.size:SetValue(db.size)
	c.size.label:SetText("Orb size: " .. db.size)
	local pct = math.floor(db.outOfCombatAlpha * 100 + 0.5)
	c.alpha:SetValue(pct)
	c.alpha.label:SetText("Opacity out of combat: " .. pct .. "%")
	c.hoverLast:SetChecked(db.hoverScope ~= "total")
	c.hoverTotal:SetChecked(db.hoverScope == "total")

	-- FadeOut: when it owns the orb's alpha the two dimming settings do nothing
	local installed = FadeOut and FadeOut.IsManaged and true or false
	local managed = IsFadeOutManaged() and true or false
	if not installed then
		c.fade:SetText("")
	elseif managed then
		c.fade:SetText("FadeOut addon DETECTED - Dimming is ignored")
	else
		c.fade:SetText("FadeOut addon DETECTED - Dimming not set")
	end
	SetControlEnabled(c.dim, not managed)
	SetControlEnabled(c.alpha, not managed)
	refreshingOptions = false
end

ToggleOptions = function()
	if not optionsFrame then
		-- real frames are born shown: build, then hide, so the first call opens it
		BuildOptions()
		optionsFrame:Hide()
	end
	if optionsFrame:IsShown() then
		optionsFrame:Hide()
	else
		RefreshOptions()
		optionsFrame:Show()
	end
end

--------------------------------------------------------------------------
-- Slash commands
--------------------------------------------------------------------------

local function SlashHandler(msg)
	msg = msg or ""
	local cmd, rest = msg:match("^(%S*)%s*(.-)$")
	cmd = (cmd or ""):lower()

	if cmd == "unlock" then
		SetLocked(false)
		Print("unlocked - drag to move. Type /om lock when done.")
	elseif cmd == "lock" then
		SetLocked(true)
		Print("locked.")
	elseif cmd == "size" then
		local n = tonumber(rest)
		if n then
			SetOrbSize(n)
			Print("size set to " .. db.size .. ".")
		else
			Print("usage: /om size <" .. MIN_SIZE .. "-" .. MAX_SIZE .. ">")
		end
	elseif cmd == "reset" then
		if OrbMeter_ResetLogs then OrbMeter_ResetLogs() end
		Print("logs reset.")
	elseif cmd == "debug" then
		if OrbMeter_DebugString then
			Print(OrbMeter_DebugString())
		else
			Print("debug info unavailable - core not loaded?")
		end
	elseif cmd == "combat" then
		SetDimOutOfCombat(not db.hideOutOfCombat)
		Print("dim out of combat: " .. (db.hideOutOfCombat and "ON" or "OFF"))
		if IsFadeOutManaged() then
			Print("FadeOut currently controls the orb's visibility - untick \"" .. FADEOUT_LABEL .. "\" in /fadeout for this setting to apply.")
		end
	elseif cmd == "adaptive" then
		local want
		if rest == "on" then want = true elseif rest == "off" then want = false else want = not db.adaptive end
		SetAdaptiveOption(want)
		Print("adaptive mode: " .. (want and "ON - the orb follows what you cast (a left-click pins it)" or "OFF - mode comes from your spec/form, or your last left-click"))
	elseif cmd == "hover" then
		if rest == "last" or rest == "total" then
			SetHoverScope(rest)
			Print("hover overview now shows the " .. (rest == "total" and "total since reset" or "last fight") .. ".")
		else
			Print("usage: /om hover last|total  (current: " .. db.hoverScope .. ")")
		end
	elseif cmd == "options" or cmd == "config" then
		ToggleOptions()
	elseif cmd == "alpha" then
		local n = tonumber(rest)
		if n and n >= 0 and n <= 100 then
			SetOutOfCombatAlpha(n)
			Print("out-of-combat alpha set to " .. n .. "%.")
			if IsFadeOutManaged() then
				Print("FadeOut currently controls the orb's visibility - use its Idle Opacity slider (/fadeout), or untick \"" .. FADEOUT_LABEL .. "\" there for this setting to apply.")
			end
		else
			Print("usage: /om alpha <0-100>  (current: " .. math.floor(db.outOfCombatAlpha * 100 + 0.5) .. "%)")
		end
	else
		Print("commands: options, unlock, lock, size <n>, reset, debug, combat, adaptive [on|off], hover last|total, alpha <0-100>")
	end
end

SLASH_ORBMETER1 = "/orbmeter"
SLASH_ORBMETER2 = "/om"
SlashCmdList["ORBMETER"] = SlashHandler

--------------------------------------------------------------------------
-- Init
--------------------------------------------------------------------------

local init = CreateFrame("Frame")
init:RegisterEvent("ADDON_LOADED")
init:SetScript("OnEvent", function(self, event, name)
	if name ~= ADDON_NAME then return end

	OrbMeterDB = OrbMeterDB or {}
	db = CopyDefaults(OrbMeterDB, defaults)

	if OrbMeter_SetAdaptive then OrbMeter_SetAdaptive(db.adaptive) end
	ApplyPosition()
	ApplySize(db.size)
	ApplyRatioColor(0)
	ApplyLockState()

	-- Optional FadeOut integration (FadeOut loads first via OptionalDeps).
	-- Registered before the first visibility pass so it already knows FadeOut
	-- owns the alpha. The suspend callback keeps FadeOut off the orb while
	-- it's unlocked for dragging.
	if FadeOut and FadeOut.Register then
		FadeOut.Register(FADEOUT_KEY, FADEOUT_LABEL, frame, function()
			return not db.locked
		end)
	end

	UpdateVisibility()

	self:UnregisterEvent("ADDON_LOADED")
end)
