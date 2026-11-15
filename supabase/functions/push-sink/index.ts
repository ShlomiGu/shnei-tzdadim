// Retired: this was a test stand-in for a browser push service. It answers nothing now.
Deno.serve(() => new Response(null, { status: 410 }));
