-- slswatch: survive Steam client updates.
--
-- A Steam update replaces steamclient.so/steamui.so. Two things can break:
--   * the achievements plugin patches three call sites by scanning; if the
--     guard shape changes the plugin reports state=failed and stops patching,
--   * the SLSsteam library itself is pattern-matched against the client; when
--     a build moves the code the closed Careca .so cannot be repaired locally.
--
-- Lumen can repair the first and verify the second. This module remembers the
-- client build it last saw, and when the build changes while the client is
-- running it:
--   1. re-applies the achievements plugin (an atomic rewrite makes SLSsteam
--      reload plugins, and the plugin re-patches on luaReload),
--   2. checks that SLSsteam.so is still mapped in the new client,
--   3. stores a report the settings menu shows ("re-applied", "SLSsteam not
--      loaded - update the Careca/SLSsteam pack").
--
-- Lumen's own re-attach is handled by the injector, independent of the build,
-- so nothing here restarts Lumen.

local lfs = require("lfs")

local M = {}

M.STATE_FILE = "steam-client-build"
M.REPORT_FILE = "steam-update.status"
M.CHECK_SECONDS = 15

local function read_file(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local data = f:read("*a")
  f:close()
  return data
end

local function write_file(path, text)
  local f = io.open(path, "wb")
  if not f then return false end
  local ok = f:write(text)
  f:close()
  return ok and true or false
end

local function data_dir(opts)
  opts = opts or {}
  if opts.data_dir then return opts.data_dir end
  local env = opts.env or os.getenv
  local base = env("XDG_DATA_HOME")
  if not base or base == "" then
    local home = opts.home or env("HOME") or ""
    if home == "" then return nil end
    base = home .. "/.local/share"
  end
  return base .. "/Lumen"
end

-- build_id(opts) -> string|nil. The client manifest's `version` is the build
-- Steam itself tracks; the steamui CLSTAMP is the fallback for a client that
-- has not written a manifest yet.
function M.build_id(opts)
  opts = opts or {}
  local read = opts.read or read_file
  local root = opts.steam_root or require("slsworkshop").steam_root(opts)
  if root then
    for _, name in ipairs({ "steam_client_steamrt64.manifest",
                            "steam_client_ubuntu12.manifest" }) do
      local text = read(root .. "/package/" .. name)
      if type(text) == "string" then
        local version = text:match('"version"%s+"(%d+)"')
        if version then return version end
      end
    end
    local html = read(root .. "/steamui/index.html")
    if type(html) == "string" then
      local stamp = html:match('CLSTAMP%s*=%s*"(%d+)"')
      if stamp then return "clstamp-" .. stamp end
    end
  end
  return nil
end

-- observe(opts) -> {first, changed, previous, current}. Read-only: the state is
-- committed only after the guard ran (see commit), so an update that lands
-- while Steam is down is retried once the new client is up.
function M.observe(opts)
  opts = opts or {}
  local read = opts.read or read_file
  local dir = opts.data_dir or data_dir(opts)
  local build = opts.build or M.build_id(opts)
  local state_path = dir and (dir .. "/" .. M.STATE_FILE) or nil
  local previous = state_path and read(state_path) or nil
  previous = type(previous) == "string" and previous:gsub("%s+$", "") or nil
  if previous == "" then previous = nil end
  return {
    first = previous == nil,
    changed = previous ~= nil and build ~= nil and previous ~= build,
    previous = previous,
    current = build,
  }
end

-- commit(build[, opts]) -> bool. Remember the build the guard just handled.
function M.commit(build, opts)
  opts = opts or {}
  local write = opts.write or write_file
  local dir = opts.data_dir or data_dir(opts)
  if not dir or not build then return false end
  return pcall(write, dir .. "/" .. M.STATE_FILE, build .. "\n") and true or false
end

-- sls_failure(opts) -> "patterns"|"exports"|"vftables"|nil. SLSsteam truncates
-- ~/.SLSsteam.log every session and aborts before hooking when a client update
-- moves what it matches, so a marker in that file always describes THIS client.
-- A clean log returns nil.
function M.sls_failure(opts)
  opts = opts or {}
  local read = opts.read or read_file
  local path = opts.sls_log
  if not path then
    local home = (opts.env or os.getenv)("HOME") or ""
    if home == "" then return nil end
    path = home .. "/.SLSsteam.log"
  end
  local text = read(path)
  if type(text) ~= "string" then return nil end
  if text:find("Failed to find all patterns", 1, true) then return "patterns" end
  if text:find("Failed to find steam exports", 1, true) then return "exports" end
  if text:find("Failed to parse VFTables", 1, true) then return "vftables" end
  return nil
end

-- guard(opts) -> report table. opts.achievements and opts.sls_loaded are
-- injectable for tests.
function M.guard(opts)
  opts = opts or {}
  local report = {
    at = os.time(),
    changed = opts.previous ~= nil and opts.build ~= nil
      and tostring(opts.previous) ~= tostring(opts.build),
    previous = opts.previous,
    build = opts.build,
    achievements = "none",
    slsLoaded = false,
  }

  local ach = opts.achievements
  if ach == nil then
    local ok, mod = pcall(require, "slsachievements")
    ach = ok and mod or false
  end
  if ach then
    local root = opts.profile
    if not root and type(ach.paths) == "function" then
      local ok, p = pcall(function() return require("slsprofile").root() end)
      root = ok and p or nil
    end
    if root and type(ach.paths) == "function" then
      local installed = false
      local ok_i, is_file = pcall(function()
        return lfs.attributes(ach.paths(root).plugin, "mode") == "file"
      end)
      installed = ok_i and is_file or false
      if not installed then
        report.achievements = "disabled"
      else
        local status = nil
        local ok_s, st = pcall(ach.read_status, root)
        if ok_s then status = st end
        if status and status.state == "active"
            and tonumber(status.sites) and tonumber(status.sites) >= 3
            and tonumber(status.version) == tonumber(ach.VERSION) then
          report.achievements = "current"
        else
          local ok_w, err = pcall(ach.install, root)
          report.achievements = ok_w and "reapplied" or ("failed: " .. tostring(err))
        end
      end
    else
      report.achievements = "unavailable"
    end
  end

  local loaded
  if opts.sls_loaded ~= nil then
    loaded = opts.sls_loaded
  else
    local ok, proc = pcall(require, "proc")
    if ok and proc and type(proc.lib_mapped) == "function" then
      local ok2, mapped = pcall(proc.lib_mapped, "steam", "SLSsteam.so")
      loaded = ok2 and mapped and true or false
    end
  end
  report.slsLoaded = loaded and true or false
  if opts.sls_failure ~= nil then
    report.slsFailure = opts.sls_failure or nil
  else
    report.slsFailure = M.sls_failure(opts)
  end

  local dir = opts.data_dir or data_dir(opts)
  if dir then
    local ok, json = pcall(require, "json")
    if ok then
      pcall(write_file, dir .. "/" .. M.REPORT_FILE, json.encode(report))
    end
  end
  return report
end

-- status(opts) -> {success, build, changed, last}. Read-only view for the menu.
function M.status(opts)
  opts = opts or {}
  local read = opts.read or read_file
  local dir = opts.data_dir or data_dir(opts)
  local build = opts.build or M.build_id(opts)
  local last = nil
  if dir then
    local body = read(dir .. "/" .. M.REPORT_FILE)
    if type(body) == "string" and body ~= "" then
      local ok, json = pcall(require, "json")
      local ok2, decoded = false, nil
      if ok then ok2, decoded = pcall(json.decode, body) end
      if ok2 and type(decoded) == "table" then last = decoded end
    end
  end
  return {
    success = true,
    build = build,
    changed = nil,
    last = last,
  }
end

-- instance(opts): called from the Lumen loop. `tick` compares the build at
-- most every CHECK_SECONDS while the client is alive, so an update that lands
-- mid-session is caught without waiting for a Lumen restart.
function M.instance(opts)
  opts = opts or {}
  local inst = {
    opts = opts,
    next_check = 0,
    last = nil,
    interval = opts.interval or M.CHECK_SECONDS,
  }

  function inst:check(now)
    local observe = self.opts.observe or M.observe
    local res = observe(self.opts)
    if not res.first and not res.changed then return res end
    local alive = true
    if self.opts.steam_alive then
      alive = self.opts.steam_alive()
    else
      local ok, proc = pcall(require, "proc")
      alive = ok and proc.is_alive("steam") or false
    end
    -- First sight of a client build is checked too: Lumen may have been
    -- installed after a Steam update, so the plugin could already be stale
    -- while there is no previous build to compare against. guard() only
    -- rewrites the plugin when its status is not current, so this is a no-op
    -- on a healthy install.
    if alive then
      local guard = self.opts.guard or M.guard
      local combined = {}
      for key, value in pairs(self.opts) do combined[key] = value end
      combined.previous = res.previous
      combined.build = res.current
      self.last = guard(combined)
      local commit = self.opts.commit or M.commit
      pcall(commit, res.current, self.opts)
    end
    return res
  end

  function inst:tick(now)
    now = tonumber(now) or 0
    if now < self.next_check then return nil end
    self.next_check = now + self.interval
    return self:check(now)
  end

  -- kick(): check on the next tick (a Steam restart just happened).
  function inst:kick()
    self.next_check = 0
  end

  return inst
end

-- register(registry[, opts]): RPC for the settings menu's update-guard row.
function M.register(registry, opts)
  opts = opts or {}
  local json = require("json")

  registry.LumenSteamUpdateStatus = function()
    local ok, report = pcall(M.status, opts)
    if not ok or type(report) ~= "table" then
      return json.encode({ success = false, error = tostring(report) })
    end
    return json.encode(report)
  end

  -- "Check now": run one guard pass synchronously (the menu calls this, then
  -- re-reads the status). Same work the loop does when the build changes.
  registry.LumenSteamUpdateCheck = function()
    local ok, err = pcall(function()
      local inst = M.instance(opts)
      local res = inst:check()
      if not res or not res.first and not res.changed then
        -- Nothing changed; still refresh the report so the row shows that the
        -- current build is healthy.
        local report = M.guard({
          build = res and res.current,
          previous = res and res.previous,
          profile = opts.profile,
          data_dir = opts.data_dir,
        })
        inst.last = report
      end
      return true
    end)
    if ok then return json.encode({ success = true }) end
    return json.encode({ success = false, error = tostring(err) })
  end
  return registry
end

return M
