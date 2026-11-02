-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- Purpose: give the driver control over the built-in anti-lag system.
-- The anti-lag physics stays vanilla; this controller only decides when the
-- system is allowed to run and how boost behaves while it is engaged.

local M = {}
M.type = "auxiliary"

local DEFAULT_SCRAMBLE_BOOST_PSI = 10 -- PSI added to the wastegate target while scrambling
local MIN_ENGINE_AV = 50              -- below this the engine is not running, so ALS cannot hold

local base = nil
local controlledEngine = nil
local controlledTurbocharger = nil

local enabled = false
local rolling = false
local scrambling = false
local scrambleBoostPsi = DEFAULT_SCRAMBLE_BOOST_PSI
local appliedOffset = 0
local alsWasEnabled = false
local rollingWasActive = false

local function updateGFX(dt)
    if not base then
        return
    end

    enabled = electrics.values.alsEnabled == 1
    rolling = electrics.values.alsRolling == 1
    scrambling = electrics.values.alsScramble == 1

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

    base.updateGFX(dt)

    -- The wastegate slider moves the set point in the part data; scramble can
    -- only add an offset on top of it, and that offset yields extra boost only
    -- while the turbo still has headroom in its own pressure curve.
    local offset = scrambling and scrambleBoostPsi or 0
    if offset ~= appliedOffset then
        appliedOffset = offset
        controlledTurbocharger.setWastegateOffset(offset)
    end
end

local function reset()
    enabled = false
    rolling = false
    scrambling = false
    alsWasEnabled = false
    appliedOffset = 0
    if controlledTurbocharger and controlledTurbocharger.isExisting then
        controlledTurbocharger.setWastegateOffset(0)
    end
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
    -- The vanilla controller reads its own name for telemetry, and it is not
    -- registered as a controller here, so nobody sets it for us.
    base.name = "antiLag"

    controlledEngine = powertrain.getDevice(data.controlledEngine or "mainEngine")
    controlledTurbocharger = controlledEngine and controlledEngine.turbocharger
    -- An engine without a turbo still gets a stub turbocharger device, so the
    -- isExisting flag is the only reliable test.
    if not controlledEngine or not controlledTurbocharger or not controlledTurbocharger.isExisting then
        log("W", "als_antiLag", "The controlled engine has no turbocharger, anti-lag will not work")
        controlledTurbocharger = nil
        base = nil
        return
    end

    scrambleBoostPsi = tonumber(data.scrambleBoostPsi) or DEFAULT_SCRAMBLE_BOOST_PSI
    base.init(data)
    -- Anti-lag is on as soon as the part is installed, the hotkey turns it off.
    electrics.values.alsEnabled = 1
end

M.init = init
M.reset = reset
M.updateGFX = updateGFX

return M
