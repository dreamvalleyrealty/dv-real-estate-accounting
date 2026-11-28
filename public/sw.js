const CACHE_NAME = "dv-back-office-static-v1";
const STATIC_ASSETS = ["/offline.html", "/dv-logo.svg", "/field.html", "/field.webmanifest", "/dv-home-icon-180.png"];

self.addEventListener("install", event => {
  event.waitUntil(caches.open(CACHE_NAME).then(cache => cache.addAll(STATIC_ASSETS)));
  self.skipWaiting();
});

self.addEventListener("activate", event => {
  event.waitUntil(
    caches.keys()
      .then(keys => Promise.all(keys.filter(key => key.startsWith("dv-back-office-") && key !== CACHE_NAME).map(key => caches.delete(key))))
      .then(() => self.clients.claim())
  );
});

self.addEventListener("fetch", event => {
  const request = event.request;
  if (request.method !== "GET") return;
  const url = new URL(request.url);
  if (url.origin !== self.location.origin) return;

  if (request.mode === "navigate") {
    const fallbackPage = url.pathname.startsWith("/field") ? "/field.html" : "/offline.html";
    event.respondWith(fetch(request).catch(() => caches.match(fallbackPage)));
    return;
  }

  const isStaticAsset = url.pathname.startsWith("/assets/") || ["/dv-logo.svg", "/field.html", "/field.webmanifest", "/dv-home-icon-180.png"].includes(url.pathname);
  if (!isStaticAsset) return;

  event.respondWith(
    caches.open(CACHE_NAME).then(async cache => {
      const cached = await cache.match(request);
      if (cached) return cached;
      const response = await fetch(request);
      if (response.ok) await cache.put(request, response.clone());
      return response;
    })
  );
});
