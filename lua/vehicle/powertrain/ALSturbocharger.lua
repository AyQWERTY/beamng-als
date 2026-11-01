-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- Be ready for what's next ;P

local M = {}

local AlsTable = {}
AlsTable.ALSActive = false
AlsTable.ALSTime = 2
AlsTable.tick = 0
AlsTable.engineLoadBuffer = {}
AlsTable.prevEngineLoad = 0
AlsTable.count = 1
AlsTable.instantEngineLoadDrop = 0
AlsTable.ALSNeed = false
AlsTable.ALS_RPM = 4000
AlsTable.normalInstantAfterFireCoef = 0
AlsTable.normalSustainedAfterFireCoef = 0
AlsTable.normalSustainedAfterFireTime = 0
AlsTable.ALSInstantAfterFireCoef = 100
AlsTable.ALSSustainedAfterFireCoef = 100
AlsTable.ALSSustainedAfterFireTime = 5
AlsTable.ALS = false
AlsTable.ALSExhaustPower = 1
AlsTable.ALSPressure = 0
AlsTable.ALSInstantLoadDrop = 1
AlsTable.ALSTemp = 0
AlsTable.decreaseALSTemp = false
AlsTable.gearCount = 6
AlsTable.prevTurboAV = 0
AlsTable.turboNormalization = false
AlsTable.boostByGear = false
AlsTable.twoStepLaunchControl = nil
AlsTable.torqueOffTolerance = 10
AlsTable.loopLimit = 0
AlsTable.keepBOVAndWastegateClosed = false
AlsTable.hasALSJustBeenActivated = false
AlsTable.ALSTransitionTicks = 0
AlsTable.maxNonScrambledALSPressure = -1
AlsTable.scramblePressure = 0
AlsTable.bbsAndNormWarningShown = false

local floor = math.floor
local sqrt = math.sqrt
local max = math.max
local min = math.min

local rpmToAV = 0.10471971768
local avToRPM = 9.5493
local invPascalToPSI = 0.00014503773773
local psiToPascal = 6894.757293178

M.isExisting = true

local assignedEngine = nil
local forcedInductionInfoStream = {
  rpm = 0,
  coef = 1,
  boost = 0,
  maxBoost = 0,
  exhaustPower = 0,
  friction = 0,
  backpressure = 0,
  bovEngaged = 0,
  wastegateFactor = 0,
  turboTemp = 0
}

--Turbo related stuff
local curTurboAV = 0
local maxTurboAV = 1
local invMaxTurboAV = 1
local invTurboInertia = 0
local turboInertiaFactor = 1
local turboPressure = 0
local turboPressureRaw = 0
local maxTurboPressure = {}
local exhaustPower = 0
local maxExhaustPower = 1
local backPressureCoef = 0
local frictionCoef = 0
local turboWhineLoop = nil
local turboHissLoop = nil
local turboWhinePitchPerAV = 0
local turboWhineVolumePerAV = 0
local  turboHissVolumePerPascal = 0
--local backPressure = 0
local wearFrictionCoef = 1
local damageFrictionCoef = 1
local damageExhaustPowerCoef = 1

-- Wastegate
local wastegateStart = nil
local wastegateLimit = nil
local wastegateFactor = 1
local wastegateRange = nil
local maxWastegateStart = 0
local maxWastegateLimit = 0
local maxWastegateRange = 1
local wastegatePCoef = 0
local wastegateICoef = 0
local wastegateDCoef = 0
local wastegateIntegral = 0
local lastBoostError = 0
local wastegateTargetBoost = 0
local wastegateStartPerGear = 0
local wastegateRangePerGear = 0

-- blow off valve
local bovEnabled = true
local bovEngaged = false
local lastBOVValue = false
local lastEngineLoad = 0
local bovOpenChangeThreshold = 0
local bovOpenThreshold = 0
local bovSoundVolumeCoef = 1
local bovSoundPressureCoef = 1
local bovTimer = 0
local ignitionCutSmoother = nil
local needsBov = false
local bovSound = nil
local flutterSoundVolumeCoef = 1
local flutterSoundPressureCoef = 1
local flutterSound = nil

local invEngMaxAV = 0

local turbo = nil
local pressureSmoother = nil
local wastegateSmoother = nil
local electricsRPMName = nil
local electricsSpinName = nil
local electricsSpinCoef = nil
local electricsSpinValue = nil

local turboDamageThresholdTemperature = 0

local function getTorqueCoefs(gear, scramble, returnEstimatedPressure)
  local coefs = {}
  local estimatedPressures = {}
  scramble = scramble or 2 --If the caller is not in this script it does not pass any parameter so it is needed to assign it a default value
  returnEstimatedPressure = returnEstimatedPressure or false --If the caller is not simEngine

  --we can't know the actual wastegate limit for sure since it's a feedback loop with the pressure, so we just estimate it.
  --lower wastegate ranges lead to more accurate results.
  local estimatedWastegateLimit
  if AlsTable.isBoostBySpeed then
    estimatedWastegateLimit = AlsTable.boostAtSpeed[scramble][AlsTable.boostAtSpeedCount] * invPascalToPSI
  elseif gear then
    estimatedWastegateLimit = (wastegateStart[gear][scramble] + wastegateRange[gear][scramble] * 0.5) * invPascalToPSI
  else
    estimatedWastegateLimit = (maxWastegateStart[scramble] + maxWastegateRange[scramble] * 0.5) * invPascalToPSI
  end

  for k, _ in pairs(assignedEngine.torqueCurve) do
    if type(k) == "number" and k < assignedEngine.maxRPM then
      local rpm = floor(k)
      local turboAV = sqrt(max((0.9 * rpm * rpmToAV * invEngMaxAV * (turbo.turboExhaustCurve[rpm] or 1) * maxExhaustPower - damageExhaustPowerCoef - frictionCoef * wearFrictionCoef * damageFrictionCoef), 0) / backPressureCoef)
      turboAV = min(turboAV, maxTurboAV)
      local turboRPM = floor(turboAV * avToRPM)
      local pressure = turbo.turboPressureCurve[turboRPM] or 0 --pressure without respecting the wastegate
      if assignedEngine.simEngine ~= nil then
        estimatedWastegateLimit = assignedEngine.simEngine.get3DTableValue('boost-table', rpm, assignedEngine.simEngine.state.requestedThrottle * 100)
      end
      local actualPressure = min(pressure, estimatedWastegateLimit) --limit the pressure to what the wastegate allows
      if returnEstimatedPressure then
        estimatedPressures[k] = actualPressure * psiToPascal * (turbo.turboEfficiencyCurve[rpm] or 0)
      end
      coefs[k + 1] = (1 + 0.0000087 * actualPressure * psiToPascal * (turbo.turboEfficiencyCurve[rpm] or 0))
    end
  end
  if returnEstimatedPressure then
    return {coefs, estimatedPressures}
  end
  return coefs
