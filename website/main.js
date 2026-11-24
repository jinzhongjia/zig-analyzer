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

// Copy buttons copy the text in the data-copy attribute of their container, or the container's
// code when the attribute is empty.
document.querySelectorAll("[data-copy] .copy").forEach(function (button) {
  button.addEventListener("click", function () {
    var block = button.closest("[data-copy]");
    var text = block.dataset.copy || block.querySelector("code").textContent;
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

// Tabs, with arrow-key navigation as in the WAI-ARIA tabs pattern; each tab list works on its own.
document.querySelectorAll('[role="tablist"]').forEach(function (list) {
  var tabs = Array.prototype.slice.call(list.querySelectorAll('[role="tab"]'));

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

  // Windows visitors see the Scoop tab of the install methods first.
  var scoop = list.querySelector("#t-scoop");
  if (scoop && /Windows/.test(navigator.userAgent)) select(scoop);
});

// Syntax highlighting of the code blocks marked with data-lang. Each language is a list of
// [class, pattern] rules; at each position the first rule that matches wins, and the patterns use
// no capturing groups, so that the group number of a match tells its rule.
(function () {
  var str = /"(?:\\.|[^"\\\n])*"/;
  var sq = /'(?:\\.|[^'\\\n])*'/;
  var num = /\b\d+(?:\.\d+)?\b/;
  var rules = {
    json: [["com", /\/\/[^\n]*/], ["key", /"(?:\\.|[^"\\\n])*"(?=\s*:)/], ["str", str], ["nu", num], ["kw", /\b(?:true|false|null)\b/]],
    zon: [["com", /\/\/[^\n]*/], ["str", str], ["kw", /\b(?:true|false|null)\b/],
          ["enum", /(?<==\s*)\.[A-Za-z_]\w*/], ["key", /\.[A-Za-z_]\w*/], ["nu", num]],
    lua: [["com", /--[^\n]*/], ["str", str], ["str", sq], ["kw", /\b(?:local|function|end|return|true|false|nil)\b/],
          ["fn", /\b[A-Za-z_][\w.]*(?=\s*\()/], ["key", /\b[A-Za-z_]\w*(?=\s*=(?!=))/], ["nu", num]],
    vim: [["com", /^[ \t]*"[^\n]*/], ["str", sq], ["kw", /\b(?:let|call|v:true|v:false)\b/], ["kw", /^[ \t]*Plug\b/],
          ["va", /\bg:\w+/], ["fn", /\b[\w#]+(?=\()/], ["nu", num]],
    elisp: [["com", /;[^\n]*/], ["str", str], ["key", /:[\w-]+/], ["fn", /(?<=\()[\w-]+/], ["kw", /\bnil\b|\bt\b/]],
    toml: [["com", /#[^\n]*/], ["str", str], ["fn", /^\[\[?[^\]\n]+\]\]?/], ["key", /^[\w.-]+(?=\s*=)/], ["kw", /\b(?:true|false)\b/], ["nu", num]],
  };

  function escape(s) {
    return s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
  }

  document.querySelectorAll("code[data-lang]").forEach(function (code) {
    var list = rules[code.dataset.lang];
    if (!list) return;
    var re = new RegExp(list.map(function (r) { return "(" + r[1].source + ")"; }).join("|"), "gm");
    var text = code.textContent;
    var out = "";
    var last = 0;
    var m;
    while ((m = re.exec(text)) !== null) {
      if (m[0] === "") { re.lastIndex++; continue; }
      var i = 1;
      while (m[i] === undefined) i++;
      out += escape(text.slice(last, m.index)) + '<span class="' + list[i - 1][0] + '">' + escape(m[0]) + "</span>";
      last = re.lastIndex;
    }
    code.innerHTML = out + escape(text.slice(last));
  });
})();
