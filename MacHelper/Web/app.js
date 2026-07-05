(function () {
  "use strict";

  // ───────── 연결 ─────────
  const statusEl = document.getElementById("status");
  const dot = document.getElementById("dot");
  let ws = null, reconnectTimer = null;
  let latencyMs = null, pingTimer = null;
  const pendingPings = new Map();
  let networkUIRefresh = null;   // 설정 모달이 열려 있을 때 자동 프리셋 변경을 반영

  function connect() {
    // https(테일스케일 serve 등)로 열렸으면 wss 로 — 아니면 ws
    const proto = location.protocol === "https:" ? "wss" : "ws";
    ws = new WebSocket(`${proto}://${location.host}/ws`);
    ws.onopen = () => {
      setStatus(true);
      send({ t: "hello", name: "Safari" });
      send({ t: "getDeck" });
      startPing();
    };
    ws.onclose = () => { stopPing(); setStatus(false); scheduleReconnect(); };
    ws.onerror = () => { try { ws.close(); } catch (e) {} };
    ws.onmessage = (ev) => {
      try {
        const m = JSON.parse(ev.data);
        if (m.t === "deck") {
          if (m.json && m.json.folders) { deck = m.json; saveLocal(); renderDeck(); }
          else { pushDeckToServer(); }   // 서버에 덱 없음 → 현재 덱으로 시드
        } else if (m.t === "apps") {
          installedApps = m.list || [];
          if (appsPickerRefresh) appsPickerRefresh();
        } else if (m.t === "cmux") {
          const snapshot = JSON.stringify(m);
          if (snapshot !== lastCmuxJSON) {   // 변경 없으면 리렌더 생략 (폴링 깜빡임 방지)
            lastCmuxJSON = snapshot;
            cmuxState = m;
            renderCmux();
          }
        } else if (m.t === "capture") {
          const capBox = document.getElementById("cap-result");
          if (capBox) capBox.innerHTML = m.data
            ? '<img src="data:image/jpeg;base64,' + m.data + '" alt="맥 화면"><div class="cap-note">이미지를 길게 눌러 저장·복사</div>'
            : '<div class="cap-note">캡처 실패 — 맥의 화면 기록 권한을 확인하세요 (시스템 설정 → 개인정보 보호 및 보안 → 화면 기록)</div>';
        } else if (m.t === "ocr") {
          const ocrBox = document.getElementById("cap-result");
          if (ocrBox) ocrBox.innerHTML = m.text
            ? '<div class="cap-note">✓ 맥 클립보드에 복사됨</div><textarea readonly>' + String(m.text).replace(/</g, "&lt;") + '</textarea>'
            : '<div class="cap-note">인식된 텍스트가 없습니다</div>';
        } else if (m.t === "pong") {
          const sent = pendingPings.get(m.id);
          if (sent) {
            pendingPings.delete(m.id);
            latencyMs = Math.max(1, Math.round(performance.now() - sent));
            setStatus(true);
            applyAutoTier();   // "자동" 프리셋이면 RTT에 맞춰 주사율/보정 조정
            const lat = document.getElementById("set-latency");
            if (lat) lat.textContent = latencyMs + "ms";
          }
        }
      } catch (e) {}
    };
  }
  function scheduleReconnect() { clearTimeout(reconnectTimer); reconnectTimer = setTimeout(connect, 1000); }
  function setStatus(ok) {
    statusEl.textContent = ok ? ("연결됨" + (latencyMs ? " · " + latencyMs + "ms" : "")) : "연결 끊김 · 재시도 중…";
    dot.className = "dot" + (ok ? " on" : "");
  }
  function send(obj) { if (ws && ws.readyState === WebSocket.OPEN) ws.send(JSON.stringify(obj)); }
  function startPing() {
    stopPing();
    const ping = () => {
      const id = "p" + Math.random().toString(36).slice(2, 9);
      pendingPings.set(id, performance.now());
      send({ t: "ping", id });
      for (const [key, value] of pendingPings) {
        if (performance.now() - value > 10000) pendingPings.delete(key);
      }
    };
    ping();
    pingTimer = setInterval(ping, 3000);
  }
  function stopPing() {
    if (pingTimer) clearInterval(pingTimer);
    pingTimer = null;
    pendingPings.clear();
    latencyMs = null;
  }

  // ───────── 페이지 확대(핀치/더블탭) 강제 차단 ─────────
  // iOS 사파리는 viewport 메타를 무시하므로 gesture 이벤트를 직접 막아야 함.
  ["gesturestart", "gesturechange", "gestureend"].forEach((ev) =>
    document.addEventListener(ev, (e) => e.preventDefault(), { passive: false }));
  // 멀티터치 핀치(스크롤 영역 밖) 방지
  document.addEventListener("touchmove", (e) => {
    if (e.touches.length > 1 && !e.target.closest("#trackpad")) e.preventDefault();
  }, { passive: false });

  // ───────── 설정 (감도 등, 기기별 localStorage) ─────────
  const SETTINGS_KEY = "macpilot.settings.v2";
  const SETTINGS_DEFAULTS = {
    moveSpeed: 1.15,
    accel: 0.045,
    scrollSpeed: 1.0,
    scrollDir: 1,
    theme: "dark",
    networkPreset: "auto",
    pointerHz: 60,
    pointerSmoothing: 0.16,
    resolutionScale: 1.0,
    airSensitivity: 1.2,   // 에어마우스(자이로) 감도
    sheetPos: 0,        // 트랙패드 시트 위치 (0=풀, 1=닫힘, 중간=부분)
    sheetOpenPos: 0,    // 마지막으로 열어둔 높이
    layoutMode: "auto"  // 화면 모드: auto(폭 기준) | phone | tablet
  };
  const NETWORK_PRESETS = {
    auto: { label: "자동" },   // RTT 기반 — 아래 AUTO_TIERS 로 실시간 조정
    fast: { label: "빠른 Wi-Fi", pointerHz: 120, pointerSmoothing: 0.06, resolutionScale: 1.05 },
    balanced: { label: "균형", pointerHz: 60, pointerSmoothing: 0.16, resolutionScale: 1.0 },
    stable: { label: "불안정한 네트워크", pointerHz: 36, pointerSmoothing: 0.26, resolutionScale: 0.92 },
    manual: { label: "수동", pointerHz: 60, pointerSmoothing: 0.16, resolutionScale: 1.0 }
  };
  // "자동": 3초마다 측정되는 RTT로 전송 주사율을 고른다. 좋은 Wi-Fi(<8ms)면 120Hz까지 올라감.
  // 측정 편차로 프리셋이 널뛰지 않게 한 번에 한 단계씩만 이동.
  const AUTO_TIERS = [
    { maxRtt: 12, pointerHz: 120, pointerSmoothing: 0.04 },
    { maxRtt: 30, pointerHz: 90, pointerSmoothing: 0.08 },
    { maxRtt: 60, pointerHz: 60, pointerSmoothing: 0.14 },
    { maxRtt: Infinity, pointerHz: 36, pointerSmoothing: 0.24 }
  ];
  let autoTierIdx = -1;
  function applyAutoTier() {
    if (settings.networkPreset !== "auto" || latencyMs == null) return;
    let idx = AUTO_TIERS.findIndex((t) => latencyMs <= t.maxRtt);
    if (idx < 0) idx = AUTO_TIERS.length - 1;
    if (autoTierIdx === -1) autoTierIdx = idx;
    else if (idx > autoTierIdx) autoTierIdx++;
    else if (idx < autoTierIdx) autoTierIdx--;
    const tier = AUTO_TIERS[autoTierIdx];
    if (settings.pointerHz === tier.pointerHz && settings.pointerSmoothing === tier.pointerSmoothing) return;
    settings.pointerHz = tier.pointerHz;
    settings.pointerSmoothing = tier.pointerSmoothing;
    if (networkUIRefresh) networkUIRefresh();
  }
  let settings = loadSettings();
  function loadSettings() {
    try { const r = localStorage.getItem(SETTINGS_KEY); if (r) return Object.assign({}, SETTINGS_DEFAULTS, JSON.parse(r)); } catch (e) {}
    return Object.assign({}, SETTINGS_DEFAULTS);
  }
  function saveSettings() { try { localStorage.setItem(SETTINGS_KEY, JSON.stringify(settings)); } catch (e) {} }

  // 테마 적용 (system 이면 기기 설정 따라감) + 로고도 테마에 맞게 교체
  const themeMQ = window.matchMedia("(prefers-color-scheme: dark)");
  function resolvedTheme() {
    let t = settings.theme || "dark";
    return t === "system" ? (themeMQ.matches ? "dark" : "light") : t;
  }
  function currentLogoSrc() { return resolvedTheme() === "light" ? "/logo-mark.png" : "/logo-mark-dark.png"; }
  function updateLogos() { document.querySelectorAll(".logo-img").forEach((i) => { i.src = currentLogoSrc(); }); }
  function applyTheme() {
    const t = resolvedTheme();
    document.documentElement.setAttribute("data-theme", t);
    const meta = document.querySelector('meta[name="theme-color"]');
    if (meta) meta.setAttribute("content", t === "light" ? "#f6f7f8" : "#0f1115");
    updateLogos();
  }
  themeMQ.addEventListener("change", () => { if (settings.theme === "system") applyTheme(); });
  function applyNetworkPreset(name) {
    const preset = NETWORK_PRESETS[name];
    if (!preset) return;
    settings.networkPreset = name;
    if (name === "manual") return;
    if (name === "auto") { autoTierIdx = -1; applyAutoTier(); return; }
    settings.pointerHz = preset.pointerHz;
    settings.pointerSmoothing = preset.pointerSmoothing;
    settings.resolutionScale = preset.resolutionScale;
  }
  if (settings.networkPreset && settings.networkPreset !== "manual") applyNetworkPreset(settings.networkPreset);
  // 예전 기본값(balanced)으로 저장된 기기를 자동 프리셋으로 1회 이관
  if (!settings._autoMigrated) {
    settings._autoMigrated = true;
    if (settings.networkPreset === "balanced") { settings.networkPreset = "auto"; }
    saveSettings();
  }
  applyTheme();

  // ───────── 실제 가시 높이 추적 ─────────
  // 사파리(주소창 접힘/펼침)와 홈 화면 웹앱(standalone)의 가시 영역이 달라
  // 100dvh 만으론 아래가 비거나 잘린다 → JS로 innerHeight 를 CSS 변수로 공급.
  if (navigator.standalone === true || window.matchMedia("(display-mode: standalone)").matches)
    document.documentElement.classList.add("standalone");
  function setAppHeight() { document.documentElement.style.setProperty("--app-height", window.innerHeight + "px"); }
  setAppHeight();
  window.addEventListener("resize", setAppHeight);

  // ───────── 화면 모드 (자동 / 폰 / 태블릿) ─────────
  // 태블릿(갤럭시 탭 등)·와이드 화면이면 html.wide → 덱 4열, 패널 폭 제한, 페이지당 12버튼.
  // 설정에서 강제 선택 가능 (자동은 화면 폭 640px 기준).
  function isWide() {
    const m = settings.layoutMode || "auto";
    if (m === "tablet") return true;
    if (m === "phone") return false;
    return window.innerWidth >= 640;
  }
  function applyLayoutMode() { document.documentElement.classList.toggle("wide", isWide()); }
  applyLayoutMode();
  window.addEventListener("resize", () => {
    const was = document.documentElement.classList.contains("wide");
    applyLayoutMode();
    if (was !== document.documentElement.classList.contains("wide")) renderDeck();
  });

  // 햅틱 피드백 (안드로이드 Chrome 지원, iOS는 무시됨)
  function buzz() { try { if (navigator.vibrate) navigator.vibrate(8); } catch (e) {} }

  // ───────── 모션 전송 큐 ─────────
  // touchmove 이벤트를 그대로 모두 보내면 네트워크/브라우저 상태에 따라 커서가 덩어리져 보인다.
  // 프레임 단위로 델타를 모아 일정한 주기로 보내고, 필요 시 잔여 델타를 짧게 분산한다.
  let motionRAF = null, motionTimer = null, lastMotionFlush = 0;
  let pendingMove = { dx: 0, dy: 0 }, pendingScroll = { dx: 0, dy: 0 }, smoothCarry = { dx: 0, dy: 0 };
  function clampNum(v, min, max) { return Math.max(min, Math.min(max, Number(v) || 0)); }
  function motionInterval() { return 1000 / clampNum(settings.pointerHz || 60, 24, 120); }
  function motionScale() { return clampNum(settings.resolutionScale || 1, 0.5, 2); }
  function scheduleMotion() {
    if (motionRAF || motionTimer) return;
    const wait = motionInterval() - (performance.now() - lastMotionFlush);
    // 리딩엣지: 전송 주기가 이미 지났으면 대기 없이 즉시 전송.
    // (기존 rAF 대기는 프레임당 최대 8~16ms 지연을 추가로 얹었다)
    if (wait <= 1) { flushMotionFrame(performance.now()); return; }
    motionTimer = setTimeout(() => { motionTimer = null; flushMotionFrame(performance.now()); }, wait);
  }
  function queueMove(dx, dy) {
    const scale = motionScale();
    pendingMove.dx += dx * scale;
    pendingMove.dy += dy * scale;
    scheduleMotion();
  }
  function queueScroll(dx, dy) {
    pendingScroll.dx += dx;
    pendingScroll.dy += dy;
    scheduleMotion();
  }
  function flushMotion(immediate) {
    if (motionTimer) { clearTimeout(motionTimer); motionTimer = null; }
    if (motionRAF) { cancelAnimationFrame(motionRAF); motionRAF = null; }
    if (immediate) {
      if (Math.abs(pendingMove.dx) > 0.01 || Math.abs(pendingMove.dy) > 0.01) send({ t: "move", dx: pendingMove.dx + smoothCarry.dx, dy: pendingMove.dy + smoothCarry.dy });
      if (Math.abs(pendingScroll.dx) > 0.01 || Math.abs(pendingScroll.dy) > 0.01) send({ t: "scroll", dx: pendingScroll.dx, dy: pendingScroll.dy });
      pendingMove = { dx: 0, dy: 0 }; pendingScroll = { dx: 0, dy: 0 }; smoothCarry = { dx: 0, dy: 0 };
      lastMotionFlush = performance.now();
      return;
    }
    flushMotionFrame(performance.now());
  }
  function flushMotionFrame(t) {
    motionRAF = null;
    lastMotionFlush = t || performance.now();

    if (Math.abs(pendingScroll.dx) > 0.01 || Math.abs(pendingScroll.dy) > 0.01) {
      send({ t: "scroll", dx: pendingScroll.dx, dy: pendingScroll.dy });
      pendingScroll = { dx: 0, dy: 0 };
    }

    const rawDx = pendingMove.dx + smoothCarry.dx;
    const rawDy = pendingMove.dy + smoothCarry.dy;
    pendingMove = { dx: 0, dy: 0 };
    smoothCarry = { dx: 0, dy: 0 };
    if (Math.abs(rawDx) > 0.01 || Math.abs(rawDy) > 0.01) {
      const s = clampNum(settings.pointerSmoothing || 0, 0, 0.45);
      const outDx = rawDx * (1 - s);
      const outDy = rawDy * (1 - s);
      const carryDx = rawDx - outDx;
      const carryDy = rawDy - outDy;
      send({ t: "move", dx: outDx, dy: outDy });
      if (Math.hypot(carryDx, carryDy) > 0.03) {
        smoothCarry = { dx: carryDx, dy: carryDy };
        scheduleMotion();
      }
    }
  }

  // ───────── 키 매핑 ─────────
  const KEYMAP = {
    a:0,s:1,d:2,f:3,h:4,g:5,z:6,x:7,c:8,v:9,b:11,q:12,w:13,e:14,r:15,y:16,t:17,
    o:31,u:32,i:34,p:35,l:37,j:38,k:40,n:45,m:46,
    "1":18,"2":19,"3":20,"4":21,"5":23,"6":22,"7":26,"8":28,"9":25,"0":29,
    "-":27,"=":24,"[":33,"]":30,";":41,"'":39,",":43,".":47,"/":44,"\\":42,"`":50," ":49
  };
  const SPECIAL_KEYS = [
    {label:"space",keyCode:49},{label:"return",keyCode:36},{label:"tab",keyCode:48},
    {label:"esc",keyCode:53},{label:"⌫",keyCode:51},{label:"⌦",keyCode:117},
    {label:"←",keyCode:123},{label:"→",keyCode:124},{label:"↑",keyCode:126},{label:"↓",keyCode:125},
    {label:"home",keyCode:115},{label:"end",keyCode:119},{label:"⇞",keyCode:116},{label:"⇟",keyCode:121},
    {label:"F1",keyCode:122},{label:"F2",keyCode:120},{label:"F3",keyCode:99},{label:"F4",keyCode:118},
    {label:"F5",keyCode:96},{label:"F6",keyCode:97},{label:"F7",keyCode:98},{label:"F8",keyCode:100},
    {label:"F9",keyCode:101},{label:"F10",keyCode:109},{label:"F11",keyCode:103},{label:"F12",keyCode:111}
  ];
  const MOD_SYMBOL = { command:"⌘", control:"⌃", shift:"⇧", option:"⌥" };
  const MOD_ORDER = ["control","option","shift","command"];

  function keyCodeForChar(ch) { if (!ch) return null; const c = ch.toLowerCase(); return KEYMAP[c] !== undefined ? KEYMAP[c] : null; }
  function keyLabel(keyCode) {
    if (keyCode === null || keyCode === undefined) return "?";
    const sp = SPECIAL_KEYS.find(s => s.keyCode === keyCode);
    if (sp) return sp.label;
    for (const k in KEYMAP) if (KEYMAP[k] === keyCode) return k === " " ? "space" : k.toUpperCase();
    return "?";
  }
  function comboLabel(keyCode, mods) {
    const ordered = MOD_ORDER.filter(m => (mods || []).includes(m)).map(m => MOD_SYMBOL[m]).join("");
    return ordered + keyLabel(keyCode);
  }
  function uid() { return "x" + Math.random().toString(36).slice(2, 9); }

  // ───────── 탭 전환 ─────────
  const kb = document.getElementById("kb-input");
  document.querySelectorAll("#tabbar .tab").forEach((tab) => {
    tab.addEventListener("click", () => {
      const name = tab.dataset.tab;
      setSheet(false);   // 탭을 누르면 트랙패드 시트를 내려 해당 탭을 보여줌
      document.querySelectorAll("#tabbar .tab").forEach((t) => t.classList.toggle("active", t === tab));
      document.querySelectorAll(".panel").forEach((p) => p.classList.toggle("active", p.id === "panel-" + name));
      if (name === "keyboard") setTimeout(() => kb.focus(), 50); else kb.blur();
      if (name === "deck") renderDeck();
      if (name === "agent") startCmuxPoll(); else stopCmuxPoll();   // 에이전트 탭 표시 중엔 4초 자동 갱신
    });
  });

  // ═════════ 트랙패드 시트 (핸들 드래그 → 원하는 높이 디텐트에 스냅) ═════════
  // 0 = 풀화면, 0.45·0.7 = 부분(위에 덱/키보드 레이어가 함께 보임), 1 = 닫힘(핸들만).
  // 마지막 높이는 기기별로 기억된다 (settings.sheetPos / sheetOpenPos).
  const mainEl = document.querySelector("main");
  const sheetEl = document.getElementById("tp-sheet");
  const sheetHandle = document.getElementById("tp-handle");
  const HANDLE_H = 46;
  const SHEET_DETENTS = [0, 0.45, 0.7, 1];
  let sheetPos = clampNum(settings.sheetPos != null ? settings.sheetPos : 0, 0, 1);
  let sheetCurOff = 0, sheetDrag = null;

  function sheetOpenNow() { return sheetPos < 1; }
  function closedOffset() { return Math.max(mainEl.clientHeight - HANDLE_H, 0); }
  function applySheet(off, animate) {
    sheetCurOff = off;
    sheetEl.style.transition = animate ? "transform .25s cubic-bezier(.2,.8,.2,1)" : "none";
    sheetEl.style.transform = "translateY(" + off + "px)";
  }
  function nearestDetent(frac) {
    let best = SHEET_DETENTS[0], dist = Infinity;
    for (const d of SHEET_DETENTS) { const dd = Math.abs(frac - d); if (dd < dist) { dist = dd; best = d; } }
    return best;
  }
  function setSheetPos(pos, animate) {
    sheetPos = pos;
    applySheet(pos * closedOffset(), animate !== false);
    sheetHandle.classList.toggle("open", pos < 1);
    if (pos < 1) { kb.blur(); settings.sheetOpenPos = pos; }   // 마지막 열림 높이 기억
    settings.sheetPos = pos;
    saveSettings();
  }
  function setSheet(open) { setSheetPos(open ? (settings.sheetOpenPos != null ? settings.sheetOpenPos : 0) : 1); }
  function sheetReflow() { applySheet(sheetPos * closedOffset(), false); }
  sheetHandle.addEventListener("touchstart", (e) => {
    sheetDrag = { y: e.touches[0].clientY, startOff: sheetPos * closedOffset(), moved: false };
  }, { passive: true });
  sheetHandle.addEventListener("touchmove", (e) => {
    if (!sheetDrag) return;
    e.preventDefault();
    const dy = e.touches[0].clientY - sheetDrag.y;
    if (Math.abs(dy) > 6) sheetDrag.moved = true;
    applySheet(Math.max(0, Math.min(sheetDrag.startOff + dy, closedOffset())), false);
  }, { passive: false });
  sheetHandle.addEventListener("touchend", () => {
    if (!sheetDrag) return;
    if (!sheetDrag.moved) setSheet(!sheetOpenNow());       // 탭 = 열기/닫기 토글
    else setSheetPos(nearestDetent(sheetCurOff / Math.max(closedOffset(), 1)));   // 드래그 = 가까운 디텐트로
    sheetDrag = null;
  });
  window.addEventListener("resize", sheetReflow);
  if (window.visualViewport) window.visualViewport.addEventListener("resize", () => { setAppHeight(); sheetReflow(); });

  // 좌/우 클릭 버튼 — 누르고 있으면 마우스 버튼이 '눌린 채' 유지.
  // → 좌클릭 누른 채 다른 손가락으로 트랙패드 드래그하면 진짜 드래그-선택.
  // → 짧게 눌렀다 떼면 down+up = 일반 클릭.
  let leftHeld = false, rightHeld = false;
  function buttonHeld() { return leftHeld || rightHeld; }
  function setupClickButton(btn, button) {
    btn.addEventListener("pointerdown", (e) => {
      e.preventDefault();
      try { btn.setPointerCapture(e.pointerId); } catch (err) {}
      if (button === "left") leftHeld = true; else rightHeld = true;
      btn.classList.add("held");
      send({ t: "down", button });
    });
    const release = () => {
      if (button === "left") { if (!leftHeld) return; leftHeld = false; }
      else { if (!rightHeld) return; rightHeld = false; }
      flushMotion(true);
      btn.classList.remove("held");
      send({ t: "up", button });
    };
    btn.addEventListener("pointerup", release);
    btn.addEventListener("pointercancel", release);
  }
  setupClickButton(document.getElementById("click-left"), "left");
  setupClickButton(document.getElementById("click-right"), "right");

  // ═════════ 에어마우스 (자이로) ═════════
  // ✈ 버튼을 누르고 있는 동안 폰의 회전 속도(rotationRate)로 커서를 움직인다 —
  // 폰을 리모컨처럼 들고 좌우로 돌리면 좌우, 위아래로 기울이면 상하. (이동이 아니라 '회전'에 반응)
  // ⚠️ iOS 는 모션 센서를 HTTPS(보안 컨텍스트)에서만 허용.
  // 조용한 실패 금지: 센서 이벤트가 1.2초 안에 안 오면 원인을 화면에 알려준다.
  const airBtn = document.getElementById("air-btn");
  let airActive = false, airListening = false, airLastEvent = 0, airCheckTimer = null;
  let airPrevOrient = null;

  function airSensK() { return clampNum(settings.airSensitivity || 1.2, 0.3, 3) * 0.3; }
  function airStatus(txt) { const s = airBtn && airBtn.querySelector("span"); if (s) s.textContent = txt; }

  function onAirMotion(e) {
    const rr = e.rotationRate;
    if (!rr || (rr.alpha == null && rr.beta == null)) return;
    airLastEvent = performance.now();
    if (!airActive) return;
    const k = airSensK();                                     // deg/s → px
    const dx = Math.abs(rr.alpha || 0) < 2 ? 0 : -(rr.alpha || 0) * k;   // 데드존 2°/s (손떨림)
    const dy = Math.abs(rr.beta || 0) < 2 ? 0 : -(rr.beta || 0) * k;
    if (dx || dy) queueMove(dx, dy);
  }

  // 회전속도(motion)가 안 오는 환경 폴백: 방향(절대각)의 변화량으로 이동
  function onAirOrient(e) {
    if (performance.now() - airLastEvent < 500) return;       // 모션이 살아있으면 무시
    if (e.alpha == null && e.beta == null) return;
    if (!airActive) { airPrevOrient = null; return; }
    const cur = { a: e.alpha || 0, b: e.beta || 0 };
    if (airPrevOrient) {
      let da = cur.a - airPrevOrient.a;
      if (da > 180) da -= 360;
      if (da < -180) da += 360;                               // 0/360 경계 보정
      const db = cur.b - airPrevOrient.b;
      const k = airSensK() * 12;                              // 각도 적분값이라 계수 큼
      const dx = Math.abs(da) < 0.15 ? 0 : -da * k;
      const dy = Math.abs(db) < 0.15 ? 0 : -db * k;
      if (dx || dy) queueMove(dx, dy);
    }
    airPrevOrient = cur;
  }

  async function airRequestPermissions() {
    // iOS의 '동작 및 방향'은 모션/방향 공용 권한 — 한 번만 요청해야 한다.
    // (연속 두 번 요청하면 두 번째가 사용자 제스처 밖으로 판정돼 자동 거부됨)
    const Ev = (typeof DeviceMotionEvent !== "undefined" && typeof DeviceMotionEvent.requestPermission === "function")
      ? DeviceMotionEvent
      : (typeof DeviceOrientationEvent !== "undefined" && typeof DeviceOrientationEvent.requestPermission === "function")
        ? DeviceOrientationEvent
        : null;
    if (!Ev) return { ok: true, detail: "no-perm-api" };   // Android 등 권한 개념 없는 플랫폼
    try {
      const res = await Ev.requestPermission();
      return { ok: res === "granted", detail: "result=" + res };
    } catch (err) {
      return { ok: false, detail: "throw=" + ((err && err.message) || String(err)) };
    }
  }

  async function airStart() {
    const needsPerm = typeof DeviceMotionEvent !== "undefined" && typeof DeviceMotionEvent.requestPermission === "function";
    if (!window.isSecureContext && needsPerm) {
      alert("iOS는 http 접속에서 모션 센서를 차단합니다.\n\nhttps://pilot.cmdspace.work 로 접속하면 에어마우스가 동작해요.\n(홈 화면 아이콘도 https 주소로 다시 추가 권장)");
      return;
    }
    if (typeof DeviceMotionEvent === "undefined" && typeof DeviceOrientationEvent === "undefined") {
      alert("이 브라우저는 모션 센서를 지원하지 않습니다."); return;
    }
    if (!airListening) {
      const perm = await airRequestPermissions();
      if (!perm.ok) {
        airBtn.classList.remove("held");
        airStatus("에어");
        // iOS 17+/27 은 전역 토글을 없애고 '사이트별 권한'으로 바꿈 → 주소창 왼쪽 메뉴에서 해제.
        alert(
          "모션 센서 권한을 얻지 못했어요.\n\n" +
          "iOS 17 이상은 사이트별 권한이라, 주소창에서 풀어야 합니다:\n" +
          "① 주소창 왼쪽의 메뉴 아이콘(≡ 또는 ⊞) 탭\n" +
          "② 웹 사이트 설정(Website Settings) 선택\n" +
          "③ 동작 및 방향(Motion & Orientation)을 허용(Allow)으로\n" +
          "→ 페이지 새로고침 후 🛸 에어 다시 누르기\n\n" +
          "안 보이면: 사생활 보호(Private) 탭으로 이 주소를 열고 🛸 → 팝업에서 허용(Allow)\n\n" +
          "[진단] " + location.protocol + " secure=" + window.isSecureContext + " / " + perm.detail
        );
        return;
      }
      window.addEventListener("devicemotion", onAirMotion);
      window.addEventListener("deviceorientation", onAirOrient);
      airListening = true;
    }
    airActive = true;
    airPrevOrient = null;
    buzz();
    airBtn.classList.add("held");
    airStatus("대기…");
    // 1.2초 안에 센서 이벤트가 안 오면 원인 안내 (조용한 실패 방지)
    clearTimeout(airCheckTimer);
    const t0 = performance.now();
    airCheckTimer = setTimeout(() => {
      if (!airActive) return;
      if (airLastEvent < t0) {
        airStop();
        alert("센서 이벤트가 오지 않습니다.\n\n현재 주소: " + location.protocol + "//" + location.host +
              "\n- https://pilot.cmdspace.work 인지 확인\n- 첫 사용 시 뜨는 '동작 및 방향' 팝업에서 허용했는지 확인");
      } else {
        airStatus("작동중");
      }
    }, 1200);
  }

  function airStop() {
    if (!airActive) return;
    airActive = false;
    airPrevOrient = null;
    airBtn.classList.remove("held");
    airStatus("에어");
    clearTimeout(airCheckTimer);
    flushMotion(true);
  }

  if (airBtn) {
    airBtn.addEventListener("pointerdown", (e) => { e.preventDefault(); airStart(); });
    airBtn.addEventListener("pointerup", airStop);
    airBtn.addEventListener("pointercancel", airStop);
  }

  // ═════════ 키보드 탭 ═════════
  let activeMods = [];
  function refreshModChips() {
    document.querySelectorAll("#kb-mods .modchip").forEach((c) => c.classList.toggle("on", activeMods.includes(c.dataset.mod)));
  }
  document.querySelectorAll("#kb-mods .modchip").forEach((chip) => {
    chip.addEventListener("pointerdown", (e) => {
      e.preventDefault();
      const m = chip.dataset.mod;
      if (activeMods.includes(m)) activeMods = activeMods.filter((x) => x !== m); else activeMods.push(m);
      refreshModChips();
    });
  });

  let lastValue = "", composing = false;
  function flushDiff() {
    const value = kb.value;
    let p = 0; const minLen = Math.min(lastValue.length, value.length);
    while (p < minLen && lastValue[p] === value[p]) p++;
    const removed = lastValue.length - p;
    const added = value.slice(p);

    if (activeMods.length > 0 && removed === 0 && added) {
      // 모디파이어 켜짐 → 입력 글자를 조합키로 전송하고 입력창은 되돌림
      for (const ch of added) {
        const kc = keyCodeForChar(ch);
        if (kc !== null) send({ t: "key", keyCode: kc, mods: activeMods.slice() });
        else send({ t: "text", text: ch });
      }
      kb.value = lastValue;
      return;
    }
    for (let i = 0; i < removed; i++) send({ t: "key", keyCode: 51, mods: [] });
    if (added) send({ t: "text", text: added });
    lastValue = kb.value;
    if (kb.value.length > 80 && !composing) { kb.value = ""; lastValue = ""; }
  }
  kb.addEventListener("compositionstart", () => { composing = true; });
  kb.addEventListener("compositionend", () => { composing = false; flushDiff(); });
  kb.addEventListener("input", (e) => { if (e.isComposing || composing) return; flushDiff(); });
  document.getElementById("kb-clear").addEventListener("click", () => { kb.value = ""; lastValue = ""; kb.focus(); });

  document.querySelectorAll("#kb-special .sp").forEach((btn) => {
    btn.addEventListener("pointerdown", (e) => {
      e.preventDefault();
      send({ t: "key", keyCode: parseInt(btn.dataset.key, 10), mods: activeMods.slice() });
    });
  });

  // ═════════ 에이전트 탭 + 퀵바 (고정 단축 버튼) ═════════
  // phrase = 텍스트 입력 후 자동 return (서버 매크로로 순차 실행 보장)
  function runQuickAction(b) {
    buzz();
    const act = b.dataset.act;
    if (act === "key") {
      const mods = (b.dataset.mods || "").split(",").filter(Boolean);
      send({ t: "key", keyCode: parseInt(b.dataset.key, 10), mods });
    } else if (act === "ctrlc") {
      send({ t: "key", keyCode: 8, mods: ["control"] });
    } else if (act === "phrase") {
      send({ t: "macro", steps: [
        { type: "text", text: b.dataset.text || "" },
        { type: "delay", ms: 120 },
        { type: "key", keyCode: 36, mods: [] }
      ] });
    } else if (act === "launch") {
      send({ t: "launch", target: b.dataset.target || "" });
    } else if (act === "capmenu") {
      openCaptureMenu();
    }
  }
  document.querySelectorAll("#panel-agent .agent-btn, #quickbar button, #quickbar2 button").forEach((b) => {
    b.addEventListener("click", () => runQuickAction(b));
  });

  // ═════════ 캡처 메뉴 (양방향) ═════════
  // ① 맥에서 영역 캡처(⇧⌘4)  ② 맥 화면을 폰으로 가져오기  ③ 폰 카메라 → OCR → 맥 클립보드
  function openCaptureMenu() {
    modalRoot.innerHTML =
      '<div class="modal-bg"></div><div class="modal-card">' +
      '<div class="modal-head"><div class="modal-title">캡처</div><button id="cap-close" class="modal-x">✕</button></div>' +
      '<div class="cap-actions">' +
        '<button id="cap-region">✂️ 맥에서 영역 캡처<span>⇧⌘4 — 맥 화면에서 드래그로 영역 선택</span></button>' +
        '<button id="cap-fetch">🖥 맥 화면 가져오기<span>지금 맥 화면을 폰으로 (길게 눌러 저장)</span></button>' +
        '<button id="cap-ocr">📷 카메라 텍스트 스캔<span>촬영 → 문자인식(OCR) → 맥 클립보드로</span></button>' +
      '</div>' +
      '<div id="cap-result" class="cap-result"></div>' +
      '</div>';
    const close = () => { modalRoot.innerHTML = ""; };
    modalRoot.querySelector(".modal-bg").addEventListener("click", close);
    modalRoot.querySelector("#cap-close").addEventListener("click", close);
    modalRoot.querySelector("#cap-region").addEventListener("click", () => {
      buzz(); send({ t: "key", keyCode: 21, mods: ["command", "shift"] }); close();
    });
    modalRoot.querySelector("#cap-fetch").addEventListener("click", () => {
      buzz();
      document.getElementById("cap-result").innerHTML = '<div class="cap-note">맥 화면 가져오는 중…</div>';
      send({ t: "capture" });
    });
    modalRoot.querySelector("#cap-ocr").addEventListener("click", () => {
      buzz();
      const inp = document.createElement("input");
      inp.type = "file"; inp.accept = "image/*"; inp.capture = "environment";
      inp.addEventListener("change", async () => {
        const file = inp.files && inp.files[0];
        if (!file) return;
        const box = document.getElementById("cap-result");
        if (box) box.innerHTML = '<div class="cap-note">텍스트 인식 중…</div>';
        try {
          const b64 = await imageFileToJpegBase64(file, 1600);
          send({ t: "ocr", text: b64 });
        } catch (e) {
          if (box) box.innerHTML = '<div class="cap-note">이미지 처리 실패</div>';
        }
      });
      inp.click();
    });
  }
  /// 카메라 원본(수 MB)을 그대로 보내지 않도록 긴 변 maxDim 으로 축소 후 JPEG base64 로.
  async function imageFileToJpegBase64(file, maxDim) {
    const bmp = await createImageBitmap(file);
    const scale = Math.min(1, maxDim / Math.max(bmp.width, bmp.height));
    const canvas = document.createElement("canvas");
    canvas.width = Math.round(bmp.width * scale);
    canvas.height = Math.round(bmp.height * scale);
    canvas.getContext("2d").drawImage(bmp, 0, 0, canvas.width, canvas.height);
    return canvas.toDataURL("image/jpeg", 0.82).split(",")[1];
  }

  // 키보드 탭: 타이핑 박스 하단 빠른 전송 버튼 (⏎ 크게 + esc/⌫/⇥)
  document.querySelectorAll(".kb-quick .kbq").forEach((btn) => {
    btn.addEventListener("pointerdown", (e) => {
      e.preventDefault();
      buzz();
      send({ t: "key", keyCode: parseInt(btn.dataset.key, 10), mods: activeMods.slice() });
    });
  });

  // ═════════ cmux 원격 (창 / 워크스페이스 / 탭 전환) ═════════
  // 동기화 모델: 요청 시 스냅샷 + 에이전트 탭이 보이는 동안 4초 폴링(변경 없으면 리렌더 생략).
  let cmuxState = null, cmuxPoll = null, lastCmuxJSON = "";
  function requestCmux(verb, target) { send({ t: "cmux", dir: verb || "state", target: target || "" }); }
  function startCmuxPoll() {
    stopCmuxPoll();
    requestCmux();
    cmuxPoll = setInterval(() => { if (document.visibilityState === "visible") requestCmux(); }, 4000);
  }
  function stopCmuxPoll() { if (cmuxPoll) clearInterval(cmuxPoll); cmuxPoll = null; }
  function cmuxChip(label, on, color, handler) {
    const b = document.createElement("button");
    b.className = "cmux-chip" + (on ? " on" : "");
    if (color && !on) b.style.borderColor = color;
    b.textContent = label;
    b.addEventListener("click", () => { buzz(); handler(); });
    return b;
  }
  function renderCmux() {
    const root = document.getElementById("cmux-remote");
    if (!root) return;
    if (!cmuxState) { root.innerHTML = '<div class="cmux-empty">cmux 상태 불러오는 중…</div>'; return; }
    if (cmuxState.available === false) { root.innerHTML = '<div class="cmux-empty">cmux가 설치되어 있지 않습니다</div>'; return; }
    if (cmuxState.denied) { root.innerHTML = '<div class="cmux-empty">cmux 소켓 권한 대기 중 — cmux를 한 번 재시작하면 활성화됩니다 (↻로 재확인)</div>'; return; }
    root.innerHTML = "";
    (cmuxState.windows || []).forEach((win) => {
      const row = document.createElement("div");
      row.className = "cmux-row";
      const wbtn = cmuxChip("창 " + ((win.index || 0) + 1), !!win.key, "", () => requestCmux("focus-window", win.id));
      wbtn.classList.add("win");
      row.appendChild(wbtn);
      const wrap = document.createElement("div");
      wrap.className = "cmux-chips";
      (win.workspaces || []).forEach((ws) => {
        wrap.appendChild(cmuxChip(ws.title || "(무제)", !!ws.selected, ws.color || "", () => requestCmux("select-workspace", ws.id)));
      });
      row.appendChild(wrap);
      root.appendChild(row);
    });
    if (cmuxState.tabs && cmuxState.tabs.length) {
      const lbl = document.createElement("div");
      lbl.className = "cmux-sub";
      lbl.textContent = "탭 (현재 워크스페이스)";
      root.appendChild(lbl);
      const wrap = document.createElement("div");
      wrap.className = "cmux-chips";
      cmuxState.tabs.forEach((tb) => {
        const chip = cmuxChip(tb.title || "터미널", !!tb.focused, "", () => requestCmux("focus-tab", tb.id));
        chip.classList.add("tab");
        wrap.appendChild(chip);
      });
      root.appendChild(wrap);
    }
  }
  document.getElementById("cmux-refresh").addEventListener("click", () => { buzz(); requestCmux(); });

  // ═════════ 덱 ═════════
  const STORE_KEY = "macpilot.deck.v2";
  let deck = loadDeck();
  let activeFolder = 0;
  let editMode = false;
  let installedApps = null, appsPickerRefresh = null;

  function loadDeck() {
    try { const raw = localStorage.getItem(STORE_KEY); if (raw) return JSON.parse(raw); } catch (e) {}
    return defaultDeck();
  }
  function saveLocal() { try { localStorage.setItem(STORE_KEY, JSON.stringify(deck)); } catch (e) {} }
  function pushDeckToServer() { send({ t: "saveDeck", deckJson: JSON.stringify(deck) }); }
  function saveDeck() { saveLocal(); pushDeckToServer(); }   // 폰 캐시 + 맥 서버 동시 저장
  function sc(label, keyCode, mods) { return { id: uid(), type: "shortcut", label, keyCode, mods }; }
  function defaultDeck() {
    return { folders: [
      { id: uid(), name: "기본", items: [
        sc("복사", 8, ["command"]), sc("붙여넣기", 9, ["command"]), sc("잘라내기", 7, ["command"]),
        sc("실행취소", 6, ["command"]), sc("다시실행", 6, ["command","shift"]), sc("전체선택", 0, ["command"]),
        sc("저장", 1, ["command"]), sc("찾기", 3, ["command"]), sc("새로고침", 15, ["command"]),
      ]},
      { id: uid(), name: "앱/창", items: [
        sc("새 탭", 17, ["command"]), sc("탭 닫기", 13, ["command"]), sc("스팟라이트", 49, ["command"]),
        sc("앱 전환", 48, ["command"]),
        { id: uid(), type: "launch", label: "미션컨트롤", target: "/System/Applications/Mission Control.app" },
      ]},
      { id: uid(), name: "매크로", items: [
        { id: uid(), type: "macro", label: "전체선택→복사", steps: [
          { type:"key", keyCode:0, mods:["command"] }, { type:"delay", ms:80 }, { type:"key", keyCode:8, mods:["command"] } ] },
        { id: uid(), type: "macro", label: "복사→앱전환→붙여넣기", steps: [
          { type:"key", keyCode:8, mods:["command"] }, { type:"delay", ms:120 },
          { type:"key", keyCode:48, mods:["command"] }, { type:"delay", ms:300 },
          { type:"key", keyCode:9, mods:["command"] } ] },
      ]},
      { id: uid(), name: "내 것", items: [] },
    ]};
  }

  function pageSize() { return document.documentElement.classList.contains("wide") ? 12 : 9; }
  const pagesEl = document.getElementById("deck-pages");
  const dotsEl = document.getElementById("page-dots");
  const tabsEl = document.getElementById("folder-tabs");
  const toolbarEl = document.getElementById("deck-toolbar");

  document.getElementById("deck-edit").addEventListener("click", () => {
    editMode = !editMode;
    document.getElementById("deck-edit").classList.toggle("on", editMode);
    toolbarEl.classList.toggle("on", editMode);
    renderDeck();
  });

  // 음량 / 밝기
  document.querySelectorAll("#media-bar button").forEach((b) => {
    b.addEventListener("click", () => { buzz(); send({ t: b.dataset.m, dir: b.dataset.d }); });
  });

  function runItem(item) {
    buzz();
    if (item.type === "shortcut") send({ t: "key", keyCode: item.keyCode, mods: item.mods || [] });
    else if (item.type === "text") send({ t: "text", text: item.text || "" });
    else if (item.type === "launch") send({ t: "launch", target: item.target || "" });
    else if (item.type === "macro") send({ t: "macro", steps: item.steps || [] });
  }
  function cellSub(item) {
    if (item.type === "shortcut") return comboLabel(item.keyCode, item.mods);
    if (item.type === "macro") return "매크로 " + (item.steps ? item.steps.length : 0) + "단계";
    if (item.type === "text") return "텍스트";
    if (item.type === "launch") return "앱/링크";
    return "";
  }

  function renderDeck() {
    if (activeFolder >= deck.folders.length) activeFolder = 0;
    renderFolderTabs();
    renderToolbar();
    renderPages();
  }
  function renderFolderTabs() {
    tabsEl.innerHTML = "";
    deck.folders.forEach((f, i) => {
      const t = document.createElement("button");
      t.className = "folder-tab" + (i === activeFolder ? " active" : "");
      t.textContent = f.name;
      t.addEventListener("click", () => { activeFolder = i; renderDeck(); });
      tabsEl.appendChild(t);
    });
    if (editMode) {
      const add = document.createElement("button");
      add.className = "folder-tab add"; add.textContent = "＋폴더";
      add.addEventListener("click", () => {
        const name = prompt("새 폴더 이름"); if (!name) return;
        deck.folders.push({ id: uid(), name, items: [] }); activeFolder = deck.folders.length - 1; saveDeck(); renderDeck();
      });
      tabsEl.appendChild(add);
    }
  }
  function renderToolbar() {
    toolbarEl.innerHTML = "";
    if (!editMode) return;
    const rename = document.createElement("button");
    rename.textContent = "✎ 폴더 이름";
    rename.addEventListener("click", () => {
      const f = deck.folders[activeFolder]; const name = prompt("폴더 이름", f.name); if (!name) return;
      f.name = name; saveDeck(); renderDeck();
    });
    const del = document.createElement("button");
    del.className = "danger"; del.textContent = "🗑 폴더 삭제";
    del.addEventListener("click", () => {
      if (deck.folders.length <= 1) { alert("폴더는 최소 1개 필요합니다"); return; }
      if (!confirm("이 폴더와 버튼을 삭제할까요?")) return;
      deck.folders.splice(activeFolder, 1); activeFolder = 0; saveDeck(); renderDeck();
    });
    toolbarEl.appendChild(rename); toolbarEl.appendChild(del);
  }
  function renderPages() {
    const keepScroll = pagesEl.scrollLeft;
    pagesEl.innerHTML = "";
    const folder = deck.folders[activeFolder];
    const items = folder ? folder.items : [];
    const cells = items.map((item, i) => renderCell(item, i));
    if (editMode) cells.push(renderAddCell());
    const pages = [];
    const per = pageSize();
    for (let i = 0; i < cells.length; i += per) pages.push(cells.slice(i, i + per));
    if (pages.length === 0) pages.push([]);
    pages.forEach((pc) => {
      const page = document.createElement("div");
      page.className = "deck-page";
      pc.forEach((c) => page.appendChild(c));
      pagesEl.appendChild(page);
    });
    pagesEl.scrollLeft = keepScroll;
    renderDots(pages.length);
  }
  function renderCell(item, idx) {
    const btn = document.createElement("button");
    btn.className = "deck-btn" + (item.type === "macro" ? " macro" : "");
    btn.dataset.idx = idx;
    if (item.color) btn.style.background = item.color;
    if (dragState && dragState.item === item) btn.classList.add("drag-src");
    if (item.icon) {
      if (item.icon.indexOf("data:") === 0) { const im = document.createElement("img"); im.className = "ic-img"; im.src = item.icon; btn.appendChild(im); }
      else { const ic = document.createElement("span"); ic.className = "ic"; ic.textContent = item.icon; btn.appendChild(ic); }
    }
    const main = document.createElement("span"); main.textContent = item.label || "(이름없음)"; btn.appendChild(main);
    const sub = cellSub(item);
    if (sub) { const s = document.createElement("span"); s.className = "sub"; s.textContent = sub; btn.appendChild(s); }
    if (editMode) {
      btn.addEventListener("touchstart", (e) => {
        const t = e.touches[0];
        dragCandidate = { item, btn, x: t.clientX, y: t.clientY, armed: false };
        dragTimer = setTimeout(() => { if (dragCandidate) { dragCandidate.armed = true; btn.classList.add("lift"); } }, 220);
      }, { passive: true });
    } else {
      btn.addEventListener("click", () => runItem(item));
    }
    return btn;
  }
  function renderAddCell() {
    const btn = document.createElement("button");
    btn.className = "deck-btn add"; btn.textContent = "＋";
    btn.addEventListener("click", () => openEditor(null));
    return btn;
  }
  function renderDots(count) {
    dotsEl.innerHTML = "";
    if (count <= 1) return;
    for (let i = 0; i < count; i++) { const d = document.createElement("span"); d.className = "pd" + (i === 0 ? " on" : ""); dotsEl.appendChild(d); }
  }
  pagesEl.addEventListener("scroll", () => {
    const w = pagesEl.clientWidth; if (!w) return;
    const idx = Math.round(pagesEl.scrollLeft / w);
    dotsEl.querySelectorAll(".pd").forEach((d, i) => d.classList.toggle("on", i === idx));
  });

  // ── 드래그 재정렬 (편집 모드: 길게 눌러 집고 끌어서 이동) ──
  let dragCandidate = null, dragState = null, dragTimer = null;
  function clearCandidate() {
    if (dragTimer) { clearTimeout(dragTimer); dragTimer = null; }
    if (dragCandidate && dragCandidate.btn) dragCandidate.btn.classList.remove("lift");
    dragCandidate = null;
  }
  function beginDrag(t) {
    const btn = dragCandidate.btn, item = dragCandidate.item;
    if (dragTimer) { clearTimeout(dragTimer); dragTimer = null; }
    dragCandidate = null;
    const rect = btn.getBoundingClientRect();
    const ghost = btn.cloneNode(true);
    ghost.classList.add("drag-ghost");
    ghost.style.cssText += "position:fixed;left:" + rect.left + "px;top:" + rect.top + "px;width:" + rect.width + "px;height:" + rect.height + "px;margin:0;z-index:60;pointer-events:none;";
    document.body.appendChild(ghost);
    dragState = { item: item, ghost: ghost, offX: t.clientX - rect.left, offY: t.clientY - rect.top };
    renderPages();
  }
  function moveDrag(t) {
    const g = dragState.ghost;
    g.style.left = (t.clientX - dragState.offX) + "px";
    g.style.top = (t.clientY - dragState.offY) + "px";
    g.style.visibility = "hidden";
    const el = document.elementFromPoint(t.clientX, t.clientY);
    g.style.visibility = "visible";
    const target = el && el.closest ? el.closest(".deck-btn") : null;
    if (!target || target.classList.contains("add") || target.classList.contains("drag-ghost")) return;
    const targetIdx = parseInt(target.dataset.idx, 10);
    if (isNaN(targetIdx)) return;
    const folder = deck.folders[activeFolder];
    const curIdx = folder.items.indexOf(dragState.item);
    if (curIdx < 0 || targetIdx === curIdx) return;
    folder.items.splice(curIdx, 1);
    folder.items.splice(targetIdx, 0, dragState.item);
    renderPages();
  }
  function endDrag() { if (dragState.ghost) dragState.ghost.remove(); dragState = null; saveDeck(); renderPages(); }

  document.addEventListener("touchmove", (e) => {
    if (dragState) { e.preventDefault(); moveDrag(e.touches[0]); return; }
    if (!dragCandidate) return;
    const t = e.touches[0];
    if (dragCandidate.armed) { e.preventDefault(); beginDrag(t); }
    else if (Math.hypot(t.clientX - dragCandidate.x, t.clientY - dragCandidate.y) > 10) clearCandidate();
  }, { passive: false });
  document.addEventListener("touchend", () => {
    if (dragState) { endDrag(); return; }
    if (dragCandidate) { const it = dragCandidate.item; clearCandidate(); openEditor(it); }
  });

  // ═════════ 버튼 에디터 (모달) ═════════
  const modalRoot = document.getElementById("modal-root");
  let draft = null;       // 편집 중 항목
  let draftIndex = -1;    // 폴더 내 인덱스 (-1=신규)

  function openEditor(item) {
    draftIndex = item ? deck.folders[activeFolder].items.indexOf(item) : -1;
    draft = item ? JSON.parse(JSON.stringify(item))
                 : { id: uid(), type: "shortcut", label: "", keyCode: 8, mods: ["command"] };
    if (!draft.mods) draft.mods = [];
    renderModal();
  }
  function closeEditor() { modalRoot.innerHTML = ""; draft = null; appsPickerRefresh = null; }

  function renderModal() {
    modalRoot.innerHTML =
      '<div class="modal-bg"></div><div class="modal-card">' +
      '<div class="modal-head"><div class="modal-title">' + (draftIndex >= 0 ? "버튼 편집" : "버튼 추가") + '</div><button id="ed-close" class="modal-x">✕</button></div>' +
      '<div class="seg" id="ed-type">' +
        '<button data-type="shortcut">단축키</button><button data-type="text">텍스트</button>' +
        '<button data-type="launch">앱/링크</button><button data-type="macro">매크로</button></div>' +
      '<input id="ed-label" class="ed-input" placeholder="버튼 이름">' +
      '<div class="ed-row"><input id="ed-icon" class="ed-input ed-icon" maxlength="2" placeholder="🙂 아이콘"><select id="ed-folder" class="ed-input"></select></div>' +
      '<div class="ed-colors" id="ed-colors"></div>' +
      '<div id="ed-body"></div>' +
      '<div class="modal-actions">' +
        (draftIndex >= 0 ? '<button id="ed-delete" class="danger">삭제</button>' : '') +
        '<span style="flex:1"></span><button id="ed-cancel">취소</button><button id="ed-save" class="primary">저장</button>' +
      '</div></div>';

    modalRoot.querySelector(".modal-bg").addEventListener("click", closeEditor);
    modalRoot.querySelector("#ed-cancel").addEventListener("click", closeEditor);
    modalRoot.querySelector("#ed-close").addEventListener("click", closeEditor);
    const lab = modalRoot.querySelector("#ed-label");
    lab.value = draft.label || "";
    lab.addEventListener("input", () => { draft.label = lab.value; });

    // 아이콘
    const iconEl = modalRoot.querySelector("#ed-icon");
    iconEl.value = (draft.icon && draft.icon.indexOf("data:") !== 0) ? draft.icon : "";
    iconEl.addEventListener("input", () => { draft.icon = iconEl.value || null; });
    // 폴더 이동
    const folderEl = modalRoot.querySelector("#ed-folder");
    deck.folders.forEach((f, i) => { const o = document.createElement("option"); o.value = String(i); o.textContent = "📁 " + f.name; if (i === activeFolder) o.selected = true; folderEl.appendChild(o); });
    // 색상
    const COLORS = ["", "#2a3b4d", "#3a2a4d", "#4d2a2a", "#2a4d34", "#4d442a", "#2a4d4d", "#3a3a42"];
    const colorsEl = modalRoot.querySelector("#ed-colors");
    COLORS.forEach((c) => {
      const sw = document.createElement("button");
      sw.className = "swatch" + ((draft.color || "") === c ? " on" : "");
      sw.style.background = c || "#1c1c20";
      if (!c) sw.textContent = "✕";
      sw.addEventListener("click", () => { draft.color = c || null; colorsEl.querySelectorAll(".swatch").forEach((x) => x.classList.remove("on")); sw.classList.add("on"); });
      colorsEl.appendChild(sw);
    });

    modalRoot.querySelectorAll("#ed-type button").forEach((b) => {
      b.classList.toggle("on", b.dataset.type === draft.type);
      b.addEventListener("click", () => { changeType(b.dataset.type); });
    });
    if (draftIndex >= 0) modalRoot.querySelector("#ed-delete").addEventListener("click", () => {
      deck.folders[activeFolder].items.splice(draftIndex, 1); saveDeck(); closeEditor(); renderDeck();
    });
    modalRoot.querySelector("#ed-save").addEventListener("click", saveDraft);
    renderBody();
  }
  function changeType(type) {
    draft.type = type;
    if (type === "shortcut") { if (draft.keyCode == null) draft.keyCode = 8; if (!draft.mods) draft.mods = ["command"]; }
    if (type === "text" && draft.text == null) draft.text = "";
    if (type === "launch" && draft.target == null) draft.target = "";
    if (type === "macro" && !draft.steps) draft.steps = [];
    modalRoot.querySelectorAll("#ed-type button").forEach((b) => b.classList.toggle("on", b.dataset.type === type));
    renderBody();
  }
  function renderBody() {
    const body = modalRoot.querySelector("#ed-body");
    if (draft.type === "shortcut") body.innerHTML = comboBuilderHTML("");
    else if (draft.type === "text") body.innerHTML = '<div class="ed-label">입력할 텍스트</div><textarea id="ed-text" class="ed-input" placeholder="예: 이메일 주소, 자주 쓰는 문구"></textarea>';
    else if (draft.type === "launch") body.innerHTML =
      '<div class="ed-label">앱 이름 · 경로 · 링크(URL)</div>' +
      '<input id="ed-target" class="ed-input" placeholder="Notes · https://… · shortcuts://…" autocapitalize="off" autocorrect="off">' +
      '<div class="ed-label">설치된 앱에서 선택</div>' +
      '<input id="ed-appsearch" class="ed-input" placeholder="앱 검색…" autocapitalize="off" autocorrect="off">' +
      '<div class="ed-apps" id="ed-apps"></div>';
    else if (draft.type === "macro") body.innerHTML = '<div class="ed-label">매크로 단계 (순서대로 실행)</div><div class="ed-steps" id="ed-steps"></div><button class="ed-addstep" id="ed-addstep">+ 단계 추가</button>';
    wireBody();
  }
  function wireBody() {
    if (draft.type === "shortcut") wireComboBuilder("", draft, () => {});
    else if (draft.type === "text") { const t = modalRoot.querySelector("#ed-text"); t.value = draft.text || ""; t.addEventListener("input", () => draft.text = t.value); }
    else if (draft.type === "launch") {
      const t = modalRoot.querySelector("#ed-target");
      t.value = draft.target || "";
      t.addEventListener("input", () => draft.target = t.value);
      const search = modalRoot.querySelector("#ed-appsearch");
      const appsEl = modalRoot.querySelector("#ed-apps");
      const renderApps = () => {
        appsEl.innerHTML = "";
        if (!installedApps) { appsEl.textContent = "앱 목록 불러오는 중…"; return; }
        const f = (search.value || "").toLowerCase();
        installedApps.filter((a) => a.name.toLowerCase().includes(f)).slice(0, 300).forEach((a) => {
          const b = document.createElement("button");
          b.className = "app-tile";
          if (a.icon) { const im = document.createElement("img"); im.className = "app-ic"; im.src = a.icon; b.appendChild(im); }
          const nm = document.createElement("span"); nm.textContent = a.name; b.appendChild(nm);
          b.addEventListener("click", () => { draft.target = a.path; t.value = a.path; if (a.icon) draft.icon = a.icon; });
          appsEl.appendChild(b);
        });
      };
      search.addEventListener("input", renderApps);
      appsPickerRefresh = renderApps;
      renderApps();
      if (!installedApps) send({ t: "getApps" });
    }
    else if (draft.type === "macro") { renderSteps(); modalRoot.querySelector("#ed-addstep").addEventListener("click", () => { draft.steps.push({ type:"key", keyCode:8, mods:["command"] }); renderSteps(); }); }
  }

  // 조합키 빌더 (단축키 + 매크로 step 공용). prefix 로 id 충돌 방지.
  function comboBuilderHTML(prefix) {
    return '' +
      '<div class="ed-mods" id="' + prefix + 'mods">' +
        '<button data-mod="command">⌘</button><button data-mod="control">⌃</button>' +
        '<button data-mod="shift">⇧</button><button data-mod="option">⌥</button></div>' +
      '<div class="ed-label">키 (직접 입력 또는 아래에서 선택)</div>' +
      '<input id="' + prefix + 'keychar" class="ed-input" maxlength="1" placeholder="a, 1, = …" autocapitalize="off" autocorrect="off">' +
      '<div class="ed-special" id="' + prefix + 'special"></div>' +
      '<div class="ed-preview" id="' + prefix + 'preview"></div>';
  }
  function wireComboBuilder(prefix, target, onChange) {
    const modsEl = modalRoot.querySelector("#" + prefix + "mods");
    const charEl = modalRoot.querySelector("#" + prefix + "keychar");
    const specialEl = modalRoot.querySelector("#" + prefix + "special");
    const previewEl = modalRoot.querySelector("#" + prefix + "preview");
    function refresh() { previewEl.textContent = comboLabel(target.keyCode, target.mods); onChange(); }

    modsEl.querySelectorAll("button").forEach((b) => {
      b.classList.toggle("on", (target.mods || []).includes(b.dataset.mod));
      b.addEventListener("click", () => {
        const m = b.dataset.mod;
        if (!target.mods) target.mods = [];
        if (target.mods.includes(m)) target.mods = target.mods.filter((x) => x !== m); else target.mods.push(m);
        b.classList.toggle("on"); refresh();
      });
    });
    // 직접 입력
    const cur = keyLabel(target.keyCode);
    if (cur.length === 1) charEl.value = cur.toLowerCase();
    charEl.addEventListener("input", () => {
      const kc = keyCodeForChar(charEl.value);
      if (kc !== null) { target.keyCode = kc; specialEl.querySelectorAll("button").forEach((x) => x.classList.remove("on")); refresh(); }
    });
    // 특수키 그리드
    SPECIAL_KEYS.forEach((sp) => {
      const b = document.createElement("button");
      b.textContent = sp.label; b.classList.toggle("on", target.keyCode === sp.keyCode);
      b.addEventListener("click", () => {
        target.keyCode = sp.keyCode; charEl.value = "";
        specialEl.querySelectorAll("button").forEach((x) => x.classList.remove("on")); b.classList.add("on"); refresh();
      });
      specialEl.appendChild(b);
    });
    refresh();
  }

  // 매크로 단계 렌더
  function renderSteps() {
    const wrap = modalRoot.querySelector("#ed-steps");
    wrap.innerHTML = "";
    draft.steps.forEach((step, idx) => {
      const row = document.createElement("div");
      row.className = "ed-step";
      const head = document.createElement("div");
      head.className = "ed-step-head";
      const sel = document.createElement("select");
      [["key","단축키"],["text","텍스트"],["delay","딜레이"],["launch","앱/링크"]].forEach(([v,l]) => {
        const o = document.createElement("option"); o.value = v; o.textContent = l; if (step.type === v) o.selected = true; sel.appendChild(o);
      });
      sel.addEventListener("change", () => { step.type = sel.value; if (step.type==="key" && step.keyCode==null){step.keyCode=8;step.mods=["command"];} renderSteps(); });
      const rm = document.createElement("button"); rm.className = "rm"; rm.textContent = "✕";
      rm.addEventListener("click", () => { draft.steps.splice(idx, 1); renderSteps(); });
      head.appendChild(sel); head.appendChild(rm); row.appendChild(head);

      const bodyId = "step" + idx + "_";
      const sb = document.createElement("div");
      if (step.type === "key") { sb.innerHTML = comboBuilderHTML(bodyId); }
      else if (step.type === "text") { sb.innerHTML = '<input class="ed-input" placeholder="입력할 텍스트">'; }
      else if (step.type === "delay") { sb.innerHTML = '<input class="ed-input" type="number" placeholder="밀리초 (예: 200)">'; }
      else if (step.type === "launch") { sb.innerHTML = '<input class="ed-input" placeholder="앱 이름 · 경로 · https://… · shortcuts://…" autocapitalize="off" autocorrect="off">'; }
      row.appendChild(sb); wrap.appendChild(row);

      if (step.type === "key") { if (!step.mods) step.mods = []; wireComboBuilder(bodyId, step, () => {}); }
      else if (step.type === "text") { const i = sb.querySelector("input"); i.value = step.text||""; i.addEventListener("input",()=>step.text=i.value); }
      else if (step.type === "delay") { const i = sb.querySelector("input"); i.value = step.ms||""; i.addEventListener("input",()=>step.ms=parseInt(i.value,10)||0); }
      else if (step.type === "launch") { const i = sb.querySelector("input"); i.value = step.target||""; i.addEventListener("input",()=>step.target=i.value); }
    });
  }

  function saveDraft() {
    if (!draft.label) draft.label = defaultLabel(draft);
    const folderEl = modalRoot.querySelector("#ed-folder");
    let dest = folderEl ? parseInt(folderEl.value, 10) : activeFolder;
    if (isNaN(dest) || dest < 0 || dest >= deck.folders.length) dest = activeFolder;
    const srcItems = deck.folders[activeFolder].items;
    if (draftIndex >= 0) {
      if (dest === activeFolder) { srcItems[draftIndex] = draft; }
      else { srcItems.splice(draftIndex, 1); deck.folders[dest].items.push(draft); activeFolder = dest; }
    } else {
      deck.folders[dest].items.push(draft); activeFolder = dest;
    }
    saveDeck(); closeEditor(); renderDeck();
  }
  function defaultLabel(d) {
    if (d.type === "shortcut") return comboLabel(d.keyCode, d.mods);
    if (d.type === "text") return (d.text || "텍스트").slice(0, 8);
    if (d.type === "launch") return "앱";
    if (d.type === "macro") return "매크로";
    return "버튼";
  }

  // ═════════ 설정 모달 ═════════
  function fmt(key) {
    if (key === "accel" || key === "pointerSmoothing") return Math.round(settings[key] * 100) + "%";
    if (key === "pointerHz") return Math.round(settings[key]) + "Hz";
    return settings[key].toFixed(2).replace(/\.00$/, "") + "×";
  }
  function sliderHTML(id, label, min, max, step) {
    return '<div class="set-row"><label>' + label + '</label><span class="set-val" id="sv-' + id + '"></span></div>' +
      '<input type="range" class="set-slider" id="set-' + id + '" min="' + min + '" max="' + max + '" step="' + step + '">';
  }
  function openSettings() {
    modalRoot.innerHTML =
      '<div class="modal-bg"></div><div class="modal-card">' +
      '<div class="modal-head"><div class="modal-title">설정</div><button id="set-close" class="modal-x">✕</button></div>' +
      '<div class="set-section">테마</div>' +
      '<div class="seg" id="set-theme"><button data-theme="system">시스템</button><button data-theme="light">라이트</button><button data-theme="dark">다크</button></div>' +
      '<div class="set-section">화면 모드</div>' +
      '<div class="seg" id="set-layout"><button data-lay="auto">자동</button><button data-lay="phone">폰</button><button data-lay="tablet">태블릿</button></div>' +
      '<div class="set-section">제스처 할당</div>' +
      GESTURE_SLOTS.map(function (slot) {
        return '<div class="gesture-row"><label>' + slot[1] + '</label><select data-gkey="' + slot[0] + '">' +
          Object.keys(GESTURE_ACTIONS).map(function (a) { return '<option value="' + a + '">' + GESTURE_ACTIONS[a].label + '</option>'; }).join("") +
          '</select></div>';
      }).join("") +
      '<div class="set-section">네트워크/주사율</div>' +
      '<div class="seg net-presets" id="set-network"><button data-net="auto">자동</button><button data-net="fast">빠른 Wi-Fi</button><button data-net="balanced">균형</button><button data-net="stable">불안정</button><button data-net="manual">수동</button></div>' +
      '<div class="latency-card"><span>현재 지연율</span><b id="set-latency">' + (latencyMs ? latencyMs + "ms" : "측정 중") + '</b></div>' +
      sliderHTML("hz", "전송 주사율", 24, 120, 1) +
      sliderHTML("smooth", "움직임 보정", 0, 0.45, 0.01) +
      sliderHTML("resolution", "해상도 배율", 0.5, 2, 0.05) +
      '<div class="set-section">트랙패드</div>' +
      sliderHTML("move", "커서 속도", 0.4, 3, 0.1) +
      sliderHTML("accel", "포인터 가속", 0, 0.15, 0.01) +
      sliderHTML("scroll", "스크롤 속도", 0.3, 3, 0.1) +
      sliderHTML("air", "에어마우스 감도", 0.3, 3, 0.1) +
      '<div class="set-row"><label>스크롤 방향 반전</label><input type="checkbox" id="set-scrolldir"></div>' +
      '<div class="modal-actions"><button id="set-reset" class="danger">기본값</button><span style="flex:1"></span><button id="set-done" class="primary">완료</button></div>' +
      '<div class="about"><img class="logo-img about-logo" alt="CmdSpace"><div class="copyright">CmdSpace Pilot · fork of MacPilot</div></div>' +
      '</div>';
    const close = () => { modalRoot.innerHTML = ""; networkUIRefresh = null; };
    modalRoot.querySelector(".modal-bg").addEventListener("click", close);
    modalRoot.querySelector("#set-close").addEventListener("click", close);
    modalRoot.querySelector("#set-done").addEventListener("click", close);

    const bind = (id, key, manualOnInput) => {
      const el = modalRoot.querySelector("#set-" + id);
      const val = modalRoot.querySelector("#sv-" + id);
      el.value = settings[key];
      val.textContent = fmt(key);
      el.addEventListener("input", () => {
        settings[key] = parseFloat(el.value);
        if (manualOnInput) settings.networkPreset = "manual";
        val.textContent = fmt(key);
        saveSettings();
        refreshNetworkButtons();
      });
    };
    bind("move", "moveSpeed");
    bind("accel", "accel");
    bind("scroll", "scrollSpeed");
    bind("air", "airSensitivity");
    bind("hz", "pointerHz", true);
    bind("smooth", "pointerSmoothing", true);
    bind("resolution", "resolutionScale", true);

    function syncNetworkSliders() {
      [["hz","pointerHz"],["smooth","pointerSmoothing"],["resolution","resolutionScale"]].forEach(([id, key]) => {
        const el = modalRoot.querySelector("#set-" + id);
        const val = modalRoot.querySelector("#sv-" + id);
        if (el && val) { el.value = settings[key]; val.textContent = fmt(key); }
      });
    }
    function refreshNetworkButtons() {
      modalRoot.querySelectorAll("#set-network button").forEach((b) => {
        b.classList.toggle("on", b.dataset.net === (settings.networkPreset || "balanced"));
      });
      const lat = modalRoot.querySelector("#set-latency");
      if (lat) lat.textContent = latencyMs ? latencyMs + "ms" : "측정 중";
    }
    modalRoot.querySelectorAll("#set-network button").forEach((b) => {
      b.addEventListener("click", () => {
        settings.networkPreset = b.dataset.net;
        applyNetworkPreset(settings.networkPreset);
        saveSettings();
        syncNetworkSliders();
        refreshNetworkButtons();
      });
    });
    refreshNetworkButtons();
    networkUIRefresh = () => { syncNetworkSliders(); refreshNetworkButtons(); };   // 자동 프리셋 조정 시 모달 갱신

    const dir = modalRoot.querySelector("#set-scrolldir");
    dir.checked = settings.scrollDir === -1;
    dir.addEventListener("change", () => { settings.scrollDir = dir.checked ? -1 : 1; saveSettings(); });

    modalRoot.querySelectorAll(".gesture-row select").forEach((sel) => {
      sel.value = settings.gestures[sel.dataset.gkey] || "none";
      sel.addEventListener("change", () => { settings.gestures[sel.dataset.gkey] = sel.value; saveSettings(); });
    });

    modalRoot.querySelectorAll("#set-layout button").forEach((b) => {
      b.classList.toggle("on", b.dataset.lay === (settings.layoutMode || "auto"));
      b.addEventListener("click", () => {
        settings.layoutMode = b.dataset.lay;
        saveSettings(); applyLayoutMode(); renderDeck();
        modalRoot.querySelectorAll("#set-layout button").forEach((x) => x.classList.toggle("on", x === b));
      });
    });

    modalRoot.querySelectorAll("#set-theme button").forEach((b) => {
      b.classList.toggle("on", b.dataset.theme === (settings.theme || "dark"));
      b.addEventListener("click", () => {
        settings.theme = b.dataset.theme; saveSettings(); applyTheme();
        modalRoot.querySelectorAll("#set-theme button").forEach((x) => x.classList.toggle("on", x === b));
      });
    });

    modalRoot.querySelector("#set-reset").addEventListener("click", () => {
      settings = Object.assign({}, SETTINGS_DEFAULTS); saveSettings(); applyTheme(); openSettings();
    });
    updateLogos();   // About 로고를 현재 테마에 맞게
  }
  document.getElementById("settings-btn").addEventListener("click", openSettings);

  // ═════════ 트랙패드 ═════════
  const ACCEL_CAP = 30;   // 가속 상한(px/이벤트). 배율/가속량/스크롤은 settings 에서 조절
  const TAP_MS = 250, TAP_MOVE = 8, DOUBLE_MS = 300;
  const FRICTION = 0.92, MOMENTUM_MIN = 0.04;
  const SWIPE3_THRESH = 45, PINCH_DECIDE = 12, ZOOM_STEP = 0.12;

  const pad = document.getElementById("trackpad");
  let startTime = 0, moved = false, maxTouches = 0;
  let dragging = false, armedForDrag = false;
  let last = null, lastCentroid = null;
  let scrollVX = 0, scrollVY = 0, lastScrollMoveT = 0, momentumRAF = null;
  let lastClickTime = 0, clickCount = 0, lastTapEnd = 0;
  let threeMode = false, g3fired = false, g3start = null, g3last = null;
  let twoMode = null, d0 = 0, c0 = null, lastZoomDist = 0;

  function now() { return performance.now(); }
  function centroid(touches) { let x = 0, y = 0; for (const t of touches) { x += t.clientX; y += t.clientY; } return { x: x / touches.length, y: y / touches.length }; }
  function dist2(touches) { const dx = touches[0].clientX - touches[1].clientX, dy = touches[0].clientY - touches[1].clientY; return Math.hypot(dx, dy); }
  function stopMomentum() { if (momentumRAF) { cancelAnimationFrame(momentumRAF); momentumRAF = null; } scrollVX = 0; scrollVY = 0; }
  function startMomentum() {
    if (Math.hypot(scrollVX, scrollVY) < MOMENTUM_MIN) return;
    let prev = now();
    const step = (t) => {
      const dt = Math.min(t - prev, 32); prev = t;
      scrollVX *= FRICTION; scrollVY *= FRICTION;
      if (Math.hypot(scrollVX, scrollVY) < MOMENTUM_MIN) { momentumRAF = null; return; }
      queueScroll(scrollVX * dt * settings.scrollSpeed * settings.scrollDir, scrollVY * dt * settings.scrollSpeed * settings.scrollDir);
      momentumRAF = requestAnimationFrame(step);
    };
    momentumRAF = requestAnimationFrame(step);
  }
  // ───────── 제스처 → 기능 할당 ─────────
  // 3·4손가락 스와이프(각 4방향)에 원하는 동작을 설정(⚙ → 제스처 할당)으로 배정한다.
  // 사파리는 동시 터치 5개까지 추적하므로 손가락 수는 touches.length 로 판별.
  const GESTURE_ACTIONS = {
    none: { label: "없음", run: () => {} },
    back: { label: "뒤로 (⌘←)", run: () => send({ t: "key", keyCode: 123, mods: ["command"] }) },
    forward: { label: "앞으로 (⌘→)", run: () => send({ t: "key", keyCode: 124, mods: ["command"] }) },
    mission: { label: "미션 컨트롤", run: () => send({ t: "launch", target: "/System/Applications/Mission Control.app" }) },
    expose: { label: "앱 엑스포제 (⌃↓)", run: () => send({ t: "key", keyCode: 125, mods: ["control"] }) },
    appswitch: { label: "앱 전환 (⌘⇥)", run: () => send({ t: "key", keyCode: 48, mods: ["command"] }) },
    tabPrev: { label: "이전 탭 (⇧⌘[)", run: () => send({ t: "key", keyCode: 33, mods: ["command", "shift"] }) },
    tabNext: { label: "다음 탭 (⇧⌘])", run: () => send({ t: "key", keyCode: 30, mods: ["command", "shift"] }) },
    spotlightSearch: { label: "스팟라이트 검색 (⌘Space)", run: () => send({ t: "key", keyCode: 49, mods: ["command"] }) },
    raycast: { label: "Raycast (⇧Space)", run: () => send({ t: "key", keyCode: 49, mods: ["shift"] }) },
    whisper: { label: "superwhisper (⌥Space)", run: () => send({ t: "key", keyCode: 49, mods: ["option"] }) },
    presSpot: { label: "발표 스팟라이트 토글", run: () => send({ t: "launch", target: "macpilot://spotlight" }) },
    volUp: { label: "음량 올리기", run: () => send({ t: "volume", dir: "up" }) },
    volDown: { label: "음량 내리기", run: () => send({ t: "volume", dir: "down" }) },
    mute: { label: "음소거", run: () => send({ t: "volume", dir: "mute" }) },
    capture: { label: "영역 캡처 (⇧⌘4)", run: () => send({ t: "key", keyCode: 21, mods: ["command", "shift"] }) }
  };
  const GESTURE_SLOTS = [
    ["s3left", "3손가락 ←"], ["s3right", "3손가락 →"], ["s3up", "3손가락 ↑"], ["s3down", "3손가락 ↓"],
    ["s4left", "4손가락 ←"], ["s4right", "4손가락 →"], ["s4up", "4손가락 ↑"], ["s4down", "4손가락 ↓"]
  ];
  const DEFAULT_GESTURES = {
    s3left: "back", s3right: "forward", s3up: "mission", s3down: "expose",
    s4left: "tabPrev", s4right: "tabNext", s4up: "appswitch", s4down: "presSpot"
  };
  if (!settings.gestures) settings.gestures = {};
  settings.gestures = Object.assign({}, DEFAULT_GESTURES, settings.gestures);

  let gFingers = 3;   // 이번 제스처의 손가락 수 (3 또는 4+)
  function fireSwipeIfNeeded() {
    if (g3fired || !g3start || !g3last) return;
    const dx = g3last.x - g3start.x, dy = g3last.y - g3start.y;
    if (Math.hypot(dx, dy) < SWIPE3_THRESH) return;
    const dir = Math.abs(dx) > Math.abs(dy) ? (dx < 0 ? "left" : "right") : (dy < 0 ? "up" : "down");
    flushMotion(true);
    const key = "s" + Math.min(gFingers, 4) + dir;
    const action = GESTURE_ACTIONS[settings.gestures[key]] || GESTURE_ACTIONS.none;
    buzz();
    action.run();
    g3fired = true;
  }

  pad.addEventListener("touchstart", (e) => {
    e.preventDefault(); stopMomentum(); flushMotion(true);
    const n = e.touches.length;
    if (n === 1) {
      startTime = now(); moved = false; maxTouches = 1; dragging = false;
      threeMode = false; g3fired = false; g3start = null; g3last = null; twoMode = null;
      last = { x: e.touches[0].clientX, y: e.touches[0].clientY };
      armedForDrag = !buttonHeld() && (now() - lastTapEnd) < DOUBLE_MS;
    } else { maxTouches = Math.max(maxTouches, n); armedForDrag = false; }
    if (n === 2) { twoMode = null; d0 = dist2(e.touches); c0 = centroid(e.touches); lastZoomDist = d0; }
    if (n >= 3) {
      if (!threeMode) { threeMode = true; gFingers = n; g3start = centroid(e.touches); g3last = g3start; }
      else { gFingers = Math.max(gFingers, n); }   // 3→4손가락 추가 감지
    }
    lastCentroid = centroid(e.touches);
  }, { passive: false });

  pad.addEventListener("touchmove", (e) => {
    e.preventDefault();
    const len = e.touches.length;
    if (threeMode) { if (len >= 3) { g3last = centroid(e.touches); fireSwipeIfNeeded(); } moved = true; return; }
    if (len === 2) {
      const c = centroid(e.touches), d = dist2(e.touches);
      if (twoMode === null) {
        const distChange = Math.abs(d - d0), transChange = c0 ? Math.hypot(c.x - c0.x, c.y - c0.y) : 0;
        if (Math.max(distChange, transChange) > PINCH_DECIDE) { twoMode = distChange > transChange ? "pinch" : "scroll"; if (twoMode === "pinch") lastZoomDist = d; }
      }
      if (twoMode === "pinch") {
        const ratio = d / lastZoomDist;
        if (ratio > 1 + ZOOM_STEP) { send({ t: "zoom", dir: "in" }); lastZoomDist = d; }
        else if (ratio < 1 - ZOOM_STEP) { send({ t: "zoom", dir: "out" }); lastZoomDist = d; }
      } else if (twoMode === "scroll") {
        if (lastCentroid) {
          const dx = c.x - lastCentroid.x, dy = c.y - lastCentroid.y;
          const t = now(), dt = Math.max(t - lastScrollMoveT, 1);
          scrollVX = 0.6 * scrollVX + 0.4 * (dx / dt); scrollVY = 0.6 * scrollVY + 0.4 * (dy / dt); lastScrollMoveT = t;
          if (Math.abs(dx) > 0.1 || Math.abs(dy) > 0.1) queueScroll(dx * settings.scrollSpeed * settings.scrollDir, dy * settings.scrollSpeed * settings.scrollDir);
        }
      }
      lastCentroid = c; moved = true; armedForDrag = false;
    } else if (len === 1 && last) {
      const x = e.touches[0].clientX, y = e.touches[0].clientY;
      const dx = x - last.x, dy = y - last.y;
      if (Math.abs(dx) > TAP_MOVE || Math.abs(dy) > TAP_MOVE) moved = true;
      if (armedForDrag && !dragging && moved) { dragging = true; send({ t: "down", button: "left" }); }
      if (dx !== 0 || dy !== 0) {
        if (dragging) queueMove(dx * settings.moveSpeed, dy * settings.moveSpeed);
        else { const speed = Math.hypot(dx, dy); const f = settings.moveSpeed * (1 + Math.min(speed, ACCEL_CAP) * settings.accel); queueMove(dx * f, dy * f); }
      }
      last = { x, y };
    }
  }, { passive: false });

  pad.addEventListener("touchend", (e) => {
    e.preventDefault();
    if (threeMode) {
      fireSwipeIfNeeded();
      if (e.touches.length === 0) { threeMode = false; g3fired = false; g3start = null; g3last = null; twoMode = null; last = null; lastCentroid = null; maxTouches = 0; armedForDrag = false; }
      return;
    }
    if (e.touches.length === 0) {
      if (dragging) { flushMotion(true); send({ t: "up", button: "left" }); dragging = false; }
      else {
        const duration = now() - startTime;
        if (!moved && duration < TAP_MS && !buttonHeld()) {
          if (maxTouches >= 2) { send({ t: "click", button: "right" }); clickCount = 0; lastClickTime = 0; }
          else { const t = now(); clickCount = (t - lastClickTime < DOUBLE_MS) ? clickCount + 1 : 1; lastClickTime = t; send({ t: "click", button: "left", count: clickCount }); }
          lastTapEnd = now();
        } else if (moved && twoMode === "scroll" && (now() - lastScrollMoveT) < 120) { flushMotion(true); startMomentum(); }
      }
      flushMotion(true);
      last = null; lastCentroid = null; maxTouches = 0; armedForDrag = false; twoMode = null;
    } else {
      if (e.touches.length === 1) last = { x: e.touches[0].clientX, y: e.touches[0].clientY };
      lastCentroid = centroid(e.touches);
    }
  }, { passive: false });

  pad.addEventListener("touchcancel", () => {
    if (threeMode) fireSwipeIfNeeded();
    if (dragging) { flushMotion(true); send({ t: "up", button: "left" }); dragging = false; }
    threeMode = false; g3fired = false; g3start = null; g3last = null; twoMode = null;
    last = null; lastCentroid = null; maxTouches = 0; armedForDrag = false;
  }, { passive: false });

  renderDeck();
  setSheetPos(sheetPos, false);         // 시작 시 기억된 높이로 (기본: 풀화면)
  connect();
})();
