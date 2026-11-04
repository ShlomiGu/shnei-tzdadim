// /j/ABC123 → a page whose link preview shows the couple photo, then straight on to the app with the code filled in.
import type { Config, Context } from "@netlify/edge-functions";

const SB = "https://yexzrxygjzzgsweiaqcm.supabase.co";
const KEY = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InlleHpyeHlnanp6Z3N3ZWlhcWNtIiwicm9sZSI6ImFub24iLCJpYXQiOjE3OTM2ODk0NzksImV4cCI6MjEwOTI2NTQ3OX0.oxbOFBA4XqjFJ4-WsBSNyh-60_4Rm8Me8CVxzpPKrJY"; // public anon key, same as the app
const APP = "https://shlomigu.github.io/shnei-tzdadim/";
const PATH_RE = /^[0-9a-f-]{36}\/[A-Za-z0-9_-]+\.(jpg|webp)$/;
const esc = (s: string) => s.replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]!));

export default async (req: Request, ctx: Context) => {
  const code = String(ctx.params?.code || "").toUpperCase().replace(/[^A-Z0-9]/g, "").slice(0, 6);
  const target = code.length === 6 ? `${APP}?code=${code}` : APP;
  let w: any = null;
  if (code.length === 6) {
    try {
      const r = await fetch(`${SB}/rest/v1/rpc/peek_code`, { method: "POST", headers: { apikey: KEY, Authorization: `Bearer ${KEY}`, "Content-Type": "application/json" }, body: JSON.stringify({ p_code: code }) });
      if (r.ok) w = await r.json();
    } catch { /* fall back to the generic preview */ }
  }
  const couple = w ? `${w.groom} ו${w.bride}` : "";
  const title = !w ? "שני צדדים · יום החתונה"
    : w.team === "guest" ? `האלבום של החתונה של ${couple}`
    : `${w.team === "groom" ? "חבורת החתן" : "חבורת הכלה"} של ${w.team === "groom" ? w.groom : w.bride} · החתונה של ${couple}`;
  const desc = !w ? "האפליקציה של יום החתונה: תמונות לכל צד, טיזרים וחשיפה בחופה."
    : w.team === "guest" ? "צלמו ושתפו את התמונות שלכם מהחתונה. הכל נשמר לזוג."
    : `מצטרפים עם הקוד ${code.slice(0, 3)}-${code.slice(3)}. רק החבורה שלכם רואה את התמונות עד החופה.`;
  const img = w && typeof w.share === "string" && PATH_RE.test(w.share) ? `${SB}/storage/v1/object/public/photos/${w.share}` : `${APP}og.png`;
  const html = `<!doctype html><html lang="he" dir="rtl"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
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
<meta http-equiv="refresh" content="0;url=${esc(target)}">
<style>body{font:16px system-ui;background:#F6F2F4;color:#241821;display:grid;place-items:center;min-height:100vh;margin:0}a{color:#22686C}</style>
</head><body><a href="${esc(target)}">ממשיכים לחתונה…</a><script>location.replace(${JSON.stringify(target)})</script></body></html>`;
  return new Response(html, { headers: { "content-type": "text/html; charset=utf-8", "cache-control": "public, max-age=60" } });
};

export const config: Config = { path: "/j/:code" };
