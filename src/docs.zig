const std = @import("std");
const evaluator = @import("eval.zig");

pub const DocItem = struct {
    name: []const u8,
    signature: []const u8,
    doc: []const u8,
    kind: DocKind,
};

pub const ModuleInfo = struct {
    name: []const u8,
    items: []const DocItem,
    module_doc: ?[]const u8,
};

pub const DocKind = enum {
    variable,
    field,
};

// ── Single-page HTML generation ─────────────────────────────────────

pub fn writeSinglePageDocs(file: anytype, modules: []const ModuleInfo, allocator: std.mem.Allocator) !void {
    // ── Head + CSS ──
    try file.writeAll(
        \\<!DOCTYPE html>
        \\<html lang="en">
        \\<head>
        \\<meta charset="UTF-8">
        \\<meta name="viewport" content="width=device-width, initial-scale=1.0">
        \\<title>Lazylang &mdash; Standard Library</title>
        \\<style>
        \\:root {
        \\  --bg: #FAF8F5;
        \\  --sidebar-bg: #1C1917;
        \\  --sidebar-hover: #292524;
        \\  --sidebar-active: #44403C;
        \\  --sidebar-text: #D6D3D1;
        \\  --sidebar-text-muted: #78716C;
        \\  --sidebar-border: #292524;
        \\  --accent: #C2410C;
        \\  --accent-hover: #9A3412;
        \\  --accent-light: #FFF7ED;
        \\  --accent-bg: #FFEDD5;
        \\  --text: #1C1917;
        \\  --text-secondary: #57534E;
        \\  --text-muted: #A8A29E;
        \\  --border: #E7E5E4;
        \\  --border-strong: #D6D3D1;
        \\  --code-bg: #F5F5F4;
        \\  --card-bg: #FFFFFF;
        \\  --highlight-bg: #FEF3C7;
        \\  --font-body: 'Charter', 'Bitstream Charter', 'Sitka Text', Georgia, 'Times New Roman', serif;
        \\  --font-ui: -apple-system, BlinkMacSystemFont, 'Segoe UI', Helvetica, Arial, sans-serif;
        \\  --font-code: 'SF Mono', 'Cascadia Code', 'JetBrains Mono', 'Fira Code', Menlo, Monaco, 'Courier New', monospace;
        \\  --sidebar-w: 260px;
        \\}
        \\*, *::before, *::after { margin: 0; padding: 0; box-sizing: border-box; }
        \\html { scroll-padding-top: 24px; }
        \\body {
        \\  font-family: var(--font-body);
        \\  line-height: 1.7;
        \\  color: var(--text);
        \\  background: var(--bg);
        \\}
        \\
        \\/* ── Sidebar ── */
        \\.sidebar {
        \\  position: fixed; top: 0; left: 0; bottom: 0;
        \\  width: var(--sidebar-w);
        \\  background: var(--sidebar-bg);
        \\  color: var(--sidebar-text);
        \\  display: flex; flex-direction: column;
        \\  z-index: 100;
        \\  border-right: 1px solid #000;
        \\}
        \\.sidebar-header {
        \\  padding: 20px 20px 16px;
        \\  border-bottom: 1px solid var(--sidebar-border);
        \\  flex-shrink: 0;
        \\}
        \\.sidebar-header h1 {
        \\  font-family: var(--font-code);
        \\  font-size: 15px;
        \\  font-weight: 600;
        \\  color: #FAFAF9;
        \\  letter-spacing: -0.02em;
        \\}
        \\.sidebar-header span {
        \\  font-family: var(--font-ui);
        \\  font-size: 11px;
        \\  color: var(--sidebar-text-muted);
        \\  display: block;
        \\  margin-top: 2px;
        \\  text-transform: uppercase;
        \\  letter-spacing: 0.08em;
        \\}
        \\.sidebar-search {
        \\  padding: 12px 16px;
        \\  border-bottom: 1px solid var(--sidebar-border);
        \\  flex-shrink: 0;
        \\}
        \\.sidebar-search button {
        \\  width: 100%;
        \\  display: flex; align-items: center; gap: 8px;
        \\  padding: 8px 12px;
        \\  font-family: var(--font-ui);
        \\  font-size: 13px;
        \\  color: var(--sidebar-text-muted);
        \\  background: var(--sidebar-hover);
        \\  border: 1px solid var(--sidebar-border);
        \\  border-radius: 6px;
        \\  cursor: pointer;
        \\  transition: border-color 0.15s, color 0.15s;
        \\}
        \\.sidebar-search button:hover {
        \\  border-color: var(--sidebar-active);
        \\  color: var(--sidebar-text);
        \\}
        \\.sidebar-search kbd {
        \\  margin-left: auto;
        \\  font-family: var(--font-ui);
        \\  font-size: 11px;
        \\  padding: 2px 6px;
        \\  background: var(--sidebar-bg);
        \\  border: 1px solid var(--sidebar-border);
        \\  border-radius: 4px;
        \\  color: var(--sidebar-text-muted);
        \\}
        \\.sidebar-nav {
        \\  flex: 1; overflow-y: auto;
        \\  padding: 8px 0 80px;
        \\}
        \\.sidebar-nav::-webkit-scrollbar { width: 6px; }
        \\.sidebar-nav::-webkit-scrollbar-thumb { background: var(--sidebar-border); border-radius: 3px; }
        \\.sidebar-section {
        \\  padding: 12px 16px 4px;
        \\  font-family: var(--font-ui);
        \\  font-size: 10px;
        \\  font-weight: 600;
        \\  text-transform: uppercase;
        \\  letter-spacing: 0.1em;
        \\  color: var(--sidebar-text-muted);
        \\}
        \\.mod-link {
        \\  display: flex; align-items: center; justify-content: space-between;
        \\  padding: 6px 16px 6px 20px;
        \\  font-family: var(--font-code);
        \\  font-size: 13px;
        \\  font-weight: 500;
        \\  color: var(--sidebar-text);
        \\  text-decoration: none;
        \\  transition: background 0.1s, color 0.1s;
        \\  border-left: 2px solid transparent;
        \\}
        \\.mod-link:hover { background: var(--sidebar-hover); }
        \\.mod-link.active {
        \\  color: #FFF;
        \\  background: var(--sidebar-hover);
        \\  border-left-color: var(--accent);
        \\}
        \\.mod-link .count {
        \\  font-size: 11px;
        \\  color: var(--sidebar-text-muted);
        \\  font-weight: 400;
        \\}
        \\.mod-fns { overflow: hidden; }
        \\.fn-link {
        \\  display: block;
        \\  padding: 3px 16px 3px 36px;
        \\  font-family: var(--font-ui);
        \\  font-size: 12px;
        \\  color: var(--sidebar-text-muted);
        \\  text-decoration: none;
        \\  transition: color 0.1s, background 0.1s;
        \\}
        \\.fn-link:hover { color: var(--sidebar-text); background: var(--sidebar-hover); }
        \\.fn-link.active { color: #FFF; }
        \\
        \\/* ── Main content ── */
        \\.main {
        \\  margin-left: var(--sidebar-w);
        \\  min-height: 100vh;
        \\}
        \\.content {
        \\  max-width: 800px;
        \\  margin: 0 auto;
        \\  padding: 48px 40px 120px;
        \\}
        \\
        \\/* ── Module sections ── */
        \\.module-section {
        \\  padding-top: 8px;
        \\  margin-bottom: 64px;
        \\}
        \\.module-heading {
        \\  font-family: var(--font-code);
        \\  font-size: 28px;
        \\  font-weight: 700;
        \\  color: var(--text);
        \\  letter-spacing: -0.03em;
        \\  padding-bottom: 12px;
        \\  border-bottom: 2px solid var(--text);
        \\  margin-bottom: 24px;
        \\}
        \\.module-doc {
        \\  color: var(--text-secondary);
        \\  margin-bottom: 32px;
        \\  line-height: 1.8;
        \\}
        \\.module-doc p { margin-bottom: 0.8em; }
        \\.module-doc a { color: var(--accent); }
        \\.module-doc code {
        \\  font-family: var(--font-code);
        \\  font-size: 0.88em;
        \\  padding: 2px 6px;
        \\  background: var(--code-bg);
        \\  border-radius: 3px;
        \\}
        \\.module-doc pre {
        \\  background: var(--code-bg);
        \\  border: 1px solid var(--border);
        \\  border-radius: 6px;
        \\  padding: 14px 18px;
        \\  overflow-x: auto;
        \\  margin: 12px 0;
        \\}
        \\.module-doc pre code { background: none; padding: 0; font-size: 0.9em; line-height: 1.6; }
        \\.module-doc li { margin-left: 1.5em; margin-bottom: 0.3em; }
        \\.module-doc strong { font-weight: 600; color: var(--text); }
        \\
        \\/* ── Function entries ── */
        \\.fn-entry {
        \\  background: var(--card-bg);
        \\  border: 1px solid var(--border);
        \\  border-radius: 8px;
        \\  margin-bottom: 16px;
        \\  transition: box-shadow 0.2s, border-color 0.2s;
        \\}
        \\.fn-entry:hover { border-color: var(--border-strong); box-shadow: 0 1px 4px rgba(0,0,0,0.04); }
        \\.fn-entry.highlight {
        \\  border-color: var(--accent);
        \\  box-shadow: 0 0 0 3px var(--accent-bg);
        \\  animation: highlight-fade 1.5s ease-out forwards;
        \\}
        \\@keyframes highlight-fade {
        \\  0% { box-shadow: 0 0 0 3px var(--accent-bg); border-color: var(--accent); }
        \\  100% { box-shadow: none; border-color: var(--border); }
        \\}
        \\.fn-sig {
        \\  display: flex; align-items: baseline; gap: 8px;
        \\  padding: 14px 20px;
        \\  border-bottom: 1px solid var(--border);
        \\  font-family: var(--font-code);
        \\  font-size: 14px;
        \\  line-height: 1.5;
        \\  color: var(--text);
        \\  cursor: pointer;
        \\  position: relative;
        \\}
        \\.fn-sig .fn-name {
        \\  font-weight: 700;
        \\  color: var(--accent);
        \\}
        \\.fn-sig .fn-params { color: var(--text-secondary); font-weight: 400; }
        \\.fn-sig .anchor-icon {
        \\  position: absolute;
        \\  right: 16px;
        \\  opacity: 0;
        \\  color: var(--text-muted);
        \\  font-size: 13px;
        \\  transition: opacity 0.15s;
        \\  font-family: var(--font-ui);
        \\}
        \\.fn-sig:hover .anchor-icon { opacity: 1; }
        \\.fn-doc {
        \\  padding: 16px 20px;
        \\  color: var(--text-secondary);
        \\  line-height: 1.8;
        \\}
        \\.fn-doc p { margin-bottom: 0.7em; }
        \\.fn-doc p:last-child { margin-bottom: 0; }
        \\.fn-doc a { color: var(--accent); }
        \\.fn-doc code {
        \\  font-family: var(--font-code);
        \\  font-size: 0.88em;
        \\  padding: 2px 6px;
        \\  background: var(--code-bg);
        \\  border-radius: 3px;
        \\}
        \\.fn-doc pre {
        \\  background: var(--code-bg);
        \\  border: 1px solid var(--border);
        \\  border-radius: 6px;
        \\  padding: 12px 16px;
        \\  overflow-x: auto;
        \\  margin: 10px 0;
        \\}
        \\.fn-doc pre code { background: none; padding: 0; font-size: 0.9em; line-height: 1.6; }
        \\.fn-doc strong { font-weight: 600; color: var(--text); }
        \\.fn-doc li { margin-left: 1.5em; margin-bottom: 0.3em; }
        \\
        \\/* ── Command palette ── */
        \\.palette-overlay {
        \\  display: none;
        \\  position: fixed; inset: 0;
        \\  z-index: 1000;
        \\  background: rgba(28,25,23,0.5);
        \\  backdrop-filter: blur(4px);
        \\  -webkit-backdrop-filter: blur(4px);
        \\  align-items: flex-start;
        \\  justify-content: center;
        \\  padding-top: min(20vh, 160px);
        \\}
        \\.palette-overlay.open { display: flex; }
        \\.palette {
        \\  width: 560px;
        \\  max-width: calc(100vw - 40px);
        \\  background: var(--card-bg);
        \\  border: 1px solid var(--border-strong);
        \\  border-radius: 12px;
        \\  box-shadow: 0 20px 60px rgba(0,0,0,0.2), 0 0 0 1px rgba(0,0,0,0.05);
        \\  overflow: hidden;
        \\  animation: palette-in 0.15s ease-out;
        \\}
        \\@keyframes palette-in {
        \\  from { opacity: 0; transform: translateY(-8px) scale(0.98); }
        \\  to { opacity: 1; transform: translateY(0) scale(1); }
        \\}
        \\.palette-input-wrap {
        \\  display: flex; align-items: center;
        \\  padding: 0 16px;
        \\  border-bottom: 1px solid var(--border);
        \\}
        \\.palette-input-wrap svg {
        \\  width: 18px; height: 18px;
        \\  color: var(--text-muted);
        \\  flex-shrink: 0;
        \\}
        \\.palette-input {
        \\  flex: 1;
        \\  padding: 14px 12px;
        \\  border: none; outline: none;
        \\  font-family: var(--font-ui);
        \\  font-size: 15px;
        \\  color: var(--text);
        \\  background: transparent;
        \\}
        \\.palette-input::placeholder { color: var(--text-muted); }
        \\.palette-results {
        \\  max-height: 360px;
        \\  overflow-y: auto;
        \\  padding: 6px;
        \\}
        \\.palette-results::-webkit-scrollbar { width: 6px; }
        \\.palette-results::-webkit-scrollbar-thumb { background: var(--border); border-radius: 3px; }
        \\.pr-item {
        \\  display: flex; align-items: center; gap: 10px;
        \\  padding: 8px 12px;
        \\  border-radius: 6px;
        \\  cursor: pointer;
        \\  transition: background 0.08s;
        \\}
        \\.pr-item:hover, .pr-item.selected { background: var(--accent-light); }
        \\.pr-item.selected { outline: 2px solid var(--accent); outline-offset: -2px; }
        \\.pr-badge {
        \\  font-family: var(--font-code);
        \\  font-size: 10px;
        \\  font-weight: 600;
        \\  text-transform: uppercase;
        \\  letter-spacing: 0.04em;
        \\  padding: 2px 6px;
        \\  border-radius: 3px;
        \\  flex-shrink: 0;
        \\}
        \\.pr-badge.mod { background: #DBEAFE; color: #1D4ED8; }
        \\.pr-badge.fn { background: #FFEDD5; color: #C2410C; }
        \\.pr-name {
        \\  font-family: var(--font-code);
        \\  font-size: 13px;
        \\  font-weight: 600;
        \\  color: var(--text);
        \\  white-space: nowrap;
        \\}
        \\.pr-sig {
        \\  font-family: var(--font-code);
        \\  font-size: 12px;
        \\  color: var(--text-muted);
        \\  white-space: nowrap;
        \\  overflow: hidden;
        \\  text-overflow: ellipsis;
        \\}
        \\.pr-hint {
        \\  margin-left: auto;
        \\  font-family: var(--font-ui);
        \\  font-size: 11px;
        \\  color: var(--text-muted);
        \\  white-space: nowrap;
        \\}
        \\.palette-footer {
        \\  display: flex; align-items: center; gap: 16px;
        \\  padding: 10px 16px;
        \\  border-top: 1px solid var(--border);
        \\  font-family: var(--font-ui);
        \\  font-size: 11px;
        \\  color: var(--text-muted);
        \\}
        \\.palette-footer kbd {
        \\  font-family: var(--font-ui);
        \\  font-size: 11px;
        \\  padding: 1px 5px;
        \\  background: var(--code-bg);
        \\  border: 1px solid var(--border);
        \\  border-radius: 3px;
        \\}
        \\.palette-empty {
        \\  padding: 24px 16px;
        \\  text-align: center;
        \\  font-family: var(--font-ui);
        \\  font-size: 13px;
        \\  color: var(--text-muted);
        \\}
        \\
        \\/* ── Responsive ── */
        \\@media (max-width: 768px) {
        \\  .sidebar { display: none; }
        \\  .main { margin-left: 0; }
        \\  .content { padding: 24px 16px 80px; }
        \\}
        \\</style>
        \\</head>
        \\<body>
        \\
    );

    // ── Sidebar ──
    try file.writeAll(
        \\<aside class="sidebar">
        \\  <div class="sidebar-header">
        \\    <h1>lazylang</h1>
        \\    <span>Standard Library</span>
        \\  </div>
        \\  <div class="sidebar-search">
        \\    <button type="button" onclick="openPalette()">
        \\      <svg xmlns="http://www.w3.org/2000/svg" width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><circle cx="11" cy="11" r="8"/><path d="m21 21-4.3-4.3"/></svg>
        \\      Search...
        \\      <kbd>&#8984;K</kbd>
        \\    </button>
        \\  </div>
        \\  <nav class="sidebar-nav">
        \\    <div class="sidebar-section">Modules</div>
        \\
    );

    // Write sidebar module links
    for (modules) |module| {
        try file.writeAll("    <a class=\"mod-link\" href=\"#");
        try file.writeAll(module.name);
        try file.writeAll("\" data-module=\"");
        try file.writeAll(module.name);
        try file.writeAll("\">");
        try file.writeAll(module.name);
        try file.writeAll("<span class=\"count\">");
        var buf: [16]u8 = undefined;
        const count_str = try std.fmt.bufPrint(&buf, "{d}", .{module.items.len});
        try file.writeAll(count_str);
        try file.writeAll("</span></a>\n");

        // Nested function links
        try file.writeAll("    <div class=\"mod-fns\" data-module-fns=\"");
        try file.writeAll(module.name);
        try file.writeAll("\">\n");
        for (module.items) |item| {
            try file.writeAll("      <a class=\"fn-link\" href=\"#");
            try file.writeAll(module.name);
            try file.writeAll(".");
            try file.writeAll(item.name);
            try file.writeAll("\">");
            try file.writeAll(item.name);
            try file.writeAll("</a>\n");
        }
        try file.writeAll("    </div>\n");
    }

    try file.writeAll(
        \\  </nav>
        \\</aside>
        \\
    );

    // ── Main content ──
    try file.writeAll(
        \\<main class="main">
        \\<div class="content">
        \\
    );

    // Write each module section
    for (modules) |module| {
        // Module section
        try file.writeAll("<section class=\"module-section\" id=\"");
        try file.writeAll(module.name);
        try file.writeAll("\">\n");
        try file.writeAll("<h2 class=\"module-heading\">");
        try file.writeAll(module.name);
        try file.writeAll("</h2>\n");

        // Module-level doc
        if (module.module_doc) |doc| {
            if (renderMarkdownToHtml(allocator, doc)) |html| {
                defer allocator.free(html);
                try file.writeAll("<div class=\"module-doc\">");
                try file.writeAll(html);
                try file.writeAll("</div>\n");
            } else |_| {}
        }

        // Function entries
        for (module.items) |item| {
            try file.writeAll("<div class=\"fn-entry\" id=\"");
            try file.writeAll(module.name);
            try file.writeAll(".");
            try file.writeAll(item.name);
            try file.writeAll("\">\n");

            // Signature header - split name from params
            try file.writeAll("<div class=\"fn-sig\" onclick=\"copyAnchor('");
            try file.writeAll(module.name);
            try file.writeAll(".");
            try file.writeAll(item.name);
            try file.writeAll("')\">");
            try file.writeAll("<span class=\"fn-name\">");
            try file.writeAll(item.name);
            try file.writeAll("</span>");

            // Extract params part (everything after "name: ")
            const sig = item.signature;
            const colon_pos = std.mem.indexOf(u8, sig, ": ");
            if (colon_pos) |pos| {
                if (pos + 2 < sig.len) {
                    try file.writeAll("<span class=\"fn-params\">: ");
                    try file.writeAll(sig[pos + 2 ..]);
                    try file.writeAll("</span>");
                }
            }
            try file.writeAll("<span class=\"anchor-icon\">#</span>");
            try file.writeAll("</div>\n");

            // Doc content
            const doc_html = renderMarkdownToHtml(allocator, item.doc) catch null;
            defer if (doc_html) |h| allocator.free(h);
            try file.writeAll("<div class=\"fn-doc\">");
            if (doc_html) |h| {
                try file.writeAll(h);
            } else {
                try file.writeAll(item.doc);
            }
            try file.writeAll("</div>\n");
            try file.writeAll("</div>\n");
        }

        try file.writeAll("</section>\n");
    }

    try file.writeAll(
        \\</div>
        \\</main>
        \\
    );

    // ── Command palette ──
    try file.writeAll(
        \\<div class="palette-overlay" id="palette-overlay">
        \\<div class="palette">
        \\  <div class="palette-input-wrap">
        \\    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><circle cx="11" cy="11" r="8"/><path d="m21 21-4.3-4.3"/></svg>
        \\    <input class="palette-input" id="palette-input" type="text" placeholder="Search modules and functions..." autocomplete="off" spellcheck="false">
        \\  </div>
        \\  <div class="palette-results" id="palette-results"></div>
        \\  <div class="palette-footer">
        \\    <span><kbd>&uarr;</kbd><kbd>&darr;</kbd> navigate</span>
        \\    <span><kbd>&crarr;</kbd> go</span>
        \\    <span><kbd>esc</kbd> close</span>
        \\  </div>
        \\</div>
        \\</div>
        \\
    );

    // ── JavaScript: build search index ──
    try file.writeAll("<script>\nconst MODULES = [\n");
    for (modules) |module| {
        try file.writeAll("  {name:\"");
        try file.writeAll(module.name);
        try file.writeAll("\",items:[\n");
        for (module.items) |item| {
            try file.writeAll("    {name:\"");
            try file.writeAll(item.name);
            try file.writeAll("\",sig:\"");
            try writeJsEscaped(file, item.signature);
            try file.writeAll("\",id:\"");
            try file.writeAll(module.name);
            try file.writeAll(".");
            try file.writeAll(item.name);
            try file.writeAll("\"},\n");
        }
        try file.writeAll("  ]},\n");
    }
    try file.writeAll("];\n");

    // ── JavaScript: palette + sidebar logic ──
    try file.writeAll(
        \\
        \\// ── Palette ──
        \\const overlay = document.getElementById('palette-overlay');
        \\const input = document.getElementById('palette-input');
        \\const resultsEl = document.getElementById('palette-results');
        \\let results = [];
        \\let selIdx = 0;
        \\
        \\function openPalette() {
        \\  overlay.classList.add('open');
        \\  input.value = '';
        \\  input.focus();
        \\  buildResults('');
        \\}
        \\function closePalette() {
        \\  overlay.classList.remove('open');
        \\}
        \\
        \\document.addEventListener('keydown', e => {
        \\  if ((e.metaKey || e.ctrlKey) && e.key === 'k') { e.preventDefault(); openPalette(); }
        \\  if (e.key === 'Escape') closePalette();
        \\});
        \\overlay.addEventListener('click', e => { if (e.target === overlay) closePalette(); });
        \\
        \\function buildResults(q) {
        \\  results = [];
        \\  const ql = q.toLowerCase();
        \\  MODULES.forEach(m => {
        \\    if (!q || m.name.toLowerCase().includes(ql)) {
        \\      results.push({type:'mod', name:m.name, id:m.name});
        \\    }
        \\    m.items.forEach(fn => {
        \\      const full = m.name + '.' + fn.name;
        \\      if (!q || fn.name.toLowerCase().includes(ql) || full.toLowerCase().includes(ql) || fn.sig.toLowerCase().includes(ql)) {
        \\        results.push({type:'fn', name:full, sig:fn.sig, id:fn.id, mod:m.name});
        \\      }
        \\    });
        \\  });
        \\  selIdx = 0;
        \\  renderResults();
        \\}
        \\
        \\function renderResults() {
        \\  if (results.length === 0) {
        \\    resultsEl.innerHTML = '<div class="palette-empty">No results found</div>';
        \\    return;
        \\  }
        \\  const visible = results.slice(0, 50);
        \\  resultsEl.innerHTML = visible.map((r, i) => {
        \\    const sel = i === selIdx ? ' selected' : '';
        \\    if (r.type === 'mod') {
        \\      return `<div class="pr-item${sel}" data-idx="${i}"><span class="pr-badge mod">mod</span><span class="pr-name">${r.name}</span></div>`;
        \\    }
        \\    return `<div class="pr-item${sel}" data-idx="${i}"><span class="pr-badge fn">fn</span><span class="pr-name">${r.name}</span><span class="pr-sig">${esc(r.sig)}</span></div>`;
        \\  }).join('');
        \\
        \\  // Scroll selected into view
        \\  const sel = resultsEl.querySelector('.selected');
        \\  if (sel) sel.scrollIntoView({block:'nearest'});
        \\}
        \\
        \\function esc(s) { return s.replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/"/g,'&quot;'); }
        \\
        \\input.addEventListener('input', () => buildResults(input.value.trim()));
        \\input.addEventListener('keydown', e => {
        \\  if (e.key === 'ArrowDown') { e.preventDefault(); selIdx = Math.min(selIdx + 1, Math.min(results.length - 1, 49)); renderResults(); }
        \\  if (e.key === 'ArrowUp') { e.preventDefault(); selIdx = Math.max(selIdx - 1, 0); renderResults(); }
        \\  if (e.key === 'Enter' && results[selIdx]) { e.preventDefault(); navigateTo(results[selIdx].id); closePalette(); }
        \\});
        \\resultsEl.addEventListener('click', e => {
        \\  const item = e.target.closest('.pr-item');
        \\  if (item) { const idx = +item.dataset.idx; navigateTo(results[idx].id); closePalette(); }
        \\});
        \\
        \\function navigateTo(id) {
        \\  const el = document.getElementById(id);
        \\  if (!el) return;
        \\  fastScrollTo(el);
        \\  el.classList.add('highlight');
        \\  setTimeout(() => el.classList.remove('highlight'), 1500);
        \\  history.replaceState(null, '', '#' + id);
        \\}
        \\function fastScrollTo(el) {
        \\  const start = window.scrollY;
        \\  const end = el.getBoundingClientRect().top + start - 24;
        \\  const dist = end - start;
        \\  const duration = Math.min(100, Math.abs(dist) * 0.08);
        \\  if (duration < 16) { window.scrollTo(0, end); return; }
        \\  const t0 = performance.now();
        \\  function step(now) {
        \\    const p = Math.min((now - t0) / duration, 1);
        \\    const ease = p < 0.5 ? 2*p*p : 1 - Math.pow(-2*p+2, 2)/2;
        \\    window.scrollTo(0, start + dist * ease);
        \\    if (p < 1) requestAnimationFrame(step);
        \\  }
        \\  requestAnimationFrame(step);
        \\}
        \\
        \\function copyAnchor(id) {
        \\  history.replaceState(null, '', '#' + id);
        \\  const url = location.href;
        \\  navigator.clipboard.writeText(url).catch(() => {});
        \\}
        \\
        \\// ── Sidebar active tracking ──
        \\const modLinks = document.querySelectorAll('.mod-link');
        \\const fnLinks = document.querySelectorAll('.fn-link');
        \\const modFns = document.querySelectorAll('.mod-fns');
        \\const sections = document.querySelectorAll('.module-section');
        \\const fnEntries = document.querySelectorAll('.fn-entry');
        \\
        \\function updateSidebar() {
        \\  const scrollY = window.scrollY + 60;
        \\
        \\  // Find active module
        \\  let activeModule = null;
        \\  for (let i = sections.length - 1; i >= 0; i--) {
        \\    if (sections[i].offsetTop <= scrollY) { activeModule = sections[i].id; break; }
        \\  }
        \\
        \\  // Find active function
        \\  let activeFn = null;
        \\  for (let i = fnEntries.length - 1; i >= 0; i--) {
        \\    if (fnEntries[i].offsetTop <= scrollY) { activeFn = fnEntries[i].id; break; }
        \\  }
        \\
        \\  modLinks.forEach(link => {
        \\    const mod = link.dataset.module;
        \\    link.classList.toggle('active', mod === activeModule);
        \\  });
        \\  modFns.forEach(el => {
        \\    const mod = el.dataset.moduleFns;
        \\    el.style.display = mod === activeModule ? '' : 'none';
        \\  });
        \\  fnLinks.forEach(link => {
        \\    link.classList.toggle('active', link.getAttribute('href') === '#' + activeFn);
        \\  });
        \\}
        \\
        \\window.addEventListener('scroll', updateSidebar, {passive: true});
        \\updateSidebar();
        \\
        \\// Intercept sidebar link clicks for fast scroll
        \\document.querySelector('.sidebar-nav').addEventListener('click', e => {
        \\  const a = e.target.closest('a[href^="#"]');
        \\  if (!a) return;
        \\  e.preventDefault();
        \\  const id = a.getAttribute('href').slice(1);
        \\  navigateTo(id);
        \\});
        \\
        \\// ── Handle initial hash ──
        \\if (location.hash) {
        \\  const el = document.getElementById(location.hash.slice(1));
        \\  if (el) { setTimeout(() => { fastScrollTo(el); el.classList.add('highlight'); setTimeout(() => el.classList.remove('highlight'), 1500); }, 50); }
        \\}
        \\</script>
        \\</body>
        \\</html>
        \\
    );
}

fn writeJsEscaped(file: anytype, s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '"' => try file.writeAll("\\\""),
            '\\' => try file.writeAll("\\\\"),
            '\n' => try file.writeAll("\\n"),
            else => try file.writeAll(&[_]u8{c}),
        }
    }
}

// ── Extraction and parsing helpers ──────────────────────────────────

fn extractParamNames(pattern: *const evaluator.Pattern, names: *std.ArrayList([]const u8), allocator: std.mem.Allocator) !void {
    switch (pattern.data) {
        .identifier => |ident| {
            try names.append(allocator, ident);
        },
        .tuple => |tuple| {
            for (tuple.elements) |elem| {
                try extractParamNames(elem, names, allocator);
            }
        },
        else => {},
    }
}

fn buildSignatureFromValue(allocator: std.mem.Allocator, field_name: []const u8, value: evaluator.Value) ![]const u8 {
    var signature = std.ArrayList(u8){};
    defer signature.deinit(allocator);

    try signature.appendSlice(allocator, field_name);
    try signature.appendSlice(allocator, ": ");

    const start_expr: ?*const evaluator.Expression = switch (value) {
        .thunk => |thunk| thunk.expr,
        .function => |func| blk: {
            try appendParamNames(allocator, &signature, func.param);
            break :blk func.body;
        },
        else => null,
    };

    if (start_expr) |expr| {
        var current_expr = expr;
        while (current_expr.data == .lambda) {
            const lambda = current_expr.data.lambda;
            try appendParamNames(allocator, &signature, lambda.param);
            current_expr = lambda.body;
        }
    }

    return signature.toOwnedSlice(allocator);
}

fn appendParamNames(allocator: std.mem.Allocator, signature: *std.ArrayList(u8), pattern: *const evaluator.Pattern) !void {
    var param_names = std.ArrayList([]const u8){};
    defer param_names.deinit(allocator);
    try extractParamNames(pattern, &param_names, allocator);
    for (param_names.items) |param_name| {
        try signature.appendSlice(allocator, param_name);
        try signature.appendSlice(allocator, " \xe2\x86\x92 ");
    }
}

fn extractDocsFromValue(obj: evaluator.ObjectValue, items: *std.ArrayListUnmanaged(DocItem), allocator: std.mem.Allocator) !void {
    for (obj.fields) |field| {
        if (field.doc) |doc| {
            const signature = try buildSignatureFromValue(allocator, field.key, field.value);
            try items.append(allocator, .{
                .name = try allocator.dupe(u8, field.key),
                .signature = signature,
                .doc = try allocator.dupe(u8, doc),
                .kind = .field,
            });
        }
    }
}

pub fn syntaxHighlightCode(allocator: std.mem.Allocator, code: []const u8) ![]const u8 {
    var result = std.ArrayListUnmanaged(u8){};
    errdefer result.deinit(allocator);

    const keywords = [_][]const u8{ "let", "if", "then", "else", "when", "matches", "import", "true", "false", "null" };

    var i: usize = 0;
    while (i < code.len) {
        if (code[i] == '#' or (code[i] == '/' and i + 1 < code.len and code[i + 1] == '/')) {
            try result.appendSlice(allocator, "<span style=\"color:#6a9955\">");
            while (i < code.len and code[i] != '\n') {
                if (code[i] == '<') {
                    try result.appendSlice(allocator, "&lt;");
                } else if (code[i] == '>') {
                    try result.appendSlice(allocator, "&gt;");
                } else if (code[i] == '&') {
                    try result.appendSlice(allocator, "&amp;");
                } else {
                    try result.append(allocator, code[i]);
                }
                i += 1;
            }
            try result.appendSlice(allocator, "</span>");
            continue;
        }

        if (code[i] == '"' or code[i] == '\'') {
            const quote = code[i];
            try result.appendSlice(allocator, "<span style=\"color:#a31515\">");
            try result.append(allocator, quote);
            i += 1;
            while (i < code.len and code[i] != quote) {
                if (code[i] == '\\' and i + 1 < code.len) {
                    try result.append(allocator, code[i]);
                    i += 1;
                    try result.append(allocator, code[i]);
                    i += 1;
                } else {
                    if (code[i] == '<') {
                        try result.appendSlice(allocator, "&lt;");
                    } else if (code[i] == '>') {
                        try result.appendSlice(allocator, "&gt;");
                    } else if (code[i] == '&') {
                        try result.appendSlice(allocator, "&amp;");
                    } else {
                        try result.append(allocator, code[i]);
                    }
                    i += 1;
                }
            }
            if (i < code.len) {
                try result.append(allocator, code[i]);
                i += 1;
            }
            try result.appendSlice(allocator, "</span>");
            continue;
        }

        if (i < code.len and (code[i] >= '0' and code[i] <= '9')) {
            try result.appendSlice(allocator, "<span style=\"color:#098658\">");
            while (i < code.len and ((code[i] >= '0' and code[i] <= '9') or code[i] == '.')) {
                try result.append(allocator, code[i]);
                i += 1;
            }
            try result.appendSlice(allocator, "</span>");
            continue;
        }

        if (i < code.len and ((code[i] >= 'a' and code[i] <= 'z') or (code[i] >= 'A' and code[i] <= 'Z') or code[i] == '_')) {
            const start = i;
            while (i < code.len and ((code[i] >= 'a' and code[i] <= 'z') or (code[i] >= 'A' and code[i] <= 'Z') or (code[i] >= '0' and code[i] <= '9') or code[i] == '_')) {
                i += 1;
            }
            const word = code[start..i];

            var is_keyword = false;
            for (keywords) |kw| {
                if (std.mem.eql(u8, word, kw)) {
                    is_keyword = true;
                    break;
                }
            }

            if (is_keyword) {
                try result.appendSlice(allocator, "<span style=\"color:#0000ff\">");
                try result.appendSlice(allocator, word);
                try result.appendSlice(allocator, "</span>");
            } else {
                try result.appendSlice(allocator, word);
            }
            continue;
        }

        if (code[i] == '<') {
            try result.appendSlice(allocator, "&lt;");
        } else if (code[i] == '>') {
            try result.appendSlice(allocator, "&gt;");
        } else if (code[i] == '&') {
            try result.appendSlice(allocator, "&amp;");
        } else if (code[i] == '-' and i + 1 < code.len and code[i + 1] == '>') {
            try result.appendSlice(allocator, "<span style=\"color:#0000ff\">-&gt;</span>");
            i += 2;
            continue;
        } else {
            try result.append(allocator, code[i]);
        }
        i += 1;
    }

    return result.toOwnedSlice(allocator);
}

fn renderInlineMarkdown(allocator: std.mem.Allocator, result: *std.ArrayListUnmanaged(u8), text: []const u8) !void {
    var i: usize = 0;
    while (i < text.len) {
        if (text[i] == '`') {
            const start_pos = i;
            const start = i + 1;
            i += 1;
            while (i < text.len and text[i] != '`') : (i += 1) {}
            if (i < text.len) {
                try result.appendSlice(allocator, "<code>");
                try result.appendSlice(allocator, text[start..i]);
                try result.appendSlice(allocator, "</code>");
                i += 1;
                continue;
            }
            i = start_pos;
        }

        if (text[i] == '[') {
            const start_pos = i;
            const start = i + 1;
            i += 1;
            while (i < text.len and text[i] != ']') : (i += 1) {}
            if (i < text.len) {
                const func_name = text[start..i];
                try result.appendSlice(allocator, "<a href=\"#");
                try result.appendSlice(allocator, func_name);
                try result.appendSlice(allocator, "\">");
                try result.appendSlice(allocator, func_name);
                try result.appendSlice(allocator, "</a>");
                i += 1;
                continue;
            }
            i = start_pos;
        }

        if (i + 1 < text.len and text[i] == '*' and text[i + 1] == '*') {
            const start_pos = i;
            const start = i + 2;
            i += 2;
            while (i + 1 < text.len and !(text[i] == '*' and text[i + 1] == '*')) : (i += 1) {}
            if (i + 1 < text.len) {
                try result.appendSlice(allocator, "<strong>");
                try result.appendSlice(allocator, text[start..i]);
                try result.appendSlice(allocator, "</strong>");
                i += 2;
                continue;
            }
            i = start_pos;
        }

        if (text[i] == '<') {
            try result.appendSlice(allocator, "&lt;");
        } else if (text[i] == '>') {
            try result.appendSlice(allocator, "&gt;");
        } else if (text[i] == '&') {
            try result.appendSlice(allocator, "&amp;");
        } else {
            try result.append(allocator, text[i]);
        }
        i += 1;
    }
}

pub fn renderMarkdownToHtml(allocator: std.mem.Allocator, markdown: []const u8) ![]const u8 {
    var result = std.ArrayListUnmanaged(u8){};
    errdefer result.deinit(allocator);

    var i: usize = 0;
    var in_code_block = false;
    var code_block_start: usize = 0;
    var line_start: usize = 0;

    while (i < markdown.len) {
        if (i + 2 < markdown.len and markdown[i] == '`' and markdown[i + 1] == '`' and markdown[i + 2] == '`') {
            if (in_code_block) {
                const code = markdown[code_block_start..i];
                const highlighted = try syntaxHighlightCode(allocator, code);
                defer allocator.free(highlighted);

                try result.appendSlice(allocator, "<pre><code>");
                try result.appendSlice(allocator, highlighted);
                try result.appendSlice(allocator, "</code></pre>\n");
                in_code_block = false;
            } else {
                in_code_block = true;
            }
            i += 3;
            while (i < markdown.len and markdown[i] != '\n') : (i += 1) {}
            if (i < markdown.len) i += 1;
            if (in_code_block) {
                code_block_start = i;
            }
            line_start = i;
            continue;
        }

        if (in_code_block) {
            i += 1;
            continue;
        }

        if (markdown[i] == '\n') {
            const line = markdown[line_start..i];
            const trimmed = std.mem.trimLeft(u8, line, " \t");

            if (std.mem.startsWith(u8, trimmed, "#")) {
                var level: usize = 0;
                var j: usize = 0;
                while (j < trimmed.len and trimmed[j] == '#') : (j += 1) {
                    level += 1;
                }
                if (j < trimmed.len and trimmed[j] == ' ') {
                    const heading_text = std.mem.trim(u8, trimmed[j + 1 ..], " \t");
                    const tag = switch (level) {
                        1 => "h1",
                        2 => "h2",
                        3 => "h3",
                        4 => "h4",
                        5 => "h5",
                        else => "h6",
                    };
                    try result.appendSlice(allocator, "<");
                    try result.appendSlice(allocator, tag);
                    try result.appendSlice(allocator, " style=\"margin-top:1.5em;margin-bottom:0.5em\">");
                    try renderInlineMarkdown(allocator, &result, heading_text);
                    try result.appendSlice(allocator, "</");
                    try result.appendSlice(allocator, tag);
                    try result.appendSlice(allocator, ">\n");
                    i += 1;
                    line_start = i;
                    continue;
                }
            }

            if (std.mem.startsWith(u8, trimmed, "- ")) {
                try result.appendSlice(allocator, "<li>");
                try renderInlineMarkdown(allocator, &result, trimmed[2..]);
                try result.appendSlice(allocator, "</li>\n");
            } else if (line.len > 0) {
                try result.appendSlice(allocator, "<p>");
                try renderInlineMarkdown(allocator, &result, line);
                try result.appendSlice(allocator, "</p>\n");
            } else {
                try result.appendSlice(allocator, "\n");
            }

            i += 1;
            line_start = i;
            continue;
        }

        i += 1;
    }

    if (line_start < markdown.len) {
        const line = markdown[line_start..];
        const trimmed = std.mem.trimLeft(u8, line, " \t");

        if (std.mem.startsWith(u8, trimmed, "#")) {
            var level: usize = 0;
            var j: usize = 0;
            while (j < trimmed.len and trimmed[j] == '#') : (j += 1) {
                level += 1;
            }
            if (j < trimmed.len and trimmed[j] == ' ') {
                const heading_text = std.mem.trim(u8, trimmed[j + 1 ..], " \t");
                const tag = switch (level) {
                    1 => "h1",
                    2 => "h2",
                    3 => "h3",
                    4 => "h4",
                    5 => "h5",
                    else => "h6",
                };
                try result.appendSlice(allocator, "<");
                try result.appendSlice(allocator, tag);
                try result.appendSlice(allocator, " style=\"margin-top:1.5em;margin-bottom:0.5em\">");
                try renderInlineMarkdown(allocator, &result, heading_text);
                try result.appendSlice(allocator, "</");
                try result.appendSlice(allocator, tag);
                try result.appendSlice(allocator, ">");
            }
        } else if (std.mem.startsWith(u8, trimmed, "- ")) {
            try result.appendSlice(allocator, "<li>");
            try renderInlineMarkdown(allocator, &result, trimmed[2..]);
            try result.appendSlice(allocator, "</li>");
        } else if (line.len > 0) {
            try result.appendSlice(allocator, "<p>");
            try renderInlineMarkdown(allocator, &result, line);
            try result.appendSlice(allocator, "</p>");
        }
    }

    return result.toOwnedSlice(allocator);
}

// ── Module collection ───────────────────────────────────────────────

pub fn collectModulesFromDirectory(
    allocator: std.mem.Allocator,
    dir_path: []const u8,
    modules: *std.ArrayList(ModuleInfo),
    stdout: anytype,
) !void {
    var dir = try std.fs.cwd().openDir(dir_path, .{ .iterate = true });
    defer dir.close();

    var walker = try dir.walk(allocator);
    defer walker.deinit();

    while (try walker.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.basename, ".lazy")) continue;

        const full_path = try std.fs.path.join(allocator, &[_][]const u8{ dir_path, entry.path });
        defer allocator.free(full_path);

        try stdout.print("Extracting docs from {s}...\n", .{full_path});
        const module_info = try extractModuleInfo(allocator, full_path);
        try modules.append(allocator, module_info);
    }
}

pub fn extractModuleInfo(
    allocator: std.mem.Allocator,
    input_path: []const u8,
) !ModuleInfo {
    const source = try std.fs.cwd().readFileAlloc(allocator, input_path, 100 * 1024 * 1024);
    defer allocator.free(source);

    const directory = std.fs.path.dirname(input_path);
    var result = try evaluator.evalInlineWithValueAndDir(allocator, source, directory);
    defer result.deinit();

    if (result.err) |err| return err;

    const value = result.value;
    const module_name = try allocator.dupe(u8, std.fs.path.stem(input_path));

    switch (value) {
        .object => |obj| {
            var doc_items = std.ArrayListUnmanaged(DocItem){};
            try extractDocsFromValue(obj, &doc_items, allocator);

            const module_doc: ?[]const u8 = if (obj.module_doc) |doc|
                try allocator.dupe(u8, doc)
            else
                null;

            return ModuleInfo{
                .name = module_name,
                .items = try doc_items.toOwnedSlice(allocator),
                .module_doc = module_doc,
            };
        },
        else => {
            return ModuleInfo{
                .name = module_name,
                .items = &.{},
                .module_doc = null,
            };
        },
    }
}
