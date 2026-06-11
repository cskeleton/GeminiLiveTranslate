"use strict";

// --- State ---
var currentDelay = 0;
var autoMode = true;
var manualDelay = 2.0;
var serverPort = 18930;
var showOSD = true;
var pollTimer = null;
var failCount = 0;
var initialized = false;

// --- Plugin Initialization ---
function init() {
  try {
    autoMode = iina.preferences.get("autoMode");
    if (autoMode === null || autoMode === undefined) autoMode = true;
    serverPort = parseInt(iina.preferences.get("serverPort") || "18930", 10);
    manualDelay = parseFloat(iina.preferences.get("manualDelay") || "2.0");
    showOSD = iina.preferences.get("showOSD");
    if (showOSD === null || showOSD === undefined) showOSD = true;

    iina.console.log("[GeminiSync] Plugin loaded. autoMode=" + autoMode + " port=" + serverPort);

    setupMenu();

    if (autoMode) {
      startPolling();
    }

    // --- Seek or file change → flush stale translated audio ---
    iina.event.on("mpv.seek", function () {
      iina.console.log("[GeminiSync] Seek → sending flush");
      sendFlush();
    });

    iina.event.on("mpv.file-loaded", function () {
      iina.console.log("[GeminiSync] File loaded → sending flush");
      sendFlush();
      if (currentDelay > 0) {
        iina.mpv.set("audio-delay", -currentDelay);
      }
    });

    // --- Resume from pause → recalibrate latency ---
    iina.event.on("mpv.unpaused", function () {
      iina.console.log("[GeminiSync] Unpaused → sending resume signal");
      sendResume();
      if (currentDelay > 0) {
        iina.mpv.set("audio-delay", -currentDelay);
      }
    });

    initialized = true;
    iina.console.log("[GeminiSync] Initialization complete");
  } catch (e) {
    iina.console.log("[GeminiSync] Init error: " + e);
  }
}

// --- Flush: clear stale audio buffers (seek/file-change only) ---
function sendFlush() {
  var url = "http://127.0.0.1:" + serverPort + "/flush";
  iina.http.post(url, {}).then(function () {
    iina.console.log("[GeminiSync] Flush acknowledged");
  }).catch(function () {
    // Server might not be running, ignore
  });
}

// --- Resume: recalibrate latency after pause ---
function sendResume() {
  var url = "http://127.0.0.1:" + serverPort + "/resume";
  iina.http.post(url, {}).then(function () {
    iina.console.log("[GeminiSync] Resume acknowledged");
  }).catch(function () {
    // Server might not be running, ignore
  });
}

// --- HTTP Polling ---
function startPolling() {
  if (pollTimer) return;
  failCount = 0;
  iina.console.log("[GeminiSync] Starting HTTP polling on port " + serverPort);
  pollOnce();
  pollTimer = setInterval(pollOnce, 500);
}

function stopPolling() {
  if (pollTimer) {
    clearInterval(pollTimer);
    pollTimer = null;
    iina.console.log("[GeminiSync] Stopped polling");
  }
}

function pollOnce() {
  var url = "http://127.0.0.1:" + serverPort + "/";
  iina.http.get(url, {}).then(function (res) {
    try {
      var data = res.data;
      if (typeof data === "string") {
        data = JSON.parse(data);
      }
      if (failCount > 0) {
        iina.console.log("[GeminiSync] Connection restored");
      }
      failCount = 0;
      handleLatencyUpdate(data);
    } catch (e) {
      iina.console.log("[GeminiSync] Parse error: " + e);
    }
  }).catch(function (err) {
    failCount++;
    if (failCount === 1) {
      iina.console.log("[GeminiSync] HTTP request failed: " + err);
    }
    if (failCount > 6 && currentDelay > 0) {
      setDelay(0);
      if (showOSD) {
        iina.core.osd("GeminiLiveSync: connection lost");
      }
    }
  });
}

// --- Latency Handling ---
function handleLatencyUpdate(data) {
  if (!autoMode) return;

  if (data.isTranslating === false) {
    if (currentDelay > 0) {
      setDelay(0);
      if (showOSD) {
        iina.core.osd("GeminiLiveSync: translation stopped");
      }
    }
    return;
  }

  if (typeof data.latency === "number" && data.latency > 0) {
    setDelay(data.latency);
  }
}

function setDelay(seconds) {
  var rounded = Math.round(seconds * 10) / 10;
  if (Math.abs(rounded - currentDelay) < 0.05) return;

  var oldDelay = currentDelay;
  currentDelay = rounded;
  iina.mpv.set("audio-delay", -rounded);
  iina.console.log("[GeminiSync] Delay set: " + oldDelay.toFixed(1) + "s -> " + rounded.toFixed(1) + "s");

  if (showOSD && rounded > 0) {
    iina.core.osd("Video delay: " + rounded.toFixed(1) + "s");
  }
}

// --- Menu Items ---
function setupMenu() {
  iina.menu.addItem(
    iina.menu.item("Gemini Sync: Auto Mode", toggleAutoMode)
  );
  iina.menu.addItem(
    iina.menu.item("Gemini Sync: Delay +0.5s", function () { adjustManualDelay(0.5); })
  );
  iina.menu.addItem(
    iina.menu.item("Gemini Sync: Delay -0.5s", function () { adjustManualDelay(-0.5); })
  );
  iina.menu.addItem(
    iina.menu.item("Gemini Sync: Reset Delay", function () {
      autoMode = false;
      iina.preferences.set("autoMode", false);
      iina.preferences.sync();
      stopPolling();
      setDelay(0);
      if (showOSD) iina.core.osd("GeminiSync: delay reset");
    })
  );
  iina.menu.addItem(
    iina.menu.item("Gemini Sync: Reconnect", function () {
      failCount = 0;
      if (autoMode) startPolling();
    })
  );
  iina.console.log("[GeminiSync] Menu items registered");
}

function toggleAutoMode() {
  autoMode = !autoMode;
  iina.preferences.set("autoMode", autoMode);
  iina.preferences.sync();
  iina.console.log("[GeminiSync] Auto mode: " + autoMode);
  if (autoMode) {
    startPolling();
    if (showOSD) iina.core.osd("GeminiSync: auto mode ON");
  } else {
    stopPolling();
    setDelay(0);
    if (showOSD) iina.core.osd("GeminiSync: auto mode OFF");
  }
}

function adjustManualDelay(delta) {
  autoMode = false;
  iina.preferences.set("autoMode", false);
  stopPolling();
  manualDelay = Math.max(0, currentDelay + delta);
  iina.preferences.set("manualDelay", manualDelay.toString());
  iina.preferences.sync();
  iina.console.log("[GeminiSync] Manual delay: " + manualDelay.toFixed(1) + "s");
  setDelay(manualDelay);
}

// --- Entry Point ---
init();
