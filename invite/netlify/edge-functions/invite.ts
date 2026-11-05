// /j/ABC123: the link people share.
// - iPhone with the app installed: iOS opens the app directly (Universal Links, see /.well-known/apple-app-site-association),
//   so this page is never shown.
// - iPhone without the app: once the app is on the App Store, a short page offers to install it (the code is copied,
//   ready to paste after installing) or to continue in the browser. Before that, straight to the web app.
// - Android and computers: straight to the web app with the code filled in (it works fully in the browser).
// - Link previews (WhatsApp, iMessage…): og tags with the couple photo, names and side.
import type { Config, Context } from "@netlify/edge-functions";

const SB = "https://yexzrxygjzzgsweiaqcm.supabase.co";
const KEY = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InlleHpyeHlnanp6Z3N3ZWlhcWNtIiwicm9sZSI6ImFub24iLCJpYXQiOjE3OTM2ODk0NzksImV4cCI6MjEwOTI2NTQ3OX0.oxbOFBA4XqjFJ4-WsBSNyh-60_4Rm8Me8CVxzpPKrJY"; // public anon key, same as the app
const APP = "https://shlomigu.github.io/shnei-tzdadim/";
const APP_STORE_ID = "6830552852";
const APP_STORE = `https://apps.apple.com/app/id${APP_STORE_ID}`;
const SCHEME = "shneitzdadim";
const PATH_RE = /^[0-9a-f-]{36}\/[A-Za-z0-9_-]+\.(jpg|webp)$/;
const esc = (s: string) => s.replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]!));

// is the app on the App Store yet? (checked at most every 10 minutes per edge instance)
let live = { v: false, t: 0 };
async function iosLive() {
  if (Date.now() - live.t < 10 * 60 * 1000) return live.v;
  try {
    const r = await fetch(`https://itunes.apple.com/lookup?id=${APP_STORE_ID}&country=il`, { signal: AbortSignal.timeout(2500) });
    const j = await r.json();
    live = { v: (j?.resultCount || 0) > 0, t: Date.now() };
  } catch { live = { v: live.v, t: Date.now() - 9 * 60 * 1000 }; }
  return live.v;
}

