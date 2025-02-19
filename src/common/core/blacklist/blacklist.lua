local class = require "middleclass"
local ipmatcher = require "resty.ipmatcher"
local plugin = require "bunkerweb.plugin"
local utils = require "bunkerweb.utils"

local blacklist = class("blacklist", plugin)

function blacklist:initialize(ctx)
	-- Call parent initialize
	plugin.initialize(self, "blacklist", ctx)
	-- Decode lists
	if ngx.get_phase() ~= "init" and self:is_needed() then
		local lists, err = self.datastore:get("plugin_blacklist_lists", true)
		if not lists then
			self.logger:log(ngx.ERR, err)
			self.lists = {}
		else
			self.lists = lists
		end
		local kinds = {
			["IP"] = {},
			["RDNS"] = {},
			["ASN"] = {},
			["USER_AGENT"] = {},
			["URI"] = {},
			["IGNORE_IP"] = {},
			["IGNORE_RDNS"] = {},
			["IGNORE_ASN"] = {},
			["IGNORE_USER_AGENT"] = {},
			["IGNORE_URI"] = {},
		}
		for kind, _ in pairs(kinds) do
			for data in self.variables["BLACKLIST_" .. kind]:gmatch("%S+") do
				if not self.lists[kind] then
					self.lists[kind] = {}
				end
				table.insert(self.lists[kind], data)
			end
		end
	end
end

function blacklist:is_needed()
	-- Loading case
	if self.is_loading then
		return false
	end
	-- Request phases (no default)
	if self.is_request and (self.ctx.bw.server_name ~= "_") then
		return self.variables["USE_BLACKLIST"] == "yes"
	end
	-- Other cases : at least one service uses it
	local is_needed, err = utils.has_variable("USE_BLACKLIST", "yes")
	if is_needed == nil then
		self.logger:log(ngx.ERR, "can't check USE_BLACKLIST variable : " .. err)
	end
	return is_needed
end

function blacklist:init()
	-- Check if init needed
	if not self:is_needed() then
		return self:ret(true, "init not needed")
	end

	-- Read blacklists
	local blacklists = {
		["IP"] = {},
		["RDNS"] = {},
		["ASN"] = {},
		["USER_AGENT"] = {},
		["URI"] = {},
		["IGNORE_IP"] = {},
		["IGNORE_RDNS"] = {},
		["IGNORE_ASN"] = {},
		["IGNORE_USER_AGENT"] = {},
		["IGNORE_URI"] = {},
	}
	local i = 0
	for kind, _ in pairs(blacklists) do
		local f, _ = io.open("/var/cache/bunkerweb/blacklist/" .. kind .. ".list", "r")
		if f then
			for line in f:lines() do
				table.insert(blacklists[kind], line)
				i = i + 1
			end
			f:close()
		end
	end
	-- Load them into datastore
	local ok, err = self.datastore:set("plugin_blacklist_lists", blacklists, nil, true)
	if not ok then
		return self:ret(false, "can't store blacklist list into datastore : " .. err)
	end
	return self:ret(true, "successfully loaded " .. tostring(i) .. " IP/network/rDNS/ASN/User-Agent/URI")
end

function blacklist:access()
	-- Check if access is needed
	if not self:is_needed() then
		return self:ret(true, "access not needed")
	end
	-- Check the caches
	local checks = {
		["IP"] = "ip" .. self.ctx.bw.remote_addr,
	}
	if self.ctx.bw.http_user_agent then
		checks["UA"] = "ua" .. self.ctx.bw.http_user_agent
	end
	if self.ctx.bw.uri then
		checks["URI"] = "uri" .. self.ctx.bw.uri
	end
	local already_cached = {
		["IP"] = false,
		["URI"] = false,
		["UA"] = false,
	}
	for k, v in pairs(checks) do
		local ok, cached = self:is_in_cache(v)
		if not ok then
			self.logger:log(ngx.ERR, "error while checking cache : " .. cached)
		elseif cached and cached ~= "ok" then
			return self:ret(
				true,
				k .. " is in cached blacklist (info : " .. cached .. ")",
				utils.get_deny_status(self.ctx)
			)
		end
		if ok and cached then
			already_cached[k] = true
		end
	end
	-- Check lists
	if not self.lists then
		return self:ret(false, "lists is nil")
	end
	-- Perform checks
	for k, _ in pairs(checks) do
		if not already_cached[k] then
			local ok, blacklisted = self:is_blacklisted(k)
			if ok == nil then
				self.logger:log(ngx.ERR, "error while checking if " .. k .. " is blacklisted : " .. blacklisted)
			else
				-- luacheck: ignore 421
				local ok, err = self:add_to_cache(self:kind_to_ele(k), blacklisted)
				if not ok then
					self.logger:log(ngx.ERR, "error while adding element to cache : " .. err)
				end
				if blacklisted ~= "ok" then
					return self:ret(
						true,
						k .. " is blacklisted (info : " .. blacklisted .. ")",
						utils.get_deny_status(self.ctx)
					)
				end
			end
		end
	end

	-- Return
	return self:ret(true, "not blacklisted")
