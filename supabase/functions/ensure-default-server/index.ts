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
  const admins = (Deno.env.get("TVCORD_ADMIN_USER_IDS") || "").split(/[\s,;]+/).map(x => x.trim()).filter(Boolean);
  if (!url || !anon || !service || !admins.length) return json(503, { error: "Set TVCORD_ADMIN_USER_IDS and Supabase function secrets first." });
  const authorization = req.headers.get("Authorization");
  if (!authorization) return json(401, { error: "Sign in required." });
  const userClient = createClient(url, anon, { global: { headers: { Authorization: authorization } } });
  const { data: { user }, error: authError } = await userClient.auth.getUser();
  if (authError || !user) return json(401, { error: "Invalid session." });

  const adminId = admins[0].toLowerCase();
  const db = createClient(url, service);
  const { data: adminUser, error: adminLookupError } = await db.auth.admin.getUserById(adminId);
  if (adminLookupError || !adminUser?.user) return json(503, { error: "The first ID in TVCORD_ADMIN_USER_IDS must be a valid Supabase Auth user UUID." });

  const { data: homeResult, error: homeError } = await db.rpc("ensure_tvcord_home_server", {
    admin_id: adminId,
    joining_user: user.id,
  });
  if (homeError || !homeResult?.ok) {
    return json(500, { error: "Could not prepare the single TvCord home server: " + (homeError?.message || "unknown database error") });
  }
  return json(200, homeResult);
});
