if EUI_CLIENT_BLOCKED then return end -- pre-12.1 client failsafe (EllesmereUI_ClientGate.lua)
-------------------------------------------------------------------------------
--  EUI_UnitFrames_Visibility.lua
--
--  Frame alpha and visibility helpers (fade out of combat, resting alpha,
--  show on missing health or mana) and the frame hover handlers, published as
--  I.UnitFrame_OnEnter / I.UnitFrame_OnLeave for EUI_UnitFrames_Init.lua.
--  Reads the main file through ns and ns._internals; db via I.dbSetters.
-------------------------------------------------------------------------------
local _, ns = ...

local I = ns._internals
local frames = I.frames
local db
I.dbSetters[#I.dbSetters + 1] = function(v) db = v end

-- Effective whole-frame alpha for a unit frame. When "Fade Out of Combat" is enabled
-- and the player is out of combat, shows at oocAlpha; otherwise full opacity (off by
-- default, existing setups unchanged). Every "shown" SetAlpha site (visibility loop +
-- mouseover hover) routes through this so a combat transition or hover can't clobber
-- the fade. Combat state comes from the caller (the visibility loop's event-tracked
-- _ufInCombat, which leads InCombatLockdown() on regen events). On ns: the pass calls it.
function ns.ResolveFrameAlpha(s, inCombat)
    if s and s.oocFadeEnabled and not inCombat then
        return s.oocAlpha or 0.5
    end
    return 1
end

-- The alpha a unit frame RESTS at while the cursor is not on it, plus whether that resting
-- state is a hover gate (an alpha 0 a hover may legitimately lift). Single source of truth:
-- the visibility pass and both hover handlers derive from it, so a mouse leave cannot land
-- on a different verdict than the pass would. On ns: the pass calls it. hiddenByOpts
-- leads because it did in the pass too (it re-forced 0 at the end of the chain); returning
-- hoverGated false with it stops a hover from revealing what an option lane has hidden.
function ns.ResolveVisResting(s, frame, ext, hiddenByOpts, inCombat)
    if hiddenByOpts then return 0, false end
    local shownAlpha = ns.ResolveFrameAlpha(s, inCombat)
    if ext == "mouseover" then return 0, true end
    if ext ~= nil then
        -- Driver registered: it owns hiding, so alpha only carries the ooc fade.
        if frame and frame._euiVisDriver then return shownAlpha, false end
        return ext and shownAlpha or 0, false
    end
    local vis = s.barVisibility or "always"
    -- Never rides the alpha too, not just the Show/Hide bucket: that bucket is
    -- lockdown-gated, so a Never picked in combat would otherwise leave the frame at
    -- full alpha until PLAYER_REGEN_ENABLED. An override reaches the ext block above.
    if vis == "never" then return 0, false end
    if vis == "in_combat" then return inCombat and shownAlpha or 0, false end
    if vis == "out_of_combat" then return (not inCombat) and shownAlpha or 0, false end
    if s.showWhenHealthMissing or s.showWhenManaMissing then
        if vis == "in_raid" then return IsInRaid() and shownAlpha or 0, false end
        if vis == "in_party" then return (IsInGroup() and not IsInRaid()) and shownAlpha or 0, false end
        if vis == "solo" then return (not IsInGroup()) and shownAlpha or 0, false end
    end
    if vis == "mouseover" then
        -- Legacy single mouseover: a configured "Hide if" override that is NOT currently
        -- triggering counts as a positive show, so the frame does not require hover
        -- (fixes "dismount in combat keeps frame hidden" / "hide if no target inverted").
        local hasAnyHideOpt = EllesmereUI.VisHasAnyOption(s)
        if hasAnyHideOpt then return shownAlpha, false end
        return 0, true
    end
    return shownAlpha, false
end

-- Same verdict for callers outside the visibility pass (the hover handlers): derives the
-- two inputs the pass would have handed over. State is left nil so the shared engine fills
-- it from its own combat/group tracking.
function ns.ResolveVisRestingLive(s, frame)
    local hiddenByOpts = EllesmereUI.CheckVisibilityOptions(s)
    local ext = EllesmereUI.EvalVisibilityExtended(s, "barVisibility", nil, EllesmereUI.VIS_CAPS_DEFAULT)
    local alpha, hoverGated = ns.ResolveVisResting(s, frame, ext, hiddenByOpts, InCombatLockdown())
    return alpha, hoverGated, hiddenByOpts
end

--- Is the hover mechanism wired for this frame at all? The cheap static prefilter both
--- handlers use, kept static on purpose (a live verdict here would write alpha on every
--- mouse leave of every frame). An applied Visibility override answers it too: it holds
--- the hover state itself, and without this the frame would rest at alpha 0 with no
--- handler willing to reveal it again.
function ns.VisMouseoverWired(s)
    if not s then return false end
    if (s.barVisibility or "always") == "mouseover" then return true end
    return (EllesmereUI.VisOverrideValue(s)) == "mouseover"
end

-- Show When Health Missing / Show When Mana Missing are display-only reveals. The
-- health curve result is always secret (UnitHealthPercent returns secrets): hand
-- it directly to alpha setters, never use it as a Lua condition. Those frames'
-- GetAlpha then reads secret too. Mana is tracked from its update events instead.
local MANA = Enum.PowerType.Mana

-- Mana reveal applies to the player frame only, and only for a character with a
-- mana pool. The max reads clean outside combat; while it reads secret the last
-- clean answer stands (unknown counts as no mana, so a warrior never reveals).
local function PlayerHasMana(frame)
    local mx = UnitPowerMax("player", MANA)
    if mx and not issecretvalue(mx) then frame._manaVisHasMana = mx > 0 end
    return frame._manaVisHasMana == true
end

-- Which reveals apply to this frame right now: health, mana (two booleans).
function ns.MissingRevealFlags(s, frame)
    if not s or not frame then return false, false end
    local wantHealth, wantMana = s.showWhenHealthMissing, s.showWhenManaMissing
    if not (wantHealth or wantMana) then return false, false end
    local unit = frame._euiUnit
    if unit ~= "player" and unit ~= "target" and unit ~= "focus" then return false, false end
    if ns.VisUnitDisabled(db.profile, unit) then return false, false end
    local override = EllesmereUI.VisOverrideValue(s)
    if (override or s.barVisibility or "always") == "never" then return false, false end
    local health = wantHealth and true or false
    local mana = (wantMana and unit == "player" and PlayerHasMana(frame)) and true or false
    return health, mana
end

-- True when any missing-resource reveal applies (health or mana).
function ns.HealthVisibilityEnabled(s, frame)
    local health, mana = ns.MissingRevealFlags(s, frame)
    return health or mana
end

-- Step curve: 1 below full, the stamped base alpha at full. Re-pointed only
-- when the base changes (stamp kept in frame[stampKey]).
local function BaseCurve(frame, key, stampKey, base)
    local c = frame[key]
    if not c then
        c = C_CurveUtil.CreateCurve()
        c:SetType(Enum.LuaCurveType.Step)
        frame[key] = c
    end
    if frame[stampKey] ~= base then
        c:ClearPoints()
        c:AddPoint(0, 1)
        c:AddPoint(1, base)
        frame[stampKey] = base
    end
    return c
end

-- Mana missing, as a clean boolean. Mana reads secret even out of combat (WoW
-- Forever), and two secret curve results cannot be combined (a curve point will
-- not take a secret), so mana is not read at all. Instead: mana only changes,
-- and UNIT_POWER_UPDATE only fires, while it is below full. Regen ticks every
-- 2s and stops at full; a cast that costs mana pauses regen for 5s (the five
-- second rule). So mana counts as missing until a quiet spell has passed since
-- the last mana update (one tick plus slack) or mana-cost cast (the 5s pause
-- plus one tick plus slack). The frame hides up to that long after mana fills.
-- Same signal as the mana regen spark (EllesmereUI_ManaRegenSpark.lua).
local MANA_TICK_QUIET = 2.5
local MANA_CAST_QUIET = 7.5
local manaActiveUntil = 0
-- One reused one-shot animation times the quiet spell (as the spark does), so no
-- activity creates a timer. Built on first mana activity; while it plays, new
-- activity only pushes manaActiveUntil out and the finish replays the remainder.
local manaQuiet, manaQuietSpan

local function PlayManaQuiet(len)
    manaQuietSpan:SetDuration(len + 0.05)
    manaQuiet:Play()
end

local function NoteManaActivity(quiet)
    local t = GetTime() + quiet
    if t > manaActiveUntil then manaActiveUntil = t end
    if not manaQuiet then
        manaQuiet = CreateFrame("Frame"):CreateAnimationGroup()
        manaQuietSpan = manaQuiet:CreateAnimation("Animation")
        manaQuiet:SetScript("OnFinished", function()
            local left = manaActiveUntil - GetTime()
            if left > 0 then
                PlayManaQuiet(left)
            else
                ns.UpdateHealthVisibilityUnit("player")
            end
        end)
    end
    if not manaQuiet:IsPlaying() then PlayManaQuiet(quiet) end
end

-- True when the spell's cost includes mana. A secret amount counts as a cost;
-- only a plain 0 is free (as in EllesmereUI_ManaRegenSpark.lua).
local function CostsMana(spellID)
    if not spellID or issecretvalue(spellID) then return false end
    local costs = C_Spell.GetSpellPowerCost(spellID)
    if not costs then return false end
    for i = 1, #costs do
        local c = costs[i]
        if not issecretvalue(c.type) and c.type == MANA then
            local amt = c.cost
            return issecretvalue(amt) or (type(amt) == "number" and amt > 0)
        end
    end
    return false
end

-- The reveal alpha from the flags and base stamped by HealthVisibilityAlpha:
-- full opacity while mana is missing (out of combat only), else the health
-- curve (1 below full health, the base at full), else the base.
local function PaintReveal(frame)
    local base = frame._healthVisBase
    if frame._healthVisMana and not frame._healthVisInCombat and GetTime() < manaActiveUntil then
        return 1
    end
    if not frame._healthVisHealth then return base end
    return UnitHealthPercent(frame._euiUnit, false, BaseCurve(frame, "_healthVisCurve", "_healthVisCurveAlpha", base))
end

-- Every writer of the reveal (the visibility pass, both hover handlers) goes
-- through here, so the curves always map full health / mana to the base alpha
-- last painted, and _healthVisLive says whether the reveal currently applies.
function ns.HealthVisibilityAlpha(s, frame, baseAlpha, hoverGated, inCombat)
    local health, mana = ns.MissingRevealFlags(s, frame)
    if not (health or mana) then
        if frame then frame._healthVisLive = nil end
        return baseAlpha
    end
    frame._healthVisLive = true
    -- A visibility refresh must preserve an active mouseover reveal. Keep
    -- this decision on clean UI state, before evaluating the curves.
    if hoverGated and frame._healthVisHovered then
        baseAlpha = ns.ResolveFrameAlpha(s, inCombat)
    end
    frame._healthVisBase = baseAlpha
    frame._healthVisHealth, frame._healthVisMana = health, mana
    -- Combat state for the mana check: the pass hands over its event-tracked
    -- _ufInCombat and repaints on every combat edge; hover handlers pass none.
    if inCombat == nil then inCombat = InCombatLockdown() end
    frame._healthVisInCombat = inCombat and true or false
    return PaintReveal(frame)
end

-- A health or mana event moves only the inputs: the base alpha, which reveals
-- apply and the combat state change on visibility events and hover, which
-- repaint through HealthVisibilityAlpha above. So a tick re-evaluates the
-- stamped state and re-derives nothing (this runs on every UNIT_HEALTH in combat).
function ns.UpdateHealthVisibilityUnit(unit)
    local frame = frames[unit]
    if not (frame and frame._healthVisLive and frame._healthVisBase ~= nil) then return end
    local alpha = PaintReveal(frame)
    ;(frame._visWrap or frame):SetAlpha(alpha)
    local model = frame.Portrait and frame.Portrait.backdrop and frame.Portrait.backdrop._3d
    if model then ns.UF_SetModelAlpha(model, alpha) end
    local mini = ns.UF_MINI_OF and frames[ns.UF_MINI_OF[unit]]
    if mini and not (unit == "player" and db.profile.pet and db.profile.pet.alwaysShow) then
        mini:SetAlpha(alpha)
    end
end

function ns.SyncHealthVisibilityEvents()
    -- Health events go to every unit with any reveal (a mana-only player frame
    -- just repaints its base); mana events only to the player with Show When
    -- Mana Missing.
    local player, playerMana = ns.MissingRevealFlags(db.profile.player, frames.player)
    player = player or playerMana
    local target = ns.HealthVisibilityEnabled(db.profile.target, frames.target)
    local focus = ns.HealthVisibilityEnabled(db.profile.focus, frames.focus)
    local mask = (player and 1 or 0) + (target and 2 or 0) + (focus and 4 or 0) + (playerMana and 8 or 0)
    local eventFrame = ns.healthVisibilityEvents
    if not eventFrame then
        if mask == 0 then return end
        eventFrame = CreateFrame("Frame")
        eventFrame:SetScript("OnEvent", function(_, event, unit, arg2, arg3)
            if event == "PLAYER_FOCUS_CHANGED" then
                unit = "focus"
            elseif event == "UNIT_POWER_UPDATE" then
                -- arg2 is the power token. A secret token counts as mana; other
                -- power types are ignored.
                if not issecretvalue(arg2) and arg2 ~= "MANA" then return end
                NoteManaActivity(MANA_TICK_QUIET)
            elseif event == "UNIT_SPELLCAST_SUCCEEDED" then
                -- arg3 is the spell ID.
                if not CostsMana(arg3) then return end
                NoteManaActivity(MANA_CAST_QUIET)
            end
            ns.UpdateHealthVisibilityUnit(unit)
        end)
        ns.healthVisibilityEvents = eventFrame
    end
    if eventFrame.mask == mask then return end
    eventFrame.mask = mask
    eventFrame:UnregisterAllEvents()
    if mask ~= 0 then
        local units = eventFrame.units or {}
        eventFrame.units = units
        wipe(units)
        if player then units[#units + 1] = "player" end
        if target then units[#units + 1] = "target" end
        if focus then units[#units + 1] = "focus" end
        eventFrame:RegisterUnitEvent("UNIT_HEALTH", unpack(units))
        eventFrame:RegisterUnitEvent("UNIT_MAXHEALTH", unpack(units))
        if playerMana then
            eventFrame:RegisterUnitEvent("UNIT_POWER_UPDATE", "player")
            eventFrame:RegisterUnitEvent("UNIT_MAXPOWER", "player")
            eventFrame:RegisterUnitEvent("UNIT_SPELLCAST_SUCCEEDED", "player")
        end
        if focus then eventFrame:RegisterEvent("PLAYER_FOCUS_CHANGED") end
    end
end

local function UnitFrame_OnEnter(self)
    local unit = self._euiUnit
    if not unit then return end
    local unitKey = unit:match("^boss%d$") and "boss" or unit
    local s = db and db.profile and db.profile[unitKey]
    if s and (s.showWhenHealthMissing or s.showWhenManaMissing) then self._healthVisHovered = true end
    if ns.VisMouseoverWired(s) then
        -- Reveal only what is actually hover-gated right now. Under Any the frame may
        -- already be shown on another passing disjunct, in which case there is nothing to
        -- reveal and OnLeave must not undo anything either -- both handlers read the same
        -- resting verdict so they cannot disagree.
        local _, hoverGated = ns.ResolveVisRestingLive(s, self)
        if hoverGated then
            local a = ns.ResolveFrameAlpha(s, InCombatLockdown())
            if s.showWhenHealthMissing or s.showWhenManaMissing then a = ns.HealthVisibilityAlpha(s, self, a) end
            ;(self._visWrap or self):SetAlpha(a)
            -- 3D models don't inherit parent alpha: reveal the portrait too
            local bd3d = self.Portrait and self.Portrait.backdrop and self.Portrait.backdrop._3d
            if bd3d then ns.UF_SetModelAlpha(bd3d, a) end
            -- Mini-frame inheritance: the companion frame reveals with us.
            -- Always Show Pet Frame opts the pet out (it is already visible
            -- and must not pick up the player's fade alpha).
            local mini = ns.UF_MINI_OF and frames[ns.UF_MINI_OF[unitKey]]
            if mini and not (unitKey == "player" and db.profile.pet and db.profile.pet.alwaysShow) then
                mini:SetAlpha(a)
            end
        end
    end
    if unit and GameTooltip and GameTooltip_SetDefaultAnchor then
        local showTooltip = not s or s.showUnitTooltip ~= false
        if showTooltip then
            GameTooltip_SetDefaultAnchor(GameTooltip, self)
            if GameTooltip:SetUnit(unit) then
                GameTooltip:Show()
            end
            if self._tooltipTicker then self._tooltipTicker:Cancel() end
            self._tooltipTicker = C_Timer.NewTicker(0.5, function()
                if not self:IsMouseOver() then
                    if self._tooltipTicker then self._tooltipTicker:Cancel(); self._tooltipTicker = nil end
                    return
                end
                GameTooltip_SetDefaultAnchor(GameTooltip, self)
                if GameTooltip:SetUnit(self._euiUnit) then
                    GameTooltip:Show()
                end
            end)
        end
    end
end

local function UnitFrame_OnLeave(self)
    self._healthVisHovered = nil
    local unit = self._euiUnit
    if not unit then return end
    local unitKey = unit:match("^boss%d$") and "boss" or unit
    local s = db and db.profile and db.profile[unitKey]
    if ns.VisMouseoverWired(s) then
        -- Return to the resting alpha the visibility pass would paint, never a hardcoded
        -- 0: under Any a passing disjunct keeps the frame visible with no hover involved,
        -- and hiding it here would leave it wrong until the next visibility event fires.
        local leaveAlpha, _, hiddenByOpts = ns.ResolveVisRestingLive(s, self)
        if (s.showWhenHealthMissing or s.showWhenManaMissing) and not hiddenByOpts then
            leaveAlpha = ns.HealthVisibilityAlpha(s, self, leaveAlpha)
        else
            self._healthVisLive = nil
        end
        ;(self._visWrap or self):SetAlpha(leaveAlpha)
        -- 3D models don't inherit parent alpha: hide/dim the portrait too
        local bd3d = self.Portrait and self.Portrait.backdrop and self.Portrait.backdrop._3d
        if bd3d then ns.UF_SetModelAlpha(bd3d, leaveAlpha) end
        -- Mini-frame inheritance: the companion frame hides/dims with us.
        -- Always Show Pet Frame opts the pet out (a leave alpha of 0 would
        -- hide a pet frame that must stay visible).
        local mini = ns.UF_MINI_OF and frames[ns.UF_MINI_OF[unitKey]]
        if mini and not (unitKey == "player" and db.profile.pet and db.profile.pet.alwaysShow) then
            mini:SetAlpha(leaveAlpha)
        end
    end
    if self._tooltipTicker then self._tooltipTicker:Cancel(); self._tooltipTicker = nil end
    if GameTooltip and GameTooltip:IsOwned(self) then
        GameTooltip:Hide()
    end
end

I.UnitFrame_OnEnter = UnitFrame_OnEnter
I.UnitFrame_OnLeave = UnitFrame_OnLeave
