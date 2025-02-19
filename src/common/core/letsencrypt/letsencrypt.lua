local cjson = require "cjson"
local class = require "middleclass"
local plugin = require "bunkerweb.plugin"

local letsencrypt = class("letsencrypt", plugin)

function letsencrypt:initialize(ctx)
	-- Call parent initialize
	plugin.initialize(self, "letsencrypt", ctx)
end

function letsencrypt:access()
	if string.sub(self.ctx.bw.uri, 1, string.len("/.well-known/acme-challenge/")) == "/.well-known/acme-challenge/" then
		self.logger:log(ngx.NOTICE, "got a visit from Let's Encrypt, let's whitelist it")
		return self:ret(true, "visit from LE", ngx.OK)
	end
	return self:ret(true, "success")
end

-- luacheck: ignore 212
function letsencrypt:api(ctx)
	if
		not string.match(ctx.bw.uri, "^/lets%-encrypt/challenge$")
		or (ctx.bw.request_method ~= "POST" and ctx.bw.request_method ~= "DELETE")
	then
		return false, nil, nil
	end
	local acme_folder = "/var/tmp/bunkerweb/lets-encrypt/.well-known/acme-challenge/"
	ngx.req.read_body()
	local ret, data = pcall(cjson.decode, ngx.req.get_body_data())
	if not ret then
		return true, ngx.HTTP_BAD_REQUEST, { status = "error", msg = "json body decoding failed" }
	end
	os.execute("mkdir -p " .. acme_folder)
	if ctx.bw.request_method == "POST" then
		local file, err = io.open(acme_folder .. data.token, "w+")
		if not file then
			return true,
				ngx.HTTP_INTERNAL_SERVER_ERROR,
				{ status = "error", msg = "can't write validation token : " .. err }
		end
		file:write(data.validation)
		file:close()
		return true, ngx.HTTP_OK, { status = "success", msg = "validation token written" }
	elseif ctx.bw.request_method == "DELETE" then
		local ok, err = os.remove(acme_folder .. data.token)
		if not ok then
			return true,
				ngx.HTTP_INTERNAL_SERVER_ERROR,
				{ status = "error", msg = "can't remove validation token : " .. err }
		end
		return true, ngx.HTTP_OK, { status = "success", msg = "validation token removed" }
	end
	return true, ngx.HTTP_NOT_FOUND, { status = "error", msg = "unknown request" }
end

return letsencrypt
