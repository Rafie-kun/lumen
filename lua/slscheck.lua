-- slscheck: backend for the "slsteam-moon not loaded" warning modal.
--
-- Exposes two RPCs (registered into the CDP dispatch registry by register()),
-- each returning a JSON string per the callServerMethod convention:
--   GetSlsLoaded()  -> {success, loaded, client64}  is SLSsteam.so mapped in?
--   RunSlsAutofix() -> {success[, error, incompatible64, terminal]}  open a
--                      terminal + auto-fix
--
-- The menu (menu/13-sls-check.js) calls GetSlsLoaded the moment the moon button
-- anchors; if slsteam-moon didn't inject, it shows a modal offering the auto-fix
-- (RunSlsAutofix), which re-installs the latest slsteam-moon, repairs every
-- *steam*.desktop launcher and relaunches Steam injected.
--
-- That auto-fix only makes sense for the 32-bit client: slsteam-moon ships a
-- 32-bit SLSsteam.so, and the 64-bit client (steamrt64/steam) rejects it with
-- "wrong ELF class: ELFCLASS32". When the running client is 64-bit, client64 is
-- true and RunSlsAutofix refuses with an explanation instead of reinstalling
-- something that cannot load.
--
-- Detection lives in proc.lib_mapped (a /proc/<pid>/maps scan of the running
-- `steam` client) and proc.exe_path (the client executable, for arch). The
-- terminal-launch machinery is reused verbatim from about.lua so a single
-- implementation covers "Update All" and this auto-fix.
local json = require("json")
local proc = require("proc")
local about = require("about")
local privatefs = require("privatefs")

local slscheck = {}

-- The main Steam client process (comm, exact) and the library we look for in
-- its address space. slsteam-moon loads via LD_AUDIT at preinit, so by the time
-- the moon button anchors it is definitely mapped if the session is injected.
slscheck.STEAM_COMM = "steam"
slscheck.LIB_NEEDLE = "SLSsteam.so"

-- Path fragment of the 64-bit Steam runtime client. Upstream slsteam-moon
-- builds a 32-bit SLSsteam.so only; LD_AUDIT rejects it in a 64-bit client with
-- "wrong ELF class: ELFCLASS32", so its auto-fix cannot inject anything there
-- (and used to leave the user with a "reinstalled but still unlicensed"
-- session). Detect that client and refuse the misleading fix.
slscheck.STEAM64_MARKER = "/steamrt64/"

-- The auto-fix script, served from the slsteam-moon repo's raw branch URL (like
-- install.sh) so fixes go live without cutting a new release. The main line is
-- the branch literally named `slsteam-moon`.
slscheck.AUTOFIX_URL =
  "https://raw.githubusercontent.com/swwayps/slsteam-moon/slsteam-moon/autofix.sh"

-- Single-quote a token for safe POSIX-shell interpolation.
local function shq(s)
  return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

-- client_exe(opts) -> path|nil. opts.exe (injectable) wins; otherwise read
-- /proc/<pid>/exe of the running `steam` process (opts.root overrides /proc).
function slscheck.client_exe(opts)
  opts = opts or {}
  if opts.exe then return opts.exe() end
  return proc.exe_path(slscheck.STEAM_COMM, opts.root)
end

-- is_64bit_client(opts) -> boolean. True when the running client's executable
-- lives under steamrt64/, where a 32-bit library cannot be audited in.
function slscheck.is_64bit_client(opts)
  local path = slscheck.client_exe(opts)
  return type(path) == "string"
    and path:find(slscheck.STEAM64_MARKER, 1, true) ~= nil
end

-- is_loaded(opts) -> boolean. opts.mapped is injectable for tests; by default it
-- scans /proc for SLSsteam.so in the running `steam` process.
function slscheck.is_loaded(opts)
  opts = opts or {}
  local mapped = opts.mapped
    or function() return proc.lib_mapped(slscheck.STEAM_COMM, slscheck.LIB_NEEDLE) end
  return mapped() and true or false
end

