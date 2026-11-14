// LM-FRAGMENT slsteam-moon settings tab (makeRow, renderConfig)
// LM-FRAGMENT source fragment of lumen_menu, assembled in order into ONE IIFE
// LM-FRAGMENT by boot.lua (read_menu_js). Not a standalone module. See 01-core.js.


  function makeRow(entry, value, S, onChange) {
    var row = document.createElement("div");
    row.className = "lumen-row";

    var wrap = document.createElement("div");
    wrap.className = "lumen-lblwrap";
    var ks = (S.keys && S.keys[entry.key]) || {};
    var lbl = document.createElement("div");
    lbl.className = "lbl";
    lbl.textContent = ks.label || entry.label || entry.key;
    wrap.appendChild(lbl);
    if (ks.desc) {
      var d = document.createElement("div");
      d.className = "lumen-desc";
      d.textContent = ks.desc;
      wrap.appendChild(d);
    }
    row.appendChild(wrap);

    var ctrl = document.createElement("span");
    ctrl.className = "lumen-ctrl";
    if (entry.type === "bool") {
      var sw = document.createElement("label");
      sw.className = "lumen-sw";
      var cb = document.createElement("input");
      cb.type = "checkbox";
      cb.checked = !!value;
      var sl = document.createElement("span");
      sl.className = "sl";
      cb.addEventListener("change", function () { onChange(cb.checked); });
      sw.appendChild(cb); sw.appendChild(sl);
      ctrl.appendChild(sw);
    } else if (entry.type === "enum") {
      var sel = document.createElement("select");
      (entry.options || []).forEach(function (opt, i) {
        var o = document.createElement("option");
        o.value = String(opt);
        o.textContent = (entry.option_labels && entry.option_labels[i]) || String(opt);
        if (String(opt) === String(value)) o.selected = true;
        sel.appendChild(o);
      });
      sel.addEventListener("change", function () { onChange(Number(sel.value)); });
      ctrl.appendChild(sel);
    } else if (entry.type === "int") {
      var ni = document.createElement("input");
      ni.type = "number";
      var hasMin = typeof entry.min === "number";
      var hasMax = typeof entry.max === "number";
      if (hasMin) ni.min = String(entry.min);
      if (hasMax) ni.max = String(entry.max);
      var clampInt = function (n) {
        n = Math.floor(Number(n) || 0);
        if (hasMin && n < entry.min) n = entry.min;
        if (hasMax && n > entry.max) n = entry.max;
        return n;
      };
      ni.value = String(clampInt(value != null ? value : 0));
      ni.addEventListener("change", function () {
        var v = clampInt(ni.value);
        ni.value = String(v); // reflect the clamp back into the box
        onChange(v);
      });
      ctrl.appendChild(ni);
    } else {
      var ti = document.createElement("input");
      ti.type = "text";
      ti.value = value != null ? String(value) : "";
      ti.addEventListener("change", function () { onChange(ti.value); });
      ctrl.appendChild(ti);
    }
    row.appendChild(ctrl);
    return row;
  }

  function showConfigRestartPrompt(entry, S) {
    var ks = (S.keys && S.keys[entry.key]) || {};
    showConfirm({
      title: ks.restartTitle || S.restartTitle || "Restart Steam?",
      body: ks.restartBody || S.restartBody || "Restart Steam to apply this change.",
      declineText: ks.restartLater || "Later",
      confirmText: ks.restartNow || S.restartConfirm || "Restart Steam",
      onConfirm: function () {
        call("RestartSteam", {}).catch(function (e) { log("RestartSteam", e); });
      },
    });
  }

  function renderConfig(body, config) {
    var S = I18N[pickLang()] || I18N.en;
    body.textContent = "";
    var note = document.createElement("div");
    note.className = "lumen-note";
    note.textContent = S.note;
    body.appendChild(note);

    (config.schema || []).forEach(function (entry) {
      if (entry.hidden) return; // deprecated/no-op keys are parsed but not shown
      var current = (config.values || {})[entry.key];
      if (current === undefined) current = entry.default;
      var row = makeRow(entry, current, S, function (newVal) {
        call("SetSlsConfig", { json: JSON.stringify({ key: entry.key, value: newVal }) })
          .then(function (res) {
            var ok = false;
            try { ok = JSON.parse(res).success; } catch (e) {}
            if (!ok) {
              log("SetSlsConfig failed for", entry.key, res);
              return;
            }
            // Reflect the "Auto-update apps" switch on the Game Updates tab live
            // (grey/ungrey the per-game "Latest"). The restart prompt below is
            // about Steam re-checking updates; this is just the UI mirroring the
            // setting immediately.
            if (entry.key === "AutoUpdateApps" && typeof applyAutoUpdateSetting === "function") {
              applyAutoUpdateSetting(newVal);
            }
            if (entry.restart_on_change) showConfigRestartPrompt(entry, S);
          })
          .catch(function (e) { log("SetSlsConfig error", entry.key, e); });
      });
      body.appendChild(row);
    });

    renderPluginSection(body);
  }

  // A "Plugin" section appended below the slsteam-moon options: Lumen-level
  // plugin toggles (not part of slsteam-moon's config.yaml). A switch for the
  // library-page Fixes Menu, the achievements plugin toggle for added games, a
  // Workshop status row for added games, and the Steam-update guard row. The
  // first switch reads/writes the pref via the LumenGetPluginPrefs /
  // LumenSetPluginPref backend RPCs and applies the change live (the fixes-menu
  // fragment honours window.__lumenFixesMenuEnabled).
  function renderPluginSection(body) {
    var P = (I18N[pickLang()] || I18N.en).plugin || I18N.en.plugin;

    var title = document.createElement("div");
    title.className = "lumen-sub-title";
    title.style.marginTop = "24px";
    title.textContent = P.title;
    body.appendChild(title);

    var row = document.createElement("div");
    row.className = "lumen-row";
    var wrap = document.createElement("div");
    wrap.className = "lumen-lblwrap";
    var lbl = document.createElement("div");
    lbl.className = "lbl";
    lbl.textContent = P.fixesLabel;
    var d = document.createElement("div");
    d.className = "lumen-desc";
    d.textContent = P.fixesDesc;
    wrap.appendChild(lbl);
    wrap.appendChild(d);
    row.appendChild(wrap);

    var ctrl = document.createElement("span");
    ctrl.className = "lumen-ctrl";
    var sw = document.createElement("label");
    sw.className = "lumen-sw";
    var cb = document.createElement("input");
    cb.type = "checkbox";
    cb.checked = window.__lumenFixesMenuEnabled !== false; // optimistic; refined below
    var sl = document.createElement("span");
    sl.className = "sl";
    cb.addEventListener("change", function () {
      var on = cb.checked;
      call("LumenSetPluginPref", { key: "fixes_menu_enabled", value: on }).catch(function () {});
      try {
        window.__lumenFixesMenuEnabled = on;
        if (!on) {
          if (typeof window.__lumenRemoveFixesButton === "function") window.__lumenRemoveFixesButton();
          else { var b = document.getElementById("lumen-fixes-btn"); if (b) b.remove(); }
        }
      } catch (e) {}
    });
    sw.appendChild(cb); sw.appendChild(sl); ctrl.appendChild(sw);
    row.appendChild(ctrl);
    body.appendChild(row);

    // Reflect the stored value.
    call("LumenGetPluginPrefs", {})
      .then(function (res) {
        var p; try { p = JSON.parse(res); } catch (e) {}
        if (p && p.success && p.prefs) {
          cb.checked = p.prefs.fixes_menu_enabled !== false;
          try { window.__lumenFixesMenuEnabled = cb.checked; } catch (e) {}
        }
      })
      .catch(function () {});

    renderAchievementsRow(body);
  }

  // Achievements for games added through AdditionalApps. SLSsteam only spoofs
  // achievements for apps it considers unowned, and its ownership spoof makes
  // the client report them as owned — so Steam returns no achievement list.
  // Turning this on installs a small SLSsteam plugin into the ACTIVE profile
  // (the one the running client reads, which may be a private careca-x64
  // profile); SLSsteam hot-reloads it. Owned games are not affected.
  function renderAchievementsRow(body) {
    var P = (I18N[pickLang()] || I18N.en).plugin || I18N.en.plugin;

    var row = document.createElement("div");
    row.className = "lumen-row";
    var wrap = document.createElement("div");
    wrap.className = "lumen-lblwrap";
    var lbl = document.createElement("div");
    lbl.className = "lbl";
    lbl.textContent = P.achLabel;
    var d = document.createElement("div");
    d.className = "lumen-desc";
    d.textContent = P.achDesc;
    var st = document.createElement("div");
    st.className = "lumen-desc";
    wrap.appendChild(lbl);
    wrap.appendChild(d);
    wrap.appendChild(st);
    row.appendChild(wrap);

    var ctrl = document.createElement("span");
    ctrl.className = "lumen-ctrl";
    var sw = document.createElement("label");
    sw.className = "lumen-sw";
    var cb = document.createElement("input");
    cb.type = "checkbox";
    cb.checked = false;
    cb.disabled = true;
    var sl = document.createElement("span");
    sl.className = "sl";
    sw.appendChild(cb); sw.appendChild(sl); ctrl.appendChild(sw);
    row.appendChild(ctrl);
    body.appendChild(row);

    function render(s) {
      if (typeof s !== "string") s = "";
      if (s) {
        st.textContent = s;
      }
      st.title = "";
    }

    function applyStatus(res) {
      var r; try { r = JSON.parse(res); } catch (e) { return false; }
      if (!r) return false;
      if (!r.success) {
        cb.checked = false;
        cb.disabled = true;
        render((P.achUnavailable || "") + (r.error ? " (" + r.error + ")" : ""));
        return true;
      }
      cb.disabled = false;
      cb.checked = !!r.installed;
      if (!r.installed) {
        render(P.achOff);
      } else if (r.state === "active") {
        render(P.achOn);
      } else if (r.state === "failed") {
        render((P.achFailed || "") + (r.reason || ""));
      } else if (!r.steam) {
        render(P.achNoSteam);
      } else {
        render(P.achPending);
      }
      return true;
    }

    function refresh() {
      call("LumenAchievementsFixStatus", {}).then(function (res) {
        applyStatus(res);
      }).catch(function () {});
    }

    cb.addEventListener("change", function () {
      var want = cb.checked;
      cb.disabled = true;
      call("LumenAchievementsFixSet", { enabled: want }).then(function (res) {
        var r; try { r = JSON.parse(res); } catch (e) { r = null; }
        if (!r || !r.success) {
          cb.checked = !want;
          cb.disabled = false;
          render((P.achError || "") + ((r && r.error) || ""));
          return;
        }
        applyStatus(res);
        // SLSsteam reloads its plugin directory within a second; re-read the
        // status once so the row settles on "active" instead of "pending".
        setTimeout(refresh, 2500);
      }).catch(function () {
        cb.checked = !want;
        cb.disabled = false;
        render(P.achError || "");
      });
    });

    refresh();
    renderWorkshopRow(body);
  }

  // Workshop for added games. Steam's workshop manager only registers apps that
  // have an installed appmanifest at client start: a licensed-but-not-installed
  // added game silently drops SubscribeWorkshopItem (no download, empty Workshop
  // tab). Installing the game and restarting Steam is what makes it register, so
  // this row reports which added games are ready, which need a restart, and
  // which are simply not installed yet. It never writes a manifest.
  function renderWorkshopRow(body) {
    var P = (I18N[pickLang()] || I18N.en).plugin || I18N.en.plugin;

    var row = document.createElement("div");
    row.className = "lumen-row";
    var wrap = document.createElement("div");
    wrap.className = "lumen-lblwrap";
    var lbl = document.createElement("div");
    lbl.className = "lbl";
    lbl.textContent = P.wsLabel;
    var d = document.createElement("div");
    d.className = "lumen-desc";
    d.textContent = P.wsDesc;
    var st = document.createElement("div");
    st.className = "lumen-desc";
    wrap.appendChild(lbl);
    wrap.appendChild(d);
    wrap.appendChild(st);
    row.appendChild(wrap);

    var ctrl = document.createElement("span");
    ctrl.className = "lumen-ctrl";
    var refreshBtn = document.createElement("button");
    refreshBtn.className = "lumen-mbtn";
    refreshBtn.textContent = P.wsRefresh || "Refresh";
    ctrl.appendChild(refreshBtn);
    row.appendChild(ctrl);
    body.appendChild(row);

    var restartBtn = document.createElement("button");
    restartBtn.className = "lumen-mbtn primary";
    restartBtn.textContent = P.wsRestartNow || "Restart Steam";
    restartBtn.addEventListener("click", function () {
      call("RestartSteam", {}).catch(function (e) { log("RestartSteam", e); });
    });

    function show(text, withRestart) {
      st.textContent = text || "";
      if (restartBtn.parentNode) restartBtn.remove();
      if (withRestart) {
        var holder = document.createElement("div");
        holder.className = "lumen-desc";
        holder.style.marginTop = "8px";
        holder.appendChild(restartBtn);
        wrap.appendChild(holder);
      }
    }

    function render(res) {
      var r; try { r = JSON.parse(res); } catch (e) { return; }
      if (!r || !r.success) {
        show((P.wsError || "") + ((r && r.error) || ""));
        return;
      }
      var total = (r.ready || 0) + (r.pending || 0);
      var parts = [];
      if (total > 0) parts.push((P.wsReady || "").replace("%d", r.ready || 0)
        .replace("%d", total));
      if (r.pending > 0) parts.push((P.wsPending || "").replace("%d", r.pending));
      if (r.notInstalled > 0) parts.push((P.wsNotInstalled || "").replace("%d", r.notInstalled));
      if (parts.length === 0) {
        show(P.wsNone || "");
        return;
      }
      show(parts.join(" "), (r.needsRestart || 0) > 0);
    }

    function refresh() {
      refreshBtn.disabled = true;
      call("LumenWorkshopStatus", {}).then(function (res) {
        refreshBtn.disabled = false;
        render(res);
      }).catch(function () { refreshBtn.disabled = false; });
    }

    refreshBtn.addEventListener("click", refresh);
    refresh();
    renderGuardRow(body);
  }

  // Steam-update guard. A client update replaces steamclient.so/steamui.so; the
  // achievements plugin re-patches by pattern and SLSsteam is pattern-matched
  // too. Lumen records the client build it last saw and, when it changes,
  // re-applies the achievements plugin and checks that SLSsteam.so is still
  // mapped. The row shows the last repair so a broken update is visible.
  function renderGuardRow(body) {
    var P = (I18N[pickLang()] || I18N.en).plugin || I18N.en.plugin;

    var row = document.createElement("div");
    row.className = "lumen-row";
    var wrap = document.createElement("div");
    wrap.className = "lumen-lblwrap";
    var lbl = document.createElement("div");
    lbl.className = "lbl";
    lbl.textContent = P.guardLabel;
    var d = document.createElement("div");
    d.className = "lumen-desc";
    d.textContent = P.guardDesc;
    var st = document.createElement("div");
    st.className = "lumen-desc";
    wrap.appendChild(lbl);
    wrap.appendChild(d);
    wrap.appendChild(st);
    row.appendChild(wrap);

    var ctrl = document.createElement("span");
    ctrl.className = "lumen-ctrl";
    var btn = document.createElement("button");
    btn.className = "lumen-mbtn";
    btn.textContent = P.guardCheck || "Check now";
    ctrl.appendChild(btn);
    row.appendChild(ctrl);
    body.appendChild(row);

    function render(res) {
      var r; try { r = JSON.parse(res); } catch (e) { return; }
      if (!r || !r.success) {
        st.textContent = (P.guardError || "") + ((r && r.error) || "");
        return;
      }
      var last = r.last || null;
      if (!last) {
        st.textContent = (P.guardWatching || "").replace("%s", r.build || "?");
        return;
      }
      var same = r.build && last.build && String(r.build) === String(last.build);
      var ach = last.achievements || "none";
      var achText = "";
      if (ach === "current") achText = P.guardAchCurrent || "";
      else if (ach === "reapplied") achText = P.guardAchReapplied || "";
      else if (ach === "disabled") achText = P.guardAchDisabled || "";
      else if (ach.indexOf("failed") === 0) achText = (P.guardAchFailed || "") + ach.slice(7);
      else achText = "";
      var sls = last.slsLoaded ? (P.guardSlsOk || "") : (P.guardSlsMissing || "");
      var head = same
        ? (P.guardChecked || "").replace("%s", r.build || "?")
        : (P.guardUpdated || "").replace("%s", (last.previous || "?")).replace("%s", last.build || "?");
      st.textContent = [head, achText, sls].filter(function (x) { return !!x; }).join(" ");
    }

    function refresh() {
      btn.disabled = true;
      call("LumenSteamUpdateStatus", {}).then(function (res) {
        btn.disabled = false;
        render(res);
      }).catch(function () { btn.disabled = false; });
    }

    btn.addEventListener("click", function () {
      btn.disabled = true;
      call("LumenSteamUpdateCheck", {}).then(function () {
        call("LumenSteamUpdateStatus", {}).then(function (res) {
          btn.disabled = false;
          render(res);
        }).catch(function () { btn.disabled = false; });
      }).catch(function () { btn.disabled = false; });
    });

    refresh();
  }
