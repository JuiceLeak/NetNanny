local DataStoreService = game:GetService("DataStoreService")
local SoloStore = DataStoreService:GetDataStore("NetNanny_SoloExperience")
local BanStore = DataStoreService:GetDataStore("NetNanny_Bans")
local StrikeStore = DataStoreService:GetDataStore("NetNanny_Strikes")

local NetNanny = {}

NetNanny.StrikesToBan = 2 -- adjustable number of strikes to trigger a ban

---- SoloExperience System ----

function NetNanny.MarkSoloBatch(userIds: {number})
	for _, userId in ipairs(userIds) do
		local success, err = pcall(function()
			local existing = SoloStore:GetAsync(tostring(userId))
			if not existing then
				SoloStore:SetAsync(tostring(userId), {Solo = true, Reason = "Matchmaking Adjustment"})
			end
		end)
		if not success then
			warn("NetNanny: Failed to mark Solo for UserId " .. userId .. ": " .. tostring(err))
		end
	end
end

function NetNanny.UnmarkSoloBatch(userIds: {number})
	for _, userId in ipairs(userIds) do
		local success, err = pcall(function()
			SoloStore:RemoveAsync(tostring(userId))
		end)
		if not success then
			warn("NetNanny: Failed to unmark Solo for UserId " .. userId .. ": " .. tostring(err))
		end
	end
end

function NetNanny.IsSolo(userId: number): boolean
	local success, result = pcall(function()
		local record = SoloStore:GetAsync(tostring(userId))
		return record and record.Solo == true or false
	end)
	if success then
		return result
	else
		warn("NetNanny: Failed to check Solo status for UserId " .. userId)
		return false
	end
end

---- Strike & Ban System ----

-- Add a strike to a user, auto-ban if threshold reached
function NetNanny.AddStrike(userId: number, reason: string)
	local currentStrikes = 0
	local success, result = pcall(function()
		local record = StrikeStore:GetAsync(tostring(userId))
		currentStrikes = record or 0
	end)
	if not success then
		warn("NetNanny: Failed to get strikes for UserId " .. userId)
	end

	currentStrikes += 1

	local strikeSuccess, strikeErr = pcall(function()
		StrikeStore:SetAsync(tostring(userId), currentStrikes)
	end)
	if not strikeSuccess then
		warn("NetNanny: Failed to update strikes for UserId " .. userId .. ": " .. tostring(strikeErr))
	end

	if currentStrikes >= NetNanny.StrikesToBan then
		NetNanny.BanUser(userId, reason)
	end
end

-- Ban a user manually
function NetNanny.BanUser(userId: number, reason: string)
	local success, err = pcall(function()
		BanStore:SetAsync(tostring(userId), {Banned = true, Reason = reason})
	end)
	if not success then
		warn("NetNanny: Failed to ban UserId " .. userId .. ": " .. tostring(err))
	end
end

-- Unban a user manually
function NetNanny.UnbanUser(userId: number)
	local success, err = pcall(function()
		BanStore:RemoveAsync(tostring(userId))
	end)
	if not success then
		warn("NetNanny: Failed to unban UserId " .. userId .. ": " .. tostring(err))
	end

	-- Reset strikes on unban
	local resetSuccess, resetErr = pcall(function()
		StrikeStore:RemoveAsync(tostring(userId))
	end)
	if not resetSuccess then
		warn("NetNanny: Failed to reset strikes for UserId " .. userId .. ": " .. tostring(resetErr))
	end
end

-- Check if a user is banned
function NetNanny.IsBanned(userId: number): boolean
	local success, result = pcall(function()
		local record = BanStore:GetAsync(tostring(userId))
		return record and record.Banned == true or false
	end)
	if success then
		return result
	else
		warn("NetNanny: Failed to check ban status for UserId " .. userId)
		return false
	end
end

-- Get the reason a user is banned
function NetNanny.GetBanReason(userId: number): string
	local success, record = pcall(function()
		return BanStore:GetAsync(tostring(userId))
	end)
	if success and record then
		return record.Reason or "No reason provided"
	else
		return "Unable to retrieve ban reason"
	end
end

return NetNanny
