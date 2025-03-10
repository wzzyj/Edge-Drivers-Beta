-- Copyright 2021 SmartThings
--
-- Licensed under the Apache License, Version 2.0 (the "License");
-- you may not use this file except in compliance with the License.
-- You may obtain a copy of the License at
--
--     http://www.apache.org/licenses/LICENSE-2.0
--
-- Unless required by applicable law or agreed to in writing, software
-- distributed under the License is distributed on an "AS IS" BASIS,
-- WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
-- See the License for the specific language governing permissions and
-- limitations under the License.

------ Author Mariano Colmenarejo (nov 2021) --------

local capabilities = require "st.capabilities"
local ZigbeeDriver = require "st.zigbee"
local defaults = require "st.zigbee.defaults"
local xiaomi_utils = require "xiaomi_utils"
local data_types = require "st.zigbee.data_types"

--- Temperature Mesurement config
local zcl_clusters = require "st.zigbee.zcl.clusters"
local BasicInput = zcl_clusters.BasicInput
local tempMeasurement = zcl_clusters.TemperatureMeasurement
local device_management = require "st.zigbee.device_management"
local tempMeasurement_defaults = require "st.zigbee.defaults.temperatureMeasurement_defaults"

-- default Humidity Measurement
local HumidityCluster = require ("st.zigbee.zcl.clusters").RelativeHumidity
local utils = require "st.utils"

local child_devices = require "child-devices"
local signal = require "signal-metrics"
local refresh_thermostat = require "refresh-thermostat"

local read_attribute = require "st.zigbee.zcl.global_commands.read_attribute"
local zcl_messages = require "st.zigbee.zcl"
local messages = require "st.zigbee.messages"
local zb_const = require "st.zigbee.constants"


-- Custom Capability AtmPressure declaration
local atmos_Pressure = capabilities ["legendabsolute60149.atmosPressure"]
local temp_Condition = capabilities ["legendabsolute60149.tempCondition2"]
local temp_Target = capabilities ["legendabsolute60149.tempTarget"]
local humidity_Condition = capabilities ["legendabsolute60149.humidityCondition"]
local humidity_Target = capabilities ["legendabsolute60149.humidityTarget"]
local illumin_Condition = capabilities ["legendabsolute60149.illuminCondition"]
local illumin_Target = capabilities ["legendabsolute60149.illuminTarget"]
local signal_Metrics = capabilities["legendabsolute60149.signalMetrics"]
local atm_Pressure_Rate_Change = capabilities["legendabsolute60149.atmPressureRateChange"]


-- initialice variables
local temp_Condition_set ={}
temp_Condition_set.value = 0
temp_Condition_set.unit = "C"
local humidity_Condition_set = 0
local illumin_Condition_set = 0
local temp_Target_set = " "
local humidity_Target_set = " "
local illumin_Target_set = " "
local last_hour_press_values = {}
local last_hour_press_time = {}

--tuyaBlackMagic() {return zigbee.readAttribute(0x0000, [0x0004, 0x000, 0x0001, 0x0005, 0x0007, 0xfffe], [:], delay=200)}
local function read_attribute_function(device, cluster_id, attr_id)
  if device.preferences.logDebugPrint == true then
    print("<<<< attr_id >>>>",utils.stringify_table(attr_id))
  end
  --local read_body = read_attribute.ReadAttribute({ attr_id }) --- Original lua librares
  local read_body = read_attribute.ReadAttribute( attr_id )
  local zclh = zcl_messages.ZclHeader({
    cmd = data_types.ZCLCommandId(read_attribute.ReadAttribute.ID)
  })

  local addrh = messages.AddressHeader(
      zb_const.HUB.ADDR,
      zb_const.HUB.ENDPOINT,
      device:get_short_address(),
      device:get_endpoint(cluster_id.value),
      zb_const.HA_PROFILE_ID,
      cluster_id.value
  )
  local message_body = zcl_messages.ZclMessageBody({
    zcl_header = zclh,
    zcl_body = read_body
  })
  return messages.ZigbeeMessageTx({
    address_header = addrh,
    body = message_body
  --}))
})
end

--- do configure for temperature capability
local function do_configure(self,device)
  -- if is one Child device return
