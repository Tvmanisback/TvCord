import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (status: number, body: unknown) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json" } });

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json(405, { error: "POST only" });

  const url = Deno.env.get("SUPABASE_URL");
  const anon = Deno.env.get("SUPABASE_ANON_KEY");
  const service = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!url || !anon || !service) return json(503, { safe: false, reason: "Moderation service is not configured." });
  const auth = req.headers.get("Authorization");
  if (!auth) return json(401, { safe: false, reason: "Sign in required." });
  const client = createClient(url, anon, { global: { headers: { Authorization: auth } } });
  const { data: { user }, error: authError } = await client.auth.getUser();
  if (authError || !user) return json(401, { safe: false, reason: "Invalid session." });

  let body: { path?: string; file_name?: string; mime_type?: string; size?: number };
  try { body = await req.json(); } catch { return json(400, { safe: false, reason: "Invalid request." }); }
  const path = String(body.path || "");
  const mime = String(body.mime_type || "").toLowerCase();
  const size = Number(body.size || 0);
  if (!path.startsWith(user.id + "/") || path.includes("..") || path.length > 300) return json(403, { safe: false, reason: "You can only scan your own uploads." });
  if (!Number.isSafeInteger(size) || size < 1 || size > 50 * 1024 * 1024) return json(413, { safe: false, reason: "File exceeds the 50 MB limit." });
  const allowed = new Set(["image/jpeg", "image/png", "image/webp", "image/gif", "application/pdf", "text/plain", "application/zip", "application/x-zip-compressed"]);
  if (!allowed.has(mime)) return json(415, { safe: false, reason: "File type is not allowed." });

  const db = createClient(url, service);
  const { data: object, error: downloadError } = await db.storage.from("attachments").download(path);
  if (downloadError || !object) return json(404, { safe: false, reason: "Uploaded file could not be retrieved for scanning." });
  if (object.size !== size) return json(400, { safe: false, reason: "File size verification failed." });

  if (mime.startsWith("image/")) {
    const key = Deno.env.get("GOOGLE_CLOUD_VISION_API_KEY");
    if (!key) return json(503, { safe: false, reason: "Image safety scanner is not configured; image upload blocked." });
    // Vision's image-content request is limited; fail closed instead of skipping checks.
    if (size > 18 * 1024 * 1024) return json(413, { safe: false, reason: "Images larger than 18 MB cannot be safely scanned by this configured scanner. Use a smaller image." });
    const bytes = new Uint8Array(await object.arrayBuffer());
    let binary = "";
    for (let i = 0; i < bytes.length; i += 0x8000) binary += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
    const content = btoa(binary);
    const response = await fetch("https://vision.googleapis.com/v1/images:annotate?key=" + encodeURIComponent(key), {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ requests: [{ image: { content }, features: [{ type: "SAFE_SEARCH_DETECTION" }, { type: "IMAGE_PROPERTIES" }] }] }),
    });
    if (!response.ok) return json(503, { safe: false, reason: "Image scanner unavailable; upload blocked." });
    const result = await response.json();
    const annotations = result?.responses?.[0]?.safeSearchAnnotation;
    if (!annotations) return json(503, { safe: false, reason: "Image scanner returned no safety verdict; upload blocked." });
    const severe = new Set(["LIKELY", "VERY_LIKELY"]);
    if (severe.has(annotations.adult) || severe.has(annotations.racy) || severe.has(annotations.violence)) {
      return json(200, { safe: false, reason: "The image was blocked by automated safety screening." });
    }
    return json(200, { safe: true, scanner: "Google Cloud Vision SafeSearch", verdict: annotations });
  }

  // PDFs, archives and text files require a trusted malware scanning endpoint.
  // The endpoint must accept raw bytes and return JSON { "clean": true } only after scanning.
  const scannerUrl = Deno.env.get("TVCORD_FILE_SCANNER_URL");
  const scannerToken = Deno.env.get("TVCORD_FILE_SCANNER_TOKEN");
  if (!scannerUrl || !scannerToken) return json(503, { safe: false, reason: "File malware scanner is not configured; this upload is blocked." });
  const scanResponse = await fetch(scannerUrl, {
    method: "POST",
    headers: {
      "Authorization": "Bearer " + scannerToken,
      "Content-Type": mime,
      "X-Filename": String(body.file_name || "upload").replace(/[\r\n]/g, "").slice(0, 180),
      "X-Expected-Size": String(size),
    },
    body: object,
  });
  if (!scanResponse.ok) return json(503, { safe: false, reason: "File scanner unavailable; upload blocked." });
  let scanResult: { clean?: boolean; infected?: boolean };
  try { scanResult = await scanResponse.json(); } catch { return json(503, { safe: false, reason: "File scanner returned an invalid verdict; upload blocked." }); }
  if (scanResult.clean !== true || scanResult.infected === true) return json(200, { safe: false, reason: "File was blocked by malware screening." });
  return json(200, { safe: true, scanner: "configured malware scanner" });
});
