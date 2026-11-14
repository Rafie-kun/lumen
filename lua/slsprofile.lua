-- slsprofile: find the SLSsteam profile the RUNNING Steam client is using.
--
-- Lumen runs in its own process, so it does not inherit Steam's environment.
-- The 64-bit launchers (slsteam-moon, SLSsteam-Careca-x64) start Steam with
-- XDG_CONFIG_HOME pointing at a private profile, e.g.
--   XDG_CONFIG_HOME=$HOME/.config/SLSsteam-careca-x64
-- because SLSsteam reads $XDG_CONFIG_HOME/SLSsteam. Editing the default
-- ~/.config/SLSsteam then changes a file the injected client never reads:
-- toggles look applied but have no effect.
--
-- Resolution order (mirrors LuaTools' backend/sls_profile.lua):
--   1. SLSSTEAM_CONFIG_HOME (explicit override, same layout as XDG_CONFIG_HOME)
--   2. XDG_CONFIG_HOME of the running `steam` process (same HOME only)
--   3. XDG_CONFIG_HOME of another same-HOME process (launcher wrappers)
--   4. our own XDG_CONFIG_HOME
--   5. $HOME/.config
--
-- The returned directory is the one that CONTAINS the `SLSsteam` directory
-- (XDG_CONFIG_HOME semantics). Another user's Steam process is ignored.
local lfs = require("lfs")

local M = {}

-- Main client process names: the 64-bit runtime starts `steamrt64/steam` but
-- keeps comm `steam`; helpers are `steamwebhelper`.
local STEAM_COMMS = { steam = true, steamwebhelper = true }

local function default_read(path)
  local file = io.open(path, "rb")
  if not file then return nil end
  local data = file:read("*a")
  file:close()
  return data
end

local function default_comm(pid)
  local file = io.open("/proc/" .. tostring(pid) .. "/comm", "rb")
  if not file then return nil end
  local name = file:read("*l")
  file:close()
  return name
end

-- lfs closes the directory object only when the iterator runs to the end, so
-- close it explicitly as well (a second close is guarded and harmless).
local function default_pids(root)
  local pids = {}
  local ok, iter, dir_obj = pcall(lfs.dir, root or "/proc")
  if not ok then return pids end
  for entry in iter, dir_obj do
    if entry:match("^%d+$") then pids[#pids + 1] = entry end
  end
  if dir_obj then pcall(function() dir_obj:close() end) end
  return pids
end

-- Parse a NUL-separated environ blob. Replacing NULs keeps the pattern engine
-- away from embedded NULs (older LuaJIT builds treat them as end of subject).
local function environ_value(blob, key)
  if type(blob) ~= "string" then return nil end
  local text = blob:gsub("%z", "\n")
  for item in text:gmatch("[^\n]+") do
    if item:sub(1, #key + 1) == key .. "=" then
      return item:sub(#key + 2)
    end
  end
  return nil
end

-- config_home(opts) -> string|nil
-- opts (all optional, for tests): pids(), read(path), comm(pid), env(name), home.
function M.config_home(opts)
  opts = opts or {}
  local env = opts.env or os.getenv
  local read = opts.read or default_read
  local comm = opts.comm or default_comm
  local pids = opts.pids or default_pids
  local home = opts.home or env("HOME") or ""

  local explicit = env("SLSSTEAM_CONFIG_HOME")
  if explicit and explicit ~= "" then return explicit end

  if home ~= "" then
    local fallback
    local ok, list = pcall(pids)
    if ok and type(list) == "table" then
      for _, pid in ipairs(list) do
        local blob = read("/proc/" .. tostring(pid) .. "/environ")
        if blob then
          local proc_home = environ_value(blob, "HOME")
          if proc_home == home then
            local xdg = environ_value(blob, "XDG_CONFIG_HOME")
            local okc, name = pcall(comm, pid)
            if not okc then name = nil end
            if name ~= nil and STEAM_COMMS[name] == true then
              if xdg and xdg ~= "" then return xdg end
              -- The running client has no private profile: this is the default
              -- ~/.config layout, so stop looking for another process.
              return home .. "/.config"
            end
            if fallback == nil and xdg and xdg ~= "" then fallback = xdg end
          end
        end
      end
    end
    if fallback then return fallback end
  end

  local own = env("XDG_CONFIG_HOME")
  if own and own ~= "" then return own end
  if home == "" then return nil end
  return home .. "/.config"
end

-- root(opts) -> "<config home>/SLSsteam" | nil
function M.root(opts)
  local base = M.config_home(opts)
  if not base then return nil end
  return base .. "/SLSsteam"
end

return M