if device.network_type == "DEVICE_EDGE_CHILD" then return end
  ---defualt configuration capabilities
  --device:configure()

  if device:get_manufacturer() == "KMPCIL" then
    device:send(device_management.build_bind_request(device, BasicInput.ID, self.environment_info.hub_zigbee_eui))
    device:send(BasicInput.attributes.PresentValue:configure_reporting(device, 0xFFFF, 0xFFFF))
  end
  ----configure temperature capability
  local maxTime = device.preferences.tempMaxTime * 60
  local changeRep = device.preferences.tempChangeRep * 100
  print ("maxTime y changeRep: ",maxTime, changeRep )
  device:send(device_management.build_bind_request(device, tempMeasurement.ID, self.environment_info.hub_zigbee_eui))
  device:send(tempMeasurement.attributes.MeasuredValue:configure_reporting(device, 30, maxTime, changeRep))

  -- configure Humidity
  maxTime = device.preferences.humMaxTime * 60
  changeRep = device.preferences.humChangeRep * 100
  print ("Humidity maxTime & changeRep: ", maxTime, changeRep)
  device:send(device_management.build_bind_request(device, HumidityCluster.ID, self.environment_info.hub_zigbee_eui))
  device:send(HumidityCluster.attributes.MeasuredValue:configure_reporting(device, 60, maxTime, changeRep))
  --device:configure()

  -- configure pressure reports
  if device.preferences.pressMaxTime ~= nil and device.preferences.pressChangeRep  ~= nil then
    maxTime = device.preferences.pressMaxTime * 60
    changeRep = device.preferences.pressChangeRep * 10
    print ("Pressure maxTime y changeRep: ",maxTime, changeRep )
    if device:get_manufacturer() == "KMPCIL" then
      local config =
      {
        cluster = 0x0403,
        attribute = 0x0000,
        minimum_interval = 60,
        maximum_interval = maxTime,
        reportable_change = changeRep,
        data_type = data_types.Uint16,
      }
      device:add_configured_attribute(config)
      device:add_monitored_attribute(config)
    --end         
    else  
      device:send(device_management.build_bind_request(device, zcl_clusters.PressureMeasurement.ID, self.environment_info.hub_zigbee_eui))
      device:send(zcl_clusters.PressureMeasurement.attributes.MeasuredValue:configure_reporting(device, 60, maxTime, changeRep))
    end
 end
  -- configure Illuminance reports
 if device.preferences.illuMaxTime ~= nil and device.preferences.illuChangeRep  ~= nil then
  maxTime = device.preferences.illuMaxTime * 60
  changeRep = math.floor(10000 * (math.log((device.preferences.illuChangeRep + 1), 10)))
  print ("Illuminance maxTime y changeRep: ",maxTime, changeRep )
  device:send(device_management.build_bind_request(device, zcl_clusters.IlluminanceMeasurement.ID, self.environment_info.hub_zigbee_eui))
  device:send(zcl_clusters.IlluminanceMeasurement.attributes.MeasuredValue:configure_reporting(device, 60, maxTime, changeRep))
 end
 ---battery configure
 if device:get_manufacturer() ~= "_TZ2000_a476raq2" then
    print("Battery Config >>>>>>>>>")
    device:send(device_management.build_bind_request(device, zcl_clusters.PowerConfiguration.ID, self.environment_info.hub_zigbee_eui))
    device:send(zcl_clusters.PowerConfiguration.attributes.BatteryPercentageRemaining:configure_reporting(device, 30, 21600, 1))
 else
    device:send(device_management.build_bind_request(device, zcl_clusters.PowerConfiguration.ID, self.environment_info.hub_zigbee_eui))
    device:send(zcl_clusters.PowerConfiguration.attributes.BatteryVoltage:configure_reporting(device, 30, 21600, 1))
 end
end

