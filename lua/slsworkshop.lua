-- slsworkshop: Workshop state for added games.
--
-- Steam picks the apps it manages workshop for at startup, from the installed
-- app list (appmanifest_<id>.acf) - not from the licences SLSsteam injects. So
-- an added game with no manifest looks owned and sits in the library, but
-- SubscribeWorkshopItem() is dropped without a word and the Workshop tab stays
-- empty. Add a manifest and restart, and the same client downloads normally
-- (checked with Starbound 211820).
--
-- States we can report:
--   ready          appworkshop_<id>.acf exists, workshop is live
--   pending        manifest exists, no workshop state yet (subscribe or restart)
--   notInstalled   added but no manifest, so workshop is hidden
--
-- For a game the user installed by hand (folder in steamapps/common, no
-- manifest) we can write a minimal manifest, marked "LumenSynthetic" so undo
-- only removes our own. It stays deliberately bare: buildid 0, no depots, zero
-- sizes. SLSsteam's DisableUpdates keeps Steam from planning an update from it.

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

local function is_file(path)
  return lfs.attributes(path, "mode") == "file"
end

local function list_dir(path)
  local out = {}
  local ok, iter, obj = pcall(lfs.dir, path)
  if not ok then return out end
  for entry in iter, obj do
    if entry ~= "." and entry ~= ".." then out[#out + 1] = entry end
  end
  if obj then pcall(function() obj:close() end) end
  return out
end

local function trim(s)
  return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

-- ── pure parsers ────────────────────────────────────────────────────────────

-- parse_manifest(acf) -> {appid, name, installdir, stateFlags, buildid,
-- synthetic} | nil. synthetic means we wrote it (see write_manifest).
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
    synthetic = text:match('"LumenSynthetic"%s+"1"') ~= nil,
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
  local list = opts.list or list_dir
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

-- common_dirs(opts) -> folders under steamapps/common, with the appid that
-- already claims them (or nil). The writer only offers unclaimed ones, so two
-- apps can't end up pointing at the same folder.
function M.common_dirs(opts)
  opts = opts or {}
  local dir = opts.is_dir or is_dir
  local list = opts.list or list_dir
  local top = opts.steam_root or M.steam_root(opts)
  if not top then return {} end
  local installed = opts.installed or M.installed(opts)
  local claimed = {}
  for _, m in pairs(installed) do
    if m.installdir and m.library then
      claimed[m.library .. "/" .. m.installdir] = m.appid
    end
  end
  local out = {}
  for _, root in ipairs(M.library_roots(top, opts)) do
    local common = root .. "/steamapps/common"
    for _, entry in ipairs(list(common)) do
      local path = common .. "/" .. entry
      if dir(path) then
        out[#out + 1] = {
          installdir = entry,
          library = root,
          path = path,
          claimedBy = claimed[root .. "/" .. entry],
        }
      end
    end
  end
  table.sort(out, function(a, b)
    if a.library ~= b.library then return a.library < b.library end
    return a.installdir < b.installdir
  end)
  return out
end

-- added(opts) -> sorted list of added appids. Union of the stplug-in directive
-- stems (the Careca/LuaTools source of truth) and the legacy AdditionalApps
-- block, matching what the plugin injects.
function M.added(opts)
  opts = opts or {}
  local read = opts.read or read_file
  local list = opts.list or list_dir
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
    local list = opts.list or list_dir
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
    missing = {},
    commonDirs = {},
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
      status.missing[#status.missing + 1] = { appid = appid }
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
        synthetic = manifest.synthetic and true or false,
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
  local dirs = opts.common_dirs or M.common_dirs({
    steam_root = root, installed = installed, list = opts.list,
    is_dir = opts.is_dir,
  })
  for _, entry in ipairs(dirs) do
    if not entry.claimedBy then
      status.commonDirs[#status.commonDirs + 1] = {
        installdir = entry.installdir,
        library = entry.library,
        path = entry.path,
      }
    end
  end
  return status
end

-- ── manifest writer ─────────────────────────────────────────────────────────

-- synthetic_manifest(appid, installdir) -> ACF text. Bare on purpose: no
-- depots, buildid 0. Steam only needs the app to exist at startup so the
-- workshop manager registers it; SLSsteam's DisableUpdates stops it planning a
-- download from buildid 0.
function M.synthetic_manifest(appid, installdir)
  local id = tostring(appid)
  local lines = {
    '"AppState"',
    '{',
    '\t"appid"\t\t"' .. id .. '"',
    '\t"Universe"\t\t"1"',
    '\t"name"\t\t"' .. installdir .. '"',
    '\t"StateFlags"\t\t"4"',
    '\t"installdir"\t\t"' .. installdir .. '"',
    '\t"buildid"\t\t"0"',
    '\t"TargetBuildID"\t\t"0"',
    '\t"LastUpdated"\t\t"0"',
    '\t"LastPlayed"\t\t"0"',
    '\t"SizeOnDisk"\t\t"0"',
    '\t"StagingSize"\t\t"0"',
    '\t"BytesToDownload"\t\t"0"',
    '\t"BytesDownloaded"\t\t"0"',
    '\t"BytesToStage"\t\t"0"',
    '\t"BytesStaged"\t\t"0"',
    '\t"InstalledDepots"',
    '\t{',
    '\t}',
    '\t"SharedDepots"',
    '\t{',
    '\t}',
    '\t"LumenSynthetic"\t\t"1"',
    '}',
    '',
  }
  return table.concat(lines, "\n")
end

-- write_manifest(appid, installdir[, opts]) -> report | nil, error.
-- Guards, in order: integer appid, plain folder name, app is in the added
-- list, no manifest yet, folder exists in a library. Writes to a temp file and
-- renames, so a half-written manifest can't confuse Steam.
function M.write_manifest(appid, installdir, opts)
  opts = opts or {}
  local id = tonumber(appid)
  if not id or id <= 0 or id % 1 ~= 0 then
    return nil, "That app id doesn't look right"
  end
  if type(installdir) ~= "string" then
    return nil, "Pick the game's folder"
  end
  installdir = trim(installdir)
  if installdir == "" then
    return nil, "Pick the game's folder"
  end
  if installdir:find("[/\\]") or installdir == "." or installdir == ".." then
    return nil, "Use the plain folder name, not a path"
  end

  local dir = opts.is_dir or is_dir
  local top = opts.steam_root or M.steam_root(opts)
  if not top then return nil, "Steam library not found" end
  local added = opts.added or M.added({
    steam_root = top, profile = opts.profile, read = opts.read,
    list = opts.list,
  })
  local found = false
  for _, candidate in ipairs(added) do
    if candidate == id then found = true break end
  end
  if not found then
    return nil, "That app was not added through LuaTools/SLSsteam"
  end

  local installed = opts.installed or M.installed({
    steam_root = top, read = opts.read, list = opts.list, is_dir = opts.is_dir,
  })
  if installed[id] then return nil, "That app already has a manifest" end

  local library
  for _, root in ipairs(M.library_roots(top, opts)) do
    if dir(root .. "/steamapps/common/" .. installdir) then
      library = root
      break
    end
  end
  if not library then
    return nil, "No folder called \"" .. installdir .. "\" in steamapps/common"
  end

  local path = library .. "/steamapps/appmanifest_" .. tostring(id) .. ".acf"
  if (opts.is_file or is_file)(path) then
    return nil, "That app already has a manifest"
  end

  local tmp = path .. ".lumen-tmp"
  local file, err = io.open(tmp, "wb")
  if not file then
    return nil, "Could not write the manifest: " .. tostring(err)
  end
  file:write(M.synthetic_manifest(id, installdir))
  file:close()
  local ok, rename_err = os.rename(tmp, path)
  if not ok then
    os.remove(tmp)
    return nil, "Could not save the manifest: " .. tostring(rename_err)
  end
  return {
    appid = id,
    installdir = installdir,
    library = library,
    path = path,
    restart = true,
  }
end

-- remove_manifest(appid[, opts]) -> true | nil, error. Only deletes a manifest
-- we wrote (marker field), so a real Steam one is never touched.
function M.remove_manifest(appid, opts)
  opts = opts or {}
  local id = tonumber(appid)
  if not id or id <= 0 or id % 1 ~= 0 then
    return nil, "That app id doesn't look right"
  end
  local installed = opts.installed or M.installed(opts)
  local manifest = installed[id]
  if not manifest then return nil, "No manifest for that app" end
  if not manifest.synthetic then
    return nil, "Lumen didn't write this manifest, so I'll leave it alone"
  end
  local ok, err = os.remove(manifest.path)
  if not ok then
    return nil, "Could not remove the manifest: " .. tostring(err)
  end
  return true
end

-- register(registry[, opts]): JSON RPC for the settings menu's Workshop row.
function M.register(registry, opts)
  opts = opts or {}
  local json = require("json")

  local function reply(t)
    local ok, out = pcall(json.encode, t)
    if ok then return out end
    return '{"success":false,"error":"encode failed"}'
  end

  -- The menu sends one { json = "..." } argument (SetSlsConfig does the same);
  -- accept a plain table or a JSON string too, so tests and curl-style calls
  -- don't have to mimic the client.
  local function request(arg)
    local data
    if type(arg) == "table" then
      data = type(arg.json) == "string" and json.decode(arg.json) or arg
    elseif type(arg) == "string" and trim(arg):sub(1, 1) == "{" then
      data = json.decode(arg)
    end
    if type(data) ~= "table" then return nil end
    return data
  end

  registry.LumenWorkshopStatus = function()
    local ok, report = pcall(M.collect, opts)
    if not ok or type(report) ~= "table" then
      return reply({ success = false, error = tostring(report) })
    end
    return reply(report)
  end

  registry.LumenWorkshopRegister = function(arg)
    local request_ok, data = pcall(request, arg)
    if not request_ok or not data then
      return reply({ success = false, error = "Missing request" })
    end
    local ok, report, err = pcall(M.write_manifest, data.appid, data.installdir, opts)
    if not ok then report, err = nil, tostring(report) end
    if not report then
      return reply({ success = false, error = err or "Could not write the manifest" })
    end
    report.success = true
    return reply(report)
  end

  registry.LumenWorkshopUnregister = function(arg)
    local request_ok, data = pcall(request, arg)
    if not request_ok or not data then
      return reply({ success = false, error = "Missing request" })
    end
    local ok, result, err = pcall(M.remove_manifest, data.appid, opts)
    if not ok then result, err = nil, tostring(result) end
    if not result then
      return reply({ success = false, error = err or "Could not remove the manifest" })
    end
    return reply({ success = true, appid = tonumber(data.appid) })
  end

  return registry
end

return M
