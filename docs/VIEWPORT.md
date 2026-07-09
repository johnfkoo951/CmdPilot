# iOS 웹앱 뷰포트 · Safe-Area 설계 원칙

> 폰용 풀높이 웹 UI를 **Safari**와 **홈 화면 추가(standalone PWA)** 양쪽에서 깔끔하게 만드는 원칙.
> MacPilot에서 겪은 "standalone 하단 빈 띠" 버그의 근본 원인과 해법을 일반 원칙으로 정리 — **다른 앱에도 그대로 재사용**.
> 근거: 2026-07 공식 소스(WebKit·W3C·Apple 포럼) 대조 조사 + 적대적 검증. 하단 §출처.

---

## 0. TL;DR — 한 문장 원칙

> **셸 높이를 "하나의 값"으로 고정하지 마라. 모드별로 소스를 갈라라 — 키보드 열림=`visualViewport`, standalone=`innerHeight`, Safari=`visualViewport`. 그리고 safe-area는 콘텐츠가 아니라 "최하단 고정 바"에서만 흡수하라.**

이유: **Safari와 standalone은 하단에서 정반대로 동작**한다. 한 값으로 묶으면 한쪽이 반드시 깨진다.

---

## 1. 왜 두 모드가 다른가 — 하단의 두 좌표계

| | **Safari** (하단 URL 바 있음) | **standalone** (홈 화면 웹앱, URL 바 없음) |
|---|---|---|
| 하단 크롬 | URL 바가 홈 인디케이터 영역을 **덮음** | 없음 → 홈 인디케이터가 **노출** |
| `env(safe-area-inset-bottom)` | **0px** (URL 바가 이미 그 자리 차지) | **~34px** (홈 인디케이터, Face ID 기기) |
| `visualViewport.height` | URL 바 **제외**한 가시영역 (정확) | 물리 바닥보다 **~24~34px 짧게** 보고 (부정확) |
| `window.innerHeight` | URL 바 접힌 **큰** 뷰포트 (고전적 100vh 초과 문제) | **물리 풀높이**(홈 인디케이터 포함) — 정확 |

**핵심 비대칭**: `env(safe-area-inset-bottom)`이 Safari=0 / standalone=34. **같은 CSS가 두 모드에서 정반대 값을 받는다.** 그래서 한쪽 기준으로 튜닝하면 다른 쪽에서 빈 띠(standalone) 또는 URL 바 뒤로 숨음(Safari)이 난다.

### MacPilot에서 났던 증상
- Safari: 탭바가 URL 바 위에 깔끔 ✓ (visualViewport.height가 URL 바를 제외 → body가 딱 맞음)
- standalone: 탭바 아래 **한 줄 높이 검은 띠** ✗ — body 높이를 `visualViewport.height`(짧게 보고됨)에 묶어, body가 물리 바닥보다 위에서 끝나고 그 갭이 배경색(`--bg`)으로 칠해짐.

---

## 2. 높이 · Safe-area 값 레퍼런스 (viewport-fit=cover 전제, iOS 15.4+)

| 값 | 무엇을 가리키나 | 소프트키보드에 반응? |
|---|---|---|
| `100svh` | 접히는 바 **보이는** 상태의 최소 높이(고정) | ❌ |
| `100lvh` | 바 **숨은** 상태의 최대 높이(고정, 첫 페인트 도달 불가→빈 줄) | ❌ |
| `100dvh` | svh↔lvh 실시간 보간 (주소창은 추적) | ❌ **키보드로 안 줄어듦** |
| `window.innerHeight` | 주소창 접힌 큰 뷰포트 / standalone은 물리 풀높이 | ❌ |
| `visualViewport.height` | 상하 크롬 **사이 현재 가시영역** (URL 바·키보드 제외) | ✅ **유일하게 키보드만큼 줄어듦** |

