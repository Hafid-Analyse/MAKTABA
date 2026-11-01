/* عامل الخدمة: يجعل التطبيق يفتح بسرعة ويعمل دون اتصال.
   عند تعديل index.html غيّر رقم الإصدار هنا ليحصل الجميع على النسخة الجديدة. */
const VERSION = "maktaba-v4";
const SHELL = [
  "./", "./index.html", "./manifest.webmanifest",
  "./icons/icon-192.png", "./icons/icon-512.png", "./icons/icon-maskable-512.png",
  "./icons/apple-touch-icon.png", "./icons/favicon-32.png"
];
const CDN = ["cdnjs.cloudflare.com", "unpkg.com", "fonts.googleapis.com", "fonts.gstatic.com"];

self.addEventListener("install", e => {
  e.waitUntil(caches.open(VERSION).then(c => c.addAll(SHELL)).then(() => self.skipWaiting()));
});

self.addEventListener("activate", e => {
  e.waitUntil(
    caches.keys().then(keys => Promise.all(keys.filter(k => k !== VERSION).map(k => caches.delete(k))))
      .then(() => self.clients.claim())
  );
});

self.addEventListener("fetch", e => {
  const req = e.request;
  if (req.method !== "GET") return;               // طلبات Apps Script (POST) تمر مباشرة دون تخزين
  const url = new URL(req.url);

  // صفحة التطبيق: الشبكة أولاً ثم النسخة المحفوظة
  if (req.mode === "navigate") {
    e.respondWith(
      fetch(req, { cache: "no-store" }).then(res => { const copy = res.clone(); caches.open(VERSION).then(c => c.put("./index.html", copy)); return res; })
        .catch(() => caches.match("./index.html"))
    );
    return;
  }

  // ملفات التطبيق والمكتبات والخطوط: من المخزن فوراً مع تحديث في الخلفية
  if (url.origin === location.origin || CDN.includes(url.hostname)) {
    e.respondWith(
      caches.open(VERSION).then(async c => {
        const hit = await c.match(req);
        const net = fetch(req).then(res => { if (res.ok || res.type === "opaque") c.put(req, res.clone()); return res; }).catch(() => hit);
        return hit || net;
      })
    );
  }
});
