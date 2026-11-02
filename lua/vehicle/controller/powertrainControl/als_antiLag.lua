-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- Purpose: give the driver control over the built-in anti-lag system.
-- The anti-lag physics stays vanilla; this controller only decides when the
-- system is allowed to run and how boost behaves while it is engaged.

local M = {}
M.type = "auxiliary"

local SCRAMBLE_INTERVAL = 0.25 -- seconds per pulse while scrambling
local SCRAMBLE_OFFSET = 5      -- PSI added to the wastegate target while scrambling
local MIN_ENGINE_AV = 50       -- below this the engine is not running, so ALS cannot hold

local base = nil
local controlledEngine = nil
local controlledTurbocharger = nil

local enabled = false
local rolling = false
local scrambling = false
local scrambleClock = 0
local scramblePhase = false
local alsWasActive = false
local alsWasEnabled = false
local rollingWasActive = false

local function setWastegateOffset(offset)
    if controlledTurbocharger and controlledTurbocharger.setWastegateOffset then
        controlledTurbocharger.setWastegateOffset(offset)
    end
end

local function updateGFX(dt)
    if not base then
        return
    end

    enabled = electrics.values.ALS_toggle == 1
    rolling = electrics.values.rollingALS == 1
    scrambling = enabled and electrics.values.scramble == 1

    -- The vanilla state machine is only entered on the edges of the hotkey
    -- state: forcing "idle" every frame would reset the arming timer and the
    -- system would never engage.
    if enabled ~= alsWasEnabled then
        alsWasEnabled = enabled
        base.setAntilagState(enabled and "idle" or "off")
    end

    if enabled and rolling and controlledEngine and controlledEngine.outputAV1 >= MIN_ENGINE_AV then
        if not rollingWasActive then
            rollingWasActive = true
            base.setAntilagState("manualOverride")
        end
    elseif rollingWasActive then
        rollingWasActive = false
        base.setAntilagState(enabled and "idle" or "off")
    end

    if scrambling and electrics.values.alsActive then
        scrambleClock = scrambleClock + dt
        if scrambleClock >= SCRAMBLE_INTERVAL then
            scrambleClock = 0
            scramblePhase = not scramblePhase
        end
        setWastegateOffset(scramblePhase and SCRAMBLE_OFFSET or 0)
    else
        scrambleClock = 0
        scramblePhase = false
        setWastegateOffset(0)
    end

    base.updateGFX(dt)

    local alsActive = electrics.values.alsActive
    if alsActive ~= alsWasActive then
        alsWasActive = alsActive
        guihooks.message(alsActive and "Anti-lag engaged" or "Anti-lag released", 3, "ALS")
    end
end

local function reset()
    enabled = false
    rolling = false
    scrambling = false
    scrambleClock = 0
    scramblePhase = false
    alsWasActive = false
    setWastegateOffset(0)
    if base then
        base.reset()
    end
end

local function init(data)
    base = rerequire("controller/powertrainControl/antiLag")
    if not base then
        log("W", "als_antiLag", "Vanilla anti-lag controller is missing, anti-lag will not work")
        return
    end
    base.init(data)

    controlledEngine = powertrain.getDevice(data.controlledEngine or "mainEngine")
    controlledTurbocharger = controlledEngine and controlledEngine.turbocharger
    if not controlledTurbocharger or not controlledTurbocharger.isExisting then
        log("W", "als_antiLag", "The controlled engine has no turbocharger, anti-lag will not work")
        base = nil
    end
end

M.init = init
M.reset = reset
M.updateGFX = updateGFX

return M
