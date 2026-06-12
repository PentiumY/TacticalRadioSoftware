local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local RadioEvent = ReplicatedStorage:WaitForChild("RadioBridgeEvent")

local PTT_KEY = Enum.KeyCode.V

local isHoldingPtt = false

UserInputService.InputBegan:Connect(function(input, gameProcessed)
	if gameProcessed then
		return
	end

	if input.KeyCode == PTT_KEY then
		if isHoldingPtt then
			return
		end

		isHoldingPtt = true
		print("[Radio] PTT down")
		RadioEvent:FireServer("PttDown")
	end
end)

UserInputService.InputEnded:Connect(function(input, gameProcessed)
	if input.KeyCode == PTT_KEY then
		if not isHoldingPtt then
			return
		end

		isHoldingPtt = false
		print("[Radio] PTT up")
		RadioEvent:FireServer("PttUp")
	end
end)

RadioEvent.OnClientEvent:Connect(function(action, payload)
	if action == "TxGranted" then
		print("[Radio] TX granted on", payload.frequency)

	elseif action == "TxDenied" then
		warn("[Radio] TX denied:", payload.reason)

	elseif action == "TxStopped" then
		print("[Radio] TX stopped")

	elseif action == "FrequencyChanged" then
		print("[Radio] Frequency changed to", payload.frequency)
	end
end)