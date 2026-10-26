--[[
    OrbMeter: core (tracking only - all UI lives in OrbMeter_visual.lua)
    Made by X08 | Dreamwind (ChromieCraft-EU).  WoW 3.3.5a, Lua 5.1.

    What it does
      * Parses the combat log into damage and effective-healing totals for you
        (pets and guardians folded in) and for your party/raid, per fight and
        since the last reset, plus a per-ability breakdown of your own output.
      * Defines "a fight" (see Combat session handling): one window shared by
        the whole group, so every member's rate is over the same seconds.
      * Picks the orb's mode (damage or healing): by spec and form while out of
        combat, and by what you cast while in combat (adaptive mode).
      * Reads threat, and builds the chat/print text for the reports.

    How the numbers are counted
      damage  = amount - overkill + absorbed   (shield-absorbed damage counts,
                overkill does not)
      healing = amount - overheal, plus damage a shield actually absorbed,
                credited to the shield's caster
      Soul Link damage that is redirected to a pet is netted out first.

    The visual layer polls the OrbMeter_* globals exported at the bottom of this
    file. No slash commands live here - see the header of OrbMeter_visual.lua.
--]]

local frame = CreateFrame("Frame", "OrbMeterEventFrame")

-- ============================================================
-- State
-- ============================================================

local playerGUID = nil
local petGUID = nil            -- your own pet's GUID, re-checked on UNIT_PET; nil when no pet
-- Pet/guardian -> owner maps. Both are language-independent (GUIDs only).
-- petOwnerUnit is rebuilt from the pet unit tokens (pet, partypetN, raidpetN)
-- on roster / UNIT_PET events; petOwnerSummon is filled from SPELL_SUMMON
-- (totems, guardians, anything without a unit token) and capped.
local petOwnerUnit = {}
local petOwnerSummon = {}
local petOwnerSummonCount = 0
local SUMMON_CACHE_MAX = 300

-- Active absorb shields on any unit, learned from aura events:
-- shields[targetGUID][spellId] = { credit = <GUID that gets the healing credit>, seq = <apply order> }
-- Only shields cast by you / your group (or their pets) are tracked.
local shields = {}
local shieldSeq = 0
local absorbCredited = 0       -- shield absorb credited to a caster since reset (debug)
local absorbUnattributed = 0   -- damage absorbed on you/your group with no tracked shield (debug)
local rosterGUIDs = {}          -- [GUID] = true, for party/raid members (does NOT include player)
local rosterNames = {}          -- [GUID] = unit name, for report text. Deliberately NOT wiped on roster
                                -- rebuilds, so someone who leaves the group still has a name in the report.

local inCombat = false          -- a fight is being recorded: you OR anyone in your group is in combat
local playerInCombat = false    -- from PLAYER_REGEN_* events
local groupInCombat = false     -- from polling UnitAffectingCombat on party/raid members
local combatStartTime = nil
local combatEndTime = nil      -- GetTime() at the last EndFight(), nil until the first fight ends

-- How long the orb keeps showing the last fight's DPS/HPS after combat ends
-- before it settles back to idle (0 / neutral colour).
local LAST_FIGHT_LINGER_SECONDS = 10

local currentFight = {
	damage = 0,
	healing = 0,   -- effective healing: amount - overhealing - healAbsorbed
}

local rosterFightDamage = {}    -- [GUID] = damage dealt this fight, roster members only
local rosterFightHealing = {}   -- [GUID] = effective healing dealt this fight, roster members only

-- Since-reset per-member totals, accumulated from the two tables above at
-- the end of each fight (same moment totalStats is). Feed the "Total" top-5
-- reports; wiped by ResetLogs.
local rosterTotalDamage = {}     -- [GUID] = damage across all completed fights since reset
local rosterTotalHealing = {}    -- [GUID] = effective healing across all completed fights since reset

-- Per-ability breakdown of YOUR output (pets included, tagged), for the
-- Damage Stats / Healing Stats reports. Entries:
--   { total, hits, crits, misses, over (overheal), pet, shield }
-- abilityFight holds the fight in progress; abilityTotal accumulates each
-- finished fight (see EndFight).
local abilityFight = { damage = {}, healing = {} }
local abilityTotal = { damage = {}, healing = {} }

-- The "current" tables above (currentFight, rosterFight*, abilityFight) hold
-- the fight in progress. When a fight ends they are copied into these "last
-- fight" snapshots and cleared, so "Last Fight" always means the most recent
-- COMPLETED fight - even while the next one is being fought.
local rosterLastDamage = {}
local rosterLastHealing = {}
local abilityLast = { damage = {}, healing = {} }