-- preferences update
local function do_preferences(self, device)
  --if device.network_type == "DEVICE_EDGE_CHILD" then return end
  for id, value in pairs(device.preferences) do
    --print("device.preferences[infoChanged]=", device.preferences[id])
    local oldPreferenceValue = device:get_field(id)
    local newParameterValue = device.preferences[id]
     if oldPreferenceValue ~= newParameterValue then
      device:set_field(id, newParameterValue, {persist = true})
      if device.preferences.logDebugPrint == true then
        print("<< Preference changed:",id, "old value", oldPreferenceValue, "new value>>", newParameterValue)
      end
      if  id == "tempMaxTime" or id == "tempChangeRep" then
        local maxTime = device.preferences.tempMaxTime * 60
        local changeRep = device.preferences.tempChangeRep * 100
        print ("Temp maxTime & changeRep: ", maxTime, changeRep)
        --device:send(device_management.build_bind_request(device, tempMeasurement.ID, self.environment_info.hub_zigbee_eui))
        device:send(tempMeasurement.attributes.MeasuredValue:configure_reporting(device, 30, maxTime, changeRep))
      elseif id == "humMaxTime" or id == "humChangeRep" then
        local maxTime = device.preferences.humMaxTime * 60
        local changeRep = device.preferences.humChangeRep * 100
        print ("Humidity maxTime & changeRep: ", maxTime, changeRep)
        --device:send(device_management.build_bind_request(device, HumidityCluster.ID, self.environment_info.hub_zigbee_eui))
        device:send(HumidityCluster.attributes.MeasuredValue:configure_reporting(device, 60, maxTime, changeRep))
      elseif id == "pressMaxTime" or id == "pressChangeRep" then
        --local minTime = 60
        local maxTime = device.preferences.pressMaxTime * 60
        local changeRep = device.preferences.pressChangeRep * 10
        if device:get_manufacturer() == "KMPCIL" then
          print ("Press maxTime & changeRep: ", maxTime, changeRep)
          local config =
          {
            cluster = 0x0403,
            attribute = 0x0000,
            minimum_interval = 60,
            maximum_interval = maxTime,
            reportable_change = changeRep,
            data_type = data_types.Uint16,
          }
          device:add_configured_attribute(config)
          device:add_monitored_attribute(config)
          device:configure() -- configure pressure with correct data types
          do_configure(self,device)  -- configure correct intervals for temp, humid and illumin   
        else
          print ("Press maxTime & changeRep: ", maxTime, changeRep)
          --device:send(device_management.build_bind_request(device, zcl_clusters.PressureMeasurement.ID, self.environment_info.hub_zigbee_eui))
          device:send(zcl_clusters.PressureMeasurement.attributes.MeasuredValue:configure_reporting(device, 60, maxTime, changeRep))
        end
      elseif id == "illuMaxTime" or id == "illuChangeRep" then
        local maxTime = device.preferences.illuMaxTime * 60
        local changeRep = math.floor(10000 * (math.log((device.preferences.illuChangeRep + 1), 10)))
        print ("Illumin maxTime & changeRep: ", maxTime, changeRep)
        --device:send(device_management.build_bind_request(device, zcl_clusters.IlluminanceMeasurement.ID, self.environment_info.hub_zigbee_eui))
        device:send(zcl_clusters.IlluminanceMeasurement.attributes.MeasuredValue:configure_reporting(device, 60, maxTime, changeRep))
      elseif id == "changeProfileTHB" then
        if newParameterValue == "Single" then
           device:try_update_metadata({profile = "temp-humid-battery"})
        else
           device:try_update_metadata({profile = "temp-humid-battery-multi"})
        end
      elseif id == "changeProfileTHPB" then
        if newParameterValue == "Single" then
          device:try_update_metadata({profile = "temp-humid-press-battery"})
        else
          device:try_update_metadata({profile = "temp-humid-press-battery-multi"})
        end
      elseif id == "changeProfileTHPI" then
        if newParameterValue == "Single" then
          device:try_update_metadata({profile = "temp-humid-press-illumin"})
        else
          device:try_update_metadata({profile = "temp-humid-press-illumin-multi"})
        end
      elseif id == "changeProfileTHIB" then
        if newParameterValue == "Single" then
          device:try_update_metadata({profile = "temp-humid-illumin-battery"})
        else
          device:try_update_metadata({profile = "temp-humid-illumin-battery-multi"})
        end
      end

      if id == "childThermostat" then
        if oldPreferenceValue ~= nil and newParameterValue == true then
         child_devices.create_new(self, device, "main")
        end 
      end

      --configure basicinput cluster
      if device:get_manufacturer() == "KMPCIL" then
        --device:send(device_management.build_bind_request(device, BasicInput.ID, self.environment_info.hub_zigbee_eui))
        --device:send(BasicInput.attributes.PresentValue:configure_reporting(device, 0xFFFF, 0xFFFF))
      end     
    end
  end

  --print manufacturer, model and leng of the strings
  local manufacturer = device:get_manufacturer()
  local model = device:get_model()
  local manufacturer_len = string.len(manufacturer)
  local model_len = string.len(model)

  if device.preferences.logDebugPrint == true then
    print("Device ID", device)
    print("Manufacturer >>>", manufacturer, "Manufacturer_Len >>>",manufacturer_len)
    print("Model >>>", model,"Model_len >>>",model_len)
    local firmware_full_version = device.data.firmwareFullVersion
    print("<<<<< Firmware Version >>>>>",firmware_full_version)
    -- This will print in the log the total memory in use by Lua in Kbytes
    print("Memory >>>>>>>",collectgarbage("count"), " Kbytes")
  end
