-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt
-- Do Not Remove Comments

local M = {}
local rpmToAV = 0.104719755
local function init()
end

local function printK()
	if electrics.values.ALS_toggle == 1 then
		gui.message("ALS Enabled")
	else
		gui.message("ALS disabled")
	end
end

local function printO()
	if electrics.values.scramble == 1 then
		gui.message("Scramble Enabled")
	else
		gui.message("Scramble disabled")
	end
end

local function toggleRALS(state)
    local engine = powertrain.getDevice("mainEngine")
    electrics.values.rollingALS = state
    if state == 1 and --[[electrics.values.throttle >= 1.0 and ]] electrics.values.gearIndex >= 1 then
        --electrics.values.rollingALSRpms = engine.outputRPM
        engine:setTempRevLimiter(engine.outputRPM * rpmToAV)    
    else
        --electrics.values.rollingALSRpms = -1
        engine:resetTempRevLimiter()
    end
end
	--print(electrics.values.lockupClutchRatio)
-- public interface
--[[M.updateGFX   = updateGFX
M.init      = init
M.reset     = init]]--
M.printK 	  = printK
M.printO	  = printO
M.toggleRALS  = toggleRALS
return M