-- get_loaded(opts) -> JSON string {success=true, loaded=<bool>, client64=<bool>}.
-- client64 lets the menu explain the situation instead of offering a fix that
-- cannot work. It is only probed when nothing is loaded (the healthy path stays
-- cheap and never reads another process's exe link).
function slscheck.get_loaded(opts)
  opts = opts or {}
  local loaded = slscheck.is_loaded(opts)
  return json.encode({
    success = true,
    loaded = loaded,
    client64 = (not loaded) and slscheck.is_64bit_client(opts) or false,
  })
end

-- The bash script the terminal runs: fetch + run autofix.sh. autofix.sh owns its
-- own success pause and the Steam relaunch, so we only pause here when the fetch
-- itself failed (no network), to keep the error on screen. No user-controlled
-- input is interpolated (the URL is a constant), so this is injection-safe.
function slscheck.autofix_script(url)
  local run = "curl -fsSL " .. shq(url) .. " | bash"
  return table.concat({
    "#!/usr/bin/env bash",
    "set -u",
    'echo "slsteam-moon auto-fix"',
    "echo",
    run,
    "status=$?",
    'if [ "$status" -ne 0 ]; then',
    "  echo",
    '  echo "Auto-fix could not start (exit $status). Check your internet connection."',
    '  read -rp "Press Enter to close this window… " _',
    "fi",
    "",
  }, "\n")
end

-- run_autofix(opts) -> table {success[, error, terminal]}. opts (injectable for
-- tests): which (PATH probe), write_file, spawn, tmp_path. Reuses about.lua's
-- terminal detection + detached-launch helpers.
function slscheck.run_autofix(opts)
  opts = opts or {}
  local which = opts.which or function(bin)
    local f = io.popen("command -v " .. shq(bin) .. " 2>/dev/null", "r")
    if not f then return false end
    local out = f:read("*a") or ""
    f:close()
    return out:gsub("%s+", "") ~= ""
  end
  -- See about.update_all: this script is executed by a terminal, so it is
  -- created privately (O_EXCL|O_NOFOLLOW, 0700) under a random name instead of a
  -- guessable /tmp path any local process could pre-create.
  local write_file = opts.write_file or privatefs.write_script
  local spawn = opts.spawn or function(cmd) return os.execute(cmd) end

  -- Architecture guard: slsteam-moon (and its autofix.sh) ship a 32-bit
  -- SLSsteam.so. A 64-bit client rejects it at LD_AUDIT ("wrong ELF class:
  -- ELFCLASS32"), so running the fix here would reinstall it and still leave
  -- added games showing Buy. Refuse with an explanation instead.
  local is64 = opts.is_64bit_client or function()
    return slscheck.is_64bit_client(opts)
  end
  if is64() then
    local exe = slscheck.client_exe(opts)
    return {
      success = false,
      incompatible64 = true,
      client64 = true,
      exe = exe,
      error = "This Steam session runs the 64-bit client"
        .. (exe and (" (" .. tostring(exe) .. ")") or "")
        .. ", but slsteam-moon only ships a 32-bit SLSsteam.so, which Steam "
        .. "rejects with \"wrong ELF class: ELFCLASS32\". The auto-fix cannot "
        .. "inject it. Use a 64-bit (multi-arch) SLSsteam build and launch "
        .. "Steam through it instead.",
    }
  end

  local term = about.detect_terminal(which)
  if not term then
    return {
      success = false,
      error = "No terminal emulator found. Run the auto-fix manually: "
        .. "curl -fsSL " .. slscheck.AUTOFIX_URL .. " | bash",
    }
  end

  local script = opts.tmp_path or privatefs.temp_script_path("lumen-slsfix")
  if not script then
    return { success = false, error = "Could not create a private working directory." }
  end
  if not write_file(script, slscheck.autofix_script(slscheck.AUTOFIX_URL)) then
    return { success = false, error = "Could not write the auto-fix script." }
  end

  spawn(about.build_command(about.launch_argv(term, script)))
  return { success = true, terminal = term.bin }
end

-- register(registry): install GetSlsLoaded / RunSlsAutofix. Args from the
-- dispatcher are ignored (both are parameterless).
function slscheck.register(registry)
  registry.GetSlsLoaded = function() return slscheck.get_loaded() end
  registry.RunSlsAutofix = function() return json.encode(slscheck.run_autofix()) end
  return registry
end

return slscheck
