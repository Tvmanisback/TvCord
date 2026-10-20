// TvCord API library — JavaScript ESM, Node 18+ / Bun / Deno.
// Include TvCord
// Set TVCORD_BOT_TOKEN in your host's environment variables.
// Example:
// import { Bot } from "./TvCord.js";
// const bot = new Bot(process.env.TVCORD_BOT_TOKEN);
// bot.command("ping", (msg) => msg.reply("Pong!"));
// bot.command("help", (msg) => msg.reply("Commands: /ping, /help"));
// await bot.start();

const GATEWAY = "https://dbiinubzfmsqlzngrjoc.supabase.co/functions/v1/tvcord-bot";

export class Bot {
  constructor(token, { gateway = GATEWAY, pollInterval = 4000 } = {}) {
    if (!token || !String(token).startsWith("tvc_")) {
      throw new Error("Pass your TvCord bot token from TVCORD_BOT_TOKEN.");
    }
    this.token = token;
    this.gateway = gateway;
    this.pollInterval = Math.max(2000, pollInterval);
    this.handlers = new Map();
    this.messageHandlers = [];
    this.running = false;
    this.since = new Date(Date.now() - 60_000).toISOString();
    this.seen = new Set();
  }

  command(name, handler) {
    this.handlers.set(String(name).replace(/^\//, "").toLowerCase(), handler);
    return this;
  }

  onMessage(handler) {
    this.messageHandlers.push(handler);
    return this;
  }

  async request(action, extra = {}) {
    const response = await fetch(this.gateway, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ token: this.token, action, ...extra }),
    });
    const payload = await response.json().catch(() => ({}));
    if (!response.ok || payload.error) throw new Error(payload.error || "TvCord gateway request failed.");
    return payload.data;
  }

  async sendChannelMessage(channelId, content) {
    return this.request("send_channel_message", { channel_id: channelId, content: String(content).slice(0, 4000) });
  }

  async sendDM(userId, content) {
    return this.request("send_dm_message", { user_id: userId, content: String(content).slice(0, 4000) });
  }

  async dispatch(message, isDM) {
    if (!message?.id || this.seen.has(message.id)) return;
    this.seen.add(message.id);
    if (this.seen.size > 2000) this.seen.clear();
    const content = String(message.content || "");
    const prefix = content.match(/^\/(\w+)(?:\s+([\s\S]*))?$/);
    const context = {
      id: message.id,
      content,
      userId: message.user_id,
      channelId: message.channel_id || null,
      isDM,
      reply: (text) => isDM
        ? this.sendDM(message.user_id, text)
        : this.sendChannelMessage(message.channel_id, text),
    };
    if (prefix) {
      const handler = this.handlers.get(prefix[1].toLowerCase());
      if (handler) {
        try { await handler(context, prefix[2] || ""); }
        catch (error) { console.error("TvCord command error:", error); }
      }
    }
    for (const handler of this.messageHandlers) {
      try { await handler(context); }
      catch (error) { console.error("TvCord message handler error:", error); }
    }
  }

  async poll() {
    const result = await this.request("poll", { since: this.since });
    const channelMessages = Array.isArray(result?.channel_messages) ? result.channel_messages : [];
    const dmMessages = Array.isArray(result?.dm_messages) ? result.dm_messages : [];
    const all = [
      ...channelMessages.map(m => ({ message: m, isDM: false })),
      ...dmMessages.map(m => ({ message: m, isDM: true })),
    ].sort((a, b) => new Date(a.message.created_at) - new Date(b.message.created_at));

    for (const item of all) await this.dispatch(item.message, item.isDM);
    if (all.length) {
      const latest = all[all.length - 1].message.created_at;
      if (latest && new Date(latest) > new Date(this.since)) this.since = latest;
    } else {
      this.since = new Date().toISOString();
    }
  }

  async start() {
    if (this.running) return;
    this.running = true;
    console.log("TvCord bot polling started.");
    while (this.running) {
      try { await this.poll(); }
      catch (error) { console.error("TvCord bot polling error:", error.message || error); }
      await new Promise(resolve => setTimeout(resolve, this.pollInterval));
    }
  }

  stop() {
    this.running = false;
  }
}