end

local function applyDeformGroupDamage(damageAmount)
  damageFrictionCoef = damageFrictionCoef + linearScale(damageAmount, 0, 0.01, 0, 1)
  damageExhaustPowerCoef = max(damageExhaustPowerCoef - linearScale(damageAmount, 0, 0.01, 0, 0.1), 0)
end

local function setPartCondition(odometer, integrity, visual)
  wearFrictionCoef = linearScale(odometer, 30000000, 500000000, 1, 5)
  local integrityState = integrity
  if type(integrity) == "number" then
    local integrityValue = integrity
    integrityState = {
      damageFrictionCoef = linearScale(integrityValue, 1, 0, 1, 20),
      damageExhaustPowerCoef = linearScale(integrityValue, 1, 0, 1, 0.2)
    }
  end

  damageFrictionCoef = integrityState.damageFrictionCoef or 1
  damageExhaustPowerCoef = integrityState.damageExhaustPowerCoef or 1
end


local function getPartCondition()
  local integrityState = {
    damageFrictionCoef = damageFrictionCoef,
    damageExhaustPowerCoef = damageExhaustPowerCoef
  }

  local frictionIntegrityValue = linearScale(damageFrictionCoef, 1, 20, 1, 0)
  local exhaustPowerIntegrityValue = linearScale(damageExhaustPowerCoef, 1, 0.2, 1, 0)

  local integrityValue = min(frictionIntegrityValue, exhaustPowerIntegrityValue)
  return integrityValue, integrityState
end

local function updateSounds(dt)
  if turboWhineLoop then
    local spindlePitch = curTurboAV * turboWhinePitchPerAV
    local spindleVolume = curTurboAV * turboWhineVolumePerAV
    local hissVolume = max(turboPressure * turboHissVolumePerPascal, 0)
    obj:setVolumePitch(turboHissLoop, hissVolume, 1)
    obj:setVolumePitch(turboWhineLoop, spindleVolume, spindlePitch)
  end
end