end

--- temperature handler
local function temp_attr_handler(self, device, tempvalue, zb_rx)
  local last_temp_value = tempvalue.value / 100

  -- save new temperature for Thermostat Child device
  local child_device = device:get_child_by_parent_assigned_key("main")
  --print("<<<< child_device", child_device)
  if child_device ~= nil then
    child_device:set_field("last_temp", last_temp_value, {persist = false})
    child_device:emit_event(capabilities.temperatureMeasurement.temperature({value = last_temp_value, unit = "C" }))

    -- thermostat calculations
    refresh_thermostat.thermostat_data_check (self, child_device)

  end

  local temp_scale = "C"
  -- convert temp sent by device to ºF
  if device.preferences.thermTempUnits == "Fahrenheit" then 
    temp_scale = "F"
    last_temp_value = utils.round((last_temp_value * 9 / 5)) + 32
  end
  last_temp_value =  utils.round(last_temp_value) + device.preferences.tempOffset

  if last_temp_value < temp_Condition_set.value then
    temp_Target_set = "Down"
  elseif last_temp_value >= temp_Condition_set.value then
    temp_Target_set = "Equal-Up"
  end
  
  -- emit temp target
  device:emit_event(temp_Target.tempTarget(temp_Target_set))

  -- emit signal metrics
  signal.metrics(device, zb_rx)

  -- emmit device temperature
  tempMeasurement_defaults.temp_attr_handler(self, device, tempvalue, zb_rx)

end

