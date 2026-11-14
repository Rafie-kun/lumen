-- Run: ./bin/lumen --test tools/test_slsworkshop.lua
-- Tests the Workshop status module behind the settings menu's "Workshop for
-- added games" row: ACF parsing, library/added-app discovery, and the
-- collect() summary. Everything runs in a temp Steam root.
package.path = "lua/?.lua;" .. package.path
local lfs = require("lfs")
local json = require("json")
local slsworkshop = require("slsworkshop")

local function assert_true(c, m) if not c then error("FAIL: " .. (m or ""), 0) end end
local function assert_eq(got, want, msg)
  if got ~= want then
    error("FAIL: " .. (msg or "") .. " (got=" .. tostring(got) ..
          " want=" .. tostring(want) .. ")", 0)
  end
end

local function write(path, data)
  local f = assert(io.open(path, "wb"))
  f:write(data)
  f:close()
end

local function rmtree(path)
  local attr = lfs.attributes(path)
  if not attr then return end
  if attr.mode == "directory" then
    for entry in lfs.dir(path) do
      if entry ~= "." and entry ~= ".." then rmtree(path .. "/" .. entry) end
    end
    lfs.rmdir(path)
  else
    os.remove(path)
  end
end

-- ── parsers ───────────────────────────────────────────────────────────────
do
  local manifest = [["AppState"
{
	"appid"		"211820"
	"name"		"Starbound"
	"StateFlags"		"4"
	"installdir"		"Starbound"
	"buildid"		"19867013"
}]]
  local m = slsworkshop.parse_manifest(manifest)
  assert_true(m ~= nil, "manifest parses")
  assert_eq(m.appid, 211820, "appid")
  assert_eq(m.name, "Starbound", "name")
  assert_eq(m.installdir, "Starbound", "installdir")
  assert_eq(m.stateFlags, 4, "StateFlags")
  assert_eq(m.buildid, "19867013", "buildid")
  assert_eq(slsworkshop.parse_manifest("nope"), nil, "junk manifest -> nil")
  assert_eq(slsworkshop.parse_manifest(nil), nil, "nil manifest -> nil")

  local ws = [["AppWorkshop"
{
	"appid"		"211820"
	"SizeOnDisk"		"28189943"
	"NeedsUpdate"		"0"
	"WorkshopItemsInstalled"
	{
		"3025139283"
		{
			"size"		"28189943"
		}
		"3025139284"
		{
			"size"		"1"
		}
	}
}]]
  local a = slsworkshop.parse_appworkshop(ws)
  assert_true(a ~= nil, "appworkshop parses")
  assert_eq(a.items, 2, "two installed items")
  assert_eq(a.needsUpdate, false, "NeedsUpdate 0 -> false")
  assert_eq(a.size, 28189943, "SizeOnDisk")
  local pending = slsworkshop.parse_appworkshop('"AppWorkshop"\n{\n"NeedsUpdate"\t"1"\n}')
  assert_eq(pending.needsUpdate, true, "NeedsUpdate 1 -> true")
  assert_eq(pending.items, 0, "no items section -> 0")
end

-- ── a temp Steam install ──────────────────────────────────────────────────
local root = os.tmpname()
os.remove(root)
assert(lfs.mkdir(root))
assert(lfs.mkdir(root .. "/steamapps"))
assert(lfs.mkdir(root .. "/steamapps/workshop"))
assert(lfs.mkdir(root .. "/config"))
assert(lfs.mkdir(root .. "/config/stplug-in"))

local function manifest(appid, name, extra)
  return '"AppState"\n{\n"appid"\t\t"' .. appid .. '"\n"name"\t\t"' .. name ..
    '"\n"StateFlags"\t\t"4"\n"installdir"\t\t"' .. name .. '"\n' ..
    (extra or "") .. "}\n"
end

-- 100: installed + workshop state (ready)
write(root .. "/steamapps/appmanifest_100.acf", manifest(100, "Ready Game"))
write(root .. "/steamapps/workshop/appworkshop_100.acf",
  '"AppWorkshop"\n{\n"NeedsUpdate"\t\t"0"\n"WorkshopItemsInstalled"\n{\n"1"\n{\n"size"\t"1"\n}\n}\n}\n')
-- 200: installed, no workshop state yet (pending)
write(root .. "/steamapps/appmanifest_200.acf", manifest(200, "Pending Game"))
-- Both manifests predate this Steam session (written two hours ago).
local old = os.time() - 7200
assert(lfs.touch(root .. "/steamapps/appmanifest_100.acf", old, old))
assert(lfs.touch(root .. "/steamapps/appmanifest_200.acf", old, old))
-- 300: added in stplug-in, not installed
-- 400: added through config.yaml AdditionalApps, not installed
write(root .. "/config/stplug-in/100.lua", "addappid(100)\n")
write(root .. "/config/stplug-in/200.lua", "addappid(200)\n")
write(root .. "/config/stplug-in/300.lua", "addappid(300)\n")

