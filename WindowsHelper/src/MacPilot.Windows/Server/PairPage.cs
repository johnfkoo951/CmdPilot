namespace MacPilot.Windows.Server;

/// <summary>
/// Self-contained PIN entry page served by the server when pairing is enabled and the request is
/// not yet authorized. Plain HTML form (GET /pair?pin=...), inline CSS, no dependency on the reused
/// web client. Submitting a correct PIN sets the auth cookie and redirects to "/".
/// </summary>
public static class PairPage
{
    public static string Html(bool error) => """
<!DOCTYPE html>
<html lang="ko">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no">
<meta name="theme-color" content="#141416">
<title>MacPilot · 연결</title>
<style>
  :root { color-scheme: dark; }
  * { box-sizing: border-box; }
  body { margin:0; min-height:100vh; display:flex; align-items:center; justify-content:center;
         background:#141416; color:#f2f2f4; font:16px/1.5 -apple-system,system-ui,"Segoe UI",sans-serif; }
  .card { width:min(92vw,360px); background:#1c1c20; border:1px solid #2a2a30; border-radius:18px;
          padding:28px 24px; box-shadow:0 12px 40px rgba(0,0,0,.4); }
  h1 { margin:0 0 4px; font-size:20px; }
  p { margin:0 0 18px; color:#9a9aa2; font-size:14px; }
  input { width:100%; padding:14px; font-size:24px; letter-spacing:6px; text-align:center;
          background:#0f0f12; color:#fff; border:1px solid #3a3a42; border-radius:12px; }
  button { width:100%; margin-top:14px; padding:14px; font-size:16px; font-weight:600;
           background:#85714D; color:#fff; border:0; border-radius:12px; }
  .err { color:#ff7b7b; font-size:13px; margin-top:10px; min-height:18px; text-align:center; }
</style>
</head>
<body>
  <form class="card" action="/pair" method="get" autocomplete="off">
    <h1>MacPilot 연결</h1>
    <p>PC 트레이에 표시된 PIN을 입력하세요.</p>
    <input name="pin" inputmode="numeric" pattern="[0-9]*" maxlength="6" autofocus
           placeholder="••••••" aria-label="PIN">
    <button type="submit">연결</button>
    <div class="err">__ERROR__</div>
  </form>
</body>
</html>
""".Replace("__ERROR__", error ? "PIN이 올바르지 않습니다. 다시 시도하세요." : "");
}