export default async (req: Request, ctx: Context) => {
  const code = String(ctx.params?.code || "").toUpperCase().replace(/[^A-Z0-9]/g, "").slice(0, 6);
  const web = code.length === 6 ? `${APP}?code=${code}` : APP;
  const ua = req.headers.get("user-agent") || "";
  const ios = /iPhone|iPad|iPod/i.test(ua);
  let w: any = null;
  if (code.length === 6) {
    try {
      const r = await fetch(`${SB}/rest/v1/rpc/peek_code`, { method: "POST", headers: { apikey: KEY, Authorization: `Bearer ${KEY}`, "Content-Type": "application/json" }, body: JSON.stringify({ p_code: code }) });
      if (r.ok) w = await r.json();
    } catch { /* fall back to the generic preview */ }
  }
  const couple = w ? `${w.groom} ו${w.bride}` : "";
  const side = !w ? "" : w.team === "guest" ? "אורחים" : w.team === "groom" ? `חבורת החתן של ${w.groom}` : `חבורת הכלה של ${w.bride}`;
  const title = !w ? "שני צדדים · יום החתונה"
    : w.team === "guest" ? `האלבום של החתונה של ${couple}`
    : `${side} · החתונה של ${couple}`;
  const desc = !w ? "האפליקציה של יום החתונה: תמונות לכל צד, טיזרים וחשיפה בחופה."
    : w.team === "guest" ? "צלמו ושתפו את התמונות שלכם מהחתונה. הכל נשמר לזוג."
    : `מצטרפים עם הקוד ${code.slice(0, 3)}-${code.slice(3)}. רק החבורה שלכם רואה את התמונות עד החופה.`;
  const img = w && typeof w.share === "string" && PATH_RE.test(w.share) ? `${SB}/storage/v1/object/public/photos/${w.share}` : `${APP}og.png`;
  const face = w && typeof w.cover === "string" && PATH_RE.test(w.cover) ? `${SB}/storage/v1/object/public/photos/${w.cover}` : "";

  // a choice page only where it helps: an iPhone, a real code, and the app is on the App Store
  const choose = ios && !!w && await iosLive();
  const head = `<meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
<title>${esc(title)}</title>
<meta name="description" content="${esc(desc)}">
<meta property="og:type" content="website">
<meta property="og:site_name" content="שני צדדים">
<meta property="og:title" content="${esc(title)}">
<meta property="og:description" content="${esc(desc)}">
<meta property="og:image" content="${esc(img)}">
<meta property="og:image:width" content="1200"><meta property="og:image:height" content="630">
<meta property="og:url" content="${esc(new URL(req.url).origin + "/j/" + code)}">
<meta name="twitter:card" content="summary_large_image">
<meta name="apple-itunes-app" content="app-id=${APP_STORE_ID}, app-argument=${esc(`${SCHEME}://j/${code}`)}">`;

  if (!choose) {
    const html = `<!doctype html><html lang="he" dir="rtl"><head>${head}
<meta http-equiv="refresh" content="0;url=${esc(web)}">
<style>body{font:16px system-ui;background:#F6F2F4;color:#241821;display:grid;place-items:center;min-height:100vh;margin:0}a{color:#22686C}</style>
</head><body><a href="${esc(web)}">ממשיכים לחתונה…</a><script>location.replace(${JSON.stringify(web)})</script></body></html>`;
    return new Response(html, { headers: { "content-type": "text/html; charset=utf-8", "cache-control": "public, max-age=60", vary: "user-agent" } });
  }

  const pretty = `${code.slice(0, 3)}-${code.slice(3)}`;
  const html = `<!doctype html><html lang="he" dir="rtl"><head>${head}
<link rel="preconnect" href="https://fonts.googleapis.com"><link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
<link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=Frank+Ruhl+Libre:wght@500&family=Rubik:wght@400;600&display=swap">
<style>
:root{--bg:#F6F2F4;--surface:#fff;--ink:#241821;--muted:#776A73;--line:#E6DDE2;--gold:#9A7426;--teal:#22686C;color-scheme:light}
@media (prefers-color-scheme: dark){:root{--bg:#140F16;--surface:#1E1720;--ink:#F3ECF1;--muted:#A99BA6;--line:#352A37;--gold:#D9B568;--teal:#7CC7C9;color-scheme:dark}}
*{box-sizing:border-box}
body{margin:0;min-height:100vh;background:var(--bg);color:var(--ink);font:16px/1.5 "Rubik","Arial Hebrew",system-ui,sans-serif;
  display:flex;flex-direction:column;justify-content:center;padding:calc(env(safe-area-inset-top,0px) + 28px) 20px calc(env(safe-area-inset-bottom,0px) + 28px)}
main{max-width:420px;width:100%;margin:0 auto;text-align:center;display:flex;flex-direction:column;gap:14px}
.face{width:112px;height:112px;border-radius:50%;object-fit:cover;margin:0 auto 4px;box-shadow:0 0 0 4px var(--surface),0 10px 30px rgba(0,0,0,.15)}
.rings{margin:0 auto 4px}
h1{font-family:"Frank Ruhl Libre",serif;font-weight:500;font-size:34px;line-height:1.1;margin:0}
.side{color:var(--muted);margin:0}
.code{margin:6px auto 0;display:inline-flex;align-items:center;gap:10px;padding:10px 18px;border-radius:999px;background:var(--surface);box-shadow:0 0 0 1px var(--line);
  font:600 22px/1 ui-monospace,SFMono-Regular,Menlo,monospace;letter-spacing:.08em;direction:ltr;cursor:pointer;border:0;color:var(--ink)}
.code small{font:500 13px "Rubik",system-ui;letter-spacing:0;color:var(--muted)}
.btn{display:block;padding:15px 18px;border-radius:999px;text-decoration:none;font-weight:600;font-size:17px}
.primary{background:var(--ink);color:var(--bg)}
.ghost{box-shadow:inset 0 0 0 1.5px var(--line);color:var(--ink)}
.note{font-size:14px;color:var(--muted);margin:2px 0 0}
.link{color:var(--teal);font-weight:600;text-decoration:none;font-size:15px;margin-top:4px}
</style></head><body><main>
  ${face ? `<img class="face" src="${esc(face)}" alt="">` : `<svg class="rings" width="92" height="64" viewBox="0 0 92 64" aria-hidden="true"><circle cx="34" cy="32" r="24" fill="none" stroke="#C0517A" stroke-width="5"/><circle cx="58" cy="32" r="24" fill="none" stroke="#22686C" stroke-width="5"/></svg>`}
  <h1>${esc(w.groom)} &amp; ${esc(w.bride)}</h1>
  <p class="side">הוזמנתם ל${esc(side)}</p>
  <button class="code" id="code" type="button" aria-label="העתקת הקוד">${pretty}<small id="code-t">העתקה</small></button>
  <a class="btn primary" id="store" href="${APP_STORE}">הורדת האפליקציה</a>
  <p class="note">הלחיצה מעתיקה את הקוד. אחרי ההתקנה: "יש לי קוד הצטרפות" ואז "הדבקת קוד או קישור".</p>
  <a class="btn ghost" href="${esc(`${SCHEME}://j/${code}`)}">כבר יש לי את האפליקציה</a>
  <a class="link" href="${esc(web)}">להמשיך בדפדפן, בלי להתקין</a>
</main>
<script>
const CODE = ${JSON.stringify(code)};
const copy = () => { try { navigator.clipboard && navigator.clipboard.writeText(CODE); } catch (e) {} };
document.getElementById("code").onclick = () => { copy(); document.getElementById("code-t").textContent = "הועתק ✓"; };
document.getElementById("store").addEventListener("click", copy);
</script></body></html>`;
  return new Response(html, { headers: { "content-type": "text/html; charset=utf-8", "cache-control": "private, max-age=60", vary: "user-agent" } });
};

export const config: Config = { path: "/j/:code" };
