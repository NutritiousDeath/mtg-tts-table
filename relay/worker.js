/**
 * MTG TTS image relay (Cloudflare Worker)
 *
 * Scryfall blocks Tabletop Simulator's built-in image downloader, so TTS
 * can't load card art from cards.scryfall.io directly. This Worker fetches
 * the image from Scryfall with proper headers and hands it to TTS.
 *
 * URL paths mirror Scryfall's exactly:
 *   https://<your-worker>.workers.dev/large/front/8/e/8ee443cc-....jpg
 *   -> https://cards.scryfall.io/large/front/8/e/8ee443cc-....jpg
 *
 * Only Scryfall card image paths are accepted, so this can't be used as a
 * general-purpose proxy. Images are cached at Cloudflare for 30 days, so
 * each card is fetched from Scryfall once and served from cache after that.
 */

const UPSTREAM = "https://cards.scryfall.io";
const CACHE_SECONDS = 60 * 60 * 24 * 30; // 30 days

// /<size>/<face>/<x>/<y>/<uuid>.<ext>
const PATH_RE =
  /^\/(small|normal|large|png|art_crop|border_crop)\/(front|back)\/[0-9a-f]\/[0-9a-f]\/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.(jpg|png)$/;

export default {
  async fetch(request, env, ctx) {
    const url = new URL(request.url);

    if (url.pathname === "/" || url.pathname === "/health") {
      return new Response("MTG relay OK", { headers: { "Content-Type": "text/plain" } });
    }

    if (request.method !== "GET" && request.method !== "HEAD") {
      return new Response("Method not allowed", { status: 405 });
    }

    if (!PATH_RE.test(url.pathname)) {
      return new Response("Not a Scryfall card image path", { status: 404 });
    }

    // Cache key ignores any query string, so "?123" variants share one entry.
    const cacheKey = new Request(url.origin + url.pathname, { method: "GET" });
    const cache = caches.default;

    let response = await cache.match(cacheKey);
    if (!response) {
      const upstream = await fetch(UPSTREAM + url.pathname, {
        headers: {
          "User-Agent": "MTG-TTS-Table-Relay/1.0",
          "Accept": "image/*",
        },
        cf: { cacheTtl: CACHE_SECONDS, cacheEverything: true },
      });

      if (!upstream.ok) {
        return new Response("Upstream error " + upstream.status, { status: upstream.status });
      }

      const ext = url.pathname.endsWith(".png") ? "png" : "jpeg";
      response = new Response(upstream.body, {
        status: 200,
        headers: {
          "Content-Type": "image/" + ext,
          "Cache-Control": "public, max-age=" + CACHE_SECONDS,
          "Access-Control-Allow-Origin": "*",
        },
      });
      ctx.waitUntil(cache.put(cacheKey, response.clone()));
    }

    if (request.method === "HEAD") {
      return new Response(null, { status: response.status, headers: response.headers });
    }
    return response;
  },
};
