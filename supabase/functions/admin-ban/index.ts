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
  const admins = (Deno.env.get("TVCORD_ADMIN_USER_IDS") || "").split(",").map(x => x.trim()).filter(Boolean);
  if (!url || !anon || !service || admins.length === 0) return json(503, { error: "Admin backend is not configured. Set TVCORD_ADMIN_USER_IDS and Supabase function secrets." });
  const auth = req.headers.get("Authorization");
  if (!auth) return json(401, { error: "Sign in required" });
  const userClient = createClient(url, anon, { global: { headers: { Authorization: auth } } });
  const { data: { user }, error: authError } = await userClient.auth.getUser();
  if (authError || !user) return json(401, { error: "Invalid session" });
  if (!admins.includes(user.id)) return json(403, { error: "Admin access denied" });
  let body: { action?: string; user_id?: string; reason?: string; duration?: string };
  try { body = await req.json(); } catch { return json(400, { error: "Invalid JSON" }); }
  if (body.action === "check") return json(200, { is_admin: true });
  const target = String(body.user_id || "");
  if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(target)) return json(400, { error: "Enter a valid user UUID" });
  if (target === user.id) return json(400, { error: "You cannot restrict your own admin account" });
  const db = createClient(url, service);
  if (body.action === "unban") {
    const { error: authBanError } = await db.auth.admin.updateUserById(target, { ban_duration: "none" });
    if (authBanError) return json(500, { error: "Could not remove the Supabase Auth ban: " + authBanError.message });
    const { error } = await db.from("user_restrictions").delete().eq("user_id", target);
    if (error) return json(500, { error: "Auth ban removed, but the database restriction could not be removed. Run the TvCord safety migration first." });
    return json(200, { ok: true, message: "Supabase Auth ban and database restriction removed." });
  }
  if (body.action !== "ban") return json(400, { error: "Action must be check, ban, or unban" });
  const durations: Record<string, number | null> = { "1h": 3600, "24h": 86400, "7d": 604800, "30d": 2592000, permanent: null };
  const duration = body.duration || "permanent";
  if (!(duration in durations)) return json(400, { error: "Invalid duration" });
  const expires = durations[duration] === null ? null : new Date(Date.now() + durations[duration]! * 1000).toISOString();
  const seconds = durations[duration];
  const authBanDuration = seconds === null ? "876000h" : seconds + "s";
  const { error: authBanError } = await db.auth.admin.updateUserById(target, { ban_duration: authBanDuration });
  if (authBanError) return json(500, { error: "Could not apply Supabase Auth ban: " + authBanError.message });
  const { error } = await db.from("user_restrictions").upsert({
    user_id: target,
    reason: String(body.reason || "Safety policy violation").slice(0, 300),
    expires_at: expires,
    created_by: user.id,
  }, { onConflict: "user_id" });
  if (error) return json(500, { error: "Supabase Auth ban applied, but the database restriction failed. Run the TvCord safety migration immediately." });
  return json(200, { ok: true, message: expires ? "Account banned until " + expires : "Account permanently banned (100-year Auth ban)." });
});
