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
  try { body = await req.json(); } catch { return json(400, { safe: false, reason: "Invalid upload request." }); }
  const path = String(body.path || "");
  const mime = String(body.mime_type || "application/octet-stream").toLowerCase();
  const size = Number(body.size || 0);
  const fileName = String(body.file_name || "attachment").slice(0, 180);

  if (!path.startsWith(user.id + "/") || path.includes("..") || path.length > 300) {
    return json(403, { safe: false, reason: "You can only approve your own uploads." });
  }
  if (!Number.isSafeInteger(size) || size < 1 || size > 50 * 1024 * 1024) {
    return json(413, { safe: false, reason: "File exceeds the 50 MB limit." });
  }
  if (mime.length > 150 || /[\\r\\n]/.test(mime)) {
    return json(415, { safe: false, reason: "Invalid file content type." });
  }

  const db = createClient(url, service);
  const { data: object, error: downloadError } = await db.storage.from("attachments").download(path);
  if (downloadError || !object) return json(404, { safe: false, reason: "The uploaded file could not be retrieved. Check the private attachments bucket and its policies." });
  if (object.size !== size) return json(400, { safe: false, reason: "File size verification failed. Please retry the upload." });

  // Image/content scanning has intentionally been removed at the owner's request.
  // This validates authentication, upload ownership, size, and object existence only.
  const { error: recordError } = await db.from("attachment_scan_results").upsert({
    object_path: path,
    user_id: user.id,
    safe: true,
    scanner: "owner-disabled-content-scanning",
    scanned_at: new Date().toISOString(),
  }, { onConflict: "object_path" });
  if (recordError) return json(503, { safe: false, reason: "Could not save the attachment record. Check the attachment SQL migration and database permissions." });

  return json(200, {
    safe: true,
    scanned: false,
    scanner: "content checks disabled",
    file_name: fileName,
    warning: "This file was not checked for unsafe or malicious content.",
  });
});
