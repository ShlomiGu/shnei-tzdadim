// ai-plan: turns a free-text request into a proposed schedule or task list.
// It never writes: the browser shows the proposal and applies it with ai_apply_sched / ai_apply_tasks.
const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const SB = Deno.env.get("SUPABASE_URL")!;
const SR = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const ANTHROPIC = Deno.env.get("ANTHROPIC_API_KEY");
const OPENAI = Deno.env.get("OPENAI_API_KEY");
const MODEL = Deno.env.get("AI_MODEL") || "claude-sonnet-5-5";
const OPENAI_MODEL = Deno.env.get("OPENAI_MODEL") || "gpt-4.1-mini";

const json = (b: unknown, s = 200) =>
  new Response(JSON.stringify(b), { status: s, headers: { ...CORS, "Content-Type": "application/json" } });

const hhmm = (iso: string) => {
  try {
    return new Date(iso).toLocaleTimeString("en-GB", { timeZone: "Asia/Jerusalem", hour: "2-digit", minute: "2-digit", hour12: false });
  } catch { return ""; }
};

async function callModel(system: string, user: string, tool: { name: string; description: string; input_schema: unknown }) {
  if (ANTHROPIC) {
    const r = await fetch("https://api.anthropic.com/v1/messages", {
      method: "POST",
      headers: { "x-api-key": ANTHROPIC, "anthropic-version": "2023-06-01", "content-type": "application/json" },
      body: JSON.stringify({
        model: MODEL, max_tokens: 6000, system,
        tools: [tool], tool_choice: { type: "tool", name: tool.name },
        messages: [{ role: "user", content: user }],
      }),
    });
    const d = await r.json();
    if (!r.ok) throw new Error("anthropic " + r.status + " " + JSON.stringify(d).slice(0, 300));
    const tu = (d.content || []).find((c: { type: string }) => c.type === "tool_use");
    if (!tu) throw new Error("no tool_use");
    return tu.input;
  }
  const r = await fetch("https://api.openai.com/v1/chat/completions", {
    method: "POST",
    headers: { Authorization: "Bearer " + OPENAI, "content-type": "application/json" },
    body: JSON.stringify({
      model: OPENAI_MODEL,
      messages: [{ role: "system", content: system }, { role: "user", content: user }],
      tools: [{ type: "function", function: { name: tool.name, description: tool.description, parameters: tool.input_schema } }],
      tool_choice: { type: "function", function: { name: tool.name } },
    }),
  });
  const d = await r.json();
  if (!r.ok) throw new Error("openai " + r.status + " " + JSON.stringify(d).slice(0, 300));
  const args = d.choices?.[0]?.message?.tool_calls?.[0]?.function?.arguments;
  return JSON.parse(args || "{}");
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return json({ error: "method" }, 405);
  let body: { token?: string; kind?: string; text?: string };
  try { body = await req.json(); } catch { return json({ error: "bad_input" }, 400); }
  const { token, kind, text } = body || {};
  if (typeof token !== "string" || !/^[0-9a-f-]{36}$/.test(token) || (kind !== "sched" && kind !== "tasks") ||
      typeof text !== "string" || !text.trim() || text.length > 1500) return json({ error: "bad_input" }, 400);
  if (!ANTHROPIC && !OPENAI) return json({ error: "ai_not_configured" }, 503);

  const cr = await fetch(`${SB}/rest/v1/rpc/ai_context`, {
    method: "POST",
    headers: { apikey: SR, Authorization: `Bearer ${SR}`, "Content-Type": "application/json" },
    body: JSON.stringify({ p_token: token, p_kind: kind }),
  });
  if (!cr.ok) {
    const e = await cr.json().catch(() => ({}));
    const m = (e && e.message) || "";
    if (m === "rate_limited") return json({ error: "rate_limited" }, 429);
    if (m === "bad_token") return json({ error: "bad_token" }, 401);
    return json({ error: "context_failed" }, 500);
  }
  const ctx = await cr.json();
  const team: string = ctx.me.team;
  const teamHe = team === "groom" ? "חבורת החתן" : "חבורת הכלה";
  const w = ctx.wedding;
  const chuppah = hhmm(w.reveal_at);

  const keyToId: Record<string, string> = {};
  const memKeyToId: Record<string, string> = {};
  const idToMemKey: Record<string, string> = {};
  (ctx.members || []).forEach((x: { id: string }, i: number) => { memKeyToId["m" + (i + 1)] = x.id; idToMemKey[x.id] = "m" + (i + 1); });

  const intro = `Wedding of ${w.groom} (groom) and ${w.bride} (bride) on ${w.date}. Chuppah at ${chuppah} (Israel time).` +
    (w.venue ? ` Venue: ${w.venue}${w.venue_city ? ", " + w.venue_city : ""}.` : " Venue not set yet.") +
    ` The request comes from ${ctx.me.name}, a member of ${teamHe} (side "${team}").`;

  const common = `You manage the wedding-day plan inside an Israeli wedding app. Write every title, place, note and the summary in natural, short Hebrew.
You receive the CURRENT list this side may edit, and a free-text REQUEST. Return the COMPLETE new list.
Rules:
- Keep every item the request does not touch exactly as it is, with its key.
- Use side "${team}" for things only ${teamHe} does, and "all" for things both sides share. Never use the other side.
- Do not invent details the request does not imply. If the request is unclear or unrelated, return the list unchanged and explain in the summary.
- summary: one or two short Hebrew sentences saying what you changed.`;

  let tool, user;
  if (kind === "sched") {
    const items = (ctx.sched || []).map((s: Record<string, unknown>, i: number) => {
      const k = "i" + (i + 1); keyToId[k] = s.id as string;
      return { key: k, t: s.t, title: s.title, place: s.place, note: s.note, side: s.side, done: s.done, reveal: s.reveal };
    });
    const other = (ctx.sched_other || []).map((s: { t: string; title: string }) => `${s.t} ${s.title}`).join("; ");
    tool = {
      name: "propose_schedule",
      description: "Return the full proposed wedding-day schedule for this side.",
      input_schema: {
        type: "object",
        properties: {
          summary: { type: "string" },
          items: {
            type: "array",
            items: {
              type: "object",
              properties: {
                key: { type: "string", description: "key of an existing item; omit for a new item" },
                t: { type: "string", description: "24h time HH:MM" },
                title: { type: "string" }, place: { type: "string" }, note: { type: "string" },
                side: { type: "string", enum: [team, "all"] },
                done: { type: "boolean" },
                reveal: { type: "boolean", description: "true only for the chuppah item, the moment all photos are revealed" },
              },
              required: ["t", "title", "side"],
            },
          },
        },
        required: ["summary", "items"],
      },
    };
    user = `${intro}\n\nCURRENT schedule (editable by this side):\n${JSON.stringify(items)}\n\nThe other side's private items (read-only context): ${other || "none"}\n\nREQUEST:\n${text}`;
    const system = common + `\n- Times are 24h HH:MM, sorted logically through the day. Exactly one item has reveal=true (the chuppah) unless the user explicitly asks otherwise; if the chuppah time changes, move that item.\n- When it helps, fill place with the venue name for events at the venue.`;
    try {
      const out = await callModel(system, user, tool);
      const res = (out.items || []).filter((x: { t?: string; title?: string }) => x && /^\d\d:\d\d$/.test(x.t || "") && (x.title || "").trim())
        .slice(0, 60).map((x: Record<string, unknown>) => ({
          id: x.key && keyToId[x.key as string] ? keyToId[x.key as string] : null,
          t: x.t, title: String(x.title).slice(0, 80), place: String(x.place || "").slice(0, 80), note: String(x.note || "").slice(0, 160),
          side: x.side === "all" ? "all" : team, done: !!x.done, reveal: !!x.reveal,
        }));
      return json({ summary: String(out.summary || "").slice(0, 400), items: res });
    } catch (e) { console.error(e); return json({ error: "ai_failed" }, 502); }
  }

  const items = (ctx.tasks || []).map((s: Record<string, unknown>, i: number) => {
    const k = "i" + (i + 1); keyToId[k] = s.id as string;
    return { key: k, title: s.title, side: s.side, pts: s.pts, mission: s.mission, who: s.who ? idToMemKey[s.who as string] || "" : "", done: s.done };
  });
  const mine = (ctx.members || []).filter((x: { team: string }) => x.team === team)
    .map((x: { id: string; name: string; role: string }) => `${idToMemKey[x.id]}=${x.name}${x.role === "couple" ? " (" + (team === "groom" ? "החתן" : "הכלה") + ")" : ""}`).join(", ");
  tool = {
    name: "propose_tasks",
    description: "Return the full proposed task list for this side.",
    input_schema: {
      type: "object",
      properties: {
        summary: { type: "string" },
        items: {
          type: "array",
          items: {
            type: "object",
            properties: {
              key: { type: "string", description: "key of an existing task; omit for a new task" },
              title: { type: "string" },
              side: { type: "string", enum: [team, "all"] },
              pts: { type: "integer", description: "5-50, harder or photo tasks get more" },
              mission: { type: "boolean", description: "true when the task is completed by taking a photo" },
              who: { type: "string", description: "member key responsible, or empty string" },
            },
            required: ["title", "side"],
          },
        },
      },
      required: ["summary", "items"],
    },
  };
  user = `${intro}\n\nMembers of this side: ${mine || "none"}\n\nCURRENT tasks (editable by this side; done tasks stay done):\n${JSON.stringify(items)}\n\nREQUEST:\n${text}`;
  const system = common + `\n- Photo missions start with "משימת צילום:" and have mission=true.\n- Assign who only when the request names a person; otherwise keep the existing value.`;
  try {
    const out = await callModel(system, user, tool);
    const res = (out.items || []).filter((x: { title?: string }) => x && (x.title || "").trim()).slice(0, 80).map((x: Record<string, unknown>) => {
      const o: Record<string, unknown> = {
        id: x.key && keyToId[x.key as string] ? keyToId[x.key as string] : null,
        title: String(x.title).slice(0, 120), side: x.side === "all" ? "all" : team,
        pts: Math.max(0, Math.min(100, Number(x.pts) || 10)), mission: !!x.mission,
      };
      // only send an assignment when the model named someone, so nobody is unassigned by accident
      if (x.who && memKeyToId[x.who as string]) o.who = memKeyToId[x.who as string];
      return o;
    });
    return json({ summary: String(out.summary || "").slice(0, 400), items: res });
  } catch (e) { console.error(e); return json({ error: "ai_failed" }, 502); }
});