-- attributte handler Atmospheric pressure
local pressure_value_attr_handler = function (driver, device, value, zb_rx)

  print("Pressure.value >>>>>>", value.value)
  -- save previous pressure  and time values
  if device:get_field("last_value") == nil then device:set_field("last_value", 0, {persist = true}) end
  local last_value = device:get_field("last_value")

  if device:get_field("last_value_time") == nil then device:set_field("last_value_time", (os.time() - (device.preferences.pressMaxTime * 60)) , {persist = false}) end
  local last_value_time = device:get_field("last_value_time")

  -- initialice 4 values of last hour to claculate rate change
  if device:get_field("last_hour_press_values") == nil or
    device:get_field("last_hour_press_time") == nil then
      local current_time = os.time()
      for i = 1, 4, 1 do
        last_hour_press_values[i] = value.value
        last_hour_press_time[i] = current_time
        if device.preferences.logDebugPrint == true then
          print("<<<< [i]=", i)
          print("<<<< last_hour_press_values[i]",last_hour_press_values[i],"last_hour_press_time[i]",os.date("%H:%M:%S",last_hour_press_time[i]))
        end
      end
      device:set_field("last_hour_press_values", last_hour_press_values, {persist = true})
      device:set_field("last_hour_press_time", last_hour_press_time, {persist = true})

    -- emit event atm_Pressure_Rate_Change
    device:emit_event(atm_Pressure_Rate_Change.atmPressureRateChange({value = 0, unit = "mBar/h"}))
  end

  last_hour_press_values = device:get_field("last_hour_press_values")
  last_hour_press_time = device:get_field("last_hour_press_time")
  
  local kPa = math.floor ((value.value + device.preferences.atmPressureOffset) / 10)

  --- Rate Change calculations
    if os.time() - last_hour_press_time[1] >= 3600 then
      local current_time = os.time()
      if device.preferences.logDebugPrint == true then
        for i = 1, 4, 1 do
          print("<<<< [i]=", i)
          print("<<<< last_hour_press_values[i]",last_hour_press_values[i],"last_hour_press_time[i]",os.date("%H:%M:%S",last_hour_press_time[i]))
        end
      end
      local delta_press = value.value - last_hour_press_values[1]
      local delta_time = current_time - last_hour_press_time[1]
      local rate_change = tonumber(string.format("%.1f", 3600 / delta_time * delta_press))

      if device.preferences.logDebugPrint == true then
        print("<<<< delta_press",delta_press)
        print("<<<< delta_time",delta_time)
        print("<<<< rate_change",rate_change)
      end

      for i = 1, 3, 1 do
        last_hour_press_time[i] = last_hour_press_time[i+1]
        last_hour_press_values[i] = last_hour_press_values[i+1]
      end
      last_hour_press_time[4] = current_time
      last_hour_press_values[4] = value.value
      device:set_field("last_hour_press_values", last_hour_press_values, {persist = true})
      device:set_field("last_hour_press_time", last_hour_press_time, {persist = true})

      -- emit event atm_Pressure_Rate_Change
      device:emit_event(atm_Pressure_Rate_Change.atmPressureRateChange({value = rate_change, unit = "mBar/h"}))
      -- emit event atm_Pressure_kPa
      device: emit_event (capabilities.atmosphericPressureMeasurement.atmosphericPressure ({value = kPa, unit = "kPa"}))
      --emit even for custom capability in mBar
      local mBar = value.value + device.preferences.atmPressureOffset
      device:emit_event(atmos_Pressure.atmosPressure({value = mBar, unit = "mBar"}))
      
      --save emitted pressure value
      device:set_field("last_value", value.value + device.preferences.atmPressureOffset, {persist = false})
      device:set_field("last_value_time", os.time(), {persist = false})

    elseif os.time() - last_hour_press_time[4] >= 900 then
      local current_time = os.time()
      if last_hour_press_time[1] == last_hour_press_time[2] then
        for i = 2, 3, 1 do
          last_hour_press_time[i] = last_hour_press_time[i+1]
          last_hour_press_values[i] = last_hour_press_values[i+1]
        end
        last_hour_press_time[4] = current_time
        last_hour_press_values[4] = value.value
        device:set_field("last_hour_press_values", last_hour_press_values, {persist = true})
        device:set_field("last_hour_press_time", last_hour_press_time, {persist = true})
      end
    end
    if device.preferences.logDebugPrint == true then
      for i = 1, 4, 1 do
        print("<<<< [i]=", i)
        print("<<<< last_hour_press_values[i]",last_hour_press_values[i],"last_hour_press_time[i]",os.date("%H:%M:%S",last_hour_press_time[i]))
      end
    end

  --- emmit only events for >= device.preferences.pressChangeRep or device.preferences.pressMaxTim
  if math.abs(value.value + device.preferences.atmPressureOffset - last_value) >= device.preferences.pressChangeRep * 10 or (os.time() - last_value_time) + 20 >= (device.preferences.pressMaxTime * 60) then
    device: emit_event (capabilities.atmosphericPressureMeasurement.atmosphericPressure ({value = kPa, unit = "kPa"}))
    --emit even for custom capability in mBar
    local mBar = value.value + device.preferences.atmPressureOffset
    device:emit_event(atmos_Pressure.atmosPressure({value = mBar, unit = "mBar"}))
    
    --save emitted pressure value
    device:set_field("last_value", value.value + device.preferences.atmPressureOffset, {persist = false})
    device:set_field("last_value_time", os.time(), {persist = false})
  end
end

