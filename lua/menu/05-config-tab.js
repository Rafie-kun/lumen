  function renderConfig(body, config) {
    // Ensure config is always a proper object
    if (!config || typeof config !== 'object') config = {};
    if (config === null) config = {};
    var S = I18N[pickLang()] || I18N.en;
    body.textContent = "";
    var note = document.createElement("div");
    note.className = "lumen-note";
    note.textContent = S.note;
    body.appendChild(note);

    try {
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
    } catch(e) {
      console.error("renderConfig error:", e);
    }

    renderPluginSection(body);
  }
