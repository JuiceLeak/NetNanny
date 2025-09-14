local Players = game:GetService("Players")
local TeleportService = game:GetService("TeleportService")
local HttpService = game:GetService("HttpService")
local RunService = game:GetService("RunService")

local NetNanny = require(game.ServerScriptService:WaitForChild("NNDataStore"))

local FLAGGED_WORDS = {
	"badword1",
	"gaming",
}

local PRIVATE_PLACE_ID = 12345678 -- Replace with your game's place ID for solo experiences

-- CONFIG
local CONFIG = {
	DebugPrints = true, -- Set false to silence debug prints; warns, bans, and flags always show
	MaxFriendChecks = 20, -- How many friends to inspect at most
	FriendFetchAttempts = 3, -- How many attempts when fetching friends list
	FriendFlaggingEnabled = true, -- Set to false to prevent friends' profiles from triggering Solo
	SoloStrikesThreshold = 2, -- number of server-side solo strikes required to mark/send to SoloExperience

	-- bksh protection configuration
	BKSH = {
		Enabled = true,
		DistanceThreshold = 4,
		BehindDotThreshold = 0.8,
		FacingDotThreshold = 0.8,
		ForwardPeakThreshold = 2.0,
		MinPeakInterval = 0.12,
		Window = 1.5,
		RequiredPeaks = 3, -- How many shots are required to take action
	},
}

local function dprint(...)
	if CONFIG.DebugPrints then
		print(...)
	end
end

local FUZZY_THRESHOLD = 0.30
local FUZZY_MAX_CHECKS = 1000

local FRIEND_PROFILE_CACHE_TTL = 300
local FRIEND_PROFILE_MAX_CONCURRENCY = 3

local profileCache = {}

-- build keywords / phrases
local bannedKeywords = {}
local bannedPhrases = {}
for _, entry in ipairs(FLAGGED_WORDS) do
	if type(entry) == "string" then
		if entry:find("%s") then
			table.insert(bannedPhrases, entry)
		else
			table.insert(bannedKeywords, entry)
		end
	end
end

-- normalization & leet helpers
local function basicNormalize(s)
	if not s then return "" end
	s = tostring(s):lower()
	s = s:gsub("[^%w%s]", "")
	s = s:gsub("(.)%1+", "%1")
	s = s:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
	return s
end