---humidity_attr_handler
local function humidity_attr_handler(driver, device, value, zb_rx)

  -- emit signal metrics
  signal.metrics(device, zb_rx)

  if device:get_manufacturer() == "_TZ3000_ywagc4rj" then
    value.value = value.value * 10
    if device.preferences.logDebugPrint == true then
      print("_TZ3000_ywagc4rj-value.value=", value.value)
    end
  end

  local last_humid_value = utils.round(value.value / 100.0) + device.preferences.humidityOffset

  if last_humid_value < humidity_Condition_set then
    humidity_Target_set = "Down"
  elseif last_humid_value >= humidity_Condition_set then
    humidity_Target_set = "Equal-Up"
  end
    
  -- emit temp target
  device:emit_event(humidity_Target.humidityTarget(humidity_Target_set))
  -- emit device humidity
  device:emit_event_for_endpoint(zb_rx.address_header.src_endpoint.value, capabilities.relativeHumidityMeasurement.humidity(utils.round(value.value / 100.0))) -- + device.preferences.humidityOffset))

   -- Emit new Humidity for Thermostat Child device
  local child_device = device:get_child_by_parent_assigned_key("main")
  if child_device ~= nil then
    child_device:emit_event(capabilities.relativeHumidityMeasurement.humidity(utils.round(value.value / 100.0) + device.preferences.humidityOffset))
  end
end

--- illuminance_measurement_defaults
local function illuminance_measurement_defaults(driver, device, value, zb_rx)
  --print("luxOffset >>>>>",device.preferences.luxOffset)
  local lux_value = math.floor(10 ^ ((value.value - 1) / 10000)) + device.preferences.luxOffset
  if lux_value < 0 then lux_value = 0 end

  if lux_value < illumin_Condition_set then
    illumin_Target_set = "Down"
  elseif lux_value >= illumin_Condition_set then
    illumin_Target_set = "Equal-Up"
  end

  -- emit illumin target
  device:emit_event(illumin_Target.illuminTarget(illumin_Target_set))
  -- emit device illuminance
  device:emit_event_for_endpoint(zb_rx.address_header.src_endpoint.value, capabilities.illuminanceMeasurement.illuminance(lux_value))
end

---  set_TempCondition_handler
local function set_TempCondition_handler(self,device,command)
  print("set_TempCondition.value=", command.args.value)
  temp_Condition_set.value = command.args.value

  local last_temp_value = device:get_latest_state("main", capabilities.temperatureMeasurement.ID, capabilities.temperatureMeasurement.temperature.NAME)
  if last_temp_value == nil then last_temp_value = 0 end
  last_temp_value = utils.round(last_temp_value) + device.preferences.tempOffset

  if device.preferences.logDebugPrint == true then
    print("device:get_latest_state >>>>", device:get_latest_state("main", capabilities.temperatureMeasurement.ID, capabilities.temperatureMeasurement.temperature.NAME))
    print("last_temp_value ºC=",last_temp_value)
  end
  local temp_scale = "C"
  -- convert temp sent by device to ºF
  if device.preferences.thermTempUnits == "Fahrenheit" then 
    temp_scale = "F"
    last_temp_value = utils.round((last_temp_value * 9 / 5)) + 32
  end
  if device.preferences.logDebugPrint == true then
    print("last_temp_value C or F =",last_temp_value)
  end
  
  if last_temp_value < temp_Condition_set.value then
    temp_Target_set = "Down"
  elseif last_temp_value >= temp_Condition_set.value then
    temp_Target_set = "Equal-Up"
  end

  -- emit temp target
  device:emit_event(temp_Target.tempTarget(temp_Target_set))
  device:emit_event(temp_Condition.tempCondition({value = temp_Condition_set.value, unit = temp_scale}))

end

--- set_HumidityCondition_handler
local function set_HumidityCondition_handler(self,device,command)
  print("set_HumidityCondition=", command.args.value)
  humidity_Condition_set = command.args.value
  local last_humid_value = device:get_latest_state("main", capabilities.relativeHumidityMeasurement.ID, capabilities.relativeHumidityMeasurement.humidity.NAME) + device.preferences.humidityOffset
  if device.preferences.logDebugPrint == true then
    print ("last_humid_value = ",last_humid_value)
  end

  if last_humid_value < humidity_Condition_set then
    humidity_Target_set = "Down"
  elseif last_humid_value >= humidity_Condition_set then
    humidity_Target_set = "Equal-Up"
  end
    
  --  emit temp target and condition
  device:emit_event(humidity_Target.humidityTarget(humidity_Target_set))
  device:emit_event(humidity_Condition.humidityCondition(humidity_Condition_set))

