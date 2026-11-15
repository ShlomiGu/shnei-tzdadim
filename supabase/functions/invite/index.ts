// Supabase rewrites HTML from edge functions to plain text, so link previews are served elsewhere (invite/ in the repo).
// This endpoint only forwards ?c=CODE to the app.
const APP = "https://shlomigu.github.io/shnei-tzdadim/";
Deno.serve((req) => {
  const c = (new URL(req.url).searchParams.get("c") || "").toUpperCase().replace(/[^A-Z0-9]/g, "").slice(0, 6);
  return new Response(null, { status: 302, headers: { Location: c.length === 6 ? `${APP}?code=${c}` : APP } });
});
