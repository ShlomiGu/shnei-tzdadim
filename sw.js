// שני צדדים · service worker: shows push notifications and opens the right screen when tapped.
self.addEventListener("install", () => self.skipWaiting());
self.addEventListener("activate", e => e.waitUntil(self.clients.claim()));

// instrument samples for the recap music never change: keep them on the phone after the first time
self.addEventListener("fetch", e => {
  const u = new URL(e.request.url);
  if (e.request.method !== "GET" || u.origin !== self.location.origin || !u.pathname.includes("/music/")) return;
  e.respondWith(caches.open("music-v1").then(async c => {
    const hit = await c.match(e.request); if (hit) return hit;
    const r = await fetch(e.request); if (r.ok) c.put(e.request, r.clone()); return r;
  }));
});

self.addEventListener("push", e => {
  let d = {};
  try { d = e.data ? e.data.json() : {}; } catch { d = { body: e.data && e.data.text() }; }
  const base = self.registration.scope;
  e.waitUntil(self.registration.showNotification(d.title || "שני צדדים", {
    body: d.body || "",
    icon: base + "icon-192.png",
    badge: base + "icon-192.png",
    tag: d.tag || undefined,
    renotify: !!d.tag,
    dir: "rtl",
    lang: "he",
    data: { url: base + (d.url && d.url.startsWith("#") ? d.url : "") }
  }));
});

self.addEventListener("notificationclick", e => {
  e.notification.close();
  const url = (e.notification.data && e.notification.data.url) || self.registration.scope;
  e.waitUntil((async () => {
    const all = await self.clients.matchAll({ type: "window", includeUncontrolled: true });
    for (const c of all) {
      if (c.url.startsWith(self.registration.scope)) {
        await c.focus();
        try { await c.navigate(url); } catch {}
        return;
      }
    }
    await self.clients.openWindow(url);
  })());
});