end

--- set_IlluminCondition_handler
local function set_IlluminCondition_handler(self,device,command)
  print("set_IlluminCondition", command.args.value)
  illumin_Condition_set = command.args.value
  local lux_value = device:get_latest_state("main", capabilities.illuminanceMeasurement.ID, capabilities.illuminanceMeasurement.illuminance.NAME) + device.preferences.luxOffset
  --print("lux_value =",lux_value)

  if lux_value < illumin_Condition_set then
    illumin_Target_set = "Down"
  elseif lux_value >= illumin_Condition_set then
    illumin_Target_set = "Equal-Up"
  end

  -- emit temp target and condition
  device:emit_event(illumin_Target.illuminTarget(illumin_Target_set))
  device:emit_event(illumin_Condition.illuminCondition(illumin_Condition_set))

end

local function do_init(self,device)

    --tuyaBlackMagic() {return zigbee.readAttribute(0x0000, [0x0004, 0x000, 0x0001, 0x0005, 0x0007, 0xfffe], [:], delay=200)}
    --if device:get_model() == "TS0601" and device:get_manufacturer()== "_TZE200_znbl8dj5" then
    --if device:get_model() == "TS0222" and device:get_manufacturer()== "_TYZB01_ftdkanlj" then
      print("<<< Read Basic clusters attributes >>>")
      local attr_ids = {0x0004, 0x0000, 0x0001, 0x0005, 0x0007,0xFFFE} 
      device:send(read_attribute_function (device, data_types.ClusterId(0x0000), attr_ids))
    --end
      -- initialice device profiles
    if device.preferences.changeProfileTHB == "Single" then
        device:try_update_metadata({profile = "temp-humid-battery"})
    elseif device.preferences.changeProfileTHB == "Multi" then
        device:try_update_metadata({profile = "temp-humid-battery-multi"})
    elseif device.preferences.changeProfileTHPB == "Single" then
        device:try_update_metadata({profile = "temp-humid-press-battery"})
    elseif device.preferences.changeProfileTHPB == "Multi" then
        device:try_update_metadata({profile = "temp-humid-press-battery-multi"})
    elseif device.preferences.changeProfileTHPI == "Single" then 
        device:try_update_metadata({profile = "temp-humid-press-illumin"})
    elseif device.preferences.changeProfileTHPI == "Multi" then 
        device:try_update_metadata({profile = "temp-humid-press-illumin-multi"})
    elseif device.preferences.changeProfileTHIB == "Single" then
        device:try_update_metadata({profile = "temp-humid-illumin-battery"})
    elseif device.preferences.changeProfileTHIB == "Multi" then
        device:try_update_metadata({profile = "temp-humid-illumin-battery-multi"})
    end

    --  initialize values of capabilities
    if device:supports_capability_by_id(illumin_Condition.ID) then
      illumin_Condition_set = device:get_latest_state("main", illumin_Condition.ID, illumin_Condition.illuminCondition.NAME)
      if illumin_Condition_set == nil then illumin_Condition_set = 0 end
      device:emit_event(illumin_Condition.illuminCondition(illumin_Condition_set))
    end

    humidity_Condition_set = device:get_latest_state("main", humidity_Condition.ID, humidity_Condition.humidityCondition.NAME)
    if humidity_Condition_set == nil then humidity_Condition_set = 0 end
    device:emit_event(humidity_Condition.humidityCondition(humidity_Condition_set))

    temp_Condition_set.value = device:get_latest_state("main", temp_Condition.ID, temp_Condition.tempCondition.NAME)
    print("device:get_latest_state", device:get_latest_state("main", temp_Condition.ID, temp_Condition.tempCondition.NAME))
    if temp_Condition_set.value == nil then temp_Condition_set.value = 0 end
    local temp_scale = "C"
    if device.preferences.thermTempUnits == "Fahrenheit" then 
      temp_scale = "F"
    end
    device:emit_event(temp_Condition.tempCondition({value = temp_Condition_set.value, unit = temp_scale }))

    if device:supports_capability_by_id(illumin_Target.ID) then
      illumin_Target_set = device:get_latest_state("main", illumin_Target.ID, illumin_Target.illuminTarget.NAME)
      if illumin_Target_set == nil then illumin_Target_set = " " end
      device:emit_event(illumin_Target.illuminTarget(illumin_Target_set))
    end

    humidity_Target_set = device:get_latest_state("main", humidity_Target.ID, humidity_Target.humidityTarget.NAME)
    if humidity_Target_set == nil then humidity_Target_set = " " end
    device:emit_event(humidity_Target.humidityTarget(humidity_Target_set))

    temp_Target_set = device:get_latest_state("main", temp_Target.ID, temp_Target.tempTarget.NAME)
    if temp_Target_set == nil then temp_Target_set = " " end
    device:emit_event(temp_Target.tempTarget(temp_Target_set))

    if device:get_latest_state("main", signal_Metrics.ID, signal_Metrics.signalMetrics.NAME) == nil then
      device:emit_event(signal_Metrics.signalMetrics({value = "Waiting Zigbee Message"}, {visibility = {displayed = false }}))
    end

    if device:get_manufacturer() == "KMPCIL" then
      local maxTime = device.preferences.pressMaxTime * 60
      local changeRep = device.preferences.pressChangeRep * 10
      local config =
      {
        cluster = 0x0403,
        attribute = 0x0000,
        minimum_interval = 60,
        maximum_interval = maxTime,
        reportable_change = changeRep,
        data_type = data_types.Uint16,
      }
      device:add_configured_attribute(config)
      device:add_monitored_attribute(config)            
    end

    if device:get_latest_state("main", atm_Pressure_Rate_Change.ID, atm_Pressure_Rate_Change.atmPressureRateChange.NAME) == nil then
      --device:emit_event(atm_Pressure_Rate_Change.atmPressureRateChange({value = nil, unit = "mBar/h"}))
    end

