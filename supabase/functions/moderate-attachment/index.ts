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

  // TvCord accepts all file types without an external malware scanner, as requested.
  // This is an acceptance verdict only; it does NOT mean the file is safe.
  if (!await recordSafe("unscanned user upload")) {
    return json(503, { safe: false, reason: "Upload verdict could not be recorded; upload blocked." });
  }
  return json(200, { safe: true, scanned: false, warning: "This attachment was not malware-scanned." });
});
