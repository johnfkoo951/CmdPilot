# 폰/태블릿 화면 문서 (CmdPilot Web Client)

> 폰 쪽 UI는 바닐라 `index.html` + `style.css` + `app.js`(빌드 스텝·프레임워크 0). 이 문서는 **화면 구조 · 기기 분류(iPhone/Galaxy/iPad) · 반응형 · 탭별 UI · 화면별 와이어 프로토콜**을 정리한다.
> 관련: `docs/VIEWPORT.md`(**iOS Safari↔standalone 뷰포트·safe-area 설계 원칙 — 필독**), `docs/MULTIPLEXER_BRIDGE_PLAN.md`(에이전트 탭의 다중 백엔드), `docs/CMUX_BRIDGE.md`, `docs/DEVELOPMENT.md`.

---

## 0. 한눈에

- 단일 페이지. 하단 **탭바 6개**(키보드 · **cmux** · **herdr** · 터미널 · 미러 · 덱)로 패널 전환.
- 어느 탭에서나 **트랙패드 시트**(하단, 핸들로 높이 조절)와 **퀵바 2줄**이 상시 노출.
- **기기 분류**는 뷰포트 긴 변으로 자동 판정 → iPhone/Galaxy = `phone`, iPad = `tablet-sm/lg`. 큰 화면·가로는 **도킹(docked)** 레이아웃(트랙패드 + 패널 나란히).
- 설정 없이 브라우저로 접속(선택적 PWA 홈 화면 설치). `https`면 `wss`, 아니면 `ws` 자동.

---

## 1. 기기 분류 & 반응형 (`classifyDevice` / `applyDeviceClass`)

뷰포트 **긴 변(longest)** + 방향으로 클래스를 `<html>`에 토글한다.

| 클래스 | 조건(긴 변) | 대표 기기 |
|---|---|---|
| `phone` | ≤ 950 | **iPhone**(Pro Max 932) · **Galaxy**(대부분) |
| `tablet-sm` | ≤ 1150 | **iPad mini**(1133) · 소형 태블릿 |
| `tablet-lg` | > 1150 | **iPad**·11"·12.9" Pro |

- 수동 override: 설정 `layoutMode` = `auto`(기본) / `phone` / `tablet`.
- 방향: `orient-land`(가로) / `orient-port`(세로) 토글.
- **도킹**: `isTablet && min(vw,vh) ≥ 680` → `docked`. 트랙패드와 활성 패널을 **나란히** 배치(아래 §7).
- 덱 그리드도 기기별로 달라짐(`deckGrid`):

| 클래스 | 가로 | 세로 |
|---|---|---|
| tablet-lg | 5×4 | 7×6 |
| tablet-sm | 4×3 | 5×5 |
| phone | 3×3 | 3×3 |

- 리렌더는 레이아웃 시그니처(`cls+방향+docked`)가 바뀔 때만 → 리사이즈 깜빡임 방지.
- Android 햅틱: `navigator.vibrate(8)`(iOS는 무시). 물리 키보드 감지 시 `has-hwkb`.

---

## 2. 공통 크롬

| 요소 | 내용 |
|---|---|
| `#bar` 헤더 | 로고 · 연결 점(`#dot`) · 상태 텍스트(`#status`, 지연 ms) · 설정(⚙) |
| `#tabbar` | 키보드 · cmux · herdr · 터미널 · 미러 · **덱(기본 활성)** |
| `#quickbar` | 위스퍼(⌥Space) · Raycast(⇧Space) · 앱 전환(⌘Tab) · 미션 컨트롤 · 캡처 메뉴 |
| `#quickbar2` | 메인 볼트 · 위키 볼트 · cmux 열기 · 앱 내 창 전환(다음/이전) |
| `#tp-sheet` | 트랙패드 시트(핸들 드래그: 풀·부분·닫힘) + 좌/우클릭 + 🛸 에어마우스 |
| `#dock-bar` | (도킹 시) 패널 배치 · 컴패니언 슬롯 · 분할 프리셋 |

---

## 3. 탭별 화면

### 3.1 덱 (deck) — 기본 탭
- 미디어 바(음량/밝기), 폴더 탭, 페이지(스와이프), 페이지 도트.
- Stream-Deck 스타일 버튼(앱 실행·키·매크로). 편집 모드로 커스터마이즈.

### 3.2 키보드 (keyboard)
- 조합키 칩(⌘⌃⇧⌥) · 특수키(esc/⇥/⌫/return/화살표) · 텍스트영역 · 빠른 보내기.
- 한글은 IME 조합 완성형만 전송(자소분리 방지).

### 3.3 에이전트 (agent) — **다중 백엔드 (재구조화됨)** ⭐
아래 §4 상세.

### 3.4 미러 (mirror)
- 맥 화면 실시간(WKWebView 아닌 canvas + JPEG 프레임). 탭=클릭, 길게=우클릭, 드래그=이동, 두 손가락=스크롤.
- 모니터 탭(다중 디스플레이), 키보드 입력, 전체화면/맞춤.

