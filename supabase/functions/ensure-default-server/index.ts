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

  let { data: home, error } = await db.from("servers").select("id,name,owner_id,invite_code").eq("name", "TvCord").limit(1).maybeSingle();
  if (error) return json(500, { error: "Could not look up the TvCord home server: " + error.message });
  if (!home) {
    const created = await db.from("servers").insert({ name: "TvCord", owner_id: adminId }).select("id,name,owner_id,invite_code").single();
    if (created.error || !created.data) return json(500, { error: "Could not create the TvCord home server: " + (created.error?.message || "unknown error") });
    home = created.data;
  } else if (home.owner_id !== adminId) {
    const updated = await db.from("servers").update({ owner_id: adminId }).eq("id", home.id).select("id,name,owner_id,invite_code").single();
    if (updated.error || !updated.data) return json(500, { error: "Could not set the TvCord home server owner: " + (updated.error?.message || "unknown error") });
    home = updated.data;
  }

  const memberships = user.id === adminId
    ? [{ server_id: home.id, user_id: adminId, role: "owner" }]
    : [
        { server_id: home.id, user_id: adminId, role: "owner" },
        { server_id: home.id, user_id: user.id, role: "member" },
      ];
  const { error: memberError } = await db.from("server_members").upsert(memberships, { onConflict: "server_id,user_id" });
  if (memberError) return json(500, { error: "Could not add the signed-in user to the TvCord home server: " + memberError.message });

  const { data: existingChannels, error: channelReadError } = await db.from("channels").select("name,type").eq("server_id", home.id);
  if (channelReadError) return json(500, { error: "Could not load TvCord home channels: " + channelReadError.message });
  const wanted = [
    { server_id: home.id, name: "general", type: "text", position: 0 },
    { server_id: home.id, name: "voice-lounge", type: "voice", position: 1 },
  ];
  const missing = wanted.filter(w => !(existingChannels || []).some(c => c.name === w.name && c.type === w.type));
  if (missing.length) {
    const { error: channelError } = await db.from("channels").insert(missing);
    if (channelError) return json(500, { error: "Could not set up TvCord home channels: " + channelError.message });
  }
  return json(200, { ok: true, server_id: home.id, admin_user_id: adminId, is_admin: user.id === adminId });
});