local function updateFixedStep(dt)
  if assignedEngine.engineDisabled then
    M.updateGFX = nop
    M.updateFixedStep = nop
    electrics.values.turboRpmRatio = 0
    electrics.values.turboBoost = 0
    electrics.values.turboEfficiency = 0
    turboPressure = 0
    turboPressureRaw = 0
    curTurboAV = 0
    return
  end
  local ALSgear = electrics.values.gearIndex >= 1 and (#wastegateStart > 1 and electrics.values.gearIndex or 1) or 1
  local sButton = electrics.values.scramble + 1

  local engAV = max(1, assignedEngine.outputAV1)
  local engAvRatio = min(engAV * invEngMaxAV, 1)
  local engineRPM = floor(max(assignedEngine.outputRPM or 0, 0))

  --AlsTable.rollingALS = electrics.values.rollingALS == 1
  --AlsTable.ALSActive = AlsTable.ALSActive or AlsTable.rollingALS and engineRPM > 0 and ALSgear >= 1

  if AlsTable.ALSActive then
    assignedEngine.instantAfterFireCoef   = AlsTable.ALSInstantAfterFireCoef
    assignedEngine.sustainedAfterFireCoef = AlsTable.ALSSustainedAfterFireCoef
    assignedEngine.sustainedAfterFireTime = AlsTable.ALSSustainedAfterFireTime
  else
	  assignedEngine.instantAfterFireCoef   = AlsTable.normalInstantAfterFireCoef
    assignedEngine.sustainedAfterFireCoef = AlsTable.normalSustainedAfterFireCoef
    assignedEngine.sustainedAfterFireTime = AlsTable.normalSustainedAfterFireTime
  end

  local boostError = turboPressureRaw - wastegateTargetBoost
  wastegateIntegral = clamp(wastegateIntegral + boostError * dt, -500, 500)
  local wastegateDerivative = (boostError - lastBoostError) / dt
  wastegateFactor = bovEngaged and 0 or wastegateSmoother:getUncapped(clamp((1 - (boostError * wastegatePCoef + wastegateIntegral * wastegateICoef + wastegateDerivative * wastegateDCoef)), 0, 1), dt)

  local engineLoadF = assignedEngine.engineLoad
  local throttleF = assignedEngine.throttle
  if AlsTable.ALSActive then
    engineLoadF = 1
    throttleF = 1
    bovEngaged = false
  elseif AlsTable.ALSTransitionTicks == 40 then
    bovEngaged = false
  end

  if AlsTable.hasALSJustBeenActivated then
    wastegateFactor = 1
    AlsTable.hasALSJustBeenActivated = false
  end

  if AlsTable.ALSTransitionTicks > 0 then
    AlsTable.ALSTransitionTicks = AlsTable.ALSTransitionTicks - 1
  elseif assignedEngine.simEngine ~= nil and assignedEngine.simEngine.exhaustSystem ~= nil then
    exhaustPower = (assignedEngine.simEngine.exhaustSystem.exhaustPower or 0) * dt
  else
    exhaustPower = (0.1 + engineLoadF * 0.8) * throttleF * throttleF * engAvRatio * (turbo.turboExhaustCurve[floor(assignedEngine.outputRPM)] or 1) * maxExhaustPower * damageExhaustPowerCoef * dt
  end

  local friction = frictionCoef * wearFrictionCoef * damageFrictionCoef * dt --simulate some friction and stuff there
  local backPressure = curTurboAV * curTurboAV * backPressureCoef * (bovEngaged and 0.4 or 1) * dt --back pressure from compressing the air
  local turboTorque = ((exhaustPower * wastegateFactor) - backPressure - friction)

  curTurboAV = clamp((curTurboAV + dt * turboTorque * invTurboInertia), 0, maxTurboAV)

  --Turbo Normalization (kinda) not 100% accurate when boost by speed is selected
  if AlsTable.turboNormalization and assignedEngine.instantEngineLoad >= 0.3 and electrics.values.gearIndex >= 1 and electrics.values.clutch <= 0.5 and not AlsTable.ALSActive then
    local torqueAtSeaLevel
    if AlsTable.boostByGear then
      torqueAtSeaLevel = (AlsTable.torqueCurveAtSeaLevel[ALSgear][sButton][engineRPM] or 0) * electrics.values.throttle --Aproximation of the torque the engine would be producing if at sea level \
    else                                                                                                                --                                                                          -- this does NOT take into consideration the presence of a supercharger or a N02 System
      torqueAtSeaLevel = (AlsTable.torqueCurveAtSeaLevel[1][sButton][engineRPM] or 0) * electrics.values.throttle       --Aproximation of the torque the engine would be producing if at sea level /
    end
    local torqueDelta = max(torqueAtSeaLevel - (assignedEngine.combustionTorque <= 0 and torqueAtSeaLevel or assignedEngine.combustionTorque), 0)
    local torqueOffPerc = torqueAtSeaLevel ~= 0 and (torqueDelta * 100 / torqueAtSeaLevel) or 0
    local relativeAirDensity = obj:getRelativeAirDensity()
    if torqueOffPerc >= AlsTable.torqueOffTolerance * relativeAirDensity * relativeAirDensity * relativeAirDensity then --If the torque delta is not high enough the boost will be very unstable (+/- 0.1Bar)
      local tp = (turboPressure + (torqueOffPerc / math.sqrt(relativeAirDensity)) * psiToPascal) --Calculate the needed turbo pressure to keep the same torque as at sea level
      if AlsTable.isBoostBySpeed then
        local index
        if electrics.values.wheelspeed <= AlsTable.boostAtSpeedCount then
          index = floor(electrics.values.wheelspeed)
        else
          index = AlsTable.boostAtSpeedCount
        end
          curTurboAV = min(curTurboAV + (120000 * dt), (AlsTable.invTurboPressureCurve[floor(tp * invPascalToPSI)] or AlsTable.invTurboPressureCurve[AlsTable.invTurboPressureCurveCount]) * (wastegateTargetBoost / AlsTable.boostAtSpeed[sButton][index]) * rpmToAV)
      else
        curTurboAV = min(curTurboAV + (120000 * dt), (AlsTable.invTurboPressureCurve[floor(tp * invPascalToPSI)] or AlsTable.invTurboPressureCurve[AlsTable.invTurboPressureCurveCount]) * rpmToAV)
      end
    end
  end

  local turboRPM = curTurboAV * avToRPM
  turboPressureRaw = assignedEngine.isStalled and 0 or ((turbo.turboPressureCurve[floor(turboRPM)] * psiToPascal) or turboPressure)
  turboPressure = pressureSmoother:getUncapped(turboPressureRaw, dt)

  -- --old Turbo Normalization
  -- if AlsTable.turboNormalization and assignedEngine.instantEngineLoad >= 0.3 then
  --     local torqueAtSeaLevel
  --     if AlsTable.boostByGear then
  --       torqueAtSeaLevel = (AlsTable.torqueCurveAtSeaLevel[ALSgear][sButton][engineRPM] or 0) * electrics.values.throttle --Aproximation of the torque the engine would be producing if at sea level \
  --     else                                                                                                                --                                                                          -- this does NOT take into consideration the presence of a supercharger or a N02 System
  --       torqueAtSeaLevel = (AlsTable.torqueCurveAtSeaLevel[1][sButton][engineRPM] or 0) * electrics.values.throttle       --Aproximation of the torque the engine would be producing if at sea level /
  --     end
  --     local torqueDelta = max(torqueAtSeaLevel - (assignedEngine.combustionTorque <= 0 and torqueAtSeaLevel or assignedEngine.combustionTorque), 0)
  --     local torqueOffPerc = torqueAtSeaLevel ~= 0 and (torqueDelta * 100 / torqueAtSeaLevel) or 0
  --     local relativeAirDensity = obj:getRelativeAirDensity()
  --     if torqueOffPerc >= AlsTable.torqueOffTolerance * relativeAirDensity * relativeAirDensity * relativeAirDensity then --If the torque delta is not high enough the boost will be very unstable (+/- 0.1Bar)
  --       local tp = (turboPressure + (torqueOffPerc / math.sqrt(relativeAirDensity)) * psiToPascal) --Calculate the needed turbo pressure to keep the same torque as at sea level
  --       turboPressure = min(pressureSmoother:getUncapped(tp, dt * 2), tp) --Smooth the result and apply it
  --     end
  -- end

  -- 1 psi = 6% more power
  -- 1 pascal = 0.00087% more power

  assignedEngine.forcedInductionCoef = assignedEngine.forcedInductionCoef * (1 + 0.0000087 * turboPressure * (turbo.turboEfficiencyCurve[engineRPM] or 0))
end

local function updateGFX(dt)
  --Some verification stuff
  if assignedEngine.engineDisabled then
    M.updateGFX = nop
    M.updateFixedStep = nop
    electrics.values.turboRpmRatio = 0
    electrics.values.turboBoost = 0
    electrics.values.turboEfficiency = 0
    turboPressure = 0
    turboPressureRaw = 0
    curTurboAV = 0
    return
  end

  local sButton = electrics.values.scramble + 1
  local ALSgear = electrics.values.gearIndex >= 1 and (# wastegateStart > 1 and electrics.values.gearIndex or 1) or 1

  local gear = electrics.values.gearIndex or 1
  wastegateStartPerGear = wastegateStart[gear] or maxWastegateStart
  wastegateRangePerGear = wastegateRange[gear] or maxWastegateRange
  if AlsTable.isBoostBySpeed then
    if electrics.values.wheelspeed <= AlsTable.boostAtSpeedCount then
      local fWheelSpeed = floor(electrics.values.wheelspeed)
      wastegateTargetBoost = AlsTable.boostAtSpeed[sButton][fWheelSpeed > 0 and fWheelSpeed or 1]
      --print("wastegateTargetBoost: " .. wastegateTargetBoost)
    else
      wastegateTargetBoost = AlsTable.boostAtSpeed[sButton][AlsTable.boostAtSpeedCount]
    end
  else
    wastegateTargetBoost = assignedEngine.simEngine ~= nil and assignedEngine.simEngine.state.targetBoostPressure or (wastegateStartPerGear[sButton] + wastegateRangePerGear[sButton] * 0.5)
    -- print(
    --   " targetBoostPressure: " .. (assignedEngine.simEngine and assignedEngine.simEngine.state.targetBoostPressure or -1)
    -- )
  end

  if AlsTable.ALSActive then
    wastegateTargetBoost = wastegateTargetBoost * AlsTable.ALSPressureRate
  end
  --print(wastegateTargetBoost)
  --open the BOV if we have very little load or if the engine load drops significantly
  local loadLow = assignedEngine.instantEngineLoad < bovOpenThreshold or assignedEngine.requestedThrottle <= 0
  local highLoadDrop = (lastEngineLoad - assignedEngine.instantEngineLoad) > bovOpenChangeThreshold
  local notInRevLimiter = assignedEngine.revLimiterWasActiveTimer > 0.1
  local ignitionNotCut = ignitionCutSmoother:getUncapped(assignedEngine.ignitionCutTime > 0 and 1 or 0, dt) <= 0
  local bovRequested = needsBov and (loadLow or highLoadDrop) and notInRevLimiter and ignitionNotCut

  if AlsTable.ALSActive then --Keep the bov shut to keep the pressure if the ALS is active
    bovRequested = false
  end

  if AlsTable.count > 2 then
    AlsTable.count = 1
  end

  AlsTable.engineLoadBuffer[AlsTable.count] = assignedEngine.engineLoad
  AlsTable.prevEngineLoad = (AlsTable.engineLoadBuffer[AlsTable.count - 1] or 0)
  AlsTable.count = AlsTable.count + 1

  AlsTable.twoStepLaunchControl = require("controller/twoStepLaunch")
  AlsTable.twoStepRpm = AlsTable.twoStepLaunchControl:serialize().rpm
  electrics.values.twoStepState = AlsTable.twoStepLaunchControl:serialize().state

  electrics.values.ALStwoStep = assignedEngine.outputRPM >= AlsTable.twoStepRpm - (2 * electrics.values.revLimiterRPMDrop) and electrics.values.twoStepState == "armed"
  electrics.values.doingBurnout = electrics.values.brake >= 0.2 and electrics.values.throttle >= 0.2 and electrics.values.airspeed <= 2 and electrics.values.wheelspeed >= 1
  electrics.values.ALSRevlimiter = assignedEngine.outputRPM >= (assignedEngine.maxRPM - 2 * electrics.values.revLimiterRPMDrop) and electrics.values.wheelspeed <= 2 and electrics.values.airspeed <= 2
  AlsTable.rollingALS = electrics.values.rollingALS == 1

  AlsTable.instantEngineLoadDrop = AlsTable.prevEngineLoad - assignedEngine.instantEngineLoad
  local alsConditions = AlsTable.ALS and (electrics.values.ALS_toggle == 1) and (not (assignedEngine.engineDisabled or assignedEngine.outputRPM < 10))
  if alsConditions and --General checks
      (--[[(AlsTable.instantEngineLoadDrop > AlsTable.ALSInstantLoadDrop and electrics.values.wheelspeed >= 3)]] highLoadDrop or --Meh non mi ispira
      (electrics.values.ALStwoStep) or
      (electrics.values.ALSRevlimiter) or
      (AlsTable.rollingALS) and
      not electrics.values.doingBurnout)then
    AlsTable.ALSNeed = true
  else
    AlsTable.ALSNeed = false
  end

  if AlsTable.ALSNeed and not AlsTable.ALSActive then --Activate ALS if needed
    AlsTable.ALSActive = true
  end

  if not AlsTable.ALSNeed and AlsTable.ALSActive then --Keep the ALS active for X more seconds
    if electrics.values.throttle <= 0 then -- If there is no throttle input keep the ALS active
      AlsTable.tick = AlsTable.tick + dt
    else --Otherwise disable it and give back the control of the turbo to the normal code
      AlsTable.ALSActive = false
      AlsTable.tick = 0
      AlsTable.ALSTransitionTicks = 40
      AlsTable.decreaseALSTemp = true
    end
    if (electrics.values.ALS_toggle == 0) then
      AlsTable.ALSActive = false
      AlsTable.tick = 0
    end
  end

  if not AlsTable.ALSNeed and not AlsTable.ALSActive and AlsTable.tick > 0 then --Reset the ticks
    AlsTable.tick = 0
  end

  if AlsTable.tick >= AlsTable.ALSTime then --If the ALS has been active and not "used" for more than X seconds, disable it
    AlsTable.tick = 0
    AlsTable.ALSActive = false
    AlsTable.ALSTransitionTicks = 40
    AlsTable.decreaseALSTemp = true
  end

  if AlsTable.ALSActive then --Increase the turbo temp if the ALS is active
    AlsTable.decreaseALSTemp = false
    AlsTable.ALSTemp = math.abs(AlsTable.ALSTemp) + ((wastegateTargetBoost + AlsTable.ALSExhaustPower) / 10000) * dt
  end

  if AlsTable.decreaseALSTemp then --Lower the turbo temp if needed
  	AlsTable.ALSTemp = AlsTable.ALSTemp - ((wastegateTargetBoost + AlsTable.ALSExhaustPower) / 9000) * dt
    if AlsTable.ALSTemp <= 0 then
      AlsTable.decreaseALSTemp = false
      AlsTable.ALSTemp = 0
    end
  end

  local turboTemp = AlsTable.ALSTemp + assignedEngine.thermals.exhaustTemperature + (assignedEngine.thermals.coolantTemperature or 0) + assignedEngine.thermals.oilTemperature
  --calculate turbo damage using our turbo temp
  if turboTemp > turboDamageThresholdTemperature then
    damageFrictionCoef = damageFrictionCoef * (1 + (turboTemp - turboDamageThresholdTemperature) * 0.001 * dt)
    damageTracker.setDamage("engine", "turbochargerHot", true)
  else
    damageTracker.setDamage("engine", "turbochargerHot", false)
  end

  bovEngaged = bovEnabled and bovRequested and not AlsTable.ALSActive
  bovTimer = max(bovTimer - dt, 0)
  if not AlsTable.ALSActive and not AlsTable.ALSNeed then
    if bovRequested and needsBov and not lastBOVValue and bovTimer <= 0 then
      if bovEnabled then
        local relativePressure = min(max(turboPressure / maxTurboPressure[sButton], 0), 1)
        local bovVolume = relativePressure * bovSoundPressureCoef
        obj:setVolumePitchCT(bovSound, bovVolume, 1, bovSoundVolumeCoef, 0)
        obj:playSFX(bovSound)
      else
        local relativePressure = min(max(turboPressure / maxTurboPressure[sButton], 0), 1)
        local flutterVolume = relativePressure * flutterSoundPressureCoef
        obj:setVolumePitchCT(flutterSound, flutterVolume, 1, flutterSoundVolumeCoef, 0)
        obj:playSFX(flutterSound)
      end
      bovTimer = 0.5
    end
  end

  if bovRequested and not AlsTable.ALSActive then --if the BOV is supposed to be open and we have positive pressure, we don't actually have any pressure ;)
    turboPressure = pressureSmoother:getUncapped(0, dt)
  elseif lastBOVValue or AlsTable.ALSActive then
    if bovSound then
      obj:stopSFX(bovSound)
    end
    if flutterSound then
      obj:stopSFX(flutterSound)
    end
  end

  local turboRPM = curTurboAV * avToRPM
  electrics.values[electricsRPMName] = turboRPM
  electricsSpinValue = electricsSpinValue + turboRPM * dt
  electrics.values[electricsSpinName] = (electricsSpinValue * electricsSpinCoef) % 360
  -- Update sounds
  electrics.values.turboRpmRatio = curTurboAV * invMaxTurboAV * 580
  electrics.values.turboBoost = turboPressure * invPascalToPSI
  electrics.values.turboEfficiency = turbo.turboEfficiencyCurve[floor(assignedEngine.outputRPM)] or 0

  lastEngineLoad = assignedEngine.instantEngineLoad
  lastBOVValue = bovRequested

  -- Update streams
  if streams.willSend("forcedInductionInfo") then
    forcedInductionInfoStream.rpm = curTurboAV * avToRPM
    forcedInductionInfoStream.coef = assignedEngine.forcedInductionCoef
    forcedInductionInfoStream.boost = turboPressure * 0.001
    --forcedInductionInfoStream.exhaustPower = exhaustPower / dt
    --forcedInductionInfoStream.backpressure = backPressure / dt
    forcedInductionInfoStream.bovEngaged = (bovEngaged and 1 or 0) * 10
    forcedInductionInfoStream.wastegateFactor = wastegateFactor * 10
    forcedInductionInfoStream.turboTemp = turboTemp

    gui.send("forcedInductionInfo", forcedInductionInfoStream)
  end

  if not AlsTable.bbsAndNormWarningShown and AlsTable.turboNormalization and AlsTable.isBoostBySpeed then
    gui.message("You have enabled both Boost By Speed and Turbo Nornalization, this effectivelly removes theeffects of the Boost By Speed controller! ")
    AlsTable.bbsAndNormWarningShown = true
  end

end

local function reset()
  AlsTable.ALSInstantAfterFireCoef   = 100
  AlsTable.ALSSustainedAfterFireCoef = 100
  AlsTable.ALSSustainedAfterFireTime = 5
  electrics.values.scramble = 0

  curTurboAV = 0
  turboPressure = 0
  turboPressureRaw = 0
  bovEngaged = false
  lastBOVValue = true
  lastEngineLoad = 0
  wastegateFactor = 1
  bovTimer = 0
  wastegateIntegral = 0
  lastBoostError = 0
  wastegateTargetBoost = 0
  wastegateStartPerGear = 0
  wastegateRangePerGear = 0
  electricsSpinValue = 0

  wearFrictionCoef = 1
  damageFrictionCoef = 1
  damageExhaustPowerCoef = 1

  AlsTable.ALSActive = false
  AlsTable.engineLoadBuffer = {}
  AlsTable.prevEngineLoad = 0
  AlsTable.count = 1
  AlsTable.instantEngineLoadDrop = 0
  AlsTable.ALSNeed = false
  AlsTable.ALSTemp = 0
  AlsTable.decreaseALSTemp = false
  AlsTable.hasALSJustBeenActivated = false
  AlsTable.ALSTransitionTicks = 0
  AlsTable.maxNonScrambledALSPressure = -1

  frictionCoef = turbo.frictionCoef or 0.01

  pressureSmoother:reset()
  wastegateSmoother:reset()
  ignitionCutSmoother:reset()

  damageTracker.setDamage("engine", "turbochargerHot", false)
  AlsTable.timeSinceLastActivation = AlsTable.ALSTime
end

local function init(device, jbeamData)
  turbo = jbeamData
  if turbo == nil then
    M.turboUpdate = nop
    return
  end
  local rpmToAV = 0.10471971768
  local avToRPM = 9.5493
  local invPascalToPSI = 0.00014503773773
  local psiToPascal = 6894.757293178

  assignedEngine = device

  curTurboAV = 0
  turboPressure = 0
  turboPressureRaw = 0
  bovEngaged = false
  lastBOVValue = true
  lastEngineLoad = 0
  wastegateFactor = 1
  bovTimer = 0
  wastegateIntegral = 0
  lastBoostError = 0
  wastegateTargetBoost = 0
  wastegateStartPerGear = 0
  wastegateRangePerGear = 0
  AlsTable.ALSTransitionTicks = 0

  maxTurboAV = 1
  electrics.values.scramble = 0
  AlsTable.scramblePressure = (turbo.scramblePressure or 0) * psiToPascal

  -- add the turbo pressure curve
  -- define y PSI at x RPM
  local pressurePSIcount = #turbo.pressurePSI
  local tpoints = table.new(pressurePSIcount, 0)
  if turbo.pressurePSI then
    for i = 1, pressurePSIcount do
      local point = turbo.pressurePSI[i]
      tpoints[i] = {point[1], point[2]}
      --Get max turbine rpm
      maxTurboAV = max(point[1] * rpmToAV, maxTurboAV)
    end
  else
    log("E", "Turbo", "No turbocharger.pressurePSI table found!")
    return
  end
  turbo.turboPressureCurve = createCurve(tpoints, true)
  -- add the turbo exhaust curve
  -- simulate pressure factor going between the exhasut and the turbine
  --
  -- add the turbo efficiency curve
  -- simulate power coef per engine RPM
  -- Eg: Small turbos will be more efficient on engine low rpm than high rpm and vice versa
  local engineDefcount = #turbo.engineDef
  local tepoints = table.new(engineDefcount, 0)
  local tipoints = table.new(engineDefcount, 0)
  if turbo.engineDef then
    for i = 1, engineDefcount do
      local point = turbo.engineDef[i]
      tepoints[i] = {point[1], point[2]}
      tipoints[i] = {point[1], min(point[3], 1)}
    end
  else
    log("E", "Turbo", "No turbocharger.engineDef curve found!")
    return
  end

  turbo.turboExhaustCurve = createCurve(tipoints)
  turbo.turboEfficiencyCurve = createCurve(tepoints)

  turboInertiaFactor = (turbo.inertia * 100) or 1

  wastegateStart = {}
  wastegateLimit = {}
  wastegateRange = {}
  AlsTable.torqueCurveAtSeaLevel = {}
  local turboCoefs = {}
  local maxGear = v.data.gearbox.gearRatios and #v.data.gearbox.gearRatios - 2 or AlsTable.gearCount
  if(type(turbo.wastegateStart) == "table") then
	  AlsTable.loopLimit = maxGear
    AlsTable.boostByGear = true
  else
	  AlsTable.loopLimit = 1
  end

  for i = 1,  AlsTable.loopLimit do
    wastegateStart[i] = {}
	  wastegateLimit[i] = {}
	  wastegateRange[i] = {}
    AlsTable.torqueCurveAtSeaLevel[i] = {}
    turboCoefs[i] = {}
    for j = 1, 2 do
      wastegateStart[i][j] = 0
	    wastegateLimit[i][j] = 0
	    wastegateRange[i][j] = 0
      AlsTable.torqueCurveAtSeaLevel[i][j] = {}
      turboCoefs[i][j] = {}
    end
  end

  maxWastegateStart = {}
  maxWastegateLimit = {}
  if type(turbo.wastegateStart) == "table" then
    for k, v in pairs(turbo.wastegateStart) do
      if k <= maxGear then
        --scramble pressure already in pascal
        v = v * psiToPascal--V to Pascal
        wastegateStart[k][1] = v
        wastegateStart[k][2] = v + AlsTable.scramblePressure

        if(k == 6) then
          for i = 6, AlsTable.loopLimit do 
            wastegateStart[i][1] = wastegateStart[6][1]
            wastegateStart[i][2] = (wastegateStart[i][1] + (AlsTable.scramblePressure))
          end
        end
      end
    end

    for i = 1, table.getn(wastegateStart) do
      if wastegateStart[i][1] > (maxWastegateStart[1] or -1) and i <= maxGear then
        maxWastegateStart[1] = wastegateStart[i][1]
      end
      if wastegateStart[i][2] > (maxWastegateStart[2] or -1) and i <= maxGear then
        maxWastegateStart[2] = wastegateStart[i][2]
      end
    end

  else
    if assignedEngine.simEngine ~= nil then
      wastegateStart[1][1] = assignedEngine.simEngine.ecu.maxBoostWastegateStart * psiToPascal
      maxWastegateStart[1] = wastegateStart[1][1]
  
      wastegateStart[1][2] = assignedEngine.simEngine.ecu.maxBoostWastegateStart * psiToPascal + AlsTable.scramblePressure
      maxWastegateStart[2] = wastegateStart[1][2]
    else
      wastegateStart[1][1] = (turbo.wastegateStart or 0) * psiToPascal
      maxWastegateStart[1] = wastegateStart[1][1]
  
      wastegateStart[1][2] = (turbo.wastegateStart or 0) * psiToPascal + AlsTable.scramblePressure
      maxWastegateStart[2] = wastegateStart[1][2]
    end
  end

  if type(turbo.wastegateLimit) == "table" then
    local tmp = -1
    for k, v in pairs(turbo.wastegateLimit) do
      if k <= maxGear then
	      wastegateLimit[k][1] = v * psiToPascal 
	      tmp = wastegateLimit[k][1]
        if tmp > (maxWastegateLimit[1] or -1)  and k <= maxGear then
          maxWastegateLimit[1] = tmp
        end

	      wastegateLimit[k][2] = (v + (AlsTable.scramblePressure * invPascalToPSI)) * psiToPascal

        tmp = wastegateLimit[k][2] + (AlsTable.scramblePressure * invPascalToPSI)
        if tmp > (maxWastegateLimit[2] or -1) and k <= maxGear then
          maxWastegateLimit[2] = tmp
        end

        if(k == 6) then
  	  	  for i = 6, AlsTable.loopLimit do 
            wastegateLimit[i][1] = wastegateLimit[6][1]
  	  	    wastegateLimit[i][2] = wastegateLimit[i][1] + AlsTable.scramblePressure
  	  	  end
        end
      end
    end
  else
    if assignedEngine.simEngine ~= nil then
      wastegateLimit[1][1] = assignedEngine.simEngine.ecu.maxBoostWastegateLimit * psiToPascal
      maxWastegateLimit[1] = wastegateLimit[1][1]

      wastegateLimit[1][2] = assignedEngine.simEngine.ecu.maxBoostWastegateLimit * psiToPascal + AlsTable.scramblePressure
      maxWastegateLimit[2] = wastegateLimit[1][2]
    else
      wastegateLimit[1][1] = (turbo.wastegateLimit or 0) * psiToPascal
      maxWastegateLimit[1] = wastegateLimit[1][1]

      wastegateLimit[1][2] = ((turbo.wastegateLimit or 0)) * psiToPascal + AlsTable.scramblePressure
      maxWastegateLimit[2] = wastegateLimit[1][2]
    end
  end

  maxWastegateRange = {}
  for k, v in pairs(wastegateStart) do
		local start = v[1]
		local limit = wastegateLimit[k][1] or maxWastegateLimit[1]
		wastegateRange[k][1] = limit - start
		maxWastegateRange[1] = wastegateRange[k][1]

		start = v[2]
		limit = wastegateLimit[k][2] or maxWastegateLimit[2]
		wastegateRange[k][2] = limit - start
		maxWastegateRange[2] = wastegateRange[k][2]
  end

  AlsTable.ALSTime = turbo.ALSTime or 2
  AlsTable.timeSinceLastActivation = AlsTable.ALSTime
  AlsTable.ALS = turbo.ALS or false
  AlsTable.hasALSJustBeenActivated = false
  AlsTable.ALSExhaustPower = turbo.ALSExhaustPower or 1
  AlsTable.gearCount = v.data.gearbox.gearRatios and #v.data.gearbox.gearRatios - 2 or AlsTable.gearCount
  AlsTable.ALSPressureRate = turbo.ALSPressure / 100
  --[[AlsTable.ALSPressure = {}
  AlsTable.maxNonScrambledALSPressure = -1
  for k, v in pairs(wastegateStart) do
    AlsTable.ALSPressure[k] = {}
    local value = ((type(turbo.wastegateStart) == "table" and wastegateLimit[k][1] or wastegateLimit[1][1]) or 0) * AlsTable.ALSPressureRate
    local scrambredValue = value + AlsTable.scramblePressure

    AlsTable.ALSPressure[k][1] = value
    AlsTable.ALSPressure[k][2] = scrambredValue
    if AlsTable.ALSPressure[k][1] > AlsTable.maxNonScrambledALSPressure then
      AlsTable.maxNonScrambledALSPressure = AlsTable.ALSPressure[k][1]
    end
  end

  if #AlsTable.ALSPressure < AlsTable.gearCount then
    for i = #AlsTable.ALSPressure, AlsTable.gearCount do
      AlsTable.ALSPressure[i] = {}
      AlsTable.ALSPressure[i][1] = AlsTable.maxNonScrambledALSPressure
      AlsTable.ALSPressure[i][2] = AlsTable.maxNonScrambledALSPressure + AlsTable.scramblePressure
    end
  end]]
  local firstBoostPoint = nil
  AlsTable.isBoostBySpeed = turbo.isBoostBySpeed or false
  if AlsTable.isBoostBySpeed then
    local points = turbo.boostAtSpeed
    if points == nil then
      log("E", "Turbo", "No Boost At Speed curve found!!")
    else
      local boostAtSpeed = {{}, {}}
      for i = 1, #points do
        if firstBoostPoint == nil then
          firstBoostPoint = points[i][2] * psiToPascal
        end
        boostAtSpeed[1][i] = {points[i][1], points[i][2] * psiToPascal} --w/o scramble
        boostAtSpeed[2][i] = {points[i][1], points[i][2] * psiToPascal + AlsTable.scramblePressure} --w scramble
      end
      AlsTable.boostAtSpeed = {createCurve(boostAtSpeed[1]), createCurve(boostAtSpeed[2])}
      AlsTable.boostAtSpeedCount = #(AlsTable.boostAtSpeed[1])
    end
    --[[TODO: Optimize]]
    --local index = 1

    local lastBoostPoint = firstBoostPoint--[[
    while AlsTable.boostAtSpeed[1][index] == nil or AlsTable.boostAtSpeed[2][index] == nil do
      AlsTable.boostAtSpeed[1][index] = firstBoostPoint
      AlsTable.boostAtSpeed[2][index] = firstBoostPoint + AlsTable.scramblePressure
      index = index + 1
    end]]
    for index = 1, #(AlsTable.boostAtSpeed[1]) do
      if AlsTable.boostAtSpeed[1][index] ~= nil then
        lastBoostPoint = AlsTable.boostAtSpeed[1][index]
      else
        AlsTable.boostAtSpeed[1][index] = lastBoostPoint
        AlsTable.boostAtSpeed[2][index] = lastBoostPoint + AlsTable.scramblePressure
      end
    end
    AlsTable.boostAtSpeedCount = #(AlsTable.boostAtSpeed[1])
  end
  local invTurboPressureCurvePoints = table.new(pressurePSIcount, 0)
  for i = 1, pressurePSIcount do
    local point = turbo.pressurePSI[i]
    invTurboPressureCurvePoints[i] = {point[2], point[1]}
  end

  local invTurboPressureCurve = createCurve(invTurboPressureCurvePoints)
  AlsTable.invTurboPressureCurve = invTurboPressureCurve
  AlsTable.invTurboPressureCurveCount = #AlsTable.invTurboPressureCurve

  AlsTable.ALSInstantLoadDrop = turbo.ALSInstantLoadDrop or 1
  electrics.values.ALS_toggle = 0
  AlsTable.decreaseALSTemp = false

  maxExhaustPower = turbo.maxExhaustPower or 1

  backPressureCoef = turbo.backPressureCoef or 0.0005
  frictionCoef = turbo.frictionCoef or 0.01

  turboDamageThresholdTemperature = turbo.damageThresholdTemperature or 1000

  wastegatePCoef = turbo.wastegatePCoef or 0.0001
  wastegateICoef = turbo.wastegateICoef or 0.0015
  wastegateDCoef = turbo.wastegateDCoef or 0

  electricsRPMName = turbo.electricsRPMName or "turboRPM"
  electricsSpinName = turbo.electricsSpinName or "turboSpin"
  electricsSpinCoef = turbo.electricsSpinCoef or 0.1
  electricsSpinValue = 0

  --optimizations:
  invMaxTurboAV = 1 / maxTurboAV
  invEngMaxAV = 1 / ((assignedEngine.maxRPM or 8000) * rpmToAV)
  invTurboInertia = 1 / (0.000003 * turboInertiaFactor * 2.5)
  pressureSmoother = newTemporalSmoothing(100 * psiToPascal, (turbo.pressureRatePSI or 30) * psiToPascal)
  wastegateSmoother = newTemporalSmoothing(50, 50)
  ignitionCutSmoother = newTemporalSmoothing(1, 10)
  bovEnabled = (turbo.bovEnabled == nil or turbo.bovEnabled)
  bovOpenThreshold = turbo.bovOpenThreshold or 0.05
  bovOpenChangeThreshold = turbo.bovOpenChangeThreshold or 0.3
  needsBov = assignedEngine.requiredEnergyType ~= "diesel"
  maxTurboPressure[1] = maxWastegateStart[1] * invPascalToPSI * (1 + (maxWastegateRange[1] * invPascalToPSI) * 0.01) * psiToPascal
  maxTurboPressure[2] = maxWastegateStart[2] * invPascalToPSI * (1 + (maxWastegateRange[2] * invPascalToPSI) * 0.01) * psiToPascal

  forcedInductionInfoStream.friction = frictionCoef
  forcedInductionInfoStream.maxBoost = maxWastegateLimit[2] * 0.001

  wearFrictionCoef = 1
  damageFrictionCoef = 1
  damageExhaustPowerCoef = 1

  damageTracker.setDamage("engine", "turbochargerHot", false)

  AlsTable.normalInstantAfterFireCoef   = assignedEngine.instantAfterFireCoef   or 0
  AlsTable.normalSustainedAfterFireCoef = assignedEngine.sustainedAfterFireCoef or 0
  AlsTable.normalSustainedAfterFireTime = assignedEngine.sustainedAfterFireTime or 2.5
  AlsTable.ALSInstantAfterFireCoef   = 100
  AlsTable.ALSSustainedAfterFireCoef = 100
  AlsTable.ALSSustainedAfterFireTime = 5

  AlsTable.twoStepLaunchControl = require("controller/twoStepLaunch")
  AlsTable.twoStepRpm = AlsTable.twoStepLaunchControl:serialize().rpm

  electrics.values.revLimiterRPMDrop = (assignedEngine.revLimiterAVDrop or 5) * avToRPM
  if assignedEngine.revLimiterType == "timeBased" then
    electrics.values.revLimiterRPMDrop = (assignedEngine.revLimiterMaxAVDrop or 5) * avToRPM
  end  
  v.data.turbocharger.wastegateStart = maxWastegateStart[2] * invPascalToPSI

  --Turbo Normalization Init
  AlsTable.turboNormalization = turbo.turboNormalization or false
  if AlsTable.turboNormalization then
    AlsTable.torqueOffTolerance = turbo.torqueOffTolerance or 10
    for i = 1, AlsTable.loopLimit do
      for j = 1, 2 do
        turboCoefs[i][j] = getTorqueCoefs(i, j) --Get the turbo coeficients taking into consideration both boost by gear and scramble
      end
    end

    for i = 1, AlsTable.loopLimit do
      for k, v in pairs(assignedEngine.torqueCurve) do
        if type(k) == "number" and k < assignedEngine.maxRPM then
          local toSub = assignedEngine.friction + (assignedEngine.dynamicFriction * k * rpmToAV)
          for j = 1, 2 do 
            --i: gear index
            --(j == 1) --> scramble disabled, (j == 2) --> scramble enabled
            --k engine
            AlsTable.torqueCurveAtSeaLevel[i][j][k + 1] = (v * (turboCoefs[i][j][k] or 0)) - toSub --Calculate the torque the engine would produce at sea level
          end
        end
      end
    end

    --Optimization
    turboCoefs = nil
  end

  M.updateGFX = updateGFX
  M.updateFixedStep = updateFixedStep
  M.updateSounds = updateSounds
end

local function initSounds()
  local turboHissLoopFilename = turbo.hissLoopEvent or "event:>Vehicle>Forced_Induction>Turbo_01>turbo_hiss"
  turboHissLoop = obj:createSFXSource(turboHissLoopFilename, "AudioDefaultLoop3D", "TurbochargerWhine", assignedEngine.engineNodeID)
  local turboWhineLoopFilename = turbo.whineLoopEvent or "event:>Vehicle>Forced_Induction>Turbo_01>turbo_spin"
  turboWhineLoop = obj:createSFXSource(turboWhineLoopFilename, "AudioDefaultLoop3D", "TurbochargerWhine", assignedEngine.engineNodeID)

  turboWhinePitchPerAV = (turbo.whinePitchPer10kRPM or 0.05) * 0.01 * rpmToAV
  turboWhineVolumePerAV = (turbo.whineVolumePer10kRPM or 0.04) * 0.01 * rpmToAV
  turboHissVolumePerPascal = (turbo.hissVolumePerPSI or 0.04) * invPascalToPSI

  bovSoundVolumeCoef = turbo.bovSoundVolumeCoef or 0.3
  bovSoundPressureCoef = turbo.bovSoundPressureCoef or 0.3
  local bovSoundFileName = turbo.bovSoundFileName or "event:>Vehicle>Forced_Induction>Turbo_01>turbo_bov"
  bovSound = obj:createSFXSource2(bovSoundFileName, "AudioDefaultLoop3D", "Bov", assignedEngine.engineNodeID, 0)

  flutterSoundVolumeCoef = turbo.flutterSoundVolumeCoef or 0.3
  flutterSoundPressureCoef = turbo.flutterSoundPressureCoef or 0.3
  local flutterSoundFileName = turbo.flutterSoundFileName or "event:>Vehicle>Forced_Induction>Turbo_02>turbo_bov"
  flutterSound = obj:createSFXSource2(flutterSoundFileName, "AudioDefaultLoop3D", "Flutter", assignedEngine.engineNodeID, 0)
end

local function resetSounds()
end

-- public interface
M.init = init
M.initSounds = initSounds
M.resetSounds = resetSounds
M.updateSounds = nop
M.reset = reset
M.updateGFX = nop
M.updateFixedStep = nop
M.getTorqueCoefs = getTorqueCoefs

M.applyDeformGroupDamage = applyDeformGroupDamage
M.setPartCondition = setPartCondition
M.getPartCondition = getPartCondition

return M