> **결정적 사실**: 소프트키보드는 `dvh`(레이아웃 뷰포트)를 **밀지 않는다**(W3C 설계). 키보드 오프셋을 반영하는 CSS 단위는 **2026년에도 없다**(W3C csswg-drafts #7194 open). → **셸을 키보드 위로 수축시키려면 JS로 `visualViewport.height`를 읽는 수밖에 없다.**

> `env(safe-area-inset-*)`는 `<meta viewport-fit=cover>`가 **없으면 전부 0**. cover는 전제조건.

---

## 3. iOS 26 `visualViewport` 회귀 (알아둘 것, 과신 금지)

- 커뮤니티 재현(Apple 포럼 thread 800125): **소프트키보드를 한 번 연 뒤**부터, 키보드를 닫아도 `visualViewport.height`가 `innerHeight`보다 **~24px 작게 상주**. WebKit 297779 / FB19889436로 추적 중.
- 상태: **Apple이 공식 버그로 확정한 건 아님**(엔지니어링팀 라우팅). **iOS 26.1 beta에서 수정됐다는 보고**(26.0.1 미수정).
- 함의: MacPilot처럼 키보드를 자주 쓰는 앱은 이 잔차가 상시화되기 쉽다 → **셸 높이를 `visualViewport.height`에 묶으면 검은 띠가 영구화**. 아래 원칙(모드별 소스)이 이 회귀와 무관하게 옳은 이유.

---

## 4. 원칙 (재사용 레시피)

### P1. 모드별 '다른 메커니즘' — Safari=높이값, standalone=물리 확장 + 구분 배경

> ⚠️ **실측(iPhone 16 Pro, iOS 26)**: standalone에서 **웹 뷰포트=894, 물리 화면=956** — 위 28 + 아래 34(홈 인디케이터)의 safe-area가 **뷰포트 밖**이다(`innerHeight`·`visualViewport.height`·`clientHeight` 전부 894 보고). 그래서:
> 1. 어떤 '높이 값'도 물리 바닥에 못 닿음 → `inset:0`조차 뷰포트 바닥(894)까지만. **body를 `bottom: calc(-1 * env(safe-area-inset-bottom))`로 strip만큼 아래로 확장**해야 하단 바가 물리 바닥(956)까지 닿는다.
> 2. 이건 Safari에선 탭바를 URL 바 뒤로 숨기므로 **`html.standalone`로 한정**.
> 3. **★ 그것만으론 안 끝난다** — 바가 바닥까지 닿아도 **배경색이 페이지와 같으면** safe-area 여백이 "빈 검은 띠"로 보인다(실제로 여기서 두 번 헛발질). **하단 바에 페이지와 구분되는 배경색**(예: `--surface`)을 줘야 바로 읽힌다.

CSS:
```css
body { height: var(--app-height, 100dvh); }                        /* Safari: JS가 visualViewport.height 공급 */
/* standalone: body를 홈 인디케이터 strip(env)만큼 아래로 확장 → 하단 바가 물리 바닥까지 닿음 */
html.standalone body { position: fixed; top: 0; right: 0; left: 0; height: auto;
                       bottom: calc(-1 * env(safe-area-inset-bottom, 0px)); }
html.standalone.kb-open body { bottom: var(--kb-height, 0px); }    /* 키보드 위로 수축 */
/* 하단 바: 페이지와 '구분되는' 배경 + safe-area 흡수 → strip이 '바'로 읽힘(빈 띠 X) */
#tabbar { background: var(--surface); padding-bottom: max(env(safe-area-inset-bottom, 0px), 4px); }
html.kb-open #tabbar { padding-bottom: 0; }
```
JS (Safari 높이 + 키보드 인셋만 계산):
```js
const vvp = window.visualViewport;
function setAppHeight() {
  root.style.setProperty("--app-height", Math.round(vvp ? vvp.height : innerHeight) + "px"); // Safari 높이
  const kb = vvp ? Math.max(0, innerHeight - vvp.height - (vvp.offsetTop || 0)) : 0;
  root.style.setProperty("--kb-height", Math.round(kb) + "px");
  root.classList.toggle("kb-open", kb > 100);   // 후보바(~55px)·iOS26 잔차(~24px) 제외
}
```

### P2. Safe-area는 "최하단 고정 바"에서만 흡수 (콘텐츠 아님)
홈 인디케이터를 물리적으로 덮는 요소(=탭바)가 `padding-bottom`으로 아이콘/라벨을 인셋만큼 올리고, **배경은 물리 바닥까지** 흘린다. 콘텐츠에 인셋 패딩을 주면 스크롤 위 죽은 여백만 생긴다.
```css
#tabbar { padding-bottom: max(env(safe-area-inset-bottom, 0px), 4px); }
html.kb-open #tabbar { padding-bottom: 0; }   /* 키보드가 인디케이터를 가림 → 죽은 여백 제거 */
```

### P3. 이벤트는 `visualViewport`의 `resize` + `scroll` (window 'resize' 신뢰 금지)
iOS Safari는 `window` `resize`가 뷰포트 변화에 **미발화/부정확**. 주소창 접힘·키보드는 `visualViewport`의 `resize`/`scroll`이 정확.
```js
vvp.addEventListener("resize", setAppHeight);
vvp.addEventListener("scroll", setAppHeight);   // offsetTop 단독 변화까지 반영(필수)
```

### P4. 전제 메타 (한 번만)
```html
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<meta name="apple-mobile-web-app-capable" content="yes">
<meta name="apple-mobile-web-app-status-bar-style" content="black-translucent">
```

### P5. 키보드 판정 임계 ~100–120px
`kb = innerHeight - vvp.height - vvp.offsetTop`. 물리 키보드 후보바(~55px)·iOS26 잔차(~24px)·주소창(44~88px)과 구분하려면 임계 100+.

---

## 5. 안티패턴 (하지 말 것)

| 안티패턴 | 왜 깨지나 |
|---|---|
| 셸 높이 = `visualViewport.height` **단일** | standalone에서 짧게 보고 → **하단 빈 띠** (MacPilot 원래 버그) |
| standalone 풀높이를 `innerHeight`나 `visualViewport.height`로 잼 | 둘 다 홈 인디케이터만큼 짧게 보고 → 빈 띠. `inset:0`도 뷰포트(894)까지만 — **body를 `bottom:calc(-1*env(…))`로 strip만큼 확장**해야 물리 바닥에 닿음 |
| `inset:0`를 **Safari에도**(모드 무관) 적용 | Safari에서 탭바가 URL 바 뒤로 숨음 → **`html.standalone`로 한정** |
| **하단 바 배경 == 페이지 배경** | 바가 물리 바닥까지 닿아도 safe-area 여백(홈 인디케이터 예약)이 **빈 검은 띠로 보임**. 바에 구분 배경(`--surface`)을 줘라 (← 이번 버그의 최종 원인) |
| 셸 높이 = 바로 `100dvh`만 | 키보드로 안 줄어듦(입력창 가림) + standalone 콜드스타트 오값 보고 사례 |
| 탭바 인셋 클램프(`min(env,22px)`)를 body 미수정 채 제거 | body가 바닥에 안 닿으면 **빈 띠 + 홈 인디케이터가 라벨 가림** 이중 악화 |
| 콘텐츠 컨테이너에 `padding-bottom: env(safe-area-inset-bottom)` | 스크롤 위 죽은 여백 |

> ⚠️ **결합 위험**(검증 지적): "탭바 클램프 제거"는 "body가 모드별로 물리 바닥까지 닿는다"에 **의존**한다. 둘은 세트로만 안전하다 — 반드시 **실기기(Face ID·세로)로 함께 확인**.

---

## 6. MacPilot 적용 위치

| 파일 | 무엇 |
|---|---|
| `MacHelper/Web/index.html:5-9` | viewport-fit=cover + web-app-capable + black-translucent |
| `MacHelper/Web/app.js` `setAppHeight()` | P1 모드별 높이 소스 + P3 이벤트 |
| `MacHelper/Web/style.css` `body` | `height: var(--app-height, 100dvh)` (P1이 공급) |
| `MacHelper/Web/style.css` `#tabbar` / `html.kb-open #tabbar` | P2 safe-area 흡수 |

---

## 7. 미래 앱용 체크리스트

- [ ] `<meta viewport-fit=cover>` 있는가 (없으면 env() 전부 0)
- [ ] 셸 높이가 **모드별**로 갈리는가 (키보드=vvp / standalone=innerHeight / Safari=vvp)
- [ ] safe-area를 **최하단 바에서만** 흡수하는가 (콘텐츠 아님)
- [ ] `visualViewport` `resize`+`scroll` 둘 다 바인딩했는가 (window resize 아님)
- [ ] 키보드 임계 ≥100px인가 (후보바·iOS26 잔차 오판 방지)
- [ ] `inset:0` / 단일 `100dvh` / 단일 `visualViewport` 안티패턴 안 썼는가
- [ ] **실기기 2모드 × 세로/가로 × 키보드 열림/닫힘** 8케이스 확인했는가

---

## 8. 출처 (2026-07 확인)
- W3C csswg-drafts #7194 — visualViewport(키보드) 대응 CSS 단위 부재(open)
- WebKit #261185 — svh/dvh iOS 하단 바 관련 버그
- Apple 포럼 thread 800125 — iOS 26 visualViewport ~24px 회귀(커뮤니티 재현, 26.1 beta 수정 보고)
- Apple 포럼 thread 716552 — Safari가 safe-area-inset-bottom을 0 반환(URL 바가 홈 인디케이터 덮음)
- WICG/visual-viewport #78 — standalone에서 visualViewport.height 바닥 인셋 누락
- terluinwebdesign svh/lvh/dvh 정의 · css-tricks env()/notch · dev.to karmasakshi PWA 34px vs 0px
