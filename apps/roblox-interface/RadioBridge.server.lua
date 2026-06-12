local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local HttpService = game:GetService("HttpService")
local RunService = game:GetService("RunService")

local BRIDGE_BASE_URL = "http://83.254.129.17:3000"

local PLACE_ID = game.PlaceId ~= 0 and game.PlaceId or 123
local JOB_ID = "studio-local"

local STATE_SEND_INTERVAL = 0.2 -- 5 Hz
local TX_HEARTBEAT_INTERVAL = 0.2

local RadioEvent = ReplicatedStorage:FindFirstChild("RadioBridgeEvent")

if not RadioEvent then
	RadioEvent = Instance.new("RemoteEvent")
	RadioEvent.Name = "RadioBridgeEvent"
	RadioEvent.Parent = ReplicatedStorage
end

local radioStates = {}

local function defaultRadioState()
	return {
		frequency = "30.125",
		isPtt = false,
		radioId = "primary",
		team = "BLUFOR",
		squad = "Alpha",
		txToken = nil,
		lastHeartbeatAt = 0,

		radios = {
			{
				id = 1,
				channel = "30.125",
				listening = true,
				transmitting = false,
				ear = "both",
				volume = 1.0,
				minDistance = 0,
				maxDistance = 3000
			}
		}
	}
end

local function getState(player)
	local state = radioStates[player.UserId]

	if not state then
		state = defaultRadioState()
		radioStates[player.UserId] = state
	end

	return state
end

local function requestJson(path, body)
	local url = BRIDGE_BASE_URL .. path
	local encoded = HttpService:JSONEncode(body)

	local ok, response = pcall(function()
		return HttpService:RequestAsync({
			Url = url,
			Method = "POST",
			Headers = {
				["Content-Type"] = "application/json"
			},
			Body = encoded
		})
	end)

	if not ok then
		warn("[RadioBridge] HTTP failed:", response)
		return nil
	end

	if not response.Success then
		warn("[RadioBridge] HTTP error:", response.StatusCode, response.Body)
		return nil
	end

	local decodeOk, decoded = pcall(function()
		return HttpService:JSONDecode(response.Body)
	end)

	if not decodeOk then
		warn("[RadioBridge] Failed to decode response:", response.Body)
		return nil
	end

	return decoded
end

local function vectorToTable(v)
	return {
		x = v.X,
		y = v.Y,
		z = v.Z
	}
end

local function getPlayerPayload(player)
	local state = getState(player)
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")

	if not root then
		return nil
	end

	state.radios[1].channel = state.frequency
	state.radios[1].transmitting = state.isPtt

	return {
		robloxUserId = player.UserId,
		username = player.Name,
		displayName = player.DisplayName,

		position = vectorToTable(root.Position),
		lookVector = vectorToTable(root.CFrame.LookVector),

		-- Legacy single-radio fields
		frequency = state.frequency,
		isPtt = state.isPtt,
		radioId = state.radioId,

		-- New multi-radio fields
		radios = state.radios,

		team = state.team,
		squad = state.squad
	}
end

local function sendStateBatch()
	local playersPayload = {}

	for _, player in ipairs(Players:GetPlayers()) do
		local payload = getPlayerPayload(player)

		if payload then
			table.insert(playersPayload, payload)
		end
	end

	if #playersPayload == 0 then
		return
	end

	requestJson("/v1/roblox/state", {
		placeId = PLACE_ID,
		jobId = JOB_ID,
		players = playersPayload
	})
end

local function startTransmit(player)
	local state = getState(player)

	if state.txToken then
		return
	end

	state.isPtt = true

	task.spawn(function()
		local result = requestJson("/v1/tx/start", {
			placeId = PLACE_ID,
			jobId = JOB_ID,
			frequency = state.frequency,
			robloxUserId = player.UserId,
			radioId = state.radioId
		})

		if not result then
			state.isPtt = false
			RadioEvent:FireClient(player, "TxDenied", {
				reason = "bridge_error"
			})
			return
		end

		if result.granted == true and result.lock then
			state.txToken = result.lock.token
			state.lastHeartbeatAt = os.clock()

			RadioEvent:FireClient(player, "TxGranted", {
				frequency = state.frequency
			})
		else
			state.isPtt = false

			RadioEvent:FireClient(player, "TxDenied", {
				reason = "frequency_busy",
				frequency = state.frequency,
				currentOwnerRobloxUserId = result.currentOwnerRobloxUserId
			})
		end
	end)
end

local function stopTransmit(player)
	local state = getState(player)

	state.isPtt = false

	local token = state.txToken
	state.txToken = nil

	if not token then
		RadioEvent:FireClient(player, "TxStopped", {
			frequency = state.frequency
		})
		
		return
	end

	task.spawn(function()
		requestJson("/v1/tx/stop", {
			placeId = PLACE_ID,
			jobId = JOB_ID,
			frequency = state.frequency,
			robloxUserId = player.UserId,
			token = token
		})

		RadioEvent:FireClient(player, "TxStopped", {
			frequency = state.frequency
		})
	end)
end

local function heartbeatTransmit(player)
	local state = getState(player)

	if not state.isPtt or not state.txToken then
		return
	end

	local now = os.clock()

	if now - state.lastHeartbeatAt < TX_HEARTBEAT_INTERVAL then
		return
	end

	state.lastHeartbeatAt = now

	task.spawn(function()
		local result = requestJson("/v1/tx/heartbeat", {
			placeId = PLACE_ID,
			jobId = JOB_ID,
			frequency = state.frequency,
			robloxUserId = player.UserId,
			token = state.txToken
		})

		if not result or result.ok ~= true then
			state.isPtt = false
			state.txToken = nil

			RadioEvent:FireClient(player, "TxDenied", {
				reason = "heartbeat_failed"
			})
		end
	end)
end

RadioEvent.OnServerEvent:Connect(function(player, action, payload)
	local state = getState(player)

	if action == "SetFrequency" then
		if typeof(payload) ~= "table" then
			return
		end

		local frequency = tostring(payload.frequency or "")

		if frequency == "" then
			return
		end

		if state.isPtt then
			return
		end

		state.frequency = frequency
		state.radios[1].channel = frequency

		RadioEvent:FireClient(player, "FrequencyChanged", {
			frequency = state.frequency
		})

	elseif action == "PttDown" then
		startTransmit(player)

	elseif action == "PttUp" then
		stopTransmit(player)
	elseif action == "SetStero" then
		state.radios[1].ear = payload
		
		RadioEvent:FireClient(player, "SteroChanged", {
			stero = state.radios[1].stero
		})
	end
end)

Players.PlayerRemoving:Connect(function(player)
	stopTransmit(player)
	radioStates[player.UserId] = nil
end)

task.spawn(function()
	while true do
		sendStateBatch()

		for _, player in ipairs(Players:GetPlayers()) do
			heartbeatTransmit(player)
		end

		task.wait(STATE_SEND_INTERVAL)
	end
end)

print("[RadioBridge] Started", PLACE_ID, JOB_ID, BRIDGE_BASE_URL)