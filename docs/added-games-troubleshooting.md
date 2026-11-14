# Added games: Workshop, ownership tickets, update loops

Notes from the Linux SLSsteam stack tested here: SLSsteam (Careca x64 build) +
LuaTools (luatools-moon) + slsteam-moon + Lumen. "Added game" means a game
injected with a licence and an ownership spoof because the account does not own
it; `steamapps/appmanifest_<appid>.acf` is written by the LuaTools downloader
when the game is installed.

## 1. Workshop does not work for an added game

### Symptoms

- Subscribing to an item errors, or reports success and never downloads.
- The game's Workshop tab is missing or stays empty.

### Root cause (verified on this machine)

Steam's workshop manager builds its per-app set **when the client starts**, from
the installed-app registry (`steamapps/appmanifest_<appid>.acf`), not from
licences. SLSsteam's injection produces a licence and an ownership spoof, so the
game shows up in the library and `ISteamApps::BIsSubscribedApp()` returns true,
but with no manifest the app is never registered with the workshop manager:

- `SubscribeWorkshopItem()` is silently dropped: no `workshop_log.txt` line for
  that AppID, no `steamapps/workshop/appworkshop_<appid>.acf`, no download.
- There is no UI error because the call itself returns without a result.

The experiment that proves the gate: with Starbound (211820) licensed but no
manifest, the client wrote zero workshop log lines for it. After writing a
minimal `appmanifest_211820.acf` and restarting Steam, the client registered the
app at login, picked up the subscription made earlier, fetched item info,
downloaded 31 chunks (27 MB) and logged:

```
[AppID 211820] Starting Workshop download job (downloading  )
[AppID 211820] Finished Workshop download job : No Error
```

An owned game (Project Zomboid, 108600) worked throughout, which rules out the
workshop subsystem, the depot keys and the CDN.

### Workaround that works today

1. Install the game first (LuaTools' downloader writes the appmanifest), so the
   app is in the installed registry.
2. **Restart Steam after the install.** Registration happens at client start,
   so a subscription made in the same session as the install is not enough.
3. Subscribe (in the client or on the Workshop page). The first subscription
   creates `appworkshop_<appid>.acf` and the download starts immediately.

If it still does not work, check `~/.steam/steam/logs/workshop_log.txt`:

- no `[AppID <id>]` line at all → the app was not registered at start: manifest
  missing or in a different library than the one Steam started with;
- `Loaded workshop items ... (0 installed, 0 needed)` then no download →
  subscription is not in the server-side list: subscribe again from the client
  with the game registered.

### What Lumen shows

The settings menu now has a **Workshop for added games** row (Plugin section).
It reports how many installed added games have Workshop state, how many have
none yet, and how many are not installed at all, with a **Restart Steam** button
when a manifest was written after this client started. It is read-only.

### Why Lumen does not invent an appmanifest

A manifest carries `buildid`, `installdir`, `LastUpdated`, depot entries and
byte counts. None of that is derivable from an appid, and a wrong manifest makes
Steam plan a verify/update against depots the account cannot authorize — which
can rewrite or wipe the game folder. Install-then-restart is the safe path, so
that is what the UI recommends.

## 2. `AppID <id> failed to update ownership ticket (Access Denied)`

Logged by Steam's content manager in `logs/content_log.txt`, once per added app
per session, right when an update for that app starts.

It is **non-fatal**. The client asks Steam for a fresh app ownership ticket to
authorize the content update; the account does not own the app, so the request is
denied. SLSsteam's ownership spoof answers the game-facing check but does not
produce a server-signed ticket. The update itself proceeds on the injected
depot keys: for Metro Anomaly (4612650) the run that logged the denial finished
with `Finished ... No Error`.

Nothing to fix locally. If a game refuses to start because it validates a
ticket, that is a different problem (the game is asking for something a spoof
cannot provide).

## 3. `4612650` "Update Required" loop

The app was re-queued for update on every Steam start, then reported success
without changing anything. The cause was an inconsistent manifest: the client
compared the installed state against the depot's target build and always found a
pending update.

After the manifest was made self-consistent, the queued update ran once and
cleared:

- `StateFlags 4` (fully installed)
- `buildid` == `TargetBuildID` (26624333)
- `BytesToDownload` == `BytesDownloaded` (176/176)
- `BytesToStage` == `BytesStaged` (109336576)

with a single `removed from schedule (result No Error)` and no re-queue on later
starts. The ownership-ticket denial above appeared in that same run and did not
block it.

If this happens again: compare `buildid`/`TargetBuildID` and the byte counters
in `appmanifest_<id>.acf`; a `StateFlags` of 4 with mismatched counters is the
signature. Letting the queued update finish once is enough; repeatedly cancelling
it keeps the loop alive.

## 4. After a Steam client update

A Steam update replaces `steamclient.so`/`steamui.so`. Two things follow:

- **Lumen re-attaches by itself.** The injector follows the new CEF targets, so
  the menu comes back without a Lumen restart.
- **The achievements plugin is re-applied by Lumen's update guard.** It records
  the client build (`package/steam_client_steamrt64.manifest` `version`) in
  `~/.local/share/Lumen/steam-client-build` and, when the build changes,
  verifies the plugin status and reinstalls it if it is stale.

What Lumen cannot repair is the closed SLSsteam/Careca library: it is
pattern-matched against the client and there is no source to rebuild. The guard
therefore reads `~/.SLSsteam.log` (truncated each session) for SLSsteam's own
abort markers — `Failed to find all patterns`, `Failed to find steam exports`,
`Failed to parse VFTables` — and the Plugin section reports:

- "SLSsteam is loaded" when the library is mapped and no marker is present;
- "SLSsteam could not hook this Steam build" when a marker is present — install
  a newer SLSsteam/Careca pack;
- "SLSsteam is NOT loaded" when the library is not mapped at all.

The **Check now** button runs the same pass on demand, so a user can confirm the
state right after an update instead of waiting for the 15-second poll.

## 5. Achievements for added games

Fixed and shipped as this repo's Lumen toggle plus an upstream SLSsteam patch:

- upstream: `AceSLS/SLSsteam` branch `fix/added-app-achievements`, commit
  `62bfde3`, pull request <https://github.com/AceSLS/SLSsteam/pull/177>
- Lumen: `lua/slsachievements.lua` installs `zz-luatools-achievements.lua` into
  the active SLSsteam profile; the Plugin section has the toggle.
