-- Run: ./bin/lumen --test tools/test_slsachievements.lua
-- Tests the achievements-plugin manager: install/remove into a profile, status
-- parsing, and the JSON RPCs the settings menu calls. Everything runs against a
-- temp directory; the real Steam profile is never touched.
package.path = "lua/?.lua;" .. package.path
local lfs = require("lfs")
local json = require("json")
local slsachievements = require("slsachievements")

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
end

local function rmtree(path)
  local attr = lfs.attributes(path)
  if not attr then return end
  if attr.mode == "directory" then
    for entry in lfs.dir(path) do
      if entry ~= "." and entry ~= ".." then
        rmtree(path .. "/" .. entry)
      end
    end
    lfs.rmdir(path)
  else
    os.remove(path)
  end
end

-- ── embedded plugin source sanity ─────────────────────────────────────────
do
  assert_true(#slsachievements.SOURCE > 5000, "plugin source embedded")
  assert_true(slsachievements.SOURCE:find("SLS_AchievementsFix", 1, true) ~= nil,
    "source carries its state marker")
  assert_true(slsachievements.SOURCE:find("_ZN5CUser12isSubscribedEj", 1, true) ~= nil,
    "source patches isSubscribed")
  assert_true(slsachievements.SOURCE:find("]===]", 1, true) == nil,
    "long-bracket terminator not inside source")
  assert_eq(slsachievements.SOURCE:sub(-1), "\n", "source ends with newline")
end

-- ── install writes exactly the embedded plugin, atomically ────────────────
local root = os.tmpname()
os.remove(root)
assert(lfs.mkdir(root))
do
  local before = slsachievements.status(root)
  assert_true(before.ok == true, "status ok for existing profile")
  assert_eq(before.installed, false, "starts disabled")
  assert_eq(before.state, "off", "off state")
  assert_true(before.profile == root, "profile reported")

  local ok, err = slsachievements.install(root)
  assert_true(ok, "install ok: " .. tostring(err))
  local p = slsachievements.paths(root)
  assert_eq(read(p.plugin), slsachievements.SOURCE, "plugin content exact")
  assert_true(lfs.attributes(p.plugins_dir).mode == "directory", "plugins dir created")
  assert_true(lfs.attributes(p.plugins_dir .. "/.lumen-achievements.tmp") == nil,
    "no temp leftovers")

  local after = slsachievements.status(root)
  assert_eq(after.installed, true, "installed")
  assert_eq(after.state, "pending", "pending until SLSsteam reports")

  -- The plugin's own status file drives the reported state.
  write(p.status, "version=2\nstate=active\nreason=patched\nsites=3\n")
  local active = slsachievements.status(root)
  assert_eq(active.state, "active", "status file state")
  assert_eq(active.sites, 3, "site count parsed")
  assert_eq(active.version, 2, "version parsed")
  assert_eq(active.reason, "patched", "reason parsed")

  -- Re-install drops the stale status file (it described the old session).
  assert_true(slsachievements.install(root) == true, "reinstall ok")
  assert_true(read(p.status) == nil, "stale status removed on install")

  -- remove() deletes the plugin and reports off.
  assert_true(slsachievements.remove(root) == true, "remove ok")
  local off = slsachievements.status(root)
  assert_eq(off.installed, false, "removed")
  assert_eq(off.state, "off", "off after removal")
  assert_true(slsachievements.remove(root) == true, "remove is idempotent")
end

-- ── a missing profile is refused, not silently created ────────────────────
do
  local missing = root .. "/nope"
  local ok, err = slsachievements.install(missing)
  assert_eq(ok, false, "missing profile refused")
  assert_true(tostring(err):find("not found", 1, true) ~= nil, "clear error")
  assert_true(lfs.attributes(missing) == nil, "no directory created")
  local st = slsachievements.status(missing)
  assert_true(st.ok == false, "status not ok")
end

-- ── ensure_current refreshes an old copy but never enables a disabled one ──
do
  local dir = root .. "/profile"
  assert(lfs.mkdir(dir))
  local plugins = dir .. "/plugins"
  assert(lfs.mkdir(plugins))
  local p = slsachievements.paths(dir)
  write(p.plugin, "-- old plugin\n")
  assert_true(slsachievements.ensure_current(dir) == true, "stale refreshed")
  assert_eq(read(p.plugin), slsachievements.SOURCE, "refreshed to current")

  os.remove(p.plugin)
  assert_true(slsachievements.ensure_current(dir) == true, "absent untouched")
  assert_true(lfs.attributes(p.plugin) == nil, "still disabled")
end

-- ── RPC surface: status + set, both JSON strings ──────────────────────────
do
  package.loaded["proc"] = { is_alive = function() return true end }
  local registry = {}
  slsachievements.register(registry, { root = root })
  assert_true(type(registry.LumenAchievementsFixStatus) == "function", "status rpc")
  assert_true(type(registry.LumenAchievementsFixSet) == "function", "set rpc")

  local off = json.decode(registry.LumenAchievementsFixStatus())
  assert_eq(off.success, true, "status success")
  assert_eq(off.installed, false, "status disabled")
  assert_eq(off.steam, true, "steam liveness reported")

  local on = json.decode(registry.LumenAchievementsFixSet({ enabled = true }))
  assert_eq(on.success, true, "enable success")
  assert_eq(on.installed, true, "enable installs")
  assert_eq(on.state, "pending", "enable pending")

  local now = json.decode(registry.LumenAchievementsFixStatus())
  assert_eq(now.installed, true, "status reflects install")

  local disabled = json.decode(registry.LumenAchievementsFixSet({ enabled = false }))
  assert_eq(disabled.success, true, "disable success")
  assert_eq(disabled.installed, false, "disable removes")

  -- Tolerate the non-table argument form the dispatch may produce.
  local again = json.decode(registry.LumenAchievementsFixSet(true))
  assert_eq(again.installed, true, "bare boolean enable")
  assert_true(json.decode(registry.LumenAchievementsFixSet(false)).installed == false,
    "bare boolean disable")
end

rmtree(root)
print("test_slsachievements: ALL PASS")
