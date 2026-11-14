-- slsachievements: manage the "achievements for added games" plugin.
--
-- Background: SLSsteam only spoofs achievements for apps it sees as unowned.
-- Its ownership spoof makes CUser::isSubscribed() report true for apps added
-- through AdditionalApps, so the "is this a legit app?" guard skips them and
-- Steam answers "CAPIJobRequestUserStats - received error 'Failure' (2)"; the
-- client then shows no achievement list for those games.
--
-- The plugin embedded below rewrites the three achievement-guard call sites at
-- runtime. It is scoped to exactly those instructions (owned games keep their
-- normal cloud/ticket/DLC/achievement behaviour) and forwards every app it was
-- not configured to spoof to the original CUser::isSubscribed.
--
-- Lumen runs in its own process and cannot patch Steam's memory (Yama ptrace
-- scope), so this module only manages the plugin file in the ACTIVE profile.
-- SLSsteam hot-reloads its plugins directory: writing the file applies the
-- patch within a second, and deleting it makes SLSsteam fire luaReload, which
-- runs the plugin's restore callback and puts the original instructions back.
--
-- The plugin text is embedded so a Lumen update ships a matching copy; there
-- is no second file to fall out of sync.
local lfs = require("lfs")
local slsprofile = require("slsprofile")

local M = {}

M.PLUGIN_FILE = "zz-luatools-achievements.lua"
M.STATUS_FILE = "achievements-fix.status"
M.VERSION = 2