local function leetSubstitute(s)
	if not s then return "" end
	local map = {
		["4"] = "a", ["@"] = "a",
		["3"] = "e",
		["1"] = "i", ["!"] = "i",
		["0"] = "o",
		["5"] = "s", ["$"] = "s",
		["7"] = "t",
		["8"] = "b",
		["2"] = "z",
	}
	local out = {}
	for i = 1, #s do
		local c = s:sub(i,i)
		local r = map[c]
		if r then out[#out+1] = r else out[#out+1] = c end
	end
	return table.concat(out)
end

local function levenshtein(a, b)
	if a == b then return 0 end
	local la, lb = #a, #b
	if la == 0 then return lb end
	if lb == 0 then return la end

	local prev = {}
	for j = 0, lb do prev[j] = j end

	for i = 1, la do
		local cur = {}
		cur[0] = i
		local ai = a:sub(i,i)
		for j = 1, lb do
			local cost = (ai == b:sub(j,j)) and 0 or 1
			local deletion = prev[j] + 1
			local insertion = cur[j-1] + 1
			local substitution = prev[j-1] + cost
			local v = deletion
			if insertion < v then v = insertion end
			if substitution < v then v = substitution end
			cur[j] = v
		end
		prev = cur
	end
	return prev[lb]
end

local function fuzzyContains(text, pattern, thresholdFrac, maxChecks)
	if not text or not pattern then return false end
	pattern = tostring(pattern)
	local patLen = #pattern
	if patLen == 0 then return false end
	local maxDiff = math.max(1, math.floor(patLen * (thresholdFrac or FUZZY_THRESHOLD)))
	local minLen = math.max(1, patLen - maxDiff)
	local maxLen = patLen + maxDiff

	local tlen = #text
	if tlen < minLen then return false end

	local checks = 0
	for L = minLen, maxLen do
		for i = 1, (tlen - L + 1) do
			checks = checks + 1
			if checks > (maxChecks or FUZZY_MAX_CHECKS) then return false end
			local sub = text:sub(i, i + L - 1)
			local d = levenshtein(sub, pattern)
			if d <= maxDiff then
				return true
			end
		end
	end
	return false
end

local function isLeetMatch(haystack, needle)
	if not haystack or not needle then return false end
	local h = basicNormalize(haystack)
	h = leetSubstitute(h)
	local n = basicNormalize(needle)
	n = leetSubstitute(n)
	if n == "" then return false end
	if h:find(n, 1, true) then return true end
	return fuzzyContains(h, n, FUZZY_THRESHOLD, FUZZY_MAX_CHECKS)
end

-- count unique matches in text against banned lists
local function countFlaggedMatches(text)
	if not text or text == "" then return 0, {} end
	local matches = {}
	local hay = tostring(text)
	-- keywords
	for _, kw in ipairs(bannedKeywords) do
		if isLeetMatch(hay, kw) then
			matches[kw] = true
		end
	end
	-- phrases (compare normalized no-space)
	local hayNorm = basicNormalize(hay)
	hayNorm = leetSubstitute(hayNorm)
	local hayNoSpace = hayNorm:gsub("%s+", "")
	for _, ph in ipairs(bannedPhrases) do
		local p = basicNormalize(ph)
		p = leetSubstitute(p)
		local pNoSpace = p:gsub("%s+", "")
		if isLeetMatch(hayNoSpace, pNoSpace) then
			matches[ph] = true
		end
	end
	local out = {}
	local n = 0
	for k,v in pairs(matches) do
		n = n + 1
		out[#out+1] = k
	end
	return n, out
end

local function containsFlaggedWord(text)
	if not text or text == "" then return false end
	if countFlaggedMatches(text) > 0 then
		dprint("[NetNanny] Flagged content detected.")
		return true
	end
	return false
end

-- Teleport / helpers
local function sendToSoloServer(player)
	print("[NetNanny] Sending to SoloExperience: " .. player.Name)
	local okReserve, privateServerCode = pcall(function()
		return TeleportService:ReserveServer(PRIVATE_PLACE_ID)
	end)
	if okReserve and privateServerCode then
		local okTeleport, err = pcall(function()
			TeleportService:TeleportToPrivateServer(PRIVATE_PLACE_ID, privateServerCode, {player})
		end)
		if not okTeleport then
			warn("[NetNanny] Failed to teleport player " .. player.Name .. ": " .. tostring(err))
		end
	else
		warn("[NetNanny] Failed to reserve private server for player " .. player.Name)
	end
end

local function safeFollowRedirect(location)
	if not location then return nil end
	local lower = tostring(location):lower()
	if string.find(lower, "roblox.com", 1, true) then
		return nil
	end
	return location
end

local function tryDecodeJson(body, url)
	if not body or body == "" then return nil end
	local ok, data = pcall(function()
		return HttpService:JSONDecode(body)
	end)
	if ok and type(data) == "table" then
		return data
	else
		warn("[NetNanny][HTTP] JSON decode failed for " .. tostring(url) .. ": " .. tostring(data))
		return nil
	end
end

local function handleBan(player)
	if NetNanny.IsBanned(player.UserId) then
		local reason = NetNanny.GetBanReason(player.UserId)
		print("[NetNanny] Banned player kicked: " .. player.Name .. " Reason: " .. reason)
		player:Kick("[NetNanny] You are banned from this experience. Reason: " .. reason)
		return true
	end
	return false
end

-- existing fetchProfileJson
local function fetchProfileJson(userId)
	local base = "https://users.roproxy.com/v1/users/"
	local attempts = 0
	local maxAttempts = 5
	local data = nil

	while attempts < maxAttempts and not data do
		attempts += 1
		local url = base .. tostring(userId)
		dprint(string.format("[NetNanny][HTTP] Attempt %d/%d: %s", attempts, maxAttempts, url))

		local ok, resp = pcall(function()
			return HttpService:RequestAsync({
				Url = url,
				Method = "GET",
			})
		end)

		if not ok then
			warn("[NetNanny][HTTP] RequestAsync error for " .. url .. " : " .. tostring(resp))
		else
			dprint(string.format("[NetNanny][HTTP] %s => Status: %s  Success: %s", url, tostring(resp.StatusCode), tostring(resp.Success)))

			if resp.Success and resp.StatusCode == 200 and resp.Body and resp.Body ~= "" then
				data = tryDecodeJson(resp.Body, url)
				if data then return data end
			end

			if resp.StatusCode == 301 or resp.StatusCode == 302 or resp.StatusCode == 307 or resp.StatusCode == 308 then
				local location = resp.Headers and (resp.Headers.Location or resp.Headers.location)
				dprint("[NetNanny][HTTP] Redirect Location:", tostring(location))
				local safe = safeFollowRedirect(location)
				if safe then
					dprint("[NetNanny][HTTP] Following safe redirect to:", safe)
					local ok2, resp2 = pcall(function()
						return HttpService:RequestAsync({ Url = safe, Method = "GET" })
					end)
					if ok2 and resp2 and resp2.Success and resp2.StatusCode == 200 and resp2.Body and resp2.Body ~= "" then
						data = tryDecodeJson(resp2.Body, safe)
						if data then return data end
					else
						warn("[NetNanny][HTTP] Failed after redirect: " .. tostring(resp2))
					end
				else
					warn("[NetNanny][HTTP] Redirect unsafe or points to roblox.com; skipping follow.")
				end
			end

			local alt = base .. tostring(userId) .. "/profile"
			dprint("[NetNanny][HTTP] Trying alternate endpoint:", alt)
			local ok3, resp3 = pcall(function()
				return HttpService:RequestAsync({ Url = alt, Method = "GET" })
			end)
			if ok3 and resp3 and resp3.Success and resp3.StatusCode == 200 and resp3.Body and resp3.Body ~= "" then
				data = tryDecodeJson(resp3.Body, alt)
				if data then return data end
			else
				if not ok3 then
					warn("[NetNanny][HTTP] Alternate RequestAsync failed: " .. tostring(resp3))
				else
					dprint("[NetNanny][HTTP] Alternate endpoint status:", tostring(resp3 and resp3.StatusCode))
				end
			end
		end

		if not data and attempts < maxAttempts then
			task.wait(1)
		end
	end

	dprint("[NetNanny][HTTP] No usable profile JSON found for: " .. tostring(userId))
	return nil
end

-- fetch friends list
local function fetchFriendsList(userId)
	local ok, pages = pcall(function()
		return Players:GetFriendsAsync(userId)
	end)
	if not ok or not pages then
		dprint("[NetNanny] GetFriendsAsync failed for userId:", tostring(userId))
		return {}
	end

	local out = {}
	local seen = {}

	local function processPage(page)
		if type(page) ~= "table" then return end
		for _, entry in ipairs(page) do
			local id = entry.Id or entry.id or entry.UserId or entry.userId or entry.targetId or entry.TargetId
			if id then
				local num = tonumber(id)
				if num and not seen[num] then
					seen[num] = true
					table.insert(out, num)
				end
			end
		end
	end

	local success, page = pcall(function() return pages:GetCurrentPage() end)
	if success and page then
		processPage(page)
	end

	while true do
		local finished = false
		local statusOk, isFinished = pcall(function() return pages.IsFinished end)
		if statusOk and type(isFinished) == "boolean" then
			if isFinished then break end
		end

		local advOk, advErr = pcall(function()
			pages:AdvanceToNextPage()
		end)
		if not advOk then
			break
		end

		local gotOk, nextPage = pcall(function() return pages:GetCurrentPage() end)
		if not gotOk or not nextPage then break end
		processPage(nextPage)

		if #out >= (CONFIG and CONFIG.MaxFriendChecks and CONFIG.MaxFriendChecks * 2 or 1000) then
			break
		end
	end

	local maxToReturn = (CONFIG and CONFIG.MaxFriendChecks) or 100
	if #out > maxToReturn then
		local trimmed = {}
		for i = 1, maxToReturn do trimmed[i] = out[i] end
		out = trimmed
	end

	dprint("[NetNanny] fetchFriendsList found " .. tostring(#out) .. " friends for user " .. tostring(userId))
	return out
end

local function getCachedProfile(userId)
	local rec = profileCache[userId]
	if rec and (tick() - rec.ts) < FRIEND_PROFILE_CACHE_TTL then
		return rec.data
	end
	return nil
end

local function setCachedProfile(userId, data)
	profileCache[userId] = { data = data, ts = tick() }
end

-- server-side solo strike tracking
local soloStrikes = {} -- [userId] = count
local soloMatchedSources = {} -- [userId] = { ["sourceKey"]=true, ... }

local function addSoloMatchSource(userId, source)
	soloMatchedSources[userId] = soloMatchedSources[userId] or {}
	if soloMatchedSources[userId][source] then
		return false
	end
	soloMatchedSources[userId][source] = true
	return true
end

local function getSoloCount(userId)
	return soloStrikes[userId] or 0
end

local function addSoloStrike(userId, source, player)
	if not userId then return end
	if not addSoloMatchSource(userId, source) then
		return false
	end
	soloStrikes[userId] = (soloStrikes[userId] or 0) + 1
	local count = soloStrikes[userId]
	dprint(string.format("[NetNanny] Solo strike added for %s (source=%s) — now %d/%d", tostring(userId), tostring(source), count, CONFIG.SoloStrikesThreshold))
	if count >= (CONFIG.SoloStrikesThreshold or 2) then
		local ok, err = pcall(function()
			NetNanny.MarkSoloBatch({userId})
		end)
		if not ok then
			warn("[NetNanny] Failed to mark Solo for userId " .. tostring(userId) .. ": " .. tostring(err))
			return false
		end
		if player and player.Parent then
			sendToSoloServer(player)
		end
		return true
	end
	return false
end

-- badges
local function fetchUserBadges(userId)
	local url = "https://badges.roproxy.com/v1/users/" .. tostring(userId) .. "/badges?limit=100&sortOrder=Desc"
	local ok, resp = pcall(function()
		return HttpService:RequestAsync({Url = url, Method = "GET"})
	end)

	if not ok or not resp.Success or resp.StatusCode ~= 200 then
		dprint("[NetNanny] Failed to fetch badges for userId:", userId)
		return {}
	end

	local data = tryDecodeJson(resp.Body, url)
	if type(data) ~= "table" or type(data.data) ~= "table" then
		dprint("[NetNanny] JSON decode failed or missing 'data' table for userId:", userId)
		return {}
	end

	table.sort(data.data, function(a, b)
		return (b.created or 0) < (a.created or 0)
	end)

	local out = {}
	for _, badge in ipairs(data.data) do
		if badge.name then
			table.insert(out, tostring(badge.name))
		end
	end

	return out
end

local function inspectBadgesAndMaybeSolo(player)
	task.spawn(function()
		local badges = fetchUserBadges(player.UserId)
		if not badges or #badges == 0 then
			dprint("[NetNanny] No badges to inspect for " .. player.Name)
			return
		end

		dprint("[NetNanny] Inspecting " .. tostring(#badges) .. " badges for player: " .. player.Name)

		for _, badgeName in ipairs(badges) do
			local n, matched = countFlaggedMatches(badgeName)
			if n > 0 then
				for _, m in ipairs(matched) do
					local source = "badge:" .. tostring(m)
					local marked = addSoloStrike(player.UserId, source, player)
					dprint("[NetNanny] Flagged badge detected for player: " .. player.Name .. " -> " .. badgeName .. " (source="..source..")")
					if marked then
						print("[NetNanny] Player marked SOLO due to badges: " .. player.Name)
						return
					end
				end
				break
			end
		end

		dprint("[NetNanny] Finished inspecting badges for " .. player.Name)
	end)
end

-- groups
local function fetchGroups(userId)
	local ok, groups = pcall(function()
		return Players:GetUserGroupsAsync(userId)
	end)
	if not ok or type(groups) ~= "table" then
		dprint("[NetNanny] Failed to fetch groups for userId:", userId)
		return {}
	end

	local out = {}
	for _, g in ipairs(groups) do
		if g.Name then table.insert(out, tostring(g.Name)) end
	end
	return out
end

local function inspectGroupsAndMaybeSolo(player)
	task.spawn(function()
		local groups = fetchGroups(player.UserId)
		if not groups or #groups == 0 then
			dprint("[NetNanny] No groups to inspect for " .. player.Name)
			return
		end

		for _, groupName in ipairs(groups) do
			local n, matched = countFlaggedMatches(groupName)
			if n > 0 then
				for _, m in ipairs(matched) do
					local source = "group:" .. tostring(m)
					local marked = addSoloStrike(player.UserId, source, player)
					dprint("[NetNanny] Flagged group detected for player: " .. player.Name .. " -> " .. groupName .. " (source="..source..")")
					if marked then
						print("[NetNanny] Player marked SOLO due to group matches: " .. player.Name)
						return
					end
				end
				break
			end
		end
	end)
end

-- profile extraction
local function extractProfileFields(json)
	if not json or type(json) ~= "table" then
		return "", "", ""
	end

	local function getFirst(...)
		for i = 1, select("#", ...) do
			local key = select(i, ...)
			local v = json[key]
			if type(v) == "string" and v ~= "" then
				return v
			end
		end
		if type(json.data) == "table" then
			for i = 1, select("#", ...) do
				local key = select(i, ...)
				local v2 = json.data[key]
				if type(v2) == "string" and v2 ~= "" then
					return v2
				end
			end
		end
		return ""
	end

	local username = getFirst("username", "name", "user", "userName")
	local displayName = getFirst("displayName", "displayname", "display")
	local description = getFirst("description", "about", "bio", "status")

	dprint("[NetNanny] Profile fields for user:")
	dprint("  username: " .. tostring(username))
	dprint("  displayName: " .. tostring(displayName))
	dprint("  description: " .. tostring(description))

	return username, displayName, description
end

local function inspectProfileAndMaybeSolo(player)
	if NetNanny.IsSolo(player.UserId) then
		print("[NetNanny] Player already marked Solo: " .. player.Name)
		sendToSoloServer(player)
		return
	end

	local profileJson
	local okFetch, err = pcall(function()
		profileJson = fetchProfileJson(player.UserId)
	end)
	if not okFetch then
		warn("[NetNanny] Failed to fetch profile for " .. player.Name .. ": " .. tostring(err))
		return
	end
	if not profileJson then
		dprint("[NetNanny] No profile data available for " .. player.Name)
		return
	end

	local username, displayName, description = extractProfileFields(profileJson)
	local profileText = table.concat({username, displayName, description}, " ")

	local n, matched = countFlaggedMatches(profileText)
	if n > 0 then
		for _, m in ipairs(matched) do
			local source = "profile:" .. tostring(m)
			local marked = addSoloStrike(player.UserId, source, player)
			dprint("[NetNanny] Flagged keyword detected in profile for player: " .. player.Name .. " -> " .. tostring(m) .. " (source="..source..")")
			if marked then
				print("[NetNanny] Player marked SOLO due to profile matches: " .. player.Name)
				return
			end
		end
	end
end

-- friends inspection
local function inspectFriendsAndMaybeSolo(player)
	if CONFIG and CONFIG.FriendFlaggingEnabled == false then
		dprint("[NetNanny] Friend-based flagging disabled; skipping friend inspection for " .. player.Name)
		return
	end

	task.spawn(function()
		local friends = fetchFriendsList(player.UserId)
		if not friends or #friends == 0 then
			dprint("[NetNanny] No friends to inspect for " .. player.Name)
			return
		end

		local maxCheck = math.min(CONFIG.MaxFriendChecks or #friends, #friends)
		local active = 0
		local i = 1
		while i <= maxCheck do
			if active < FRIEND_PROFILE_MAX_CONCURRENCY then
				local friendId = friends[i]
				active = active + 1
				task.spawn(function()
					pcall(function()
						if type(friendId) ~= "number" or friendId == player.UserId then return end
						local prof = getCachedProfile(friendId)
						if not prof then
							local ok, fetched = pcall(function() return fetchProfileJson(friendId) end)
							if ok and fetched then
								prof = fetched
								setCachedProfile(friendId, prof)
							else
								return
							end
						end

						local uname, dname, desc = "", "", ""
						if type(prof) == "table" then
							local function getFirst(...)
								for k = 1, select("#", ...) do
									local key = select(k, ...)
									local v = prof[key]
									if type(v) == "string" and v ~= "" then return v end
								end
								if type(prof.data) == "table" then
									for k = 1, select("#", ...) do
										local key = select(k, ...)
										local v2 = prof.data[key]
										if type(v2) == "string" and v2 ~= "" then return v2 end
									end
								end
								return ""
							end
							uname = getFirst("username", "name", "user", "userName")
							dname = getFirst("displayName", "displayname", "display")
							desc  = getFirst("description", "about", "bio", "status")
						end

						local combined = table.concat({uname, dname, desc}, " ")
						local n, matched = countFlaggedMatches(combined)
						if n > 0 then
							for _, m in ipairs(matched) do
								local source = "friend:" .. tostring(friendId) .. ":" .. tostring(m)
								local marked = addSoloStrike(player.UserId, source, player)
								dprint("[NetNanny] Friend profile flagged (friendId=" .. tostring(friendId) .. ") — adding solo strike for player " .. player.Name .. " (match="..tostring(m)..")")
								if marked then
									print("[NetNanny] Player marked SOLO due to friends: " .. player.Name)
									active = active - 1
									return
								end
							end
						end
					end)
					active = active - 1
				end)
				i = i + 1
			else
				task.wait(0.1)
			end
		end

		while active > 0 do
			task.wait(0.1)
		end

		dprint("[NetNanny] Finished inspecting friends for " .. player.Name)
	end)
end

-- on chat
local function handleChatMessage(player, message)
	if containsFlaggedWord(message) then
		dprint("[NetNanny] Flagged word detected in chat for player: " .. player.Name)
		local reason = "Inappropriate chat detected"
		pcall(function() NetNanny.AddStrike(player.UserId, reason) end)

		if NetNanny.IsBanned(player.UserId) then
			local banReason = NetNanny.GetBanReason(player.UserId)
			print("[NetNanny] Player banned and kicked: " .. player.Name .. " Reason: " .. banReason)
			player:Kick("[NetNanny] You have been banned. Reason: " .. banReason)
			return
		end
	end
end

-- player join handler
local function onPlayerAdded(player)
	if handleBan(player) then return end

	if NetNanny.IsSolo(player.UserId) then
		print("[NetNanny] Player is marked for Solo experience: " .. player.Name)
		sendToSoloServer(player)
		return
	end

	local ok, err = pcall(function()
		inspectProfileAndMaybeSolo(player)
	end)
	if not ok then
		warn("[NetNanny] Profile inspection failed for " .. player.Name .. ": " .. tostring(err))
	end

	pcall(function()
		if CONFIG.FriendFlaggingEnabled ~= false then
			inspectFriendsAndMaybeSolo(player)
		else
			dprint("[NetNanny] Skipping friend inspection for " .. player.Name .. " because FriendFlaggingEnabled == false")
		end
		inspectBadgesAndMaybeSolo(player)
		inspectGroupsAndMaybeSolo(player)
	end)

	player.Chatted:Connect(function(message)
		pcall(function()
			handleChatMessage(player, message)
		end)
	end)
end

Players.PlayerAdded:Connect(onPlayerAdded)
for _, player in ipairs(Players:GetPlayers()) do
	onPlayerAdded(player)
end

-- cleanup when players leave (clear in-memory matches to avoid leak)
Players.PlayerRemoving:Connect(function(player)
	soloStrikes[player.UserId] = nil
	soloMatchedSources[player.UserId] = nil
	profileCache[player.UserId] = nil
end)

--------------------------------------------------------------------------------
-- bksh protection
--------------------------------------------------------------------------------

local pairTrackers = {}
local lastPositions = {}

local function getTracker(attackerId, targetId)
	pairTrackers[attackerId] = pairTrackers[attackerId] or {}
	local t = pairTrackers[attackerId][targetId]
	if not t then
		t = { peakCount = 0, windowTimer = 0, lastPeakTime = 0, lastForwardVel = -math.huge }
		pairTrackers[attackerId][targetId] = t
	end
	return t
end

local function resetTracker(attackerId, targetId)
	if pairTrackers[attackerId] and pairTrackers[attackerId][targetId] then
		local t = pairTrackers[attackerId][targetId]
		t.peakCount = 0
		t.windowTimer = 0
		t.lastPeakTime = 0
		t.lastForwardVel = -math.huge
	end
end

Players.PlayerRemoving:Connect(function(p)
	local pid = p.UserId
	pairTrackers[pid] = nil
	lastPositions[pid] = nil
	for attackerId, targets in pairs(pairTrackers) do
		targets[pid] = nil
	end
end)

RunService.Heartbeat:Connect(function(dt)
	if not (CONFIG and CONFIG.BKSH and CONFIG.BKSH.Enabled) then
		return
	end

	local players = Players:GetPlayers()
	local bk = CONFIG.BKSH
	local DISTANCE_THRESHOLD = bk.DistanceThreshold or 4
	local BEHIND_DOT_THRESHOLD = bk.BehindDotThreshold or 0.8
	local FACING_DOT_THRESHOLD = bk.FacingDotThreshold or 0.8
	local FORWARD_PEAK_THRESHOLD = bk.ForwardPeakThreshold or 2.0
	local MIN_PEAK_INTERVAL = bk.MinPeakInterval or 0.12
	local BKSH_WINDOW = bk.Window or 1.5
	local REQUIRED_PEAKS = bk.RequiredPeaks or 1

	for _, attacker in ipairs(players) do
		local charA = attacker.Character
		local hrpA = charA and charA:FindFirstChild("HumanoidRootPart")
		if hrpA then
			for _, target in ipairs(players) do
				if target ~= attacker then
					local charB = target.Character
					local hrpB = charB and charB:FindFirstChild("HumanoidRootPart")
					if hrpB then
						local offset = hrpA.Position - hrpB.Position
						local dist = offset.Magnitude

						if dist > 0 and dist <= DISTANCE_THRESHOLD then
							local dir = (hrpB.Position - hrpA.Position).Unit
							local behind = hrpB.CFrame.LookVector:Dot(dir) > BEHIND_DOT_THRESHOLD
							local facing = hrpA.CFrame.LookVector:Dot(dir) > FACING_DOT_THRESHOLD

							local assemblyVel = hrpA.AssemblyLinearVelocity
							local forwardVel = assemblyVel:Dot(-dir)
							if math.abs(forwardVel) < 0.01 then
								local prevPos = lastPositions[attacker.UserId] or hrpA.Position
								local estVelVec = (hrpA.Position - prevPos) / math.max(dt, 1e-6)
								forwardVel = estVelVec:Dot(-dir)
							end

							if behind and facing then
								local tracker = getTracker(attacker.UserId, target.UserId)
								if forwardVel > FORWARD_PEAK_THRESHOLD and tracker.lastForwardVel <= FORWARD_PEAK_THRESHOLD then
									local now = tick()
									if now - tracker.lastPeakTime >= MIN_PEAK_INTERVAL then
										tracker.peakCount = tracker.peakCount + 1
										tracker.lastPeakTime = now
									end
								end

								tracker.windowTimer = tracker.windowTimer + dt
								tracker.lastForwardVel = forwardVel

								if tracker.windowTimer >= BKSH_WINDOW then
									if tracker.peakCount >= REQUIRED_PEAKS then
										local hum = charA:FindFirstChildOfClass("Humanoid")
										if hum then
											hum.Health = 0
											dprint(string.format("[NetNanny][BKSH] Killed attacker %s for backshot on %s (peaks=%d)", attacker.Name, target.Name, tracker.peakCount))
										end
									end
									tracker.peakCount = 0
									tracker.windowTimer = 0
									tracker.lastPeakTime = 0
								end
							else
								resetTracker(attacker.UserId, target.UserId)
							end
						else
							resetTracker(attacker.UserId, target.UserId)
						end
					end
				end
			end
			lastPositions[attacker.UserId] = hrpA.Position
		else
			lastPositions[attacker.UserId] = nil
		end
	end
end)
