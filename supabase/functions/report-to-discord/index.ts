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
  const webhook = Deno.env.get("DISCORD_WEBHOOK_URL");
  if (!url || !anon || !service || !webhook) return json(503, { error: "Report backend is not fully configured. Set Supabase function secrets and DISCORD_WEBHOOK_URL." });
  const auth = req.headers.get("Authorization");
  if (!auth) return json(401, { error: "Sign in required" });
  const userClient = createClient(url, anon, { global: { headers: { Authorization: auth } } });
  const { data: { user }, error: authError } = await userClient.auth.getUser();
  if (authError || !user) return json(401, { error: "Invalid session" });
  let body: { report_id?: string };
  try { body = await req.json(); } catch { return json(400, { error: "Invalid JSON" }); }
  if (!body.report_id || !/^[0-9a-f-]{36}$/i.test(body.report_id)) return json(400, { error: "Valid report_id required" });
  const db = createClient(url, service);
  const { data: report, error } = await db.from("content_reports").select("*").eq("id", body.report_id).maybeSingle();
  if (error || !report) return json(404, { error: "Report not found" });
  if (report.reporter_id !== user.id) return json(403, { error: "You can only forward your own report" });
  let message: Record<string, unknown> | null = null;
  if (report.message_id) {
    const { data } = await db.from("messages").select("id,content,attachment_url,attachment_name,channel_id,user_id,created_at").eq("id", report.message_id).maybeSingle();
    message = data;
  }
  const { data: reporter } = await db.from("profiles").select("username").eq("id", report.reporter_id).maybeSingle();
  const { data: reported } = report.reported_user_id
    ? await db.from("profiles").select("username").eq("id", report.reported_user_id).maybeSingle()
    : { data: null };
  const safe = (v: unknown, n = 900) => String(v ?? "").slice(0, n);
  let attachment = safe(message?.attachment_url, 1000);
  if (attachment && !/^https?:\/\//i.test(attachment)) { const signed = await db.storage.from("attachments").createSignedUrl(attachment, 3600); attachment = signed.data?.signedUrl || ""; }
  const embeds = [{
    title: "TvCord content report",
    color: report.reason === "underage_safety" || report.reason === "sexual_content" || report.reason === "grooming" ? 15158332 : 15844367,
    fields: [
      { name: "Reason", value: safe(report.reason, 100), inline: true },
      { name: "Status", value: safe(report.status, 50), inline: true },
      { name: "Reporter", value: safe(reporter?.username || "Unknown") + "\nID: " + report.reporter_id },
      { name: "Reported account", value: safe(reported?.username || "Unknown") + "\nID: " + safe(report.reported_user_id || "Unavailable") },
      { name: "Reported message ID", value: safe(report.message_id || "Unavailable"), inline: true },
      { name: "Channel ID", value: safe(message?.channel_id || "Unavailable"), inline: true },
      { name: "Details", value: safe(report.details || "(none)") },
      { name: "Message text", value: safe(message?.content || "(no text; possibly an attachment)") },
      { name: "Attachment", value: attachment ? attachment : "(none)" },
    ],
    ...(attachment && /\.(png|jpe?g|gif|webp)(?:[?#]|$)/i.test(attachment) ? { image: { url: attachment } } : {}),
    timestamp: report.created_at,
    footer: { text: "TvCord moderation • Report ID " + report.id },
  }];
  const sent = await fetch(webhook, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ username: "TvCord Moderation", allowed_mentions: { parse: [] }, embeds }),
  });
  if (!sent.ok) return json(502, { error: "Report saved to Supabase, but Discord webhook delivery failed", webhook_status: sent.status });
  return json(200, { ok: true, report_id: report.id });
});