### 3.5 터미널 (term) — **백엔드 인지 + 라인 버퍼 입력**
- 포커스 pane 화면을 **텍스트 그리드**로 미러(`renderTermGrid`).
- **입력은 라인 버퍼**: 입력창에 텍스트를 쌓아 **보이게** 두고 **⏎ 로 한 줄을 전송**(`wireTerm`/`sendLine`). → 글자가 보이고, 문자별 딜레이·한글 자소분리가 없다(모바일+원격+IME 안전). 상단 키(esc·tab·⌃C·↑·↓)는 raw 즉시 전송, ⏎ 는 라인 전송.
- `currentBackend`(cmux/herdr)의 터미널을 읽고 쓴다. herdr 탭의 "터미널 보기"가 backend=herdr로 진입.
- **두 백엔드 모두 ANSI 트루컬러로 렌더**: cmux=`mobile.terminal.replay`(styled grid), herdr=`pane read --source visible --format ansi` → Swift SGR 파서(`HerdrBackend.ansiGrid`, 24bit/256/16색 + bold/italic/faint/inverse)가 동일 `row_spans`+`styles` 스키마로 변환. ANSI 실패 시 평문 폴백.

### 3.6 herdr (herdr) — **원격 에이전트 상태 대시보드** ⭐
herdr 전용 탭. herdr의 킬러 기능(네이티브 agent 상태)을 상태-우선으로 보여준다.
- **에이전트 상태 카드**: `agent list` 기반(⚠️ herdr는 **`--json` 없이 JSON 네이티브 출력** — `--json`을 붙이면 "unknown command". 배열은 `result.agents[]` 아래, 필드 `agent`/`agent_status`/`pane_id`/`cwd`/`focused`). 각 카드에 색점(🟠작업·🔴차단·🟢완료·⚪대기) + 이름 + 상태. **차단>완료>작업>대기 순 정렬** → "나를 기다리는" 에이전트가 위로.
- 워크스페이스는 `workspace list`(`result.workspaces[]`, 필드 `workspace_id`/`label`/`focused`). 칩 탭 → `workspace focus <id>`.
- 카드 탭 → `agent focus <pane_id>`. "터미널 보기" → term 탭(backend=herdr), **ANSI 트루컬러 렌더**(§3.5).
- 상태: `available:false`(미설치 — herdr는 `~/.local/bin/herdr`) / `denied`(herdr 소켓/서버 미기동·원격 SSH 실패) 안내.
- 와이어: `{t:"cmux", backend:"herdr", dir:"state"}` → `renderHerdr`. **실측 검증 완료(2026-07): 로컬 herdr 2 워크스페이스·2 claude 에이전트 + `pane read --format ansi` 색 렌더 end-to-end 확인.** herdr는 앱이 아니라 **Ghostty 등 터미널 안에서 도는 TUI** — cmux 탭 "터미널 앱 열기"의 Ghostty 버튼으로 띄운다.

### 3.6 트랙패드 시트
- 한 손가락 이동 · 탭 좌클릭 · 두 손가락 스크롤·핀치 · 세 손가락 데스크탑.
- 🛸 에어마우스(기기 기울기 → 커서). iOS는 HTTPS(secure context)에서만 모션 허용.

---

## 4. 에이전트 탭 상세 — 다중 멀티플렉서 백엔드

폰의 에이전트 탭이 **여러 멀티플렉서 백엔드**(cmux 로컬 · herdr 원격 …)를 하나의 UI로 조종한다.
백엔드는 Mac 헬퍼가 `available`을 판정해 스위처에 노출한다(설계: `docs/MULTIPLEXER_BRIDGE_PLAN.md`).

### 4.1 구성 요소

```
┌─ 에이전트 원격 — 창 · 워크스페이스 · 탭        [↻]
├─ [ cmux ] [ herdr@devbox ]      ← #mux-switch  백엔드 스위처(2개 이상일 때만 표시)
├─ 창 1  [ws A] [ws B*] [ws C]    ← #cmux-remote 토폴로지 칩(선택=강조)
│  탭 · 에이전트 (현재 워크스페이스)
│  [● 빌드]  [● 배포]  [● 리뷰]    ← 상태 배지(●)가 붙은 탭 칩
├─ 제어:  ⏎ 입력·승인 / esc 중단 / ⌃C 강제중단 / ↑↓⇥ / y⏎ n⏎
├─ 빠른 지시: 계속해줘 · 진행상황 요약 · /compact · /clear · 테스트 · 커밋
└─ 앱:  ❯ cmux 열기 · ◆ Codex 열기
```

### 4.2 백엔드 스위처 (`#mux-switch` / `renderMuxSwitch`)
- `state.backends`(= `[{id,label,available}]`)에서 **available 한 것만** 칩으로.
- **1개뿐이면 숨김**(단일 백엔드 사용자는 스위처를 안 봄).
- 칩 탭 → `setBackend(id)`: `currentBackend` 변경 → 상태·터미널 강제 리렌더.

### 4.3 에이전트 상태 배지 (⑤) — 백엔드별 신뢰도가 다름
탭 칩 앞의 색 점(`.mux-dot`)이 에이전트 상태를 표시:

