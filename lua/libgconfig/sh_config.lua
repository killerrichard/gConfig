
--[[
Enums
]]
gConfig.Server = 0
gConfig.Shared = 1
gConfig.Client = 2

gConfig.User       = 0
gConfig.Admin      = 1
gConfig.SuperAdmin = 2
gConfig.None       = 3

--[[
Config Object
]]
local configs = {}

local configmeta = {}
configmeta.__index = configmeta

local requiredVars = {"id", "realm", "access", "name", "type"}
function configmeta:add(struct)
	if not self.registered then
		gConfig.msgError("[%s] Addon not registered yet (use gConfig.register)", self.name)
		return
	end

	-- Make sure all required variables exist
	for _, var in pairs(requiredVars) do
		if not struct[var] then gConfig.msgError("[%s] missing variable %q for item %q", self.name, var, struct.id or "?") return end
	end

	-- Test the variables
	local id = struct.id
	if self.items[id] then
		gConfig.msgError("[%s] Config item %q has already been added", self.name, id)
		return
	end

	if #id > 16 then
		gConfig.msgError("[%s] Config item %q's id can't be longer than 16 characters", self.name, id)
		return
	end

	if not gConfig.Types[struct.type] then
		gConfig.msgError("[%s] Invalid type %q for config item %q", self.name, struct.type, id)
		return
	end

	-- Finish
	struct.typeOptions = struct.typeOptions or {}
	struct.order = self.itemCount

	self.items[id] = struct

	self.itemCount = self.itemCount + 1
end

function configmeta:get(id, ...)
	local item = self.items[id]

	if not item then
		gConfig.msgError("[%s] Tried to get value of invalid item id %q", self.name, id)
		debug.Trace()
		return
	end

	local realm = item.realm
	if SERVER then
		if realm == gConfig.Client then
			gConfig.msgError("[%s] Tried to get client variable for %q on server", self.name, id)
			debug.Trace()
			return
		end
	else
		if realm == gConfig.Server then
			gConfig.msgError("[%s] Tried to get server variable for %q on client", self.name, id)
			debug.Trace()
			return
		end
	end

	local value
	if self.data[id] != nil then
		-- Use user set value
		value = self.data[id]
	else
		-- Use default
		value = item.default
	end

	-- If it's a function, call it and use its return value
	if isfunction(value) then
		value = value(...)
	end

	return value
end

function configmeta:getPreview(id)
	local item = self.items[id]
	assert(item != nil)

	local value, isdefault
	if self.data[id] != nil then
		value = self.data[id]
		isdefault = false
	else
		value = item.default
		isdefault = true
	end

	if value == nil then
		return "*no value*", isdefault
	end

	local itemType = gConfig.Types[item.type]

	local previewValue = itemType.preview(value, item.typeOptions)

	return previewValue, isdefault
end

function configmeta:monitor(id, onChange)
	self.monitors[id] = self.monitors[id] or {}
	table.insert(self.monitors[id], onChange)
end

function configmeta:hasAccess(id, ply)
	local item = self.items[id]

	if CLIENT and item.realm == gConfig.Client then return true end

	local accessLevel = item.access

	local defaultAccess = false
	if accessLevel == gConfig.User then
		defaultAccess = true
	elseif accessLevel == gConfig.Admin then
		defaultAccess = ply:IsAdmin()
	elseif accessLevel == gConfig.SuperAdmin then
		defaultAccess = ply:IsSuperAdmin()
	elseif accessLevel == gConfig.None then
		defaultAccess = false
	end

	-- TODO: add check for per-ply/per-group access

	return defaultAccess
end

function configmeta:set(id, value, ply, comment)
	local item = self.items[id]
	assert(item, "id not valid")

	local realm = item.realm
	if SERVER then
		if realm == gConfig.Client then error("Client variables can't be set on server") end
	else
		if realm != gConfig.Client then error("Server/shared variables can't be set on client") end
	end

	-- Test access
	if IsValid(ply) and not self:hasAccess(id, ply) then
		return false, "no access"
	end

	-- Test match
	local itemType = gConfig.Types[item.type]

	local isValid, newVal = itemType.match(value, item.typeOptions)

	if not isValid then
		return false, "invalid value"
	end

	if newVal then value = newVal end

	-- Check for change
	local old = self.data[id]
	if gConfig.equals(old, value) then
		return false, "no change"
	end

	-- Finish
	if realm == gConfig.Client then
		gConfig.SaveValue(self.name, id, value, comment)
	else
		gConfig.SaveValue(self.name, id, value, ply, comment)
	end

	self.data[id] = value

	-- Send to clients
	if SERVER then
		if realm == gConfig.Shared then
			gConfig.sendValue(self.name, id, value, ply)
		elseif realm == gConfig.Server then
			-- If it's a server variable, send an update to the author
			-- so his menu is updated directly
			gConfig.sendValue(self.name, id, value, ply, ply)
		end
	end

	self:runMonitors(id, old, value)

	if SERVER and IsValid(ply) then
		gConfig.msgInfo("[%s] %s has set %q to %q", self.name, ply:Nick(), item.name, gConfig.ellipsis(value, 100))
	else
		gConfig.msgInfo("[%s] %q has been set to %q", self.name, item.name, gConfig.ellipsis(value, 100))
	end

	return true
end

function configmeta:runMonitors(id, old, value)
	if not self.monitors[id] then return end

	for _, f in pairs(self.monitors[id]) do
		f(id, old, value)
	end
end

local function createConfigObject(addonName)
	if #addonName > 32 then
		gConfig.msgError("Addon name %q can't be longer than 32 characters", addonName)
		return
	end

	local t = setmetatable({}, configmeta)
	t.name = addonName
	t.items = {}
	t.itemCount = 0
	t.monitors = {}
	t.data = {}

	return t
end

--[[
gConfig namespace
]]
function gConfig.register(addonName)
	-- Get the file path of the addon
	local t = debug.getinfo(2)
	local addonPath = t.source or "unknown"

	local config
	if configs[addonName] then
		config = configs[addonName]

		if config.registered then
			-- If this addon was re-registered somewhere else than the original file, it's probably a collision happening
			if config.path == addonPath then
				gConfig.msgInfo("Reloading config %q", addonName)

				config.items = {}
				config.itemCount = 0
			else
				gConfig.msgError("Config %q has already been registered", addonName)
				return
			end
		end
	else
		config = createConfigObject(addonName)
		configs[addonName] = config
	end

	config.registered = true
	config.path = addonPath
	return config
end

function gConfig.get(addonName)
	if configs[addonName] then
		return configs[addonName]
	else
		local config = createConfigObject(addonName)
		configs[addonName] = config
		return config
	end
end

function gConfig.exists(addonName)
	if configs[addonName] then
		return true
	else
		return false
	end
end

function gConfig.getList()
	return configs
end
