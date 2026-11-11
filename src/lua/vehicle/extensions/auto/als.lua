-- ALS auto hook.
-- Attaches the anti-lag controller to every vehicle at runtime, vanilla or mod,
-- without any per-vehicle jbeam part. The engine auto-loads everything under
-- lua/vehicle/extensions/auto for every vehicle, after controller.init() has
-- already run, so the vanilla anti-lag controller is replaced here.

local M = {}

local function attachAntiLag()
    local engine = powertrain.getDevice("mainEngine")
    if not engine or not engine.turbocharger or not engine.turbocharger.isExisting then
        log("D", "ALS", "no turbocharger - ALS not attached")
        return
    end

    -- Replace the vanilla controller so only one anti-lag updateGFX runs.
    if controller.getController("antiLag") then
        controller.unloadControllerExternal("antiLag")
    end
    if controller.getController("alsAntiLag") then
        return
    end
    controller.loadControllerExternal("powertrainControl/als_antiLag", "alsAntiLag", {})
    log("I", "ALS", "anti-lag attached to vehicle " .. obj:getID())
end

local function onVehicleLoaded()
    attachAntiLag()
end

M.onVehicleLoaded = onVehicleLoaded

return M
