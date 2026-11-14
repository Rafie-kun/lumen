-- slsworkshop: Steam Workshop state for games added through SLSsteam/Careca.
--
-- Why this exists
-- ---------------
-- Steam's workshop manager builds its per-app set from the INSTALLED app
-- registry (steamapps/appmanifest_<id>.acf) when the client starts, not from
-- the licence list SLSsteam injects. A game that was added but has no manifest
-- is licensed, appears in the library and reports BIsSubscribedApp() true, yet
-- the workshop manager never registers it: SubscribeWorkshopItem() is silently
-- dropped (no workshop_log line, no appworkshop_<id>.acf, no download) and the
-- Workshop tab stays empty. Once a manifest exists the same build subscribes,
-- authenticates the workshop depot and downloads normally - including for a
-- game the account does not own (verified with Starbound 211820).
--
-- So the actionable states are:
--   ready       appworkshop_<id>.acf exists -> Workshop is live for this app
--   pending     manifest exists but no workshop state yet -> it appears on the
--               next client start, or after subscribing (first subscription
--               creates the acf)
--   notInstalled  added app with no manifest -> Workshop is hidden; install the
--               game (LuaTools' downloader writes the manifest), then restart
--   installThisSession  manifest written after this client started -> Workshop
--               needs a restart to register
--
-- Lumen deliberately does NOT invent a manifest. Its buildid/installdir/depot
-- sizes are not derivable from an appid, and a wrong manifest makes Steam plan
-- a verify/update against depots the account cannot authorize, which can
-- rewrite the game folder. The honest fix is install-then-restart, which this
-- module detects and reports.

local lfs = require("lfs")

local M = {}

local function read_file(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local data = f:read("*a")
  f:close()
  return data
end

local function is_dir(path)
  return lfs.attributes(path, "mode") == "directory"
end

-- ── pure parsers ────────────────────────────────────────────────────────────

-- parse_manifest(acf) -> {appid, name, installdir, stateFlags, buildid} | nil
function M.parse_manifest(text)
  if type(text) ~= "string" or text == "" then return nil end
  local appid = tonumber(text:match('"appid"%s+"(%d+)"'))
  if not appid then return nil end
  return {
    appid = appid,
    name = text:match('"name"%s+"([^"]*)"'),
    installdir = text:match('"installdir"%s+"([^"]*)"'),
    stateFlags = tonumber(text:match('"StateFlags"%s+"(%d+)"')),
    buildid = text:match('"buildid"%s+"(%d+)"'),
  }
end

-- parse_appworkshop(acf) -> {present=true, items, needsUpdate, size} | nil
function M.parse_appworkshop(text)
  if type(text) ~= "string" or text == "" then return nil end
  local items = 0
  local section = text:match('"WorkshopItemsInstalled"%s*(%b{})')
  if section then
    for _ in section:gmatch('"%d+"%s*%b{}') do items = items + 1 end
  end
  return {
    present = true,
    items = items,
    needsUpdate = (tonumber(text:match('"NeedsUpdate"%s+"(%d+)"')) or 0) ~= 0,
    size = tonumber(text:match('"SizeOnDisk"%s+"(%d+)"')) or 0,
  }
end

-- ── resolution ──────────────────────────────────────────────────────────────

-- steam_root(opts) -> path|nil. SLS_STEAM_ROOT wins (the Careca launcher sets
-- it); otherwise the usual Linux locations.
function M.steam_root(opts)
  opts = opts or {}
  if opts.steam_root then return opts.steam_root end
  local env = opts.env or os.getenv
  local explicit = env("SLS_STEAM_ROOT")
  if explicit and explicit ~= "" and (opts.is_dir or is_dir)(explicit) then
    return explicit
  end
  local home = opts.home or env("HOME") or ""
  if home == "" then return nil end
  local candidates = {
    home .. "/.local/share/Steam",
    home .. "/.steam/steam",
    home .. "/.steam/debian-installation",
  }
  local dir = opts.is_dir or is_dir
  for _, candidate in ipairs(candidates) do
    if dir(candidate) then return candidate end
  end
  return nil
end

-- library_roots(root, opts) -> {<steam root>, <extra libraries...>}
function M.library_roots(root, opts)
  opts = opts or {}
  local read = opts.read or read_file
  local roots, seen = { root }, { [root] = true }
  local vdf = read(root .. "/steamapps/libraryfolders.vdf")
  if type(vdf) == "string" then
    for path in vdf:gmatch('"path"%s*"([^"]+)"') do
      if path ~= "" and not seen[path] then
        seen[path] = true
        roots[#roots + 1] = path
      end
    end
  end
  return roots
end

-- installed(opts) -> map appid -> {appid, name, installdir, library, mtime}
function M.installed(opts)
  opts = opts or {}
  local read = opts.read or read_file
  local dir = opts.is_dir or is_dir
  local list = opts.list or function(path)
    local out = {}
    local ok, iter, obj = pcall(lfs.dir, path)
    if not ok then return out end
    for entry in iter, obj do
      if entry ~= "." and entry ~= ".." then out[#out + 1] = entry end
    end
    if obj then pcall(function() obj:close() end) end
    return out
  end
  local top = opts.steam_root or M.steam_root(opts)
  if not top then return {} end
  local out = {}
  for _, root in ipairs(M.library_roots(top, opts)) do
    local apps_dir = root .. "/steamapps"
    for _, entry in ipairs(list(apps_dir)) do
      local appid = entry:match("^appmanifest_(%d+)%.acf$")
      if appid then
        local path = apps_dir .. "/" .. entry
        local manifest = M.parse_manifest(read(path))
        if manifest then
          manifest.library = root
          manifest.path = path
          manifest.mtime = (lfs.attributes(path, "modification")) or nil
          out[manifest.appid] = manifest
        end
      end
    end
  end
  return out
end

-- added(opts) -> sorted list of added appids. Union of the stplug-in directive
-- stems (the Careca/LuaTools source of truth) and the legacy AdditionalApps
-- block, matching what the plugin injects.
function M.added(opts)
  opts = opts or {}
  local read = opts.read or read_file
  local list = opts.list or function(path)
    local out = {}
    local ok, iter, obj = pcall(lfs.dir, path)
    if not ok then return out end
    for entry in iter, obj do
      if entry ~= "." and entry ~= ".." then out[#out + 1] = entry end
    end
    if obj then pcall(function() obj:close() end) end
    return out
  end
  local seen, out = {}, {}
  local root = opts.steam_root or M.steam_root(opts)
  if root then
    for _, entry in ipairs(list(root .. "/config/stplug-in")) do
      local stem = entry:match("^(%d+)%.lua$")
      local id = stem and tonumber(stem)
      if id and not seen[id] then seen[id] = true; out[#out + 1] = id end
    end
  end
  local profile = opts.profile or require("slsprofile").root()
  if profile then
    local ok, fixesmenu = pcall(require, "fixesmenu")
    local config = read(profile .. "/config.yaml")
    if ok and fixesmenu and type(fixesmenu.parse_additional_apps) == "function" then
      for _, id in ipairs(fixesmenu.parse_additional_apps(config)) do
        if not seen[id] then seen[id] = true; out[#out + 1] = id end
      end
    end
  end
  table.sort(out)
  return out
end

-- session_start(opts) -> epoch|nil. Start time of the running `steam` client,
-- used to tell "installed before this client started" from "installed now".
-- CLK_TCK is 100 on every Linux ABI Steam ships for.
function M.session_start(opts)
  opts = opts or {}
  local read = opts.read or read_file
  local pid = opts.pid
  if not pid then
    local list = opts.list or function(path)
      local out = {}
      local ok, iter, obj = pcall(lfs.dir, path)
      if not ok then return out end
      for entry in iter, obj do
        if entry:match("^%d+$") then out[#out + 1] = entry end
      end
      if obj then pcall(function() obj:close() end) end
      return out
    end
    for _, candidate in ipairs(list("/proc")) do
      local comm = read("/proc/" .. candidate .. "/comm")
      if type(comm) == "string" and comm:gsub("%s+$", "") == "steam" then
        pid = candidate
        break
      end
    end
  end
  if not pid then return nil end
  local stat = read("/proc/" .. tostring(pid) .. "/stat")
  local procstat = read("/proc/stat")
  if type(stat) ~= "string" or type(procstat) ~= "string" then return nil end
  local btime = tonumber(procstat:match("btime%s+(%d+)"))
  -- Field 22 (`starttime`), counted from after the last ")" so a comm with
  -- spaces is harmless. Token 1 after ")" is field 3 (state), so field 22 is
  -- token 20.
  local rest = stat:match("%)%s*(.*)$")
  if not btime or not rest then return nil end
  local fields = {}
  for field in rest:gmatch("%S+") do fields[#fields + 1] = field end
  local starttime = tonumber(fields[20]) -- field 3 is fields[1]; 22 -> [20]
  if not starttime then return nil end
  return btime + math.floor(starttime / 100)
end

-- ── status ──────────────────────────────────────────────────────────────────

-- collect(opts) -> status table for the menu RPC. Everything is injectable so
-- the logic is unit-testable without a Steam install.
function M.collect(opts)
  opts = opts or {}
  local read = opts.read or read_file
  local root = opts.steam_root or M.steam_root(opts)
  local profile = opts.profile or require("slsprofile").root()
  local status = {
    success = true,
    steamRoot = root,
    profile = profile,
    installed = {},
    notInstalled = 0,
    ready = 0,
    pending = 0,
    needsRestart = 0,
  }
  if not root then
    status.success = false
    status.error = "Steam library not found"
    return status
  end
  local installed = opts.installed or M.installed({
    steam_root = root, read = read, list = opts.list, is_dir = opts.is_dir,
  })
  local added = opts.added or M.added({
    steam_root = root, profile = profile, read = read, list = opts.list,
  })
  local session = opts.session_start
  if session == nil then session = M.session_start({ read = read }) end

  for _, appid in ipairs(added) do
    local manifest = installed[appid]
    if not manifest then
      status.notInstalled = status.notInstalled + 1
    else
      local workshop = nil
      local acf_path = manifest.library .. "/steamapps/workshop/appworkshop_"
        .. tostring(appid) .. ".acf"
      if (opts.is_file or function(path)
            return lfs.attributes(path, "mode") == "file"
          end)(acf_path) then
        workshop = M.parse_appworkshop(read(acf_path))
      end
      local installed_this_session = session ~= nil and manifest.mtime ~= nil
        and manifest.mtime > session
      local entry = {
        appid = appid,
        name = manifest.name,
        installdir = manifest.installdir,
        library = manifest.library,
        workshop = workshop,
        installedThisSession = installed_this_session and true or false,
      }
      if workshop then
        status.ready = status.ready + 1
      else
        status.pending = status.pending + 1
      end
      if installed_this_session then
        status.needsRestart = status.needsRestart + 1
      end
      status.installed[#status.installed + 1] = entry
    end
  end
  return status
end

-- register(registry[, opts]): JSON RPC for the settings menu's Workshop row.
function M.register(registry, opts)
  opts = opts or {}
  local json = require("json")
  registry.LumenWorkshopStatus = function()
    local ok, report = pcall(M.collect, opts)
    if not ok or type(report) ~= "table" then
      return json.encode({ success = false, error = tostring(report) })
    end
    local ok2, out = pcall(json.encode, report)
    if ok2 then return out end
    return '{"success":false,"error":"encode failed"}'
  end
  return registry
end

return M
