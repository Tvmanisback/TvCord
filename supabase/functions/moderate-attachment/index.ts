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
  if (!mime || mime.length > 150 || /[\\r\\n]/.test(mime)) return json(415, { safe: false, reason: "A valid file content type is required." });

  const db = createClient(url, service);
  const recordSafe = async (scanner: string) => {
    const { error } = await db.from("attachment_scan_results").upsert({ object_path: path, user_id: user.id, safe: true, scanner, scanned_at: new Date().toISOString() }, { onConflict: "object_path" });
    return !error;
  };
  const { data: object, error: downloadError } = await db.storage.from("attachments").download(path);
  if (downloadError || !object) return json(404, { safe: false, reason: "Uploaded file could not be retrieved for scanning." });
  if (object.size !== size) return json(400, { safe: false, reason: "File size verification failed." });

  // Free built-in image checks: verify file signatures and reject unsupported/active formats.
  // These checks validate file format only; they cannot determine whether an image is explicit.
  if (mime.startsWith("image/")) {
    if (size > 18 * 1024 * 1024) return json(413, { safe: false, reason: "Images must be 18 MB or smaller." });
    const bytes = new Uint8Array(await object.arrayBuffer());
    const starts = (...values: number[]) => values.every((v, i) => bytes[i] === v);
    const ascii = (from: number, count: number) => String.fromCharCode(...bytes.subarray(from, from + count));
    const validJpeg = mime === "image/jpeg" && starts(0xff, 0xd8, 0xff);
    const validPng = mime === "image/png" && starts(0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a);
    const validGif = mime === "image/gif" && (ascii(0, 6) === "GIF87a" || ascii(0, 6) === "GIF89a");
    const validWebp = mime === "image/webp" && ascii(0, 4) === "RIFF" && ascii(8, 4) === "WEBP";
    const validAvif = mime === "image/avif" && ascii(4, 4) === "ftyp" && /^(avif|avis|mif1|msf1)$/.test(ascii(8, 4));
    if (!(validJpeg || validPng || validGif || validWebp || validAvif)) {
      return json(415, { safe: false, reason: "Image file type does not match its contents or is not supported. Try a JPG, PNG, GIF, WebP, or AVIF image." });
    }
    if (!await recordSafe("basic image format validation; no content moderation")) {
      return json(503, { safe: false, reason: "Image validation result could not be recorded; upload blocked." });
    }
    return json(200, { safe: true, scanned: false, scanner: "basic image format validation", warning: "Image content was not checked for explicit material." });
  }

  // Non-image files (PDFs, ZIPs, documents, and other types) are accepted without a malware scanner.
  // This is an acceptance verdict only and does not mean the file is malware-free.
  if (!await recordSafe("unscanned user upload")) {
    return json(503, { safe: false, reason: "Upload verdict could not be recorded; upload blocked." });
  }
  return json(200, { safe: true, scanned: false, warning: "This attachment was not malware-scanned." });
});
