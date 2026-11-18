// Theme toggle: flips between light and dark and stores the choice; without one the system theme applies.
(function () {
  var root = document.documentElement;
  var dark = window.matchMedia("(prefers-color-scheme: dark)");
  var meta = document.querySelectorAll('meta[name="theme-color"]');

  function current() {
    return root.dataset.theme || (dark.matches ? "dark" : "light");
  }

  function syncThemeColor() {
    var color = current() === "dark" ? "#121212" : "#ffffff";
    meta.forEach(function (m) { m.setAttribute("content", color); });
  }

  document.getElementById("theme-toggle").addEventListener("click", function () {
    var next = current() === "dark" ? "light" : "dark";
    root.dataset.theme = next;
    try { localStorage.setItem("theme", next); } catch (e) {}
    syncThemeColor();
  });

  dark.addEventListener("change", syncThemeColor);
  if (root.dataset.theme) syncThemeColor();
})();

// Copy buttons copy the command in the data-copy attribute of their container.
document.querySelectorAll("[data-copy] .copy").forEach(function (button) {
  button.addEventListener("click", function () {
    var text = button.closest("[data-copy]").dataset.copy;
    navigator.clipboard.writeText(text).then(function () {
      button.textContent = "Copied";
      button.classList.add("done");
      setTimeout(function () {
        button.textContent = "Copy";
        button.classList.remove("done");
      }, 1500);
    });
  });
});

// Install tabs, with arrow-key navigation as in the WAI-ARIA tabs pattern.
(function () {
  var tabs = Array.prototype.slice.call(document.querySelectorAll('[role="tab"]'));

  function select(tab) {
    tabs.forEach(function (t) {
      var on = t === tab;
      t.setAttribute("aria-selected", String(on));
      t.tabIndex = on ? 0 : -1;
      document.getElementById(t.getAttribute("aria-controls")).hidden = !on;
    });
  }

  tabs.forEach(function (tab, i) {
    tab.addEventListener("click", function () { select(tab); });
    tab.addEventListener("keydown", function (e) {
      var j = e.key === "ArrowRight" ? i + 1 : e.key === "ArrowLeft" ? i - 1 : null;
      if (j === null) return;
      var next = tabs[(j + tabs.length) % tabs.length];
      select(next);
      next.focus();
    });
  });

  // Windows visitors see the Scoop tab first.
  if (/Windows/.test(navigator.userAgent)) select(document.getElementById("t-scoop"));
})();