end

-----driver_switched
local function driver_switched(self,device)
  device.thread:call_with_delay(5, function() do_configure(self,device) end)
end

----- driver template ----------
local zigbee_temp_driver = {
  supported_capabilities = {
    capabilities.temperatureMeasurement,
    capabilities.relativeHumidityMeasurement,
    capabilities.atmosphericPressureMeasurement,
    atmos_Pressure,
    illumin_Condition,
    illumin_Target,
    atm_Pressure_Rate_Change,
    capabilities.illuminanceMeasurement,
    capabilities.battery,
    capabilities.refresh
  },
  lifecycle_handlers = {
    init = do_init,
    doConfigure = do_configure,
    infoChanged = do_preferences,
    driverSwitched = driver_switched
  },
  capability_handlers = {
    [temp_Condition.ID] = {
      [temp_Condition.commands.setTempCondition.NAME] = set_TempCondition_handler,
    },
    [humidity_Condition.ID] = {
      [humidity_Condition.commands.setHumidityCondition.NAME] = set_HumidityCondition_handler,
    },
    [illumin_Condition.ID] = {
      [illumin_Condition.commands.setIlluminCondition.NAME] = set_IlluminCondition_handler,
    },
  },
  zigbee_handlers = {
    attr = {
      [zcl_clusters.basic_id] = {
        [0xFF02] = xiaomi_utils.battery_handler,
        [0xFF01] = xiaomi_utils.battery_handler
      },
      [tempMeasurement.ID] = {
          [tempMeasurement.attributes.MeasuredValue.ID] = temp_attr_handler
      },
      [zcl_clusters.PressureMeasurement.ID] = {
          [zcl_clusters.PressureMeasurement.attributes.MeasuredValue.ID] = pressure_value_attr_handler
      },
      [HumidityCluster.ID] = {
        [HumidityCluster.attributes.MeasuredValue.ID] = humidity_attr_handler
      },
      [zcl_clusters.IlluminanceMeasurement.ID] = {
        [zcl_clusters.IlluminanceMeasurement.attributes.MeasuredValue.ID] = illuminance_measurement_defaults
    }
   }
  },
  sub_drivers = {require("battery"), require("thermostat")},
  --health_check = false

}

--------- driver run ------
defaults.register_for_default_handlers(zigbee_temp_driver, zigbee_temp_driver.supported_capabilities)
local temperature = ZigbeeDriver("st-zigbee-temp", zigbee_temp_driver)
temperature:run()