| 상태 | 색 | 의미 |
|---|---|---|
| `working` | 🟠 amber | 작업 중 |
| `blocked` | 🔴 red(점멸) | 입력 대기 — "가서 봐" |
| `done` | 🟢 green | 끝남(아직 안 봄) |
| `idle` | ⚪ gray | 대기 |

- **herdr**: `agent list`의 네이티브 시맨틱 상태(idle/working/blocked/unknown, JSON 네이티브) → 정확.
- **cmux**: 탭 제목 스크레이핑 기반이라 상태 필드가 없으면 배지 없음(구조상 덜 정밀).
- 상태가 없으면 배지 미표시(무해).

### 4.4 상태 안내(denied) — 백엔드별 문구
- cmux denied → "cmux 소켓 권한 대기 중 — cmux를 한 번 재시작하면…"
- herdr denied → "herdr에 연결할 수 없습니다 — 원격에 herdr가 떠 있는지·SSH 연결을 확인하세요"
- unavailable → "<backend>가 설치/설정되어 있지 않습니다"

### 4.5 폴링
- 에이전트 탭 표시 중 **4초 주기** 상태 폴링(`visibilityState==visible`일 때만). 상태 불변 시 리렌더 생략.
- 터미널 탭은 **0.7초** 그리드 폴링.

---

## 5. 화면별 와이어 프로토콜

`InboundCommand`(Swift)가 진실의 원천. 에이전트/터미널은 `backend` 필드로 백엔드 선택(없으면 cmux).

| 화면 | 폰→Mac 메시지 | Mac→폰 응답 |
|---|---|---|
| 트랙패드/미러 | `move`·`down`·`up`·`click`·`scroll`·`gesture`·`zoom` | (없음) / 미러 프레임(binary) |
| 키보드 | `key`·`text`·`macro` | (없음) |
| 덱 | `launch`·`getDeck`·`saveDeck`·`getApps`·`volume`·`brightness` | `deck`·`apps` |
| **에이전트** | `{t:"cmux", backend, dir:"state"\|"select-workspace"\|"focus-window"\|"focus-tab", target}` | `{t:"cmux", backend, available, denied, windows[], tabs[], backends[]}` (tabs[].state) |
| **터미널** | `{t:"cterm", backend, action:"grid"}` · `{t:"cterm", backend, action:"input", text, handle?}` | `{t:"ctermGrid", grid}` |
| 미러 | `{t:"mirror", action:"start"\|"stop"\|"config"\|"displays"\|"select", …}` | `mirrorInfo`·`mirrorDisplays`·프레임 |
| 창 전환 | `{t:"window", dir:"next"\|"prev"}` | `{t:"window", ok, …}` |
| 진단 | `ping` | `pong` |

- 새 필드: `backend`(문자열, 기본 cmux) · `handle`(pane 핸들, 없으면 포커스). 하위호환(구 클라이언트는 backend 없이 보내도 cmux로 라우팅).

---

## 6. 반응형 레이아웃 요약

| 상황 | 레이아웃 |
|---|---|
| phone (iPhone/Galaxy) | 단일 패널 풀스크린 + 하단 탭바 + 트랙패드 시트(오버레이) |
| tablet 비도킹 | phone과 유사하나 덱/에이전트 그리드 열 수 증가(`html.wide .agent-grid.g2 → 3열`) |
| **docked** (iPad 가로/큰 화면) | 트랙패드 **+** 활성 패널을 그리드로 나란히. `#dock-splitter`로 비율 조절, `#dock-bar`로 패널·컴패니언(트랙패드/키보드/없음)·분할 프리셋(작게 .38 / 균형 .5 / 크게 .62) 선택 |

- 에이전트 탭의 `#mux-switch`·상태 배지는 flex-wrap이라 phone/tablet 모두 자연스럽게 접힘.

---

## 7. 파일 맵

| 파일 | 역할 |
|---|---|
| `MacHelper/Web/index.html` | 마크업 — 탭·패널·에이전트/터미널·트랙패드·퀵바·도킹 바 |
| `MacHelper/Web/style.css` | 스타일 — 기기 클래스(`phone`/`tablet-*`/`docked`/`orient-*`) 반응형, `.mux-switch`/`.mux-dot` |
| `MacHelper/Web/app.js` | 로직 — `classifyDevice`/`applyDeviceClass`(반응형), `selectTab`(탭), `renderMuxSwitch`/`setBackend`/`renderCmux`(다중 백엔드), `renderTermGrid`(터미널), 미러·덱·트랙패드 |
| `MacHelper/Sources/MultiplexerBackend.swift` | 백엔드 프로토콜 + `BridgeRouter`(라우팅·`backends` 목록) |
| `MacHelper/Sources/CmuxBackend.swift` · `HerdrBackend.swift` | cmux(로컬) · herdr(로컬/원격 SSH) 어댑터 |
| `MacHelper/Sources/InboundCommand.swift` | 와이어 계약(+`backend`/`handle`) |

> **웹만 수정 시 재빌드 불필요**: `./script/macpilotctl.sh sync-web`로 App Support 오버라이드에 rsync(서버가 번들보다 우선 서빙). 단 **Swift(백엔드) 변경은 재빌드·재배포 필요**.
