import { Readable } from "node:stream";
import { pipeline } from "node:stream/promises";

export const config = {
  api: { bodyParser: false },
  supportsResponseStreaming: true,
  maxDuration: 60,
};

const TARGET_BASE = (process.env.TARGET_DOMAIN || "").replace(/\/$/, "");

// Headers that should be stripped before forwarding
const STRIP_HEADERS = new Set([
  "host",
  "connection",
  "keep-alive",
  "proxy-authenticate",
  "proxy-authorization",
  "te",
  "trailer",
  "transfer-encoding",
  "upgrade",
  "forwarded",
  "x-forwarded-host",
  "x-forwarded-proto",
  "x-forwarded-port",
]);

// Helper to clean and normalize incoming headers
function normalizeHeaders(inputHeaders) {
  const result = {};
  let clientIp = null;

  for (const [key, value] of Object.entries(inputHeaders)) {
    const lowerKey = key.toLowerCase();

    if (STRIP_HEADERS.has(lowerKey)) continue;
    if (lowerKey.startsWith("x-vercel-")) continue;

    if (lowerKey === "x-real-ip") {
      clientIp = value;
      continue;
    }
    if (lowerKey === "x-forwarded-for") {
      if (!clientIp) clientIp = value;
      continue;
    }

    result[lowerKey] = Array.isArray(value) ? value.join(", ") : value;
  }

  if (clientIp) {
    result["x-forwarded-for"] = clientIp;
  }

  return result;
}

export default async function handler(req, res) {
  if (!TARGET_BASE) {
    res.statusCode = 500;
    return res.end("Misconfigured: TARGET_DOMAIN is not set");
  }

  try {
    const targetUrl = TARGET_BASE + req.url;

    const headers = normalizeHeaders(req.headers);

    const method = req.method;
    const hasBody = method !== "GET" && method !== "HEAD";

    const fetchOpts = {
      method,
      headers,
      redirect: "manual"
    };

    if (hasBody) {
      fetchOpts.body = Readable.toWeb(req);
      fetchOpts.duplex = "half";
    }

    const upstream = await fetch(targetUrl, fetchOpts);

    res.statusCode = upstream.status;

    // Forward all response headers except transfer-encoding
    for (const [k, v] of upstream.headers) {
      if (k.toLowerCase() === "transfer-encoding") continue;
      try {
        res.setHeader(k, v);
      } catch (e) {
        // ignore
      }
    }

    // Stream response body
    if (upstream.body) {
      await pipeline(Readable.fromWeb(upstream.body), res);
    } else {
      res.end();
    }

  } catch (err) {
    console.error("relay error:", err);
    if (!res.headersSent) {
      res.statusCode = 502;
      res.end("Bad Gateway: Tunnel Failed");
    }
  }
}
