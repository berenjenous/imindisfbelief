// Injected at document start into every frame. Only observes; does not change behaviour.
(function () {
  if (window.__diagInstalled) return;
  window.__diagInstalled = true;

  // FIX: WebRune (Kotlin/JS) closes OPFS directory iterators by calling
  // iterator.return() or iterator[Symbol.asyncDispose](). Safari has neither,
  // so WebRune throws NoSuchElementException and stays on "LOADING".
  // Add a no-op return()/asyncDispose to the directory-iterator prototype.
  (function patchDirIterators() {
    try {
      if (!(navigator.storage && navigator.storage.getDirectory)) return;
      navigator.storage.getDirectory().then(function (root) {
        ["entries", "values", "keys"].forEach(function (m) {
          if (typeof root[m] !== "function") return;
          var proto = Object.getPrototypeOf(root[m]());
          if (typeof proto.return !== "function") {
            Object.defineProperty(proto, "return", {
              configurable: true, writable: true,
              value: function (v) { return Promise.resolve({ done: true, value: v }); }
            });
          }
          if (typeof Symbol.asyncDispose === "symbol" && typeof proto[Symbol.asyncDispose] !== "function") {
            Object.defineProperty(proto, Symbol.asyncDispose, {
              configurable: true, writable: true,
              value: function () { return Promise.resolve(); }
            });
          }
        });
        try { window.webkit.messageHandlers.diag.postMessage({ level: "fix", msg: "OPFS iterator patch applied in " + location.pathname }); } catch (e) {}
      });
    } catch (e) {}
  })();
  var where = (window === window.top ? "main" : "iframe") + " " + location.pathname;
  function send(level, msg) {
    try { window.webkit.messageHandlers.diag.postMessage({ level: level, msg: String(msg) }); } catch (e) {}
  }
  function fmt(args) {
    return Array.prototype.map.call(args, function (a) {
      if (a instanceof Error) return a.name + ": " + a.message + "\n" + (a.stack || "");
      if (typeof a === "object") { try { return JSON.stringify(a); } catch (e) { return String(a); } }
      return String(a);
    }).join(" ");
  }
  ["log", "info", "warn", "error", "debug"].forEach(function (lvl) {
    var orig = console[lvl];
    console[lvl] = function () {
      send(lvl, fmt(arguments));
      return orig.apply(console, arguments);
    };
  });
  window.addEventListener("error", function (e) {
    send("onerror", (e.message || "") + " @ " + (e.filename || "") + ":" + (e.lineno || "") +
      (e.error && e.error.stack ? "\n" + e.error.stack : ""));
  }, true);
  window.addEventListener("unhandledrejection", function (e) {
    var r = e.reason;
    send("rejection", r && r.stack ? r.message + "\n" + r.stack : String(r));
  });

  send("info", "diag hooks installed in " + where +
    " | WebGL2=" + (function () { try { return !!document.createElement("canvas").getContext("webgl2"); } catch (e) { return "err"; } })() +
    " | OPFS=" + !!(navigator.storage && navigator.storage.getDirectory) +
    " | crossOriginIsolated=" + self.crossOriginIsolated);

  // Hide WebRune's on-screen virtual gamepad while a physical controller is connected.
  // WebRune shows it whenever the screen is touch ("pointer: coarse") and never checks
  // for controllers. WebKit only reports a controller after one of its buttons is pressed.
  (function autoHideVirtualPad() {
    var css = ".virtual-gamepad{display:none!important}";
    var styleEl = null, last = null;
    function hasPad() {
      try {
        var pads = navigator.getGamepads ? navigator.getGamepads() : [];
        for (var i = 0; i < pads.length; i++) if (pads[i] && pads[i].connected) return true;
      } catch (e) {}
      return false;
    }
    function update() {
      var on = hasPad();
      if (on === last) return;
      last = on;
      if (on) {
        if (!styleEl) { styleEl = document.createElement("style"); styleEl.textContent = css; }
        (document.head || document.documentElement).appendChild(styleEl);
      } else if (styleEl && styleEl.parentNode) {
        styleEl.parentNode.removeChild(styleEl);
      }
      send("pad", where + " physical controller " + (on ? "connected -> virtual pad hidden" : "not connected -> virtual pad shown"));
    }
    window.addEventListener("gamepadconnected", update);
    window.addEventListener("gamepaddisconnected", update);
    setInterval(update, 1000);
  })();

  // WASM memory growth tracking (the runner can grow up to 2 GB)
  try {
    var g = WebAssembly.Memory.prototype.grow;
    WebAssembly.Memory.prototype.grow = function (pages) {
      var before = this.buffer.byteLength;
      try {
        var r = g.call(this, pages);
        send("mem", "wasm grow OK " + (before / 1048576).toFixed(0) + " -> " + (this.buffer.byteLength / 1048576).toFixed(0) + " MB");
        return r;
      } catch (err) {
        send("mem", "wasm grow FAILED at " + (before / 1048576).toFixed(0) + " MB (+" + (pages * 64 / 1024).toFixed(0) + " MB): " + err);
        throw err;
      }
    };
  } catch (e) { send("warn", "could not hook Memory.grow: " + e); }

  // WASM instantiate / compile failures
  ["instantiate", "instantiateStreaming", "compile", "compileStreaming"].forEach(function (fn) {
    var o = WebAssembly[fn];
    if (!o) return;
    WebAssembly[fn] = function () {
      send("wasm", fn + " called");
      return o.apply(WebAssembly, arguments).then(function (r) { send("wasm", fn + " OK"); return r; },
        function (err) { send("wasm", fn + " FAILED: " + err); throw err; });
    };
  });

  // Storage estimate once the page is up
  setTimeout(function () {
    if (navigator.storage && navigator.storage.estimate) {
      navigator.storage.estimate().then(function (e) {
        send("storage", where + " usage " + (e.usage / 1048576).toFixed(0) + " MB / quota " + (e.quota / 1048576).toFixed(0) + " MB");
      });
    }
    if (navigator.storage && navigator.storage.persisted) {
      navigator.storage.persisted().then(function (p) { send("storage", "persisted=" + p); });
    }
  }, 3000);

  // Heartbeat: shows whether the frame's JS thread is still alive while "LOADING"
  var n = 0;
  setInterval(function () { n++; if (n % 5 === 0) send("beat", where + " alive " + n * 2 + "s"); }, 2000);
})();
