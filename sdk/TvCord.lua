-- TvCord API library for Lua 5.3+
-- Include TvCord
-- Dependencies: LuaSocket (socket.http, ltn12), lua-cjson, and ssl.https for HTTPS.
-- Keep TVCORD_BOT_TOKEN in an environment variable; never paste it into source.
local json = require("cjson")
local ltn12 = require("ltn12")
local http_ok, http = pcall(require, "ssl.https")
if not http_ok then http = require("socket.http") end
local TvCord = {}
TvCord.GATEWAY = "https://dbiinubzfmsqlzngrjoc.supabase.co/functions/v1/tvcord-bot"
local Bot = {}; Bot.__index = Bot
local function request(self, action, extra)
  local body = {token=self.token, action=action}
  for k,v in pairs(extra or {}) do body[k]=v end
  local encoded=json.encode(body); local chunks={}
  local _, code, _, status = http.request({
    url=self.gateway, method="POST",
    headers={["Content-Type"]="application/json",["Content-Length"]=tostring(#encoded)},
    source=ltn12.source.string(encoded), sink=ltn12.sink.table(chunks)
  })
  local payload=json.decode(table.concat(chunks))
  if tonumber(code) < 200 or tonumber(code) >= 300 or payload.error then error(payload.error or status or "TvCord gateway request failed") end
  return payload.data
end
function Bot.new(token, opts)
  token=token or os.getenv("TVCORD_BOT_TOKEN")
  assert(token and token:sub(1,4)=="tvc_", "Set TVCORD_BOT_TOKEN to the token from the TvCord Developer Portal.")
  opts=opts or {}
  return setmetatable({token=token,gateway=opts.gateway or TvCord.GATEWAY,poll_interval=math.max(2,opts.poll_interval or 4),commands={},handlers={},seen={},since=os.date("!%Y-%m-%dT%H:%M:%SZ",os.time()-60),running=false},Bot)
end
function Bot:command(name, handler) self.commands=(self.commands or {}); self.commands[name:gsub("^/",""):lower()]=handler; return self end
function Bot:on_message(handler) table.insert(self.handlers,handler); return self end
function Bot:send_channel_message(channel_id, content) return request(self,"send_channel_message",{channel_id=tostring(channel_id),content=tostring(content):sub(1,4000)}) end
function Bot:send_dm(user_id, content) return request(self,"send_dm_message",{user_id=tostring(user_id),content=tostring(content):sub(1,4000)}) end
local function dispatch(self, data, is_dm)
  if not data.id or self.seen[data.id] then return end
  self.seen[data.id]=true
  local msg={id=data.id,content=data.content or "",user_id=data.user_id,channel_id=data.channel_id,is_dm=is_dm}
  function msg:reply(text) if self.is_dm then return self._bot:send_dm(self.user_id,text) else return self._bot:send_channel_message(self.channel_id,text) end end
  msg._bot=self
  local name,args=msg.content:match("^/(%w+)%s*(.*)$")
  if name and self.commands[name:lower()] then local ok,err=pcall(self.commands[name:lower()],msg,args); if not ok then io.stderr:write("TvCord command error: "..tostring(err).."\n") end end
  for _,handler in ipairs(self.handlers) do local ok,err=pcall(handler,msg); if not ok then io.stderr:write("TvCord message handler error: "..tostring(err).."\n") end end
end
function Bot:poll()
  local result=request(self,"poll",{since=self.since}) or {}
  local items={}
  for _,m in ipairs(result.channel_messages or {}) do table.insert(items,{m,false}) end
  for _,m in ipairs(result.dm_messages or {}) do table.insert(items,{m,true}) end
  table.sort(items,function(a,b) return (a[1].created_at or "") < (b[1].created_at or "") end)
  for _,item in ipairs(items) do dispatch(self,item[1],item[2]) end
  if #items>0 and items[#items][1].created_at then self.since=items[#items][1].created_at else self.since=os.date("!%Y-%m-%dT%H:%M:%SZ") end
end
function Bot:start()
  self.running=true; print("TvCord bot polling started.")
  while self.running do local ok,err=pcall(self.poll,self); if not ok then io.stderr:write("TvCord polling error: "..tostring(err).."\n") end; os.execute("sleep "..tostring(self.poll_interval)) end
end
function Bot:stop() self.running=false end
TvCord.Bot=Bot
return TvCord
