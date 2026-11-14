-- Run: ./bin/lumen --test tools/test_slsprofile.lua
-- Tests finding the SLSsteam profile the running Steam client uses. The /proc
-- scan is fully injectable, so no real process is needed here.
package.path = "lua/?.lua;" .. package.path
local slsprofile = require("slsprofile")

local function assert_eq(got, want, msg)
  if got ~= want then
    error("FAIL: " .. (msg or "") .. " (got=" .. tostring(got) ..
          " want=" .. tostring(want) .. ")", 0)
  end
end

local function env_from(map)
  return function(name) return map[name] end
end

-- No /proc entries at all: own XDG_CONFIG_HOME wins, then HOME/.config.
do
  local opts = {
    env = env_from({ HOME = "/home/u", XDG_CONFIG_HOME = "/home/u/.config/custom" }),
    pids = function() return {} end,
    read = function() return nil end,
    comm = function() return nil end,
  }
  assert_eq(slsprofile.config_home(opts), "/home/u/.config/custom", "own XDG")
  assert_eq(slsprofile.root(opts), "/home/u/.config/custom/SLSsteam", "root")
end

do
  local opts = {
    env = env_from({ HOME = "/home/u" }),
    pids = function() return {} end,
    read = function() return nil end,
    comm = function() return nil end,
  }
  assert_eq(slsprofile.config_home(opts), "/home/u/.config", "HOME fallback")
end

-- SLSSTEAM_CONFIG_HOME overrides everything, even a live Steam process.
do
  local opts = {
    env = env_from({ HOME = "/home/u", SLSSTEAM_CONFIG_HOME = "/opt/prof" }),
    pids = function() return { "10" } end,
    read = function() return "HOME=/home/u\0XDG_CONFIG_HOME=/home/u/.config/careca\0" end,
    comm = function() return "steam" end,
  }
  assert_eq(slsprofile.config_home(opts), "/opt/prof", "explicit override")
end

-- The running client wins over our own (unset) environment: this is the
-- careca-x64 layout that made Lumen edit the wrong profile.
do
  local opts = {
    env = env_from({ HOME = "/home/u" }),
    pids = function() return { "1", "10" } end,
    read = function(path)
      if path == "/proc/10/environ" then
        return "HOME=/home/u\0XDG_CONFIG_HOME=/home/u/.config/SLSsteam-careca-x64\0"
      end
      return "HOME=/home/u\0"
    end,
    comm = function(pid) return pid == "10" and "steam" or "bash" end,
  }
  assert_eq(slsprofile.config_home(opts),
    "/home/u/.config/SLSsteam-careca-x64", "running steam profile")
end

-- A Steam process without XDG_CONFIG_HOME means the default layout; do not
-- fall through to some unrelated process.
do
  local opts = {
    env = env_from({ HOME = "/home/u" }),
    pids = function() return { "10", "20" } end,
    read = function(path)
      if path == "/proc/10/environ" then return "HOME=/home/u\0" end
      return "HOME=/home/u\0XDG_CONFIG_HOME=/home/u/.config/other\0"
    end,
    comm = function(pid) return pid == "10" and "steam" or "bash" end,
  }
  assert_eq(slsprofile.config_home(opts), "/home/u/.config",
    "steam without private profile uses ~/.config")
end

-- Another user's Steam process is ignored entirely.
do
  local opts = {
    env = env_from({ HOME = "/home/u", XDG_CONFIG_HOME = "/home/u/.config/mine" }),
    pids = function() return { "10" } end,
    read = function()
      return "HOME=/home/other\0XDG_CONFIG_HOME=/home/other/.config/careca\0"
    end,
    comm = function() return "steam" end,
  }
  assert_eq(slsprofile.config_home(opts), "/home/u/.config/mine",
    "other user ignored")
end

-- A launcher wrapper (no steam comm) offers its XDG as a fallback.
do
  local opts = {
    env = env_from({ HOME = "/home/u" }),
    pids = function() return { "10" } end,
    read = function()
      return "HOME=/home/u\0XDG_CONFIG_HOME=/home/u/.config/launcher\0"
    end,
    comm = function() return "bash" end,
  }
  assert_eq(slsprofile.config_home(opts), "/home/u/.config/launcher",
    "same-home launcher fallback")
end

print("test_slsprofile: ALL PASS")
