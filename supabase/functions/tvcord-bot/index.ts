// TvCord bot HTTPS gateway.
// Deploy with: supabase functions deploy tvcord-bot
// Uses the project's server-side service role; never put that key in frontend code.
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Content-Type": "application/json",
};

const json = (status: number, body: unknown) =>
  new Response(JSON.stringify(body), { status, headers: corsHeaders });

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json(405, { error: "Use POST." });

  const url = Deno.env.get("SUPABASE_URL");
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!url || !serviceKey) return json(500, { error: "Bot gateway is not configured." });

  let body: Record<string, unknown>;
  try {
    body = await req.json();
  } catch {
    return json(400, { error: "Request body must be JSON." });
  }

  const token = typeof body.token === "string" ? body.token : "";
  const action = typeof body.action === "string" ? body.action : "";
  if (!token.startsWith("tvc_") || token.length < 20) {
    return json(401, { error: "A valid bot token is required." });
  }

  const sb = createClient(url, serviceKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });

  let rpcName: string;
  let args: Record<string, unknown>;
  if (action === "poll") {
    const since = typeof body.since === "string" ? body.since : null;
    rpcName = "tvcord_bot_poll";
    args = { p_token: token, p_since: since };
  } else if (action === "send_channel_message") {
    if (typeof body.channel_id !== "string" || typeof body.content !== "string") {
      return json(400, { error: "channel_id and content are required." });
    }
    rpcName = "tvcord_bot_send_channel_message";
    args = { p_token: token, p_channel_id: body.channel_id, p_content: body.content };
  } else if (action === "send_dm_message") {
    if (typeof body.user_id !== "string" || typeof body.content !== "string") {
      return json(400, { error: "user_id and content are required." });
    }
    rpcName = "tvcord_bot_send_dm_message";
    args = { p_token: token, p_user_id: body.user_id, p_content: body.content };
  } else {
    return json(400, { error: "Unknown action. Use poll, send_channel_message, or send_dm_message." });
  }

  const { data, error } = await sb.rpc(rpcName, args);
  if (error) {
    const status = /Invalid bot token/i.test(error.message) ? 401
      : /not found|must be a member|No DM thread|must be 1 to 4000/i.test(error.message) ? 400
      : 500;
    return json(status, { error: error.message });
  }
  return json(200, { ok: true, data });
});
