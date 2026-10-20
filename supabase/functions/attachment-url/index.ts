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
  if (!url || !anon || !service) return json(503, { error: "Attachment service not configured." });
  const auth = req.headers.get("Authorization");
  if (!auth) return json(401, { error: "Sign in required." });
  const userClient = createClient(url, anon, { global: { headers: { Authorization: auth } } });
  const { data: { user }, error: authError } = await userClient.auth.getUser();
  if (authError || !user) return json(401, { error: "Invalid session." });
  let body: { path?: string; download?: boolean };
  try { body = await req.json(); } catch { return json(400, { error: "Invalid request." }); }
  const path = String(body.path || "");
  if (!path || path.length > 300 || path.includes("..") || path.startsWith("/") || path.startsWith("http")) return json(400, { error: "Invalid attachment path." });
  const db = createClient(url, service);
  const { data: message } = await db.from("messages").select("id,channel_id,attachment_url,attachment_name").eq("attachment_url", path).maybeSingle();
  if (!message) return json(404, { error: "Attachment is not published in a message." });
  const { data: channel } = await db.from("channels").select("server_id").eq("id", message.channel_id).maybeSingle();
  if (!channel) return json(404, { error: "Channel not found." });
  const { data: membership } = await db.from("server_members").select("user_id").eq("server_id", channel.server_id).eq("user_id", user.id).maybeSingle();
  if (!membership) return json(403, { error: "You must be a member of the server to view this attachment." });
  const filename = String(message.attachment_name || "attachment").replace(/[\\r\\n"]/g, "_").slice(0, 180);
  const isImage = /\\.(png|jpe?g|gif|webp|avif)$/i.test(filename);
  // Non-image uploads are forced to download rather than being rendered inline by the browser.
  const forceDownload = body.download === true || !isImage;
  const { data, error } = await db.storage.from("attachments").createSignedUrl(path, 3600, forceDownload ? { download: filename } : {});
  if (error || !data?.signedUrl) return json(404, { error: "Attachment could not be opened." });
  return json(200, { url: data.signedUrl, expires_in: 3600 });
});
