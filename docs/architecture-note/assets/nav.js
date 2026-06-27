/* MosaicPhotos 設計資料 — 共通ナビ注入・Mermaid 初期化・コードリンク解決
 *
 * 各ページは <head> で以下を宣言してから本スクリプトを読み込む：
 *   window.DOCROOT = "../";      // このページから docs/architecture-note/ への相対パス
 *   window.PAGE    = "arch-overview"; // NAV の id（サイドバーのハイライト・前後ナビ用）
 */
(function () {
  var DOCROOT = window.DOCROOT || "";
  // リポジトリルートは docs/architecture-note/ の 2 つ上。
  var CODEROOT = DOCROOT + "../../";

  // ---- サイトのページ構成（ここが唯一の目次定義） ----
  var NAV = [
    { title: "はじめに", items: [
      { id: "index", href: "index.html", label: "概要・歩き方" },
    ]},
    { title: "アーキテクチャ", items: [
      { id: "arch-overview",   href: "architecture/overview.html",   label: "全体アーキテクチャ" },
      { id: "arch-packages",   href: "architecture/packages.html",   label: "パッケージと依存関係" },
      { id: "arch-concurrency",href: "architecture/concurrency.html",label: "並行性とアクター分離" },
      { id: "arch-data-flow",  href: "architecture/data-flow.html",  label: "データの流れと起動" },
    ]},
    { title: "主要機能", items: [
      { id: "feat-photo-sources", href: "features/photo-sources.html", label: "写真ソースの統一" },
      { id: "feat-grid-viewer",   href: "features/grid-viewer.html",   label: "グリッドと全画面ビューア" },
      { id: "feat-dropbox",       href: "features/dropbox.html",       label: "Dropbox 連携" },
      { id: "feat-on-device-ai",  href: "features/on-device-ai.html",  label: "オンデバイス AI" },
      { id: "feat-backup",        href: "features/backup.html",        label: "バックアップ" },
      { id: "feat-places",        href: "features/places.html",        label: "場所アルバム" },
      { id: "feat-caching",       href: "features/caching.html",       label: "キャッシュ戦略" },
      { id: "feat-diagnostics",   href: "features/diagnostics.html",   label: "診断と堅牢性" },
    ]},
    { title: "技術プライマー", items: [
      { id: "tech-observation",   href: "tech/swift-observation.html",        label: "Swift Observation" },
      { id: "tech-swiftdata",     href: "tech/swiftdata.html",                label: "SwiftData" },
      { id: "tech-photoskit",     href: "tech/photoskit.html",                label: "PhotosKit" },
      { id: "tech-clip",          href: "tech/clip-embeddings.html",          label: "CLIP と埋め込み" },
      { id: "tech-coreml-fm",     href: "tech/coreml-foundationmodels.html",  label: "Core ML / Foundation Models" },
      { id: "tech-oauth",         href: "tech/oauth-pkce.html",               label: "OAuth2 + PKCE" },
      { id: "tech-spm",           href: "tech/spm-modularization.html",       label: "SPM モジュール分割" },
    ]},
    { title: "設計判断・事例", items: [
      { id: "adr",            href: "design-decisions/adr.html",            label: "設計判断の記録 (ADR)" },
      { id: "case-memory",    href: "case-studies/memory.html",             label: "事例: メモリ枯渇の解消" },
      { id: "case-launch",    href: "case-studies/launch-performance.html", label: "事例: 起動の高速化" },
    ]},
    { title: "付録", items: [
      { id: "appx-glossary",    href: "appendix/glossary.html",    label: "用語集" },
      { id: "appx-conventions", href: "appendix/conventions.html", label: "規約とテスト方針" },
    ]},
  ];

  var current = window.PAGE || "";

  // ---- サイドバー描画 ----
  var html = '<a class="brand" href="' + DOCROOT + 'index.html">'
           + '<span class="title">MosaicPhotos 設計資料</span>'
           + '<span class="sub">Architecture Note</span></a>';
  NAV.forEach(function (sec) {
    html += '<div class="nav-section"><h3>' + sec.title + '</h3><ul>';
    sec.items.forEach(function (it) {
      var cls = it.id === current ? ' class="active"' : '';
      html += '<li><a href="' + DOCROOT + it.href + '"' + cls + '>' + it.label + '</a></li>';
    });
    html += '</ul></div>';
  });
  var sb = document.getElementById("sidebar");
  if (sb) sb.innerHTML = html;

  // ---- モバイル開閉 ----
  var toggle = document.createElement("button");
  toggle.id = "menu-toggle";
  toggle.setAttribute("aria-label", "メニュー");
  toggle.textContent = "☰";
  toggle.addEventListener("click", function () { document.body.classList.toggle("nav-open"); });
  document.body.appendChild(toggle);
  document.addEventListener("click", function (e) {
    if (document.body.classList.contains("nav-open") &&
        !e.target.closest("#sidebar") && e.target !== toggle) {
      document.body.classList.remove("nav-open");
    }
  });

  // ---- 前後ナビ ----
  var flat = [];
  NAV.forEach(function (s) { s.items.forEach(function (i) { flat.push(i); }); });
  var idx = flat.findIndex(function (i) { return i.id === current; });
  var pager = document.getElementById("pager");
  if (pager && idx >= 0) {
    var prev = flat[idx - 1], next = flat[idx + 1];
    var out = "";
    out += prev ? '<a class="prev" href="' + DOCROOT + prev.href + '"><span class="dir">← 前へ</span><br><span class="lbl">' + prev.label + '</span></a>' : '<span></span>';
    out += next ? '<a class="next" href="' + DOCROOT + next.href + '"><span class="dir">次へ →</span><br><span class="lbl">' + next.label + '</span></a>' : '<span></span>';
    pager.innerHTML = out;
  }

  // ---- コードリンク解決：<a class="srclink" data-path="Packages/.../Foo.swift"> ----
  document.querySelectorAll("a.srclink").forEach(function (a) {
    var p = a.getAttribute("data-path");
    if (p) a.setAttribute("href", CODEROOT + p);
  });

  // ---- Mermaid 読み込み・初期化 ----
  if (document.querySelector(".mermaid")) {
    var m = document.createElement("script");
    m.src = "https://cdn.jsdelivr.net/npm/mermaid@10/dist/mermaid.min.js";
    m.onload = function () {
      try {
        window.mermaid.initialize({ startOnLoad: false, theme: "neutral", securityLevel: "loose" });
        window.mermaid.run();
      } catch (e) { /* オフライン等で CDN 不達なら図はテキストのまま表示される */ }
    };
    document.head.appendChild(m);
  }
})();