local profile = root .. "/profile"
assert(lfs.mkdir(profile))
write(profile .. "/config.yaml",
  "AdditionalApps:\n  - 400\n  - 100\nUseWhitelist: no\n")

local opts = { steam_root = root, profile = profile }

do
  local roots = slsworkshop.library_roots(root, opts)
  assert_eq(#roots, 1, "single library without libraryfolders.vdf")
  assert_eq(roots[1], root, "library root is the steam root")
end

do
  local installed = slsworkshop.installed(opts)
  assert_eq(installed[100] and installed[100].name, "Ready Game", "installed 100")
  assert_eq(installed[200] and installed[200].name, "Pending Game", "installed 200")
  assert_eq(installed[300], nil, "300 is not installed")
  assert_true(installed[100].library == root, "library recorded")
  assert_true(type(installed[100].mtime) == "number", "mtime recorded")
end

do
  local added = slsworkshop.added(opts)
  assert_eq(#added, 4, "stplug-in + AdditionalApps union (400 and 100 deduped)")
  assert_eq(added[1], 100, "sorted")
  assert_eq(added[4], 400, "AdditionalApps entry kept")
end

-- ── collect(): the summary the menu renders ───────────────────────────────
do
  local s = slsworkshop.collect({
    steam_root = root, profile = profile, session_start = old + 60,
  })
  assert_true(s.success, "collect succeeds")
  assert_eq(#s.installed, 2, "two installed added games listed")
  assert_eq(s.ready, 1, "one ready")
  assert_eq(s.pending, 1, "one pending")
  assert_eq(s.notInstalled, 2, "two not installed")
  assert_eq(s.needsRestart, 0, "nothing installed after the session start")
  local by = {}
  for _, e in ipairs(s.installed) do by[e.appid] = e end
  assert_eq(by[100].workshop and by[100].workshop.items, 1, "100 workshop items")
  assert_eq(by[200].workshop, nil, "200 has no appworkshop yet")
end

-- An install that lands after this client started needs a restart before the
-- workshop manager registers it: needsRestart counts it and names it.
do
  local s = slsworkshop.collect({
    steam_root = root, profile = profile, session_start = old - 60,
  })
  assert_eq(s.needsRestart, 2, "both manifests look newer than the session")
  for _, e in ipairs(s.installed) do
    assert_true(e.installedThisSession, "installedThisSession flagged")
  end
end

-- ── session_start(): /proc parsing without touching the real /proc ────────
do
  local tokens = {}
  for i = 4, 52 do tokens[#tokens + 1] = (i == 22) and "500" or "0" end
  local stat = "4242 (steam) S " .. table.concat(tokens, " ") .. "\n"
  local procstat = "cpu 0 0 0 0 0 0 0 0 0 0\nbtime 1000\nprocesses 1\n"
  local files = {
    ["/proc/4242/stat"] = stat,
    ["/proc/stat"] = procstat,
  }
  local function read(path) return files[path] end
  -- CLK_TCK 100 -> 500 ticks = 5 s after boot.
  assert_eq(slsworkshop.session_start({ pid = 4242, read = read }), 1005,
    "btime + starttime/100")
  assert_eq(slsworkshop.session_start({ pid = 4242, read = function() return nil end }),
    nil, "missing /proc data -> nil")
end

-- ── missing Steam root degrades to an error, not a crash ──────────────────
do
  local s = slsworkshop.collect({
    steam_root = false, env = function() return nil end, home = nil,
  })
  assert_true(type(s) == "table", "collect returns a table")
  assert_eq(s.success, false, "no root -> success=false")
end

-- ── RPC contract ──────────────────────────────────────────────────────────
do
  local registry = {}
  slsworkshop.register(registry, { steam_root = root, profile = profile })
  assert_true(type(registry.LumenWorkshopStatus) == "function", "RPC registered")
  local decoded = json.decode(registry.LumenWorkshopStatus())
  assert_true(decoded.success, "RPC success")
  assert_eq(decoded.ready, 1, "RPC carries the summary")
end

-- ── manifest writer ───────────────────────────────────────────────────────
do
  local mine = [["AppState"
{
	"appid"		"300"
	"installdir"		"Hand Made"
	"LumenSynthetic"		"1"
}]]
  assert_true(slsworkshop.parse_manifest(mine).synthetic, "marker -> synthetic")
  assert_eq(slsworkshop.parse_manifest(manifest(100, "Ready Game")).synthetic,
    false, "real manifest is not synthetic")

  local text = slsworkshop.synthetic_manifest(300, "Hand Made")
  local parsed = slsworkshop.parse_manifest(text)
  assert_eq(parsed.appid, 300, "written manifest parses")
  assert_eq(parsed.installdir, "Hand Made", "installdir written")
  assert_eq(parsed.buildid, "0", "buildid 0")
  assert_true(parsed.synthetic, "written manifest carries the marker")

  -- Folders: two are claimed by the installed manifests, one is free.
  assert(lfs.mkdir(root .. "/steamapps/common"))
  assert(lfs.mkdir(root .. "/steamapps/common/Ready Game"))
  assert(lfs.mkdir(root .. "/steamapps/common/Pending Game"))
  assert(lfs.mkdir(root .. "/steamapps/common/Hand Made"))

  local dirs = slsworkshop.common_dirs(opts)
  assert_eq(#dirs, 3, "three folders under common")
  local free = {}
  for _, d in ipairs(dirs) do
    if not d.claimedBy then free[#free + 1] = d.installdir end
  end
  assert_eq(#free, 1, "one folder unclaimed")
  assert_eq(free[1], "Hand Made", "the unclaimed folder is Hand Made")

  local s = slsworkshop.collect({
    steam_root = root, profile = profile, session_start = os.time(),
  })
  assert_eq(#s.commonDirs, 1, "collect offers only the free folder")
  assert_eq(s.commonDirs[1].installdir, "Hand Made", "collect folder name")
  assert_eq(#s.missing, 2, "300 and 400 have no manifest")

  -- Bad inputs never touch the disk.
  local _, err = slsworkshop.write_manifest(500, "Hand Made", opts)
  assert_true(err ~= nil, "refuses an app that was not added")
  _, err = slsworkshop.write_manifest(300, "../Hand Made", opts)
  assert_true(err ~= nil, "refuses a path in installdir")
  _, err = slsworkshop.write_manifest(300, "Nope", opts)
  assert_true(err ~= nil, "refuses a folder that does not exist")

  local report, werr = slsworkshop.write_manifest(300, "Hand Made", opts)
  assert_true(report ~= nil, "writes the manifest: " .. tostring(werr))
  assert_eq(report.path, root .. "/steamapps/appmanifest_300.acf", "manifest path")
  local handle = assert(io.open(report.path, "rb"))
  local written = slsworkshop.parse_manifest(handle:read("*a"))
  handle:close()
  assert_true(written.synthetic, "on disk and marked")

  local again, dup = slsworkshop.write_manifest(300, "Hand Made", opts)
  assert_eq(again, nil, "refuses a second manifest")
  assert_true(dup ~= nil, "second attempt explains why")

  -- The claimed folder is gone from the writer's list now.
  s = slsworkshop.collect({
    steam_root = root, profile = profile, session_start = os.time(),
  })
  assert_eq(#s.commonDirs, 0, "no free folder left")
  assert_eq(#s.missing, 1, "only 400 is missing a manifest now")
  local entry
  for _, e in ipairs(s.installed) do if e.appid == 300 then entry = e end end
  assert_true(entry and entry.synthetic, "300 listed as synthetic")

  -- Undo only removes our own work.
  local removed, rerr = slsworkshop.remove_manifest(100, opts)
  assert_eq(removed, nil, "refuses a manifest Lumen did not write")
  assert_true(rerr ~= nil, "refusal has a reason")
  assert_true(slsworkshop.remove_manifest(300, opts), "undo removes ours")
  assert_eq(slsworkshop.remove_manifest(300, opts), nil, "undo twice is a no")
end

-- ── writer RPCs, the way the menu calls them ──────────────────────────────
do
  local registry = {}
  slsworkshop.register(registry, { steam_root = root, profile = profile })
  assert_true(type(registry.LumenWorkshopRegister) == "function", "register RPC")
  assert_true(type(registry.LumenWorkshopUnregister) == "function", "undo RPC")

  local bad = json.decode(registry.LumenWorkshopRegister(
    { json = json.encode({ appid = 300, installdir = "Nope" }) }))
  assert_eq(bad.success, false, "RPC refuses a bad folder")

  local ok = json.decode(registry.LumenWorkshopRegister(
    { json = json.encode({ appid = 300, installdir = "Hand Made" }) }))
  assert_true(ok.success, "RPC writes the manifest: " .. tostring(ok.error))
  assert_eq(ok.restart, true, "RPC asks for a restart")

  local undo = json.decode(registry.LumenWorkshopUnregister(
    { json = json.encode({ appid = 300 }) }))
  assert_true(undo.success, "RPC undo works: " .. tostring(undo.error))

  local refuse = json.decode(registry.LumenWorkshopUnregister(
    { json = json.encode({ appid = 100 }) }))
  assert_eq(refuse.success, false, "RPC undo refuses foreign manifests")

  local missing = json.decode(registry.LumenWorkshopRegister())
  assert_eq(missing.success, false, "RPC without a request fails cleanly")
end

rmtree(root)
print("test_slsworkshop: ALL PASS")
