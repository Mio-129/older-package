/**
 * older-package — Termux apt deposu için proxy (Cloudflare Worker)
 * ---------------------------------------------------------------
 * Sorun: .deb 228 MB, GitHub tek dosya için 100 MB sınırı koyduğu için
 *        dosya depoya konamaz -> GitHub Pages'te /pool/vs-code.deb 404.
 *        apt de Packages içindeki "Filename" alanında absolute URL kabul
 *        etmez (base URL'e ekler), yani Release asset'i doğrudan yazılamaz.
 *
 * Çözüm: metadata GitHub Pages'te kalır, bu worker iki işi yapar:
 *   /pool/<dosya>  -> GitHub Release asset'ine 302 (apt 302'yi takip eder)
 *   diğer her şey  -> GitHub Pages'e (dists/..., index.html) proxy
 *
 * Kaynak adresi olarak worker'ın kendi host'u kullanılır:
 *   deb [trusted=yes arch=aarch64] https://<worker>.workers.dev/ stable main
 *
 * Gerekli ortam değişkenleri (opsiyonel, varsayılanları aşağıda):
 *   PAGES_BASE  https://mio-129.github.io/older-package
 *   POOL_BASE   https://github.com/Mio-129/older-package/releases/latest/download
 *               (sabit sürüm istersen: .../releases/download/1.0.0)
 */

const DEFAULT_PAGES_BASE = "https://mio-129.github.io/older-package";
const DEFAULT_POOL_BASE =
  "https://github.com/Mio-129/older-package/releases/latest/download";

function text(body, status = 200) {
  return new Response(body, {
    status,
    headers: { "content-type": "text/plain; charset=utf-8", "cache-control": "no-store" },
  });
}

function trim(url) {
  return String(url || "").replace(/\/+$/, "");
}

export default {
  async fetch(request, env = {}) {
    const pagesBase = trim(env.PAGES_BASE || DEFAULT_PAGES_BASE);
    const poolBase = trim(env.POOL_BASE || DEFAULT_POOL_BASE);

    if (request.method !== "GET" && request.method !== "HEAD") {
      return text("yalnizca GET ve HEAD desteklenir\n", 405);
    }

    const url = new URL(request.url);
    const path = url.pathname;

    // ---- 1) pool/ -> GitHub Release (302) ----
    if (path === "/pool" || path.startsWith("/pool/")) {
      const name = decodeURIComponent(path.replace(/^\/pool\/?/, ""));
      // yol kaçışı / alt dizin yok
      if (!name || name.includes("/") || name.includes("..")) {
        return text("pool: gecersiz dosya adi\n", 404);
      }
      return new Response(null, {
        status: 302,
        headers: {
          location: `${poolBase}/${name}`,
          "cache-control": "no-store",
        },
      });
    }

    // ---- 2) geri kalan her şey -> GitHub Pages ----
    const upstreamUrl = pagesBase + (path === "/" ? "/index.html" : path) + url.search;

    const forward = {};
    for (const h of ["user-agent", "if-modified-since", "if-none-match", "accept"]) {
      const v = request.headers.get(h);
      if (v) forward[h] = v;
    }

    let upstream;
    try {
      upstream = await fetch(upstreamUrl, {
        method: "GET", // HEAD isteklerini de GET'e çevir, gövdeyi aşağıda atarız
        headers: forward,
        redirect: "follow",
        cf: { cacheEverything: true, cacheTtl: 300 },
      });
    } catch (err) {
      return text(`upstream hatasi: ${err && err.message ? err.message : err}\n`, 502);
    }

    const headers = new Headers();
    for (const h of [
      "content-type",
      "last-modified",
      "etag",
      "content-length",
      "content-encoding",
      "cache-control",
    ]) {
      const v = upstream.headers.get(h);
      if (v) headers.set(h, v);
    }

    // 404'ü cache'leme: Pages deploy'u gecikirse hemen düzelmesi için
    if (upstream.status === 404) headers.set("cache-control", "no-store");

    if (request.method === "HEAD") {
      headers.delete("content-length");
      return new Response(null, { status: upstream.status, headers });
    }

    return new Response(upstream.body, { status: upstream.status, headers });
  },
};
