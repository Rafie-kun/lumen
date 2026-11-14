-- Run: ./bin/lumen --test tools/test_slswatch.lua
-- Tests the Steam-update guard: client-build detection, the observe/guard/
-- commit cycle, the loop instance (first sight, build change, unchanged,
-- kick), and the two settings-menu RPCs.
package.path = "lua/?.lua;" .. package.path
local lfs = require("lfs")
local json = require("json")
local slswatch = require("slswatch")

local function assert_true(c, m) if not c then error("FAIL: " .. (m or ""), 0) end end
local function assert_eq(got, want, msg)
  if got ~= want then
    error("FAIL: " .. (msg or "") .. " (got=" .. tostring(got) ..
          " want=" .. tostring(want) .. ")", 0)
  end
end

local function read(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local d = f:read("*a")
  f:close()
  return d
end

local function write(path, data)
  local f = assert(io.open(path, "wb"))
  f:write(data)
  f:close()
  return true
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

local root = os.tmpname()
os.remove(root)
assert(lfs.mkdir(root))
assert(lfs.mkdir(root .. "/package"))
assert(lfs.mkdir(root .. "/steamui"))
local data_dir = root .. "/data"
assert(lfs.mkdir(data_dir))

-- ── build_id(): manifest version, then the steamui CLSTAMP fallback ───────
do
  write(root .. "/package/steam_client_steamrt64.manifest",
    '"steamrt64"\n{\n\t"version"\t\t"1794536281"\n}\n')
  assert_eq(slswatch.build_id({ steam_root = root }), "1794536281",
    "version from the client manifest")

  os.remove(root .. "/package/steam_client_steamrt64.manifest")
  assert_eq(slswatch.build_id({ steam_root = root }), nil,
    "no manifest and no steamui -> nil")

  write(root .. "/steamui/index.html",
    '<html><script>var CLSTAMP="11229305";</script></html>\n')
  assert_eq(slswatch.build_id({ steam_root = root }), "clstamp-11229305",
    "steamui CLSTAMP fallback")
end

-- ── observe(): read-only, first sight vs change ──────────────────────────
do
  local state = data_dir .. "/" .. slswatch.STATE_FILE
  os.remove(state)
  local first = slswatch.observe({ data_dir = data_dir, build = "100" })
  assert_true(first.first, "no state -> first")
  assert_eq(first.changed, false, "first is not a change")
  assert_eq(first.current, "100", "current build")
  assert_eq(read(state), nil, "observe does not write state")

  write(state, "100\n")
  local same = slswatch.observe({ data_dir = data_dir, build = "100" })
  assert_eq(same.first, false, "state present")
  assert_eq(same.changed, false, "same build -> not changed")

  local moved = slswatch.observe({ data_dir = data_dir, build = "200" })
  assert_true(moved.changed, "different build -> changed")
  assert_eq(moved.previous, "100", "previous build reported")
  assert_eq(read(state), "100\n", "observe leaves the old state for a retry")

  assert_true(slswatch.commit("200", { data_dir = data_dir }), "commit writes")
  assert_eq(read(state), "200\n", "committed build")
  assert_eq(slswatch.commit(nil, { data_dir = data_dir }), false, "nothing to commit")
end

-- ── guard(): re-applies the plugin when stale, verifies SLSsteam ─────────
do
  local calls = {}
  local fake_ach = {
    VERSION = 2,
    paths = function(r) return { plugin = r .. "/p.lua" } end,
    read_status = function() return { state = "failed", sites = 0, version = 2 } end,
    install = function(r) calls.install = r; return true end,
  }
  assert(lfs.mkdir(root .. "/profile"))
  write(root .. "/profile/p.lua", "-- installed\n")

  local report = slswatch.guard({
    achievements = fake_ach,
    profile = root .. "/profile",
    sls_loaded = true,
    data_dir = data_dir,
    build = "200",
    previous = "100",
  })
  assert_eq(report.achievements, "reapplied", "stale plugin is re-applied")
  assert_eq(calls.install, root .. "/profile", "install target is the active profile")
  assert_true(report.slsLoaded, "SLSsteam still loaded")
  assert_true(type(report.at) == "number", "report timestamped")
  local saved = json.decode(read(data_dir .. "/" .. slswatch.REPORT_FILE))
  assert_eq(saved.achievements, "reapplied", "report persisted for the menu")

  -- Current plugin: nothing to do.
  local clean = {
    VERSION = 2,
    paths = fake_ach.paths,
    read_status = function() return { state = "active", sites = 3, version = 2 } end,
    install = function() error("must not reinstall a current plugin") end,
  }
  local ok = slswatch.guard({
    achievements = clean, profile = root .. "/profile", sls_loaded = false,
    data_dir = data_dir, build = "200",
  })
  assert_eq(ok.achievements, "current", "current plugin is left alone")
  assert_eq(ok.slsLoaded, false, "missing SLSsteam is reported")

  -- Toggle off: the plugin file is absent, so nothing is installed.
  os.remove(root .. "/profile/p.lua")
  local off = slswatch.guard({
    achievements = clean, profile = root .. "/profile", sls_loaded = true,
    data_dir = data_dir,
  })
  assert_eq(off.achievements, "disabled", "no plugin file -> disabled")
end

-- ── instance: first sight, change, unchanged, kick ───────────────────────
do
  local seen = { observe = 0, guard = 0, commit = 0 }
  local responses = {
    { first = false, changed = false, previous = "200", current = "200" },
  }
  local inst = slswatch.instance({
    observe = function()
      seen.observe = seen.observe + 1
      return table.remove(responses, 1) or responses[1]
        or { first = false, changed = false, previous = "200", current = "200" }
    end,
    guard = function() seen.guard = seen.guard + 1; return { achievements = "reapplied" } end,
    commit = function() seen.commit = seen.commit + 1; return true end,
    steam_alive = function() return true end,
    interval = 15,
  })
  inst:check()
  assert_eq(seen.guard, 0, "unchanged build runs no guard")
  assert_eq(seen.commit, 0, "unchanged build commits nothing")

  -- A new build while Steam is up: guard runs, then the build is committed.
  responses[1] = { first = false, changed = true, previous = "200", current = "300" }
  inst:check()
  assert_eq(seen.guard, 1, "changed build runs the guard")
  assert_eq(seen.commit, 1, "changed build is committed")
  assert_eq(inst.last.achievements, "reapplied", "guard result kept")

  -- Steam down: the change is retried next tick instead of being forgotten.
  responses[1] = { first = false, changed = true, previous = "300", current = "400" }
  local inst2 = slswatch.instance({
    observe = function() return table.remove(responses, 1) or responses[1] end,
    guard = function() seen.guard = seen.guard + 1; return {} end,
    commit = function() seen.commit = seen.commit + 1; return true end,
    steam_alive = function() return false end,
  })
  inst2:check()
  assert_eq(seen.guard, 1, "no guard while Steam is down")
  assert_eq(seen.commit, 1, "no commit while Steam is down")

  -- First sight also verifies (guard is a no-op for a current plugin) so a
  -- Lumen installed after an update heals immediately.
  local inst3 = slswatch.instance({
    observe = function() return { first = true, changed = false, current = "500" } end,
    guard = function() seen.guard = seen.guard + 1; return {} end,
    commit = function() seen.commit = seen.commit + 1; return true end,
    steam_alive = function() return true end,
  })
  inst3:check()
  assert_eq(seen.guard, 2, "first sight runs the guard")
  assert_eq(seen.commit, 2, "first sight commits the build")

  -- tick honours the interval; kick forces the next tick.
  local ticked = 0
  local inst4 = slswatch.instance({
    observe = function() ticked = ticked + 1
      return { first = false, changed = false, current = "500" } end,
    steam_alive = function() return true end,
    interval = 15,
    guard = function() return {} end,
  })
  inst4:tick(100)
  inst4:tick(105)
  assert_eq(ticked, 1, "second tick inside the interval is skipped")
  inst4:kick()
  inst4:tick(106)
  assert_eq(ticked, 2, "kick forces a check")
end

-- ── RPCs ──────────────────────────────────────────────────────────────────
do
  local registry = {}
  slswatch.register(registry, { data_dir = data_dir, steam_root = root })
  assert_true(type(registry.LumenSteamUpdateStatus) == "function", "status RPC")
  assert_true(type(registry.LumenSteamUpdateCheck) == "function", "check RPC")
  local status = json.decode(registry.LumenSteamUpdateStatus())
  assert_true(status.success, "status succeeds")
  assert_true(status.build ~= nil, "status reports the client build")
  local checked = json.decode(registry.LumenSteamUpdateCheck())
  assert_true(checked.success, "check succeeds")
end

rmtree(root)
print("test_slswatch: ALL PASS")
