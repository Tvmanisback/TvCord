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
  if (req.method !== "POST") return json(405, { safe: false, reason: "POST only." });

  const url = Deno.env.get("SUPABASE_URL");
  const anon = Deno.env.get("SUPABASE_ANON_KEY");
  const service = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!url || !anon || !service) return json(503, { safe: false, reason: "TvCord attachment backend is not configured." });

  const auth = req.headers.get("Authorization");
  if (!auth) return json(401, { safe: false, reason: "Sign in required." });
  const client = createClient(url, anon, { global: { headers: { Authorization: auth } } });
  const { data: { user }, error: authError } = await client.auth.getUser();
  if (authError || !user) return json(401, { safe: false, reason: "Your session expired. Sign in again." });

  let body: { path?: string; file_name?: string; mime_type?: string; size?: number };
  try { body = await req.json(); } catch { return json(400, { safe: false, reason: "Invalid upload-check request." }); }
  const path = String(body.path || "");
  const mime = String(body.mime_type || "").toLowerCase();
  const size = Number(body.size || 0);
  const fileName = String(body.file_name || "attachment").slice(0, 180);
  if (!path.startsWith(user.id + "/") || path.includes("..") || path.length > 300) {
    return json(403, { safe: false, reason: "You can only validate your own uploads." });
  }
  if (!Number.isSafeInteger(size) || size < 1 || size > 50 * 1024 * 1024) {
    return json(413, { safe: false, reason: "File exceeds the 50 MB limit." });
  }
  if (!mime || mime.length > 150 || /[\r\n]/.test(mime)) {
    return json(415, { safe: false, reason: "A valid file content type is required." });
  }

  const db = createClient(url, service);
  const recordSafe = async (scanner: string) => {
    const { error } = await db.from("attachment_scan_results").upsert({
      object_path: path, user_id: user.id, safe: true, scanner, scanned_at: new Date().toISOString(),
    }, { onConflict: "object_path" });
    return !error;
  };
  const { data: object, error: downloadError } = await db.storage.from("attachments").download(path);
  if (downloadError || !object) return json(404, { safe: false, reason: "The uploaded file could not be retrieved. Check the private attachments bucket and its policies." });
  if (object.size !== size) return json(400, { safe: false, reason: "File size verification failed. Please retry the upload." });

  // Other file types are intentionally not content- or malware-scanned.
  // They are accepted after authentication, size, ownership and storage checks.
  if (!mime.startsWith("image/")) {
    if (!await recordSafe("accepted without scanning; non-image attachment")) {
      return json(503, { safe: false, reason: "TvCord could not save the attachment approval. Run the attachment SQL migration, then retry." });
    }
    return json(200, { safe: true, scanned: false, scanner: "not applicable to non-image file" });
  }

  if (size > 18 * 1024 * 1024) return json(413, { safe: false, reason: "Images must be 18 MB or smaller for image moderation." });
  const bytes = new Uint8Array(await object.arrayBuffer());
  const starts = (...values: number[]) => values.every((v, i) => bytes[i] === v);
  const ascii = (from: number, count: number) => String.fromCharCode(...bytes.subarray(from, from + count));
  const validJpeg = mime === "image/jpeg" && starts(0xff, 0xd8, 0xff);
  const validPng = mime === "image/png" && starts(0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a);
  const validGif = mime === "image/gif" && (ascii(0, 6) === "GIF87a" || ascii(0, 6) === "GIF89a");
  const validWebp = mime === "image/webp" && ascii(0, 4) === "RIFF" && ascii(8, 4) === "WEBP";
  const validAvif = mime === "image/avif" && ascii(4, 4) === "ftyp" && /^(avif|avis|mif1|msf1)$/.test(ascii(8, 4));
  if (!(validJpeg || validPng || validGif || validWebp || validAvif)) {
    return json(415, { safe: false, reason: "Image type does not match its contents. Try JPG, PNG, GIF, WebP, or AVIF." });
  }

  // Server-side image classification. HF_TOKEN is stored as a Supabase secret, never in the browser.
  const hfToken = Deno.env.get("HF_TOKEN");
  if (!hfToken) return json(503, { safe: false, reason: "Server-side image moderation is not configured yet. Add the HF_TOKEN secret in Supabase Edge Function secrets." });

  let inference: Response;
  try {
    inference = await fetch("https://router.huggingface.co/hf-inference/models/Falconsai/nsfw_image_detection", {
      method: "POST",
      headers: { Authorization: "Bearer " + hfToken, "Content-Type": mime },
      body: bytes,
      signal: AbortSignal.timeout(25000),
    });
  } catch {
    return json(503, { safe: false, reason: "The image moderation service could not be reached. Please retry in a moment." });
  }
  if (!inference.ok) {
    const detail = (await inference.text()).slice(0, 300);
    console.error("Image moderation provider error", inference.status, detail);
    if (inference.status === 401 || inference.status === 403) {
      return json(503, { safe: false, reason: "The HF_TOKEN secret is invalid or lacks inference access. Update it in Supabase Edge Function secrets." });
    }
    return json(503, { safe: false, reason: "The image moderation provider is temporarily unavailable or its free quota is exhausted. Please retry later." });
  }

  let predictions: Array<{ label?: string; score?: number }>;
  try {
    const result = await inference.json();
    if (!Array.isArray(result) || !result.every((x) => typeof x?.label === "string" && Number.isFinite(Number(x?.score)))) {
      return json(503, { safe: false, reason: "The image moderation service returned an unexpected result. Upload blocked for safety." });
    }
    predictions = result;
  } catch {
    return json(503, { safe: false, reason: "The image moderation service returned an unreadable result. Upload blocked for safety." });
  }
  const scores = Object.fromEntries(predictions.map((p) => [String(p.label).toLowerCase(), Number(p.score)]));
  const nsfwScore = Math.max(scores.nsfw || 0, scores["explicit"] || 0, scores["porn"] || 0);
  if (nsfwScore >= 0.55) {
    return json(422, { safe: false, reason: "Image blocked by server-side explicit-content screening. If you believe this is a mistake, report a false positive." });
  }

  if (!await recordSafe("Hugging Face Falconsai/nsfw_image_detection server-side classifier")) {
    return json(503, { safe: false, reason: "The moderation result could not be saved. Run the attachment SQL migration, then retry." });
  }
  return json(200, {
    safe: true,
    scanned: true,
    scanner: "Hugging Face Falconsai/nsfw_image_detection",
    warning: "Automated image moderation can miss content or flag harmless images.",
    file_name: fileName,
  });
});
