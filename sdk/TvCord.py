# TvCord API library for Python 3.10+
# Include TvCord
# Keep TVCORD_BOT_TOKEN in an environment variable; never paste it into source.
import json, os, time, urllib.request, urllib.error, urllib.parse, datetime

GATEWAY = "https://dbiinubzfmsqlzngrjoc.supabase.co/functions/v1/tvcord-bot"

class Message:
    def __init__(self, bot, data, is_dm):
        self._bot, self._data, self.is_dm = bot, data, is_dm
        self.id = data.get("id")
        self.content = str(data.get("content") or "")
        self.user_id = data.get("user_id")
        self.channel_id = data.get("channel_id")
    def reply(self, text):
        if self.is_dm: return self._bot.send_dm(self.user_id, text)
        return self._bot.send_channel_message(self.channel_id, text)

class Bot:
    def __init__(self, token=None, gateway=GATEWAY, poll_interval=4):
        self.token = token or os.getenv("TVCORD_BOT_TOKEN")
        if not self.token or not self.token.startswith("tvc_"):
            raise ValueError("Set TVCORD_BOT_TOKEN to the token from the TvCord Developer Portal.")
        self.gateway, self.poll_interval = gateway, max(2, poll_interval)
        self.commands, self.handlers, self.seen = {}, [], set()
        self.since = (datetime.datetime.now(datetime.timezone.utc)-datetime.timedelta(seconds=60)).isoformat()
        self.running = False
    def command(self, name, handler):
        self.commands[name.lstrip("/").lower()] = handler
        return self
    def on_message(self, handler):
        self.handlers.append(handler); return self
    def request(self, action, **extra):
        body = json.dumps({"token":self.token,"action":action,**extra}).encode()
        req = urllib.request.Request(self.gateway, data=body, headers={"Content-Type":"application/json"}, method="POST")
        try:
            with urllib.request.urlopen(req, timeout=20) as res: payload=json.loads(res.read().decode())
        except urllib.error.HTTPError as e:
            payload=json.loads(e.read().decode() or "{}")
            raise RuntimeError(payload.get("error", "TvCord gateway request failed"))
        if payload.get("error") or not payload.get("ok"): raise RuntimeError(payload.get("error","TvCord gateway request failed"))
        return payload.get("data")
    def send_channel_message(self, channel_id, content):
        return self.request("send_channel_message", channel_id=str(channel_id), content=str(content)[:4000])
    def send_dm(self, user_id, content):
        return self.request("send_dm_message", user_id=str(user_id), content=str(content)[:4000])
    def _dispatch(self, data, is_dm):
        mid=data.get("id")
        if not mid or mid in self.seen: return
        self.seen.add(mid)
        if len(self.seen)>2000: self.seen.clear()
        msg=Message(self,data,is_dm)
        parts=msg.content.strip().split(None,1)
        if parts and parts[0].startswith("/"):
            handler=self.commands.get(parts[0][1:].lower())
            if handler:
                try: handler(msg, parts[1] if len(parts)>1 else "")
                except TypeError: handler(msg)
                except Exception as e: print("TvCord command error:",e)
        for handler in self.handlers:
            try: handler(msg)
            except Exception as e: print("TvCord message handler error:",e)
    def poll(self):
        result=self.request("poll",since=self.since) or {}
        all_msgs=[(m,False) for m in result.get("channel_messages",[])]+[(m,True) for m in result.get("dm_messages",[])]
        all_msgs.sort(key=lambda item:item[0].get("created_at",""))
        for data,is_dm in all_msgs: self._dispatch(data,is_dm)
        if all_msgs: self.since=max((m.get("created_at","") for m,_ in all_msgs),default=self.since) or self.since
        else: self.since=datetime.datetime.now(datetime.timezone.utc).isoformat()
    def start(self):
        self.running=True
        print("TvCord bot polling started.")
        while self.running:
            try: self.poll()
            except Exception as e: print("TvCord polling error:",e)
            time.sleep(self.poll_interval)
    def stop(self): self.running=False