end

function blacklist:preread()
	return self:access()
end

function blacklist:kind_to_ele(kind)
	if kind == "IP" then
		return "ip" .. self.ctx.bw.remote_addr
	elseif kind == "UA" then
		return "ua" .. self.ctx.bw.http_user_agent
	elseif kind == "URI" then
		return "uri" .. self.ctx.bw.uri
	end
end

function blacklist:is_in_cache(ele)
	local ok, data = self.cachestore:get("plugin_blacklist_" .. self.ctx.bw.server_name .. ele)
	if not ok then
		return false, data
	end
	return true, data
end

function blacklist:add_to_cache(ele, value)
	local ok, err = self.cachestore:set("plugin_blacklist_" .. self.ctx.bw.server_name .. ele, value, 86400)
	if not ok then
		return false, err
	end
	return true
end

function blacklist:is_blacklisted(kind)
	if kind == "IP" then
		return self:is_blacklisted_ip()
	elseif kind == "URI" then
		return self:is_blacklisted_uri()
	elseif kind == "UA" then
		return self:is_blacklisted_ua()
	end
	return false, "unknown kind " .. kind
end

function blacklist:is_blacklisted_ip()
	-- Check if IP is in ignore list
	local ipm, err = ipmatcher.new(self.lists["IGNORE_IP"])
	if not ipm then
		return nil, err
	end
	local match, err = ipm:match(self.ctx.bw.remote_addr)
	if err then
		return nil, err
	end
	if not match then
		-- Check if IP is in blacklist
		ipm, err = ipmatcher.new(self.lists["IP"])
		if not ipm then
			return nil, err
		end
		match, err = ipm:match(self.ctx.bw.remote_addr)
		if err then
			return nil, err
		end
		if match then
			return true, "ip"
		end
	end

	-- Check if rDNS is needed
	local check_rdns = true
	if self.variables["BLACKLIST_RDNS_GLOBAL"] == "yes" and not self.ctx.bw.ip_is_global then
		check_rdns = false
	end
	if check_rdns then
		-- Get rDNS
		-- luacheck: ignore 421
		local rdns_list, err = utils.get_rdns(self.ctx.bw.remote_addr)
		if rdns_list then
			-- Check if rDNS is in ignore list
			local ignore = false
			for _, rdns in ipairs(rdns_list) do
				for _, suffix in ipairs(self.lists["IGNORE_RDNS"]) do
					if rdns:sub(-#suffix) == suffix then
						ignore = true
						break
					end
				end
			end
			-- Check if rDNS is in blacklist
			if not ignore then
				for _, rdns in ipairs(rdns_list) do
					for _, suffix in ipairs(self.lists["RDNS"]) do
						if rdns:sub(-#suffix) == suffix then
							return true, "rDNS " .. suffix
						end
					end
				end
			end
		else
			self.logger:log(ngx.ERR, "error while getting rdns : " .. err)
		end
	end

	-- Check if ASN is in ignore list
	if self.ctx.bw.ip_is_global then
		local asn, err = utils.get_asn(self.ctx.bw.remote_addr)
		if not asn then
			self.logger:log(ngx.ERR, "can't get ASN of IP " .. self.ctx.bw.remote_addr .. " : " .. err)
		else
			local ignore = false
			for _, ignore_asn in ipairs(self.lists["IGNORE_ASN"]) do
				if ignore_asn == tostring(asn) then
					ignore = true
					break
				end
			end
			-- Check if ASN is in blacklist
			if not ignore then
				for _, bl_asn in ipairs(self.lists["ASN"]) do
					if bl_asn == tostring(asn) then
						return true, "ASN " .. bl_asn
					end
				end
			end
		end
	end

	-- Not blacklisted
	return false, "ok"
end

function blacklist:is_blacklisted_uri()
	-- Check if URI is in ignore list
	local ignore = false
	for _, ignore_uri in ipairs(self.lists["IGNORE_URI"]) do
		if utils.regex_match(self.ctx.bw.uri, ignore_uri) then
			ignore = true
			break
		end
	end
	-- Check if URI is in blacklist
	if not ignore then
		for _, uri in ipairs(self.lists["URI"]) do
			if utils.regex_match(self.ctx.bw.uri, uri) then
				return true, "URI " .. uri
			end
		end
	end
	-- URI is not blacklisted
	return false, "ok"
end

function blacklist:is_blacklisted_ua()
	-- Check if UA is in ignore list
	local ignore = false
	for _, ignore_ua in ipairs(self.lists["IGNORE_USER_AGENT"]) do
		if utils.regex_match(self.ctx.bw.http_user_agent, ignore_ua) then
			ignore = true
			break
		end
	end
	-- Check if UA is in blacklist
	if not ignore then
		for _, ua in ipairs(self.lists["USER_AGENT"]) do
			if utils.regex_match(self.ctx.bw.http_user_agent, ua) then
				return true, "UA " .. ua
			end
		end
	end
	-- UA is not blacklisted
	return false, "ok"
end

return blacklist
