
util.AddNetworkString("gConfigSend")
util.AddNetworkString("gConfigSendFullUpdate")
util.AddNetworkString("gConfigSendServerVariables")
util.AddNetworkString("gConfigSendValue")
util.AddNetworkString("gConfigRequestHistory")
util.AddNetworkString("gConfigRequestFullUpdate")
util.AddNetworkString("gConfigSendHistory")

function gConfig.sendValue(addon, item, value, author, ply)
	net.Start("gConfigSend")
		net.WriteString(addon)
		net.WriteString(item)
		net.WriteType(value)
		if IsValid(author) then
			net.WriteBool(true)
			net.WriteEntity(author)
		else
			net.WriteBool(false)
		end
	if ply then
		net.Send(ply)
	else
		net.Broadcast()
	end
end

local function writeFullUpdateConfig(name, config, sendShared, sendServer, ply)
	assert(not (sendServer and not ply), "ply must be specified if sendServer is true")

	net.WriteString(name)

	for id, item in pairs(config.items) do
		if item.realm == gConfig.Server then
			if not sendServer then continue end
			if not config:hasAccess(id, ply) then continue end -- Only send server variables to authorized players, could potentially be expensive af
		end
		if item.realm == gConfig.Shared and not sendShared then continue end
		if item.realm == gConfig.Client then continue end

		net.WriteBool(true) -- here comes item
		net.WriteString(id)
		net.WriteType(config.data[id])
	end
	net.WriteBool(false) -- no more items
end

function gConfig.sendFullUpdate(ply, sendShared, sendServer)
	net.Start("gConfigSendFullUpdate")
		for name, config in pairs(gConfig.getList()) do
			net.WriteBool(true) -- here comes config
			writeFullUpdateConfig(name, config, sendShared, sendServer, ply)
		end
		net.WriteBool(false) -- no more configs
	if ply then
		net.Send(ply)
	else
		net.Broadcast()
	end
end

function gConfig.sendFullUpdateConfig(ply, config, sendShared, sendServer)
	net.Start("gConfigSendFullUpdate")
		net.WriteBool(true) -- here comes config
		writeFullUpdateConfig(config.name, config, sendShared, sendServer, ply)

		net.WriteBool(false) -- no more configs
	if ply then
		net.Send(ply)
	else
		net.Broadcast()
	end
end

local function rateLimit(ply)
	if (ply.gConfigNextMessage or 0) > SysTime() then
		gConfig.msgPlayerWarning(ply, "Please wait before doing that again.")
		return true
	end
	ply.gConfigNextMessage = SysTime() + 2
	return false
end

net.Receive("gConfigSendValue", function(_, ply)
	if rateLimit(ply) then return end

	local addon = net.ReadString()
	local id = net.ReadString()
	local comment = net.ReadString()
	local newValue = net.ReadType()

	if not gConfig.exists(addon) then return end -- Invalid config

	local config = gConfig.get(addon)

	if not config.items[id] then return end -- Invalid item

	local success, errMsg = config:set(id, newValue, ply, comment)
	if not success then
		gConfig.msgPlayerWarning(ply, "Update failed with reason: %s", errMsg)
		return
	end
end)

net.Receive("gConfigRequestHistory", function(_, ply)
	if rateLimit(ply) then return end

	local addon = net.ReadString()
	local id = net.ReadString()

	if not gConfig.exists(addon) then return end -- Invalid config

	local config = gConfig.get(addon)

	if not config.items[id] then return end -- Invalid item

	if not config:hasAccess(id, ply) then return end

	gConfig.GetHistory(addon, id, function(historyTbl)
		if not IsValid(ply) then return end

		net.Start("gConfigSendHistory")
			net.WriteString(addon)
			net.WriteString(id)
			net.WriteUInt(#historyTbl, 8)
			for i = 1, #historyTbl do
				local row = historyTbl[i]

				net.WriteUInt(row.date, 32)
				net.WriteString(row.author)
				net.WriteString(row.authorsid)
				net.WriteString(row.comment)
				net.WriteType(row.value)
			end
		net.Send(ply)
	end)
end)

net.Receive("gConfigRequestFullUpdate", function(_, ply)
	if rateLimit(ply) then return end

	local addon = net.ReadString()

	if not gConfig.exists(addon) then return end -- Invalid config

	local config = gConfig.get(addon)

	gConfig.sendFullUpdateConfig(ply, config, false, true)
end)

hook.Add("PlayerInitialSpawn", "gConfigSendVariables", function(ply)
	gConfig.sendFullUpdate(ply, true, false)
end)

hook.Add("gConfigValuesLoaded", "gConfigSendVariables", function()
	gConfig.sendFullUpdate(nil, true, false)
end)