M.SOURCE = [===[
-- luatools: Steam achievements/stats for added (unowned) apps.
--
-- SLSsteam spoofs achievements only for apps it considers unowned:
--
--   if (g_pSteamEngine->getUser(0)->isSubscribed(appId)) return; // "legit"
--
-- and the ownership spoof makes CUser::isSubscribed() return true for added
-- apps too, so SLSsteam skips them and Valve answers
-- "CAPIJobRequestUserStats - received error 'Failure' (2)".
--
-- The guard appears exactly three times inside Achievements:
--   sendAndRecvGetPlayerStats, sendAndRecvGetUserStats, sendMsg
-- Each is `call CSteamEngine::getUser; ...; call CUser::isSubscribed`.
-- This plugin rewrites only those three `call` instructions into a callback
-- that answers "not subscribed" for apps in CConfig::isAddedAppId and forwards
-- every other app to the real CUser::isSubscribed. Owned games therefore keep
-- their normal behaviour (cloud, tickets, DLC, real achievement sync) and no
-- other SLSsteam code path is affected.
--
-- The rewrite is undone on SLSsteam::luaReload, before the plugin runs again.
-- A status file next to config.yaml reports what happened.

local ffi = require("ffi")

ffi.cdef[[
	int mprotect(void* addr, size_t len, int prot);

	bool _ZN5CUser12isSubscribedEj(void*, unsigned int);
	bool _ZN7CConfig12isAddedAppIdEj(void*, unsigned int);
	void* unpack_user_data(const void*);

	unsigned int _ZN12CSteamEngine7getUserEj();

	void _ZN12Achievements25sendAndRecvGetPlayerStatsEP30CClientUnifiedServiceTransportPKcP28CPlayer_GetUserStats_RequestP29CPlayer_GetUserStats_Response();
	void _ZN12Achievements23sendAndRecvGetUserStatsEP7CAPIJobP16CProtoBufMsgBasejS3_4EMsg();
	void _ZN12Achievements7sendMsgEP10CNetPacket();
]]

local State = SLS_AchievementsFix or {
	installed = false,
	sites = {},
	reason = "not run",
}

SLS_AchievementsFix = State

local VERSION = 2
local SCAN_LIMIT = 0x600

local function statusPath()
	local base = os.getenv("XDG_CONFIG_HOME")
	if not base or base == "" then
		local home = os.getenv("HOME")
		if not home then
			return nil
		end
		base = home .. "/.config"
	end
	return base .. "/SLSsteam/achievements-fix.status"
end

local function writeStatus(state)
	local path = statusPath()
	if not path then
		return
	end
	local file = io.open(path, "w")
	if not file then
		return
	end
	file:write("version=", tostring(VERSION), "\n")
	file:write("state=", tostring(state), "\n")
	file:write("reason=", tostring(State.reason or ""), "\n")
	file:write("sites=", tostring(#State.sites), "\n")
	file:write("module=", tostring(State.moduleBase or ""), "\n")
	for i, site in ipairs(State.sites) do
		file:write(string.format("site%d=%#x\n", i, site.addr))
	end
	file:close()
end

if State.installed then
	-- Release builds keep the Lua state across a hot reload; the luaReload
	-- callback has already restored the original call instructions.
	writeStatus("reloaded")
	return
end

-- Read the module's own mapping from /proc/self/maps once. Every byte we read
-- or write is bounds-checked against it, because the scanner decodes raw bytes
-- and a false positive (an 0xE8 byte inside another instruction) can produce an
-- arbitrary "target" address.
local function moduleRange()
	local file = io.open("/proc/self/maps", "r")
	if not file then
		return nil
	end
	local start, stop
	for line in file:lines() do
		if line:find("SLSsteam%.so", 1, false) then
			local lo, hi = line:match("^(%x+)%-(%x+)")
			if lo and hi then
				lo, hi = tonumber(lo, 16), tonumber(hi, 16)
				if not start or lo < start then start = lo end
				if not stop or hi > stop then stop = hi end
			end
		end
	end
	file:close()
	if not start or not stop then
		return nil
	end
	return start, stop
end

local moduleStart, moduleStop = moduleRange()
if not moduleStart then
	State.reason = "SLSsteam.so not found in /proc/self/maps"
	writeStatus("failed")
	return
end

State.moduleBase = string.format("%#x-%#x", moduleStart, moduleStop)

local function readable(addr, len)
	return addr >= moduleStart and addr + len <= moduleStop
end

local function byteAt(addr, off)
	addr = addr + off
	if not readable(addr, 1) then
		return nil
	end
	return ffi.cast("const uint8_t*", addr)[0]
end

local function int32At(addr, off)
	addr = addr + off
	if not readable(addr, 4) then
		return nil
	end
	return ffi.cast("const int32_t*", addr)[0]
end

-- A `call` to an import goes through a `FF 25 rel32` stub in .plt/.plt.got and
-- the stub reads the real address from the GOT. Return that value, or nil for
-- anything else and for slots the dynamic linker has not filled in yet.
local function gotValue(stub)
	if byteAt(stub, 0) ~= 0xFF or byteAt(stub, 1) ~= 0x25 then
		return nil
	end
	local disp = int32At(stub, 2)
	if not disp then
		return nil
	end
	local slot = stub + 6 + disp
	if not readable(slot, 8) then
		return nil
	end
	local value = ffi.cast("const uintptr_t*", slot)[0]
	if value == stub + 6 then
		return nil
	end
	return tonumber(value)
end

local function isStub(addr)
	return byteAt(addr, 0) == 0xFF and byteAt(addr, 1) == 0x25
end

local function callTarget(site, disp)
	if not disp then
		return nil
	end
	local target = site + 5 + disp
	return tonumber(target)
end

-- Every `call x` immediately followed (within 20 bytes) by another `call y`.
-- Instruction-unaligned 0xE8 bytes are filtered out by requiring both targets
-- to be import stubs inside the module.
local function callPairs(fn)
	local base = tonumber(ffi.cast("uintptr_t", fn))
	local pairs = {}
	if not readable(base, SCAN_LIMIT) then
		return pairs
	end
	for i = 0, SCAN_LIMIT do
		if byteAt(base, i) == 0xE8 then
			local first = callTarget(base + i, int32At(base, i + 1))
			if first and isStub(first) then
				for j = i + 5, i + 20 do
					if byteAt(base, j) == 0xE8 then
						local second = callTarget(base + j, int32At(base, j + 1))
						if second and isStub(second) then
							pairs[#pairs + 1] = {
								site = base + j,
								first = first,
								second = second,
								v1 = gotValue(first),
								v2 = gotValue(second),
							}
						end
						break
					end
				end
			end
		end
	end
	return pairs
end

local functions = {
	ffi.C._ZN12Achievements25sendAndRecvGetPlayerStatsEP30CClientUnifiedServiceTransportPKcP28CPlayer_GetUserStats_RequestP29CPlayer_GetUserStats_Response,
	ffi.C._ZN12Achievements23sendAndRecvGetUserStatsEP7CAPIJobP16CProtoBufMsgBasejS3_4EMsg,
	ffi.C._ZN12Achievements7sendMsgEP10CNetPacket,
}

local function unprotect(addr)
	local page = addr - (addr % 4096)
	if not readable(page, 1) then
		return false
	end
	return ffi.C.mprotect(ffi.cast("void*", page), 8192, 7) == 0
end

local function writeCall(site, target)
	local rel = target - (site + 5)
	if rel < -2147483648 or rel > 2147483647 then
		return false, "rel32 out of range"
	end
	if not unprotect(site) then
		return false, "mprotect failed"
	end
	ffi.cast("uint8_t*", site)[0] = 0xE8
	ffi.cast("int32_t*", site + 1)[0] = rel
	return true
end

local function restore()
	for _, site in ipairs(State.sites) do
		if unprotect(site.addr) then
			for i = 0, 4 do
				ffi.cast("uint8_t*", site.addr + i)[0] = site.bytes[i]
			end
		end
	end
	State.sites = {}
	State.installed = false
end

local isSubAddr = tonumber(ffi.cast("uintptr_t", ffi.C._ZN5CUser12isSubscribedEj))
local getUserAddr = tonumber(ffi.cast("uintptr_t", ffi.C._ZN12CSteamEngine7getUserEj))
local isAdded = ffi.C._ZN7CConfig12isAddedAppIdEj
local configPtr = ffi.C.unpack_user_data(SLS.config)
local origIsSubscribed = ffi.cast("bool (*)(void*, unsigned int)", isSubAddr)

local hook = ffi.cast("bool (*)(void*, unsigned int)", function(self, appid)
	local mutex = LuaMutex()
	local ok, result = pcall(function()
		if isAdded(configPtr, appid) then
			return false
		end
		return origIsSubscribed(self, appid)
	end)
	mutex:unlock()

	if not ok then
		log.error("achievements-fix: " .. tostring(result))
		return origIsSubscribed(self, appid)
	end
	return result
end)

local function apply()
	if State.installed then
		return true
	end

	-- The ownership guard is the one call pair that occurs once in all three
	-- functions and resolves to (CSteamEngine::getUser, CUser::isSubscribed).
	local groups = {}
	for _, fn in ipairs(functions) do
		for _, pair in ipairs(callPairs(fn)) do
			local key = pair.first .. ":" .. pair.second
			local group = groups[key]
			if not group then
				group = { pairs = {}, seen = {}, count = 0, resolved = false }
				groups[key] = group
			end
			-- The scan window of one function can reach into the next one, so
			-- count every guard site once, not every time it is seen.
			if not group.seen[pair.site] then
				group.seen[pair.site] = true
				group.count = group.count + 1
				group.pairs[#group.pairs + 1] = pair
			end
			if pair.v1 == getUserAddr and pair.v2 == isSubAddr then
				group.resolved = true
			end
		end
	end

	local chosen
	for _, group in pairs(groups) do
		if group.count == #functions and group.resolved then
			chosen = group
			break
		end
	end

	if not chosen then
		local groups_seen = 0
		for _ in pairs(groups) do
			groups_seen = groups_seen + 1
		end
		State.reason = "guard not found (" .. groups_seen .. " call groups)"
		return false
	end

	local hookAddr = tonumber(ffi.cast("uintptr_t", hook))
	for _, pair in ipairs(chosen.pairs) do
		local saved = {}
		for i = 0, 4 do
			saved[i] = byteAt(pair.site, i)
		end
		local ok, why = writeCall(pair.site, hookAddr)
		if not ok then
			State.reason = string.format("patch %#x: %s", pair.site, why)
			restore()
			return false
		end
		State.sites[#State.sites + 1] = { addr = pair.site, bytes = saved }
	end

	if #State.sites ~= #functions then
		State.reason = "patched " .. #State.sites .. "/" .. #functions .. ", reverted"
		restore()
		return false
	end

	State.installed = true
	State.reason = "patched"
	SLS.registerCallback("SLSsteam::luaReload", restore)
	log.info("achievements-fix: patched 3 achievement guard call(s)")
	return true
end

if apply() then
	writeStatus("active")
else
	-- GOT slots may still be unfilled at plugin load; retry once the client is
	-- fully initialized, which happens before any achievement request arrives.
	writeStatus("pending")
	SLS.registerCallback("SLSsteam::initialized", function()
		if apply() then
			writeStatus("active")
		else
			writeStatus("failed")
			log.warn("achievements-fix: " .. tostring(State.reason) ..
				"; leaving SLSsteam unchanged")
		end
	end)
end
]===]

-- paths(root) -> {root=, plugins_dir=, plugin=, status=} | nil
function M.paths(root)
  if type(root) ~= "string" or root == "" then return nil end
  return {
    root = root,
    plugins_dir = root .. "/plugins",
    plugin = root .. "/plugins/" .. M.PLUGIN_FILE,
    status = root .. "/" .. M.STATUS_FILE,
  }
end

local function read_file(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local data = f:read("*a")
  f:close()
  return data
end

local function is_dir(path)
  local attr = lfs.attributes(path)
  return attr ~= nil and attr.mode == "directory"
end

local function is_file(path)
  local attr = lfs.attributes(path)
  return attr ~= nil and attr.mode == "file"
end

-- SLSsteam's fixPerms() strips group/other bits from plugin files. Set the
-- owner-only mode up front so it has nothing to fix on every reload.
local function default_chmod(path)
  os.execute(string.format("chmod 700 %q 2>/dev/null", path))
  return true
end

-- read_status(root) -> table|nil. Key=value lines written by the plugin itself.
function M.read_status(root)
  local p = M.paths(root)
  if not p then return nil end
  local raw = read_file(p.status)
  if not raw then return nil end
  local out = {}
  for line in raw:gmatch("[^\r\n]+") do
    local key, value = line:match("^([%w_]+)=(.*)$")
    if key then out[key] = value end
  end
  if out.sites then out.sites = tonumber(out.sites) end
  if out.version then out.version = tonumber(out.version) end
  return out
end

-- status([root[, opts]]) -> report table (never nil).
-- installed: the plugin file exists; state: off|pending|active|reloaded|failed.
function M.status(root, opts)
  opts = opts or {}
  root = root or opts.root or slsprofile.root()
  local report = { ok = true, installed = false, state = "off" }
  if not root then
    report.ok = false
    report.error = "SLSsteam profile not found"
    return report
  end
  report.profile = root
  if not is_dir(root) then
    report.ok = false
    report.error = "SLSsteam profile not found"
    return report
  end
  local p = M.paths(root)
  report.installed = is_file(p.plugin)
  if not report.installed then return report end
  local st = M.read_status(root)
  report.state = (st and st.state) or "pending"
  report.reason = st and st.reason or nil
  report.sites = st and st.sites or nil
  report.version = st and st.version or nil
  return report
end

-- install([root[, opts]]) -> ok, err. Atomic replace: SLSsteam's watcher sees a
-- single complete file and reloads its plugins once.
function M.install(root, opts)
  opts = opts or {}
  root = root or opts.root or slsprofile.root()
  if not root then return false, "SLSsteam profile not found" end
  if not is_dir(root) then
    return false, "SLSsteam profile not found: " .. root
  end
  local p = M.paths(root)
  if not is_dir(p.plugins_dir) then
    local ok = lfs.mkdir(p.plugins_dir)
    if not ok and not is_dir(p.plugins_dir) then
      return false, "cannot create " .. p.plugins_dir
    end
  end
  -- Drop the stale status first: it describes the previous session's patch. A
  -- fresh one appears as soon as SLSsteam runs the plugin.
  os.remove(p.status)
  local tmp = p.plugins_dir .. "/.lumen-achievements.tmp"
  local f, err = io.open(tmp, "wb")
  if not f then return false, "cannot write " .. tmp .. ": " .. tostring(err) end
  local written = f:write(M.SOURCE)
  f:close()
  if not written then
    os.remove(tmp)
    return false, "cannot write " .. tmp
  end
  ;(opts.chmod or default_chmod)(tmp)
  local ok, rerr = os.rename(tmp, p.plugin)
  if not ok then
    os.remove(tmp)
    return false, "cannot install plugin: " .. tostring(rerr)
  end
  return true
end

-- remove([root]) -> ok, err. Deleting the .lua file makes SLSsteam fire its
-- luaReload callback; the plugin restores the patched instructions first, then
-- the now-missing plugin is not re-run.
function M.remove(root)
  root = root or slsprofile.root()
  if not root then return false, "SLSsteam profile not found" end
  local p = M.paths(root)
  if not is_file(p.plugin) then return true end
  local ok, err = os.remove(p.plugin)
  if not ok then return false, tostring(err) end
  return true
end

-- set_enabled([enabled]) -> ok, err
function M.set_enabled(enabled, opts)
  opts = opts or {}
  local root = opts.root or slsprofile.root()
  if enabled and enabled ~= 0 then
    return M.install(root, opts)
  end
  return M.remove(root)
end

-- ensure_current([root]) -> ok, reason. Refresh an installed, older copy (an
-- upgraded Lumen carries a newer plugin) without enabling a disabled one.
function M.ensure_current(root, opts)
  opts = opts or {}
  root = root or opts.root or slsprofile.root()
  if not root then return false, "SLSsteam profile not found" end
  local p = M.paths(root)
  if not is_file(p.plugin) then return true, "not installed" end
  if read_file(p.plugin) == M.SOURCE then return true, "current" end
  local ok, err = M.install(root, opts)
  return ok, ok and "refreshed" or err
end

-- register(registry[, opts]): JSON RPCs for the settings menu's Plugin row.
-- opts.root is injectable for tests; it defaults to the active profile.
function M.register(registry, opts)
  opts = opts or {}
  local json = require("json")

  local function reply(t)
    local ok, out = pcall(json.encode, t)
    if ok then return out end
    return '{"success":false,"error":"encode failed"}'
  end

  local function steam_running()
    local ok, proc = pcall(require, "proc")
    if not ok or type(proc.is_alive) ~= "function" then return false end
    local ok2, alive = pcall(proc.is_alive, "steam")
    return ok2 and alive == true
  end

  -- Keep an installed copy in step with this Lumen build. Never creates the
  -- file, so a user who turned the toggle off stays off.
  pcall(M.ensure_current, nil, opts)

  registry.LumenAchievementsFixStatus = function()
    local ok, report = pcall(M.status, nil, opts)
    if not ok or type(report) ~= "table" then
      return reply({ success = false, error = tostring(report) })
    end
    report.success = report.ok ~= false
    report.steam = steam_running()
    return reply(report)
  end

  registry.LumenAchievementsFixSet = function(enabled)
    -- The dispatch maps the JS args object to alphabetical positional args, so
    -- {enabled: true} arrives as the first argument; tolerate both forms.
    if type(enabled) == "table" then
      local value = enabled.enabled
      if value == nil then value = enabled.value end
      enabled = value
    end
    if enabled == "false" then enabled = false end
    if enabled == "true" then enabled = true end
    local ok, res, err = pcall(M.set_enabled, enabled and true or false, opts)
    if not ok then return reply({ success = false, error = tostring(res) }) end
    if res ~= true then
      return reply({ success = false, error = tostring(err) })
    end
    local after = M.status(nil, opts)
    after.success = true
    after.steam = steam_running()
    return reply(after)
  end
  return registry
end

return M