-- Events that arrive before a fight is noticed (your first hit can log before
-- PLAYER_REGEN_DISABLED, a group member's before the 0.25s poll sees them)
-- are kept, not thrown away: if a fight starts within PREROLL seconds of the
-- first such event, they become part of it and it starts at that event.
local PREROLL = 2.0
local idleSince = nil
local EMPTY = {} -- shared, always empty

-- Fight window. A fight with other players in it is measured from the first
-- hit to the last hit by ANYONE, not by combat flags: a healer's flag can
-- outlast the last hit by a minute (HoTs, rolling Lifebloom), which skews
-- everyone's rate. Flags still decide fights nobody dealt damage in.
local DAMAGE_IDLE = 8.0         -- no group damage for this long ends a shared fight
local GROUP_END_GRACE = 3.0     -- a group member must be out of combat this long before the
                                -- group counts as done (bridges feign death, evading mobs)
local firstDamageTime, lastDamageTime = nil, nil
local sharedDamage = false      -- somebody other than you dealt damage in this fight
local flagSuppressed = false    -- the fight was ended by idleness while your flag is still up
local groupSeenTime, playerLeftTime = nil, nil

-- Snapshot taken at EndFight(). currentFight resets to 0 at the next
-- StartFight(), so this is what the orb displays in the gap between
-- fights - otherwise the number (and its color ratio) would drop to
-- 0/neutral the instant combat ends.
local lastFight = {
	damage = 0,
	duration = 0,
	dps = 0,
	topDamage = 0,
	topDPS = 0,
	healing = 0,
	hps = 0,
	topHealing = 0,
	topHPS = 0,
}

local totalStats = {
	damage = 0,
	healing = 0,
	duration = 0,  -- summed combat seconds, for total DPS/HPS
}

local autoMode = "dps"          -- "dps" | "healing" - recalculated from spec/stance
local modeOverride = nil        -- set by manual left-click cycle; nil = defer to autoMode

-- Adaptive mode: after ADAPT_RUN casts in a row of one kind (damage or
-- healing), the orb follows that kind - so a healer who starts nuking, or a
-- caster who starts healing, sees the number that matters. Each spell's kind
-- is learned from what it actually does for you (damage or heal events, DoT
-- and HoT ticks included), so no spell list is needed; shields are the one
-- exception because they only heal when damaged (see ABSORB_SPELLS).
-- Spells that haven't produced a result yet are skipped, not counted as a
-- break in the run. A manual left-click pins the mode and pauses this.
local ADAPT_RUN = 3             -- three casts in a row of one kind
local adaptiveEnabled = true
local adaptiveMode = nil        -- "dps" | "healing" | nil = no opinion
local spellKind = {}            -- spellId -> "damage" | "healing"
local unclassified = {}         -- spellIds cast before their kind was known
local runKind, runCount = nil, 0

-- Modes the inner orb (number + dps/healing color) cycles through on
-- left-click. Threat is NOT one of these any more - it's rendered as
-- the always-on outer ring instead (see the visual layer), independent
-- of whatever the inner orb is currently showing.
local MODE_SEQUENCE = { "dps", "healing" }

-- Called whenever something is recorded; marks the start of "idle" output
-- (anything recorded while no fight is running) for the pre-roll above.
local function NoteActivity()
	if not inCombat and not idleSince then idleSince = GetTime() end
end

-- ============================================================
-- Number formatting
-- ============================================================

local function FormatNumber(n)
	if n >= 1000000 then
		return string.format("%.1fM", n / 1000000)
	elseif n >= 1000 then
		return string.format("%.1fK", n / 1000)
	else
		return string.format("%d", n)
	end
end

-- ============================================================
-- Roster tracking
-- ============================================================

-- Maps every pet we can see by unit token to its owner's GUID: your own
-- pet, plus partypetN / raidpetN for group members (same approach Details!
-- uses - matching the pet's GUID against the pet unit tokens, so no
-- tooltip or name matching and therefore no locale dependence).
local function RebuildPets()
	petGUID = UnitExists("pet") and UnitGUID("pet") or nil
	table.wipe(petOwnerUnit)
	if petGUID and playerGUID then
		petOwnerUnit[petGUID] = playerGUID
	end

	local numRaid, numParty = GetNumRaidMembers(), GetNumPartyMembers()
	if numRaid > 0 then
		for i = 1, numRaid do
			local petG, ownerG = UnitGUID("raidpet" .. i), UnitGUID("raid" .. i)
			if petG and ownerG then petOwnerUnit[petG] = ownerG end
		end
	elseif numParty > 0 then
		for i = 1, numParty do
			local petG, ownerG = UnitGUID("partypet" .. i), UnitGUID("party" .. i)
			if petG and ownerG then petOwnerUnit[petG] = ownerG end
		end
	end
end

-- Who gets the credit for events from `guid`: its owner if it's a known pet
-- or guardian, else the GUID itself. Summons are stored already resolved
-- to the real owner (see OnCombatLogEvent), so a pet's guardian maps
-- straight to the player and no extra hop is needed here.
local function ResolveCredit(guid)
	return petOwnerUnit[guid] or petOwnerSummon[guid] or guid
end

local function RebuildRoster()
	table.wipe(rosterGUIDs)

	if GetNumRaidMembers() > 0 then
		for i = 1, GetNumRaidMembers() do
			local unit = "raid" .. i
			local guid = UnitGUID(unit)
			if guid and guid ~= playerGUID then
				rosterGUIDs[guid] = true
				rosterNames[guid] = UnitName(unit)
			end
		end
	elseif GetNumPartyMembers() > 0 then
		for i = 1, GetNumPartyMembers() do
			local unit = "party" .. i
			local guid = UnitGUID(unit)
			if guid and guid ~= playerGUID then
				rosterGUIDs[guid] = true
				rosterNames[guid] = UnitName(unit)
			end
		end
	end
end

-- ============================================================
-- Role detection / mode auto-selection
-- ============================================================

-- Talent-tab-index -> role, per class, using 3.3.5a's left-to-right tab
-- order (tab 1/2/3 as GetTalentTabInfo returns them). Majority points
-- across these three picks the base role; form/stance below can
-- override it for hybrids.
--
-- Two entries are inherently ambiguous and flagged:
--   Death Knight Blood can be built as a tank or a dps spec - mapped
--   to "tank" here since that's the more common Blood use case, but
--   the Frost/Unholy Presence override below will correct a dps-built
--   Blood DK as long as they're not sitting in Blood Presence.
--   Druid Feral covers both bear-tank and cat-dps - mapped to "tank"
--   for the same reason, corrected by the Cat/Bear form override.
local CLASS_TREE_ROLE = {
	WARRIOR     = { "dps", "dps", "tank" },       -- Arms, Fury, Protection
	PALADIN     = { "healer", "tank", "dps" },    -- Holy, Protection, Retribution
	HUNTER      = { "dps", "dps", "dps" },        -- Beast Mastery, Marksmanship, Survival
	ROGUE       = { "dps", "dps", "dps" },        -- Assassination, Combat, Subtlety
	PRIEST      = { "healer", "healer", "dps" },  -- Discipline, Holy, Shadow
	DEATHKNIGHT = { "tank", "dps", "dps" },       -- Blood (ambiguous), Frost, Unholy
	SHAMAN      = { "dps", "dps", "healer" },     -- Elemental, Enhancement, Restoration
	MAGE        = { "dps", "dps", "dps" },        -- Arcane, Fire, Frost
	WARLOCK     = { "dps", "dps", "dps" },        -- Affliction, Demonology, Destruction
	DRUID       = { "dps", "tank", "healer" },    -- Balance, Feral (ambiguous), Restoration
}

local function GetTalentMajorityRole()
	local _, classToken = UnitClass("player")
	local roles = CLASS_TREE_ROLE[classToken]
	if not roles then return "dps" end

	local bestTab, bestPoints, totalPoints = 1, -1, 0
	for tab = 1, GetNumTalentTabs() do
		local _, _, pointsSpent = GetTalentTabInfo(tab)
		pointsSpent = pointsSpent or 0
		totalPoints = totalPoints + pointsSpent
		if pointsSpent > bestPoints then
			bestPoints = pointsSpent
			bestTab = tab
		end
	end

	-- No talent points spent at all (below talent-unlock level, or a
	-- fresh respec) means there's no real majority to read - every tab
	-- reports 0, so the loop above would otherwise just default to tab
	-- 1 by tie-break, which is Holy for Paladins and Discipline/Holy
	-- for Priests ("healer") rather than anything meaningfully chosen.
	-- Falling back to dps here avoids defaulting a fresh level 1-9
	-- Paladin/Priest to healing mode before they've picked anything.
	if totalPoints == 0 then
		return "dps"
	end

	return roles[bestTab] or "dps"
end

-- Form/stance overrides, keyed by class. Matched by the form's icon
-- (language-independent) first, then by its English name as a fallback.
-- Icon keys are the lowercased file name of the texture that
-- GetShapeshiftFormInfo returns. NOTE: the icon names are from memory and
-- not yet confirmed in the client - /om debug prints the form it sees so
-- they can be checked.
local FORM_ROLE_BY_ICON = {
	DRUID = {
		["ability_racial_bearform"] = "tank",       -- Bear / Dire Bear
		["ability_druid_catform"] = "dps",
		["spell_nature_forceofnature"] = "dps",     -- Moonkin
		["ability_druid_treeoflife"] = "healer",
	},
	WARRIOR = {
		["ability_warrior_defensivestance"] = "tank",
		["ability_warrior_offensivestance"] = "dps", -- Battle
		["ability_racial_avatar"] = "dps",           -- Berserker
	},
	DEATHKNIGHT = {
		["spell_deathknight_bloodpresence"] = "tank",
		["spell_deathknight_frostpresence"] = "dps",
		["spell_deathknight_unholypresence"] = "dps",
	},
}

local FORM_ROLE_BY_NAME = {
	DRUID = {
		["Bear Form"] = "tank",
		["Dire Bear Form"] = "tank",
		["Cat Form"] = "dps",
		["Moonkin Form"] = "dps",
		["Tree of Life Form"] = "healer",
	},
	WARRIOR = {
		["Defensive Stance"] = "tank",
		["Battle Stance"] = "dps",
		["Berserker Stance"] = "dps",
	},
	DEATHKNIGHT = {
		["Blood Presence"] = "tank",
		["Frost Presence"] = "dps",
		["Unholy Presence"] = "dps",
	},
}

local function IconKey(icon)
	if type(icon) ~= "string" then return nil end
	return (icon:lower():match("([^\\/]+)$"))
end

-- Returns role, icon key, name for the current form (role nil = no override).
local function GetFormOverride()
	local _, classToken = UnitClass("player")
	local byIcon, byName = FORM_ROLE_BY_ICON[classToken], FORM_ROLE_BY_NAME[classToken]
	if not byIcon then return nil end

	local formIndex = GetShapeshiftForm()
	if not formIndex or formIndex == 0 then return nil end

	local icon, name = GetShapeshiftFormInfo(formIndex)
	local key = IconKey(icon)
	return (key and byIcon[key]) or (name and byName[name]), key, name
end

local function DetectRole()
	return (GetFormOverride()) or GetTalentMajorityRole()
end

-- Threat no longer has its own inner-orb mode (it's the outer ring
-- now - see the visual layer), so a tank's inner orb defaults to dps,
-- same as the dps role. Kept as an explicit mapping rather than
-- folded into the "or dps" fallback below, so a future role split
-- doesn't silently need to rediscover this.
local ROLE_TO_MODE = {
	tank = "dps",
	healer = "healing",
	dps = "dps",
}

local function RecalculateAutoMode()
	local role = DetectRole()
	autoMode = ROLE_TO_MODE[role] or "dps"
	-- a new form/spec/zone is a fresh start for the cast-following logic
	adaptiveMode, runKind, runCount = nil, nil, 0
end

local function GetCurrentMode()
	return modeOverride or (adaptiveEnabled and adaptiveMode) or autoMode
end

local function NoteCastKind(kind)
	if kind == runKind then
		runCount = runCount + 1
	else
		runKind, runCount = kind, 1
	end
	if runCount >= ADAPT_RUN then
		adaptiveMode = (kind == "healing") and "healing" or "dps"
	end
end

-- Called when one of your own spells does damage or heals.
local function LearnSpellKind(spellId, kind)
	if type(spellId) ~= "number" then return end
	spellKind[spellId] = kind
	if unclassified[spellId] then
		unclassified[spellId] = nil
		NoteCastKind(kind) -- count the cast that came before we knew
	end
end

-- Turning it on also drops a manual pin, so "follow my casts" is what you get.
local function SetAdaptive(on)
	adaptiveEnabled = on and true or false
	if adaptiveEnabled then
		modeOverride = nil
		adaptiveMode, runKind, runCount = nil, nil, 0
	end
end

local function IsAdaptive()
	return adaptiveEnabled
end

local function CycleMode()
	local currentIdx = 1
	local current = GetCurrentMode()
	for i, m in ipairs(MODE_SEQUENCE) do
		if m == current then
			currentIdx = i
			break
		end
	end
	local nextIdx = (currentIdx % #MODE_SEQUENCE) + 1
	modeOverride = MODE_SEQUENCE[nextIdx]
	return modeOverride
end

-- ============================================================
-- Threat
-- ============================================================

-- Threat of `unit` ("player" or "pet") on your target. Returns formatted text
-- (e.g. "+23%", "-87%"), a 0..1 colour ratio, and isTanking - or nil when
-- there is no valid target/threat table to read (no target, target not in
-- combat, no such unit).
--
-- UNVERIFIED ASSUMPTION: this assumes UnitDetailedThreatSituation's
-- scaledPercent is relative to the #2 threat holder when you ARE the top
-- threat (so scaledPercent - 100 is a positive "overthreat" buffer), and
-- relative to the #1/tank when you're NOT (a negative deficit). If that's
-- wrong, the tank-side number is what's off; the dps-side number is more
-- likely right either way. Worth checking the first time you are grouped with
-- an actual tank.
local function ThreatDisplayFor(unit)
	if not UnitExists(unit) or not UnitExists("target") then return nil end

	local isTanking, status, scaledPercent = UnitDetailedThreatSituation(unit, "target")
	if status == nil then return nil end

	scaledPercent = scaledPercent or 0
	local delta = scaledPercent - 100
	local sign = delta >= 0 and "+" or ""
	local text = string.format("%s%d%%", sign, math.floor(delta + 0.5))

	local ratio = scaledPercent / 100
	if ratio < 0 then ratio = 0 elseif ratio > 1 then ratio = 1 end

	return text, ratio, isTanking
end

local function GetThreatDisplay() return ThreatDisplayFor("player") end

-- The pet's own reading, for hunters/warlocks checking how close they are to
-- pulling aggro off their pet. A pet is just another entry on the mob's threat
-- table, so GetThreatDisplay is already measured against it when it holds top
-- threat; this only exposes the pet's number explicitly.
local function GetPetThreatDisplay() return ThreatDisplayFor("pet") end

-- Seconds since this pull began, or nil outside combat / before any time
-- has passed (callers treat nil as "no rate").
local function FightElapsed()
	if not combatStartTime then return nil end
	local elapsed = GetTime() - combatStartTime
	if elapsed <= 0 then return nil end
	return elapsed
end

-- Highest of your own value and any tracked roster member's value.
local function MaxWithRoster(selfValue, rosterTable)
	local top = selfValue
	for _, v in pairs(rosterTable) do
		if v > top then top = v end
	end
	return top
end

-- ============================================================
-- Combat session handling
-- ============================================================

local function ClearCurrent()
	currentFight.damage = 0
	currentFight.healing = 0
	table.wipe(rosterFightDamage)
	table.wipe(rosterFightHealing)
	table.wipe(abilityFight.damage)
	table.wipe(abilityFight.healing)
	firstDamageTime, lastDamageTime, sharedDamage = nil, nil, false
end

local function StartFight()
	local now = GetTime()
	inCombat = true
	if idleSince and now - idleSince <= PREROLL then
		combatStartTime = idleSince -- keep what happened just before the fight was noticed
	else
		combatStartTime = now
		ClearCurrent()
	end
	idleSince = nil
end

local function CopyInto(dst, src)
	table.wipe(dst)
	for k, v in pairs(src) do dst[k] = v end
end

local function MergeAbilities(dst, src)
	for key, a in pairs(src) do
		local t = dst[key]
		if not t then
			t = { total = 0, hits = 0, crits = 0, misses = 0, over = 0, pet = a.pet, shield = a.shield }
			dst[key] = t
		end
		t.total = t.total + a.total
		t.hits = t.hits + a.hits
		t.crits = t.crits + a.crits
		t.misses = t.misses + a.misses
		t.over = t.over + a.over
		if a.icon and not t.icon then t.icon = a.icon end
	end
end

-- `endTime` is when the fight really stopped (the last moment anyone was in
-- combat); it can be earlier than now when the group's grace period delayed
-- the call, and it is what the fight's duration is measured to.
local function EndFight(endTime)
	inCombat = false
	combatEndTime = GetTime()
	if combatStartTime then
		local duration = math.max(endTime or GetTime(), combatStartTime) - combatStartTime
		if duration > 0 then
			totalStats.damage = totalStats.damage + currentFight.damage
			totalStats.healing = totalStats.healing + currentFight.healing
			totalStats.duration = totalStats.duration + duration

			for guid, dmg in pairs(rosterFightDamage) do
				rosterTotalDamage[guid] = (rosterTotalDamage[guid] or 0) + dmg
			end
			for guid, heal in pairs(rosterFightHealing) do
				rosterTotalHealing[guid] = (rosterTotalHealing[guid] or 0) + heal
			end
			MergeAbilities(abilityTotal.damage, abilityFight.damage)
			MergeAbilities(abilityTotal.healing, abilityFight.healing)
			CopyInto(rosterLastDamage, rosterFightDamage)
			CopyInto(rosterLastHealing, rosterFightHealing)
			table.wipe(abilityLast.damage)
			table.wipe(abilityLast.healing)
			MergeAbilities(abilityLast.damage, abilityFight.damage)
			MergeAbilities(abilityLast.healing, abilityFight.healing)

			lastFight.damage = currentFight.damage
			lastFight.duration = duration
			lastFight.dps = currentFight.damage / duration
			lastFight.healing = currentFight.healing
			lastFight.hps = currentFight.healing / duration

			lastFight.topDamage = MaxWithRoster(currentFight.damage, rosterFightDamage)
			lastFight.topDPS = lastFight.topDamage / duration
			lastFight.topHealing = MaxWithRoster(currentFight.healing, rosterFightHealing)
			lastFight.topHPS = lastFight.topHealing / duration
		end
	end
	combatStartTime = nil
	idleSince = nil
	ClearCurrent() -- the fight is now in the "last" snapshot; start the next from zero
end

local function ResetLogs()
	currentFight.damage = 0
	currentFight.healing = 0
	totalStats.damage = 0
	totalStats.healing = 0
	totalStats.duration = 0
	table.wipe(rosterFightDamage)
	table.wipe(rosterFightHealing)
	table.wipe(rosterTotalDamage)
	table.wipe(rosterTotalHealing)
	table.wipe(abilityFight.damage)
	table.wipe(abilityFight.healing)
	table.wipe(abilityTotal.damage)
	table.wipe(abilityTotal.healing)
	table.wipe(rosterLastDamage)
	table.wipe(rosterLastHealing)
	table.wipe(abilityLast.damage)
	table.wipe(abilityLast.healing)
	idleSince = nil
	absorbCredited, absorbUnattributed = 0, 0
	lastFight.damage = 0
	lastFight.duration = 0
	lastFight.dps = 0
	lastFight.topDamage = 0
	lastFight.topDPS = 0
	lastFight.healing = 0
	lastFight.hps = 0
	lastFight.topHealing = 0
	lastFight.topHPS = 0
	combatEndTime = nil
end
OrbMeter_ResetLogs = ResetLogs -- exposed for the right-click menu

-- A fight is recorded while you OR anyone in your party/raid is in combat,
-- so damage and healing are measured even if you personally aren't (yet, or
-- any more) flagged. Your own flag comes from PLAYER_REGEN_* events; the
-- group's is polled with UnitAffectingCombat, which only reports members the
-- client can see (in range) - a member out of range isn't detected.
-- Auto mode (spec/form) is only re-evaluated OUT of combat: during a fight the
-- adaptive cast-following owns the mode, and a talent/form event must not
-- fight it. A change that arrives mid-fight is applied when the fight ends.
local pendingRecalc = false
local function RequestRecalc()
	if inCombat then
		pendingRecalc = true
	else
		RecalculateAutoMode()
	end
end

local function UpdateCombatState()
	local want = (playerInCombat and not flagSuppressed) or groupInCombat
	if want and not inCombat then
		StartFight()
	elseif not want and inCombat then
		-- a shared fight ends at the last hit by anyone (when it lasted long enough
		-- to be measured that way), otherwise at the last combat flag
		local last = math.max(playerLeftTime or 0, groupSeenTime or 0)
		if sharedDamage and combatStartTime and lastDamageTime and lastDamageTime - combatStartTime >= 1 then
			last = lastDamageTime
		end
		EndFight(last)
		if pendingRecalc then
			pendingRecalc = false
			RecalculateAutoMode()
		end
	end
end

-- Only members you can actually see count: someone fighting in another zone
-- or instance must not stretch your fight window.
local function InSameArea(unit)
	return (not UnitIsVisible) or UnitIsVisible(unit)
end

local function AnyGroupMemberInCombat()
	local numRaid = GetNumRaidMembers()
	if numRaid > 0 then
		for i = 1, numRaid do
			if InSameArea("raid" .. i) and UnitAffectingCombat("raid" .. i) then return true end
		end
	else
		for i = 1, GetNumPartyMembers() do
			if InSameArea("party" .. i) and UnitAffectingCombat("party" .. i) then return true end
		end
	end
	return false
end

-- ============================================================
-- DPS calculation
-- ============================================================

local function GetCurrentFightDPS()
	local elapsed = FightElapsed()
	return elapsed and currentFight.damage / elapsed or 0
end

local function GetTotalDPS()
	if totalStats.duration <= 0 then return 0 end
	return totalStats.damage / totalStats.duration
end

-- Top fight DPS across the player and tracked roster members, for the
-- relative colour ramp. Everyone is divided by the same fight window (see
-- Combat session handling), so members are directly comparable.
local function GetTopFightDPS()
	local elapsed = FightElapsed()
	return elapsed and MaxWithRoster(currentFight.damage, rosterFightDamage) / elapsed or 0
end

local function GetRosterCount()
	local n = 0
	for _ in pairs(rosterGUIDs) do n = n + 1 end
	return n
end

-- ============================================================
-- Healing calculation (mirrors the DPS functions above - see
-- OnCombatLogEvent below for how currentFight.healing /
-- rosterFightHealing get populated)
-- ============================================================

local function GetCurrentFightHPS()
	local elapsed = FightElapsed()
	return elapsed and currentFight.healing / elapsed or 0
end

local function GetTopFightHPS()
	local elapsed = FightElapsed()
	return elapsed and MaxWithRoster(currentFight.healing, rosterFightHealing) / elapsed or 0
end

-- ============================================================
-- Combat log handling
-- ============================================================

-- Shield spell IDs whose absorbed damage counts as healing for the caster.
-- Taken from Recount r1127's absorb table (built for 3.3.5); entries cast by
-- enemies (boss shields) are harmless because only your group's casters are
-- tracked. Not verified against the client beyond that source.
local ABSORB_SPELLS = {
	[48707]=true, [51052]=true, [51271]=true, [62606]=true, [11426]=true, [13031]=true, [13032]=true, [13033]=true,
	[27134]=true, [33405]=true, [43038]=true, [43039]=true, [6143]=true, [8461]=true, [8462]=true, [10177]=true,
	[28609]=true, [32796]=true, [43012]=true, [1463]=true, [8494]=true, [8495]=true, [10191]=true, [10192]=true,
	[10193]=true, [27131]=true, [43019]=true, [43020]=true, [543]=true, [8457]=true, [8458]=true, [10223]=true,
	[10225]=true, [27128]=true, [43010]=true, [58597]=true, [17]=true, [592]=true, [600]=true, [3747]=true,
	[6065]=true, [6066]=true, [10898]=true, [10899]=true, [10900]=true, [10901]=true, [25217]=true, [25218]=true,
	[48065]=true, [48066]=true, [47509]=true, [47511]=true, [47515]=true, [47753]=true, [54704]=true, [47788]=true,
	[7812]=true, [19438]=true, [19440]=true, [19441]=true, [19442]=true, [19443]=true, [27273]=true, [47985]=true,
	[47986]=true, [6229]=true, [11739]=true, [11740]=true, [28610]=true, [47890]=true, [47891]=true, [29674]=true,
	[29719]=true, [29701]=true, [28538]=true, [28537]=true, [28536]=true, [28513]=true, [28512]=true, [28511]=true,
	[7233]=true, [7239]=true, [7242]=true, [7245]=true, [6052]=true, [53915]=true, [53914]=true, [53913]=true,
	[53911]=true, [53910]=true, [17548]=true, [17546]=true, [17545]=true, [17544]=true, [17543]=true, [17549]=true,
	[28527]=true, [29432]=true, [36481]=true, [57350]=true, [17252]=true, [25750]=true, [25747]=true, [25746]=true,
	[23991]=true, [31000]=true, [30997]=true, [31002]=true, [30999]=true, [30994]=true, [23506]=true, [12561]=true,
	[31771]=true, [21956]=true, [29506]=true, [4057]=true, [4077]=true, [39228]=true, [27779]=true, [11657]=true,
	[10368]=true, [37515]=true, [42137]=true, [26467]=true, [27539]=true, [28810]=true, [54808]=true, [55019]=true,
	[64411]=true, [64413]=true, [40322]=true, [65874]=true, [67257]=true, [67256]=true, [67258]=true, [65858]=true,
	[67260]=true, [67259]=true, [67261]=true,
}

-- Damage sub-events we count: direct and periodic damage, plus damage shields.
local DAMAGE_EVENTS = {
	DAMAGE_SHIELD = true, -- Thorns, Lightning Shield, Retribution Aura...: credited to the wearer (spell layout)
	SWING_DAMAGE = true,
	RANGE_DAMAGE = true,
	SPELL_DAMAGE = true,
	SPELL_PERIODIC_DAMAGE = true,
}

-- A hit that was absorbed completely is logged as a MISSED event with
-- missType "ABSORB" and the absorbed amount instead of a damage event.
local MISSED_EVENTS = {
	SWING_MISSED = true,
	RANGE_MISSED = true,
	SPELL_MISSED = true,
	SPELL_PERIODIC_MISSED = true,
}

local HEAL_EVENTS = {
	SPELL_HEAL = true,
	SPELL_PERIODIC_HEAL = true,
}

local AURA_EVENTS = {
	SPELL_AURA_APPLIED = true,
	SPELL_AURA_REFRESH = true,
	SPELL_AURA_REMOVED = true,
}

local function IsTracked(credit)
	return (playerGUID ~= nil and credit == playerGUID) or rosterGUIDs[credit] ~= nil
end

-- The combat log is the one signal every client in range sees identically, so
-- group damage in it opens and extends the shared fight window (flag polling
-- alone differs per client). Only damage counts: healing (HoT ticks, rolling
-- Lifebloom) never opens or extends a fight.
local function NoteDamage(isSelf)
	local t = GetTime()
	lastDamageTime = t
	if not firstDamageTime then firstDamageTime = t end
	if isSelf then
		-- your own hit after an idle split starts the next fight
		if flagSuppressed and playerInCombat then
			flagSuppressed = false
			UpdateCombatState()
		end
		return
	end
	sharedDamage = true
	groupSeenTime = t
	-- the shared clock starts at the first hit, not at whoever's flag came first
	if inCombat and combatStartTime and firstDamageTime > combatStartTime then
		combatStartTime = firstDamageTime
	end
	if not groupInCombat then
		groupInCombat = true
		UpdateCombatState()
	end
end

local function AddDamage(credit, amount)
	NoteActivity()
	if playerGUID and credit == playerGUID then
		currentFight.damage = currentFight.damage + amount
		NoteDamage(true)
	elseif rosterGUIDs[credit] then
		rosterFightDamage[credit] = (rosterFightDamage[credit] or 0) + amount
		NoteDamage(false)
	end
end

local function AddHealing(credit, amount)
	NoteActivity()
	if playerGUID and credit == playerGUID then
		currentFight.healing = currentFight.healing + amount
	elseif rosterGUIDs[credit] then
		rosterFightHealing[credit] = (rosterFightHealing[credit] or 0) + amount
	end
end

-- Ability bookkeeping (your own output only; pets are included and tagged).
local AUTO_ATTACK_NAME = (GetSpellInfo and GetSpellInfo(6603)) or "Auto Attack"

local function SpellIcon(spellId)
	if not GetSpellInfo or type(spellId) ~= "number" then return nil end
	return (select(3, GetSpellInfo(spellId)))
end

local function GetAbility(tbl, key, isPet, isShield)
	local a = tbl[key]
	if not a then
		a = { total = 0, hits = 0, crits = 0, misses = 0, over = 0, pet = isPet or false, shield = isShield or false }
		tbl[key] = a
	end
	return a
end

local function AbilityKey(name, isPet, suffix)
	local key = name or "?"
	if suffix then key = key .. suffix end
	if isPet then key = "Pet: " .. key end
	return key
end

-- A damage hit (dealt = amount - overkill + absorbed) or a miss.
local function RecordDamageAbility(key, isPet, dealt, isMiss, isCrit, icon)
	NoteActivity()
	local a = GetAbility(abilityFight.damage, key, isPet)
	if icon and not a.icon then a.icon = icon end
	if isMiss then
		a.misses = a.misses + 1
		return
	end
	a.total = a.total + dealt
	a.hits = a.hits + 1
	if isCrit then a.crits = a.crits + 1 end
end

local function RecordHealAbility(key, isPet, effective, overheal, isCrit, icon)
	NoteActivity()
	local a = GetAbility(abilityFight.healing, key, isPet)
	if icon and not a.icon then a.icon = icon end
	a.total = a.total + effective
	a.over = a.over + overheal
	a.hits = a.hits + 1
	if isCrit then a.crits = a.crits + 1 end
end

-- Damage that a shield on `destGUID` just soaked counts as healing for
-- whoever cast it. Credit is given at the moment the damage is absorbed, so
-- a shield that expires unused earns nothing and a partly used one earns
-- exactly what it absorbed - nothing has to be deducted later. If several
-- tracked shields are up, the oldest one is assumed to absorb first
-- (approximation).
local function CreditShieldAbsorb(destGUID, absorbed)
	local list = shields[destGUID]
	local best
	if list then
		for _, shield in pairs(list) do
			if not best or shield.seq < best.seq then best = shield end
		end
	end

	if best then
		AddHealing(best.credit, absorbed)
		absorbCredited = absorbCredited + absorbed
		if playerGUID and best.credit == playerGUID then
			local a = GetAbility(abilityFight.healing, (best.name or "Shield") .. " (absorb)", false, true)
			if best.icon and not a.icon then a.icon = best.icon end
			a.total = a.total + absorbed
			a.hits = a.hits + 1
		end
	elseif IsTracked(destGUID) then
		absorbUnattributed = absorbUnattributed + absorbed
	end
end

local function Num(v)
	return type(v) == "number" and v or 0
end

-- Warlock Soul Link (and similar redirects) log the redirected part of a hit
-- twice: as a DAMAGE_SPLIT event on the pet, immediately followed by the real
-- hit whose "absorbed" field includes that same amount. That part was never
-- absorbed by a shield, so it must not be credited to a shield caster.
local splitTime, splitSource, splitAmount = nil, nil, 0

local function OnCombatLogEvent(...)
	local timestamp, eventType, sourceGUID, sourceName, sourceFlags,
		destGUID, destName, destFlags = select(1, ...)

	-- Guardians/totems have no unit token, so learn their owner from the
	-- summon event instead (owner = whoever the summoner resolves to).
	if eventType == "SPELL_SUMMON" then
		local credit = ResolveCredit(sourceGUID)
		if destGUID and IsTracked(credit) then
			if not petOwnerSummon[destGUID] then
				petOwnerSummonCount = petOwnerSummonCount + 1
				if petOwnerSummonCount > SUMMON_CACHE_MAX then
					table.wipe(petOwnerSummon)
					petOwnerSummonCount = 1
				end
			end
			petOwnerSummon[destGUID] = credit
		end
		return
	end

	-- Absorb shields: remember who cast which shield on whom.
	if AURA_EVENTS[eventType] then
		local spellId = select(9, ...)
		if ABSORB_SPELLS[spellId] and destGUID then
			local list = shields[destGUID]
			local credit = (eventType ~= "SPELL_AURA_REMOVED") and ResolveCredit(sourceGUID) or nil
			if credit and IsTracked(credit) then
				shieldSeq = shieldSeq + 1
				list = list or {}
				shields[destGUID] = list
				list[spellId] = { credit = credit, seq = shieldSeq, name = select(10, ...), icon = SpellIcon(spellId) }
			elseif list then
				-- removed, or re-applied by someone we don't track
				list[spellId] = nil
				if next(list) == nil then shields[destGUID] = nil end
			end
		end
		return
	end

	if eventType == "SPELL_CAST_SUCCESS" then
		if sourceGUID == playerGUID then
			local spellId = select(9, ...)
			local kind = spellKind[spellId] or (ABSORB_SPELLS[spellId] and "healing") or nil
			if kind then
				NoteCastKind(kind)
			elseif type(spellId) == "number" then
				unclassified[spellId] = true
			end
		end
		return
	end

	if eventType == "DAMAGE_SPLIT" then
		splitTime, splitSource, splitAmount = timestamp, sourceGUID, Num((select(12, ...)))
		return
	end

	-- Everything below is damage/healing. Events that involve nobody in your
	-- group (neither as source nor as target) can only matter if a tracked
	-- shield sits on their target, so skip them cheaply when none does.
	local credit = ResolveCredit(sourceGUID)
	local sourceTracked = IsTracked(credit)
	if not sourceTracked and not IsTracked(destGUID) and next(shields) == nil then
		return
	end

	-- Damage counted for DPS = amount - overkill + absorbed:
	--   * overkill is excluded (it was never really dealt)
	--   * damage the target's shield absorbed IS included
	-- 3.3.5 layouts (field order checked against a raw log and Recount's handlers):
	--   SWING_DAMAGE:  amount(9) overkill(10) school resisted blocked absorbed(14) ...
	--   SPELL/RANGE/PERIODIC_DAMAGE: amount(12) overkill(13) school resisted blocked absorbed(17) ...
	--   SWING_MISSED:  missType(9) amount(10);  other *_MISSED: missType(12) amount(13)
	--   SPELL_HEAL / SPELL_PERIODIC_HEAL: amount(12) overhealing(13) absorbed(14) critical
	local dealt, absorbedAmount = 0, 0
	local isSelfSource = (playerGUID ~= nil) and (credit == playerGUID)
	local isPetSource = isSelfSource and sourceGUID ~= playerGUID
	local abilityKey, abilityIcon, isMiss, isCrit -- set only for your own damage events
	if DAMAGE_EVENTS[eventType] then
		local amount, overkill, absorbed
		local swing = (eventType == "SWING_DAMAGE")
		if swing then
			amount, overkill = select(9, ...)
			absorbed, isCrit = select(14, ...)
		else
			amount, overkill = select(12, ...)
			absorbed, isCrit = select(17, ...)
		end
		if type(amount) == "number" then
			overkill, absorbed = Num(overkill), Num(absorbed)
			if overkill < 0 then overkill = 0 end -- the log uses -1 for "no overkill"
			dealt = amount - overkill + absorbed
			if dealt < 0 then dealt = 0 end
			absorbedAmount = absorbed
			if isSelfSource then
				abilityKey = AbilityKey(swing and AUTO_ATTACK_NAME or select(10, ...), isPetSource,
					(eventType == "SPELL_PERIODIC_DAMAGE") and " (DoT)" or nil)
				abilityIcon = SpellIcon(swing and 6603 or select(9, ...))
				if not isPetSource and not swing and eventType ~= "DAMAGE_SHIELD" then
					LearnSpellKind(select(9, ...), "damage")
				end
			end
		end
	elseif MISSED_EVENTS[eventType] then
		local swing = (eventType == "SWING_MISSED")
		local missType, missAmount
		if swing then
			missType, missAmount = select(9, ...)
		else
			missType, missAmount = select(12, ...)
		end
		if missType == "ABSORB" and type(missAmount) == "number" and missAmount > 0 then
			dealt, absorbedAmount = missAmount, missAmount
		else
			isMiss = true
		end
		if isSelfSource and missType then
			abilityKey = AbilityKey(swing and AUTO_ATTACK_NAME or select(10, ...), isPetSource,
				(eventType == "SPELL_PERIODIC_MISSED") and " (DoT)" or nil)
			if not isMiss and dealt <= 0 then abilityKey = nil end
		end
	elseif HEAL_EVENTS[eventType] then
		-- Effective healing = raw amount minus overhealing. (The event's own
		-- "absorbed" field is deliberately ignored, same as Recount.)
		local amount, overhealing = select(12, ...)
		if type(amount) == "number" then
			local over = Num(overhealing)
			if over < 0 then over = 0 end
			local effective = amount - over
			if effective < 0 then effective = 0 end
			if effective > 0 and sourceTracked then
				AddHealing(credit, effective)
			end
			if isSelfSource then
				RecordHealAbility(
					AbilityKey(select(10, ...), isPetSource, (eventType == "SPELL_PERIODIC_HEAL") and " (HoT)" or nil),
					isPetSource, effective, over, (select(15, ...)), SpellIcon(select(9, ...)))
				if not isPetSource then LearnSpellKind(select(9, ...), "healing") end
			end
		end
		return
	else
		return
	end

	if splitAmount > 0 then
		-- consume the pending split whether or not it matches this event
		if absorbedAmount > 0 and timestamp == splitTime and sourceGUID == splitSource then
			absorbedAmount = absorbedAmount - splitAmount
			if absorbedAmount < 0 then absorbedAmount = 0 end
		end
		splitAmount = 0
	end
	if absorbedAmount > 0 then
		CreditShieldAbsorb(destGUID, absorbedAmount)
	end
	if dealt > 0 and sourceTracked then
		-- Pet/guardian damage is folded into the owner's numbers (how
		-- Recount and Details! attribute it), for you and for other players.
		AddDamage(credit, dealt)
	end
	if abilityKey then
		RecordDamageAbility(abilityKey, isPetSource, dealt, isMiss, isCrit, abilityIcon)
	end
end

frame:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED")
frame:RegisterEvent("PLAYER_REGEN_DISABLED") -- entering combat
frame:RegisterEvent("PLAYER_REGEN_ENABLED")  -- leaving combat
frame:RegisterEvent("PARTY_MEMBERS_CHANGED")
frame:RegisterEvent("RAID_ROSTER_UPDATE")
frame:RegisterEvent("PLAYER_LOGIN")
frame:RegisterEvent("PLAYER_ENTERING_WORLD")   -- recalc role on login/reload/zone
frame:RegisterEvent("CHARACTER_POINTS_CHANGED") -- fires on talent point spend
frame:RegisterEvent("ACTIVE_TALENT_GROUP_CHANGED") -- dual spec: switching specs
frame:RegisterEvent("PLAYER_TALENT_UPDATE")        -- talents changed
frame:RegisterEvent("UPDATE_SHAPESHIFT_FORM")  -- form/stance/presence changes
frame:RegisterEvent("UNIT_PET")                -- pet summoned/dismissed/changed

frame:SetScript("OnEvent", function(self, event, ...)
	if event == "PLAYER_LOGIN" then
		playerGUID = UnitGUID("player")
		RebuildRoster()
		RebuildPets()
		RecalculateAutoMode()
	elseif event == "COMBAT_LOG_EVENT_UNFILTERED" then
		OnCombatLogEvent(...)
	elseif event == "PLAYER_REGEN_DISABLED" then
		playerInCombat = true
		flagSuppressed = false
		UpdateCombatState()
	elseif event == "PLAYER_REGEN_ENABLED" then
		playerLeftTime = GetTime()
		playerInCombat = false
		flagSuppressed = false
		UpdateCombatState()
	elseif event == "PARTY_MEMBERS_CHANGED" or event == "RAID_ROSTER_UPDATE" then
		RebuildRoster()
		RebuildPets()
	elseif event == "UNIT_PET" then
		-- fires for any unit's pet (player, partyN, raidN); the rebuild is
		-- a handful of UnitGUID calls, so no need to filter by unit
		RebuildPets()
	elseif event == "PLAYER_ENTERING_WORLD" or event == "CHARACTER_POINTS_CHANGED"
		or event == "ACTIVE_TALENT_GROUP_CHANGED" or event == "PLAYER_TALENT_UPDATE"
		or event == "UPDATE_SHAPESHIFT_FORM" then
		if event == "PLAYER_ENTERING_WORLD" then
			RecalculateAutoMode()
		else
			RequestRecalc()
		end
		if event == "PLAYER_ENTERING_WORLD" then
			RebuildPets()
			table.wipe(petOwnerSummon) -- guardians don't survive a zone change
			petOwnerSummonCount = 0
			table.wipe(shields)        -- shields we can't see removed across a zone change
		end
	end
end)

-- Polls the group's combat flags (see UpdateCombatState).
local GROUP_POLL_INTERVAL = 0.25
local groupPollAccum = 0
frame:SetScript("OnUpdate", function(self, elapsed)
	groupPollAccum = groupPollAccum + elapsed
	if groupPollAccum < GROUP_POLL_INTERVAL then return end
	groupPollAccum = 0
	local now = GetTime()
	if AnyGroupMemberInCombat() then
		groupInCombat = true
		groupSeenTime = now
	elseif groupInCombat and now - (groupSeenTime or 0) >= GROUP_END_GRACE then
		groupInCombat = false
	end
	-- a shared fight with no damage from anyone for a while is over, however
	-- long somebody's combat flag lingers (a flagged healer must not hold it open)
	if inCombat and sharedDamage and lastDamageTime and now - lastDamageTime >= DAMAGE_IDLE then
		groupInCombat = false
		if playerInCombat then flagSuppressed = true end
	end
	UpdateCombatState()
end)

-- ============================================================
-- Reports (right-click menu)
-- ============================================================
-- Two kinds, both built here as arrays of chat-ready lines:
--   * Stats    (GetStatsLines):     your own breakdown - totals, share of the
--                                   group, then each ability. Printed locally.
--   * Top list (GetTopReportLines): the group ranked by total damage or total
--                                   effective healing, with each member's share
--                                   of the group. Posted to chat.
-- Both take a scope: "current" = the fight in progress (empty between fights),
-- "last" = the most recent COMPLETED fight (never the one in progress),
-- "total" = completed fights since the last reset (same basis as totalStats).
-- Threat isn't included - it resets per target rather than accumulating.
--
-- Rates divide by the shared fight window for everyone, so every member's
-- rate is over the same seconds. Other players' pets are credited to their
-- owners.

-- Ranked entries { name, value, self } for the scope and kind ("damage" or
-- "healing"), plus the duration to rate them over and the group total.
local function BuildTopList(scope, kind)
	local isHealing = (kind == "healing")
	local selfValue, srcTable, duration

	if scope == "total" then
		selfValue = isHealing and totalStats.healing or totalStats.damage
		srcTable = isHealing and rosterTotalHealing or rosterTotalDamage
		duration = totalStats.duration
	elseif scope == "current" then
		if inCombat and combatStartTime then
			selfValue = isHealing and currentFight.healing or currentFight.damage
			srcTable = isHealing and rosterFightHealing or rosterFightDamage
			duration = GetTime() - combatStartTime
		else
			selfValue, srcTable, duration = 0, EMPTY, 1 -- no fight in progress
		end
	else -- "last": the most recent COMPLETED fight
		selfValue = isHealing and lastFight.healing or lastFight.damage
		srcTable = isHealing and rosterLastHealing or rosterLastDamage
		duration = lastFight.duration
	end

	if not duration or duration <= 0 then duration = 1 end

	local entries = { { name = (UnitName("player")), value = selfValue, self = true } }
	local groupTotal = selfValue
	for guid, value in pairs(srcTable) do
		table.insert(entries, { name = rosterNames[guid] or "Unknown", value = value })
		groupTotal = groupTotal + value
	end

	-- Ties fall back to name so the order is stable (pairs() order isn't).
	table.sort(entries, function(a, b)
		if a.value ~= b.value then return a.value > b.value end
		return tostring(a.name) < tostring(b.name)
	end)

	return entries, duration, groupTotal
end

local SCOPE_TITLE = { current = "Current Fight", last = "Last Fight", total = "Total" }

-- The per-ability table behind a scope (empty for "current" between fights).
local function AbilitiesFor(scope, kind)
	if scope == "total" then return abilityTotal[kind] end
	if scope == "last" then return abilityLast[kind] end
	if inCombat then return abilityFight[kind] end
	return EMPTY
end

-- The whole group ranked for a scope and kind, best first, for the Raid Lead
-- view: { { rank, name, value, rate, share, self }, ... } for everyone who
-- contributed (value > 0), plus the duration and the group total.
local function GetRanking(scope, kind)
	local entries, duration, groupTotal = BuildTopList(scope, kind)
	local list = {}
	for _, e in ipairs(entries) do
		if e.value > 0 then
			list[#list + 1] = {
				rank = #list + 1, name = e.name or "Unknown", value = e.value, self = e.self,
				rate = e.value / duration,
				share = groupTotal > 0 and e.value / groupTotal * 100 or 100,
			}
		end
	end
	return list, duration, groupTotal
end

-- A share of the group only means something with at least two contributors.
local function CountContributors(entries)
	local n = 0
	for _, e in ipairs(entries) do
		if e.value > 0 then n = n + 1 end
	end
	return n
end

-- Group ranking for posting to chat. `kind` is "damage" or "healing";
-- returns nil if everyone is at 0 (no data yet). At most `count` rows.
local function GetTopReportLines(scope, kind, count)
	count = count or 5
	local entries, duration, groupTotal = BuildTopList(scope, kind)
	if CountContributors(entries) == 0 then return nil end

	local isHealing = (kind == "healing")
	local rateLabel = isHealing and "HPS" or "DPS"
	local showShare = CountContributors(entries) > 1 and groupTotal > 0

	local lines = { string.format(
		"OrbMeter - %s - Top %d %s (%.1fs):",
		SCOPE_TITLE[scope] or "Last Fight", count, isHealing and "Effective Healing" or "Damage Done", duration
	) }

	local function Row(rank, e)
		local rate = FormatNumber(e.value / duration)
		if showShare then
			return string.format("%d. %s - %s (%s %s, %.0f%%)",
				rank, e.name or "Unknown", FormatNumber(e.value), rate, rateLabel, e.value / groupTotal * 100)
		end
		return string.format("%d. %s - %s (%s %s)", rank, e.name or "Unknown", FormatNumber(e.value), rate, rateLabel)
	end

	for i, e in ipairs(entries) do
		if i <= count and e.value > 0 then
			table.insert(lines, Row(i, e))
		end
	end

	return lines
end

-- Your own breakdown. `kind` is "damage" or "healing"; returns nil when
-- there's nothing recorded for the scope.
local MAX_STAT_ROWS = 12

local function Percent(part, whole)
	if not whole or whole <= 0 then return 0 end
	return part / whole * 100
end

-- Abilities as an array sorted by output (ties by name, so the order is stable).
local function SortedAbilities(abilities)
	local list = {}
	for key, a in pairs(abilities) do
		table.insert(list, { key = key, a = a })
	end
	table.sort(list, function(x, y)
		if x.a.total ~= y.a.total then return x.a.total > y.a.total end
		return x.key < y.key
	end)
	return list
end

-- Compact per-ability rows for the hover panel: the top `count` abilities of
-- the last (or current) fight - or of the total since reset when `scope` is
-- "total" - with their share of your output. `kind` is "damage" or
-- "healing". Returns rows, your total, the duration - or nil if nothing has
-- been recorded.
local function GetAbilityRows(kind, count, scope)
	if scope ~= "total" and scope ~= "current" then scope = "last" end
	local entries, duration = BuildTopList(scope, kind)
	local ownValue
	for _, e in ipairs(entries) do
		if e.self then ownValue = e.value end
	end
	if not ownValue or ownValue <= 0 then return nil end

	local rows = {}
	for _, item in ipairs(SortedAbilities(AbilitiesFor(scope, kind))) do
		if #rows >= (count or 8) then break end
		if item.a.total > 0 then
			table.insert(rows, { name = item.key, value = item.a.total, share = item.a.total / ownValue * 100, icon = item.a.icon })
		end
	end
	return rows, ownValue, duration
end

local function GetStatsLines(scope, kind)
	local isHealing = (kind == "healing")
	local entries, duration, groupTotal = BuildTopList(scope, kind)
	local ownValue
	for _, e in ipairs(entries) do
		if e.self then ownValue = e.value end
	end

	local abilities = AbilitiesFor(scope, kind)
	if ownValue <= 0 and next(abilities) == nil then return nil end

	local title = SCOPE_TITLE[scope] or "Last Fight"
	local lines = { string.format("OrbMeter - %s Stats - %s (%.1fs)", isHealing and "Healing" or "Damage", title, duration) }

	local summary = string.format("%s: %s (%s %s)",
		isHealing and "Effective healing" or "Total damage",
		FormatNumber(ownValue), FormatNumber(ownValue / duration), isHealing and "HPS" or "DPS")
	if CountContributors(entries) > 1 and groupTotal > 0 then
		summary = summary .. string.format(" - %.0f%% of the group's %s", Percent(ownValue, groupTotal), FormatNumber(groupTotal))
	end
	table.insert(lines, summary)

	local list = SortedAbilities(abilities)
	local overheal, raw = 0, 0
	for _, item in ipairs(list) do
		overheal = overheal + item.a.over
		if not item.a.shield then raw = raw + item.a.total + item.a.over end
	end

	if isHealing and raw > 0 then
		table.insert(lines, string.format("Overhealing: %s (%.0f%% of raw healing)", FormatNumber(overheal), Percent(overheal, raw)))
	end

	for i = 1, math.min(#list, MAX_STAT_ROWS) do
		local k, a = list[i].key, list[i].a
		local share = Percent(a.total, ownValue)
		if isHealing then
			if a.shield then
				table.insert(lines, string.format("%d. %s: %s (%.0f%%), %d %s", i, k, FormatNumber(a.total), share, a.hits, a.hits == 1 and "absorb" or "absorbs"))
			else
				table.insert(lines, string.format("%d. %s: %s (%.0f%%), %d %s, crit %.0f%%, overheal %.0f%%",
					i, k, FormatNumber(a.total), share, a.hits, a.hits == 1 and "cast" or "casts", Percent(a.crits, a.hits), Percent(a.over, a.total + a.over)))
			end
		else
			table.insert(lines, string.format("%d. %s: %s (%.0f%%), %d %s, crit %.0f%%, miss %d (%.0f%%)",
				i, k, FormatNumber(a.total), share, a.hits, a.hits == 1 and "hit" or "hits", Percent(a.crits, a.hits),
				a.misses, Percent(a.misses, a.hits + a.misses)))
		end
	end
	if #list > MAX_STAT_ROWS then
		table.insert(lines, string.format("+%d more", #list - MAX_STAT_ROWS))
	end

	return lines
end

-- ============================================================
-- Exposed accessors (visual layer will poll these)
-- ============================================================

OrbMeter_GetCurrentFightDPS = GetCurrentFightDPS
OrbMeter_GetTotalDPS = GetTotalDPS
OrbMeter_GetTopFightDPS = GetTopFightDPS
OrbMeter_GetRosterCount = GetRosterCount
OrbMeter_GetLastFightDPS = function() return lastFight.dps end
OrbMeter_GetLastFightTopDPS = function() return lastFight.topDPS end
OrbMeter_GetCurrentFightHPS = GetCurrentFightHPS
OrbMeter_GetTopFightHPS = GetTopFightHPS
OrbMeter_GetLastFightHPS = function() return lastFight.hps end
OrbMeter_GetLastFightTopHPS = function() return lastFight.topHPS end

-- True once the last-fight number has lingered past
-- LAST_FIGHT_LINGER_SECONDS since combat ended (or no fight has ended
-- yet this session) - the visual layer shows 0/neutral instead of the
-- lastFight snapshot once this flips true, instead of holding the
-- stale number forever.
OrbMeter_IsLastFightExpired = function()
	if not combatEndTime then return true end
	return (GetTime() - combatEndTime) >= LAST_FIGHT_LINGER_SECONDS
end

OrbMeter_FormatNumber = FormatNumber
OrbMeter_InCombat = function() return inCombat end
OrbMeter_GetCurrentMode = GetCurrentMode
OrbMeter_CycleMode = CycleMode
OrbMeter_GetThreatDisplay = GetThreatDisplay
OrbMeter_GetPetThreatDisplay = GetPetThreatDisplay
OrbMeter_GetStatsLines = GetStatsLines
OrbMeter_GetAbilityRows = GetAbilityRows
OrbMeter_SetAdaptive = SetAdaptive
OrbMeter_IsAdaptive = IsAdaptive
OrbMeter_GetTopReportLines = GetTopReportLines
OrbMeter_GetRanking = GetRanking

-- Testing aid only - prints raw internal state so tracking math can be
-- sanity-checked against what you actually did in-game.
OrbMeter_DebugString = function()
	local elapsed = combatStartTime and (GetTime() - combatStartTime) or 0
	local threatText = GetThreatDisplay()
	local petThreatText = GetPetThreatDisplay()
	local sinceEnd = combatEndTime and (GetTime() - combatEndTime) or nil
	local formRole, formIcon, formName = GetFormOverride()
	return string.format(
		"inCombat=%s  fightDamage=%d  fightElapsed=%.1fs  fightDPS=%.0f  topFightDPS=%.0f  fightHealing=%d  fightHPS=%.0f  topFightHPS=%.0f  |  lastFightDPS=%.0f  lastFightTopDPS=%.0f  lastFightHPS=%.0f  lastFightTopHPS=%.0f  lastFightAge=%s  lastFightExpired=%s  |  totalDamage=%d  totalHealing=%d  totalDuration=%.1fs  totalDPS=%.0f  |  rosterTracked=%d  |  role/mode: auto=%s override=%s current=%s  |  threat=%s  petThreat=%s  |  pet=%s",
		tostring(inCombat), currentFight.damage, elapsed, GetCurrentFightDPS(), GetTopFightDPS(),
		currentFight.healing, GetCurrentFightHPS(), GetTopFightHPS(),
		lastFight.dps, lastFight.topDPS, lastFight.hps, lastFight.topHPS,
		sinceEnd and string.format("%.1fs", sinceEnd) or "n/a",
		tostring(OrbMeter_IsLastFightExpired()),
		totalStats.damage, totalStats.healing, totalStats.duration, GetTotalDPS(), GetRosterCount(),
		autoMode, tostring(modeOverride), GetCurrentMode(),
		threatText or "n/a (no target)",
		petThreatText or "n/a (no pet/target)",
		petGUID and "active (damage folded into your own)" or "none"
	) .. string.format("  |  form: role=%s icon=%s name=%s",
		tostring(formRole), tostring(formIcon), tostring(formName))
	.. string.format("  |  shield absorb credited=%d unattributed=%d", absorbCredited, absorbUnattributed)
	.. string.format("  |  adaptive=%s follows=%s run=%s x%d", tostring(adaptiveEnabled), tostring(adaptiveMode), tostring(runKind), runCount)
end
