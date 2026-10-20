# TvCord API library for Ruby 3+
# Include TvCord
# Keep TVCORD_BOT_TOKEN in an environment variable; never paste it into source.
require "json"
require "net/http"
require "uri"
require "time"

module TvCord
  GATEWAY = "https://dbiinubzfmsqlzngrjoc.supabase.co/functions/v1/tvcord-bot"
  class Message
    attr_reader :id, :content, :user_id, :channel_id, :is_dm
    def initialize(bot, data, is_dm)
      @bot, @data, @is_dm = bot, data, is_dm
      @id, @content, @user_id, @channel_id = data["id"], data["content"].to_s, data["user_id"], data["channel_id"]
    end
    def reply(text)
      @is_dm ? @bot.send_dm(@user_id, text) : @bot.send_channel_message(@channel_id, text)
    end
  end
  class Bot
    def initialize(token = ENV["TVCORD_BOT_TOKEN"], gateway: GATEWAY, poll_interval: 4)
      raise ArgumentError, "Set TVCORD_BOT_TOKEN to the token from the TvCord Developer Portal." unless token && token.start_with?("tvc_")
      @token, @gateway, @poll_interval = token, URI(gateway), [poll_interval, 2].max
      @commands, @handlers, @seen = {}, [], {}
      @since = (Time.now.utc - 60).iso8601
      @running = false
    end
    def command(name, &handler); @commands[name.to_s.sub(/^\//, "").downcase] = handler; self; end
    def on_message(&handler); @handlers << handler; self; end
    def request(action, extra = {})
      uri = @gateway
      req = Net::HTTP::Post.new(uri, { "Content-Type" => "application/json" })
      req.body = { token: @token, action: action }.merge(extra).to_json
      res = Net::HTTP.start(uri.hostname, uri.port, use_ssl: uri.scheme == "https", open_timeout: 10, read_timeout: 20) { |http| http.request(req) }
      payload = JSON.parse(res.body) rescue {}
      raise(payload["error"] || "TvCord gateway request failed") unless res.is_a?(Net::HTTPSuccess) && !payload["error"]
      payload["data"]
    end
    def send_channel_message(channel_id, content); request("send_channel_message", channel_id: channel_id.to_s, content: content.to_s[0, 4000]); end
    def send_dm(user_id, content); request("send_dm_message", user_id: user_id.to_s, content: content.to_s[0, 4000]); end
    def dispatch(data, is_dm)
      mid = data["id"]; return if !mid || @seen[mid]
      @seen[mid] = true; @seen.clear if @seen.size > 2000
      msg = Message.new(self, data, is_dm)
      if (match = msg.content.match(/^\/(\w+)(?:\s+([\s\S]*))?$/)) && (handler = @commands[match[1].downcase])
        begin; handler.call(msg, match[2].to_s); rescue => e; warn "TvCord command error: #{e}"; end
      end
      @handlers.each { |h| begin; h.call(msg); rescue => e; warn "TvCord message handler error: #{e}"; end }
    end
    def poll
      result = request("poll", since: @since) || {}
      items = (Array(result["channel_messages"]).map { |m| [m, false] } + Array(result["dm_messages"]).map { |m| [m, true] }).sort_by { |m, _| m["created_at"].to_s }
      items.each { |m, dm| dispatch(m, dm) }
      @since = items.last[0]["created_at"] if items.any? && items.last[0]["created_at"]
      @since = Time.now.utc.iso8601 if items.empty?
    end
    def start
      @running = true; puts "TvCord bot polling started."
      while @running
        begin; poll; rescue => e; warn "TvCord polling error: #{e}"; end
        sleep @poll_interval
      end
    end
    def stop; @running = false; end
  end
end
