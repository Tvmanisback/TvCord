import React, { useEffect, useMemo, useRef, useState } from 'react';
import { createRoot } from 'react-dom/client';
import { createClient } from '@supabase/supabase-js';
import {
  Hash, Volume2, Plus, Compass, MessageCircle, Settings, LogOut, Send, Image as ImageIcon,
  Smile, Users, ChevronDown, Menu, X, Copy, Check, Sparkles, Shield, UserPlus, LoaderCircle,
  Palette, Camera, ArrowLeft, MoreHorizontal
} from 'lucide-react';
import './style.css';

const cfg = window.TVCORD_CONFIG || {};
const configured = cfg.supabaseUrl && cfg.supabaseAnonKey &&
  !cfg.supabaseUrl.includes('YOUR-PROJECT') && !cfg.supabaseAnonKey.includes('YOUR_SUPABASE');
const supabase = configured ? createClient(cfg.supabaseUrl, cfg.supabaseAnonKey) : null;
const initials = (name = '?') => name.trim().slice(0, 2).toUpperCase();
const stamp = (date) => new Date(date).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });

function App() {
  const [session, setSession] = useState(null);
  const [profile, setProfile] = useState(null);
  const [servers, setServers] = useState([]);
  const [activeServer, setActiveServer] = useState(null);
  const [channels, setChannels] = useState([]);
  const [activeChannel, setActiveChannel] = useState(null);
  const [messages, setMessages] = useState([]);
  const [members, setMembers] = useState([]);
  const [draft, setDraft] = useState('');
  const [authMode, setAuthMode] = useState('login');
  const [email, setEmail] = useState('');
  const [password, setPassword] = useState('');
  const [username, setUsername] = useState('');
  const [busy, setBusy] = useState(false);
  const [notice, setNotice] = useState('');
  const [modal, setModal] = useState('');
  const [serverName, setServerName] = useState('');
  const [channelName, setChannelName] = useState('');
  const [inviteCode, setInviteCode] = useState('');
  const [settingsName, setSettingsName] = useState('');
  const [statusText, setStatusText] = useState('');
  const [accent, setAccent] = useState('#e34b64');
  const [rightOpen, setRightOpen] = useState(true);
  const [mobileNav, setMobileNav] = useState(false);
  const [uploading, setUploading] = useState(false);
  const [copied, setCopied] = useState(false);
  const bottomRef = useRef(null);
  const uploadRef = useRef(null);

  useEffect(() => {
    if (!supabase) return;
    supabase.auth.getSession().then(({ data }) => setSession(data.session));
    const { data: listener } = supabase.auth.onAuthStateChange((_event, next) => setSession(next));
    return () => listener.subscription.unsubscribe();
  }, []);

  useEffect(() => {
    if (!session || !supabase) {
      setProfile(null); setServers([]); setActiveServer(null); setChannels([]); setActiveChannel(null);
      return;
    }
    let live = true;
    (async () => {
      const { data: p } = await supabase.from('profiles').select('*').eq('id', session.user.id).maybeSingle();
      if (!live) return;
      if (!p) {
        const newProfile = { id: session.user.id, username: session.user.user_metadata?.username || session.user.email?.split('@')[0] || 'new-user', status_text: '', accent_color: '#e34b64' };
        const { data: inserted } = await supabase.from('profiles').upsert(newProfile).select().single();
        if (live) setProfile(inserted || newProfile);
      } else setProfile(p);
      const { data: rows, error } = await supabase.from('server_members')
        .select('server_id, role, servers(id,name,owner_id,invite_code,icon_url)')
        .eq('user_id', session.user.id);
      if (!live) return;
      if (error) { setNotice(error.message); return; }
      const list = (rows || []).map(row => ({ ...row.servers, myRole: row.role })).filter(Boolean);
      setServers(list);
      if (list.length) setActiveServer(prev => list.find(s => s.id === prev?.id) || list[0]);
    })();
    return () => { live = false; };
  }, [session]);

  useEffect(() => {
    if (!activeServer || !supabase) { setChannels([]); setActiveChannel(null); return; }
    let live = true;
    (async () => {
      const { data, error } = await supabase.from('channels').select('*').eq('server_id', activeServer.id).order('position');
      if (!live) return;
      if (error) { setNotice(error.message); return; }
      const list = data || [];
      setChannels(list);
      setActiveChannel(prev => list.find(c => c.id === prev?.id) || list.find(c => c.type === 'text') || list[0] || null);
      const { data: people } = await supabase.from('server_members')
        .select('role, profiles(id,username,avatar_url,status_text)')
        .eq('server_id', activeServer.id);
      if (live) setMembers((people || []).map(m => ({ ...m.profiles, role: m.role })).filter(Boolean));
    })();
    return () => { live = false; };
  }, [activeServer]);

  useEffect(() => {
    if (!activeChannel || !supabase) { setMessages([]); return; }
    let live = true;
    const load = async () => {
      const { data, error } = await supabase.from('messages')
        .select('id,content,created_at,user_id,attachment_url,attachment_name,profiles(id,username,avatar_url,accent_color)')
        .eq('channel_id', activeChannel.id).order('created_at', { ascending: true }).limit(150);
      if (!live) return;
      if (error) setNotice(error.message);
      else setMessages(data || []);
    };
    load();
    const channel = supabase.channel('messages:' + activeChannel.id)
      .on('postgres_changes', { event: 'INSERT', schema: 'public', table: 'messages', filter: 'channel_id=eq.' + activeChannel.id }, async payload => {
        const { data } = await supabase.from('messages')
          .select('id,content,created_at,user_id,attachment_url,attachment_name,profiles(id,username,avatar_url,accent_color)')
          .eq('id', payload.new.id).single();
        if (data) setMessages(old => old.some(m => m.id === data.id) ? old : [...old, data]);
      }).subscribe();
    return () => { live = false; supabase.removeChannel(channel); };
  }, [activeChannel]);

  useEffect(() => { bottomRef.current?.scrollIntoView({ behavior: 'smooth' }); }, [messages]);

  const onlineMembers = useMemo(() => members.filter(m => m.id === session?.user?.id), [members, session]);
  const show = (message) => { setNotice(message); window.setTimeout(() => setNotice(''), 4500); };

  async function signIn(e) {
    e.preventDefault(); if (!supabase) return;
    setBusy(true);
    const result = authMode === 'signup'
      ? await supabase.auth.signUp({ email, password, options: { data: { username: username.trim() || email.split('@')[0] } } })
      : await supabase.auth.signInWithPassword({ email, password });
    setBusy(false);
    if (result.error) show(result.error.message);
    else if (authMode === 'signup' && !result.data.session) show('Account created. Check your email to confirm, then log in.');
    else show(authMode === 'signup' ? 'Welcome to TvCord!' : 'Welcome back!');
  }

  async function signOut() { await supabase?.auth.signOut(); }
  async function createServer(e) {
    e.preventDefault();
    const name = serverName.trim(); if (!name || !session) return;
    setBusy(true);
    const { data, error } = await supabase.rpc('create_server', { server_name: name });
    setBusy(false);
    if (error) return show(error.message);
    setServerName(''); setModal('');
    const { data: s } = await supabase.from('servers').select('*').eq('id', data).single();
    if (s) { setServers(old => [...old, { ...s, myRole: 'owner' }]); setActiveServer(s); }
    show('Server created. Invite friends with its invite code.');
  }
  async function createChannel(e) {
    e.preventDefault();
    const name = channelName.trim().toLowerCase().replace(/[^a-z0-9-]/g, '-').replace(/-+/g, '-');
    if (!name || !activeServer) return;
    const { data, error } = await supabase.from('channels').insert({ server_id: activeServer.id, name, type: 'text', position: channels.length }).select().single();
    if (error) return show(error.message);
    setChannels(old => [...old, data]); setActiveChannel(data); setChannelName(''); setModal('');
  }
  async function joinServer(e) {
    e.preventDefault(); const code = inviteCode.trim(); if (!code) return;
    const { data, error } = await supabase.rpc('join_server_by_invite', { code });
    if (error) return show(error.message);
    const { data: s } = await supabase.from('servers').select('*').eq('id', data).single();
    if (s) { setServers(old => old.some(x => x.id === s.id) ? old : [...old, { ...s, myRole: 'member' }]); setActiveServer(s); }
    setInviteCode(''); setModal(''); show('You joined the server!');
  }
  async function sendMessage(e) {
    e.preventDefault(); const content = draft.trim();
    if (!content || !activeChannel || !session) return;
    setDraft('');
    const { error } = await supabase.from('messages').insert({ channel_id: activeChannel.id, user_id: session.user.id, content });
    if (error) { setDraft(content); show(error.message); }
  }
  async function uploadFile(file) {
    if (!file || !session || !activeChannel) return;
    if (file.size > 25 * 1024 * 1024) return show('This app currently limits uploads to 25 MB. Adjust the Supabase Storage limit to change it.');
    setUploading(true);
    const safeName = file.name.replace(/[^a-zA-Z0-9._-]/g, '_');
    const path = session.user.id + '/' + Date.now() + '-' + safeName;
    const { error: uploadError } = await supabase.storage.from('attachments').upload(path, file, { upsert: false, contentType: file.type });
    if (uploadError) { setUploading(false); return show(uploadError.message); }
    const { data: publicData } = supabase.storage.from('attachments').getPublicUrl(path);
    const { error } = await supabase.from('messages').insert({
      channel_id: activeChannel.id, user_id: session.user.id,
      content: '', attachment_url: publicData.publicUrl, attachment_name: file.name
    });
    setUploading(false);
    if (error) show(error.message);
  }
  async function saveProfile(e) {
    e.preventDefault();
    const patch = { username: settingsName.trim() || profile.username, status_text: statusText.trim().slice(0, 80), accent_color: accent };
    const { data, error } = await supabase.from('profiles').update(patch).eq('id', session.user.id).select().single();
    if (error) return show(error.message);
    setProfile(data); setModal(''); show('Profile updated.');
  }
  async function uploadAvatar(file) {
    if (!file || !session) return;
    setUploading(true);
    const ext = file.name.split('.').pop().replace(/[^a-zA-Z0-9]/g, '') || 'png';
    const path = session.user.id + '/avatar-' + Date.now() + '.' + ext;
    const { error: upError } = await supabase.storage.from('avatars').upload(path, file, { upsert: true, contentType: file.type });
    if (upError) { setUploading(false); return show(upError.message); }
    const { data: urlData } = supabase.storage.from('avatars').getPublicUrl(path);
    const { data, error } = await supabase.from('profiles').update({ avatar_url: urlData.publicUrl }).eq('id', session.user.id).select().single();
    setUploading(false);
    if (error) return show(error.message);
    setProfile(data); show('Avatar updated.');
  }
  async function copyInvite() {
    if (!activeServer?.invite_code) return;
    await navigator.clipboard.writeText(activeServer.invite_code);
    setCopied(true); setTimeout(() => setCopied(false), 1500);
  }

  if (!configured) return <SetupScreen />;
  if (!session) return <div className="auth-page"><div className="auth-glow"></div><div className="auth-card">
    <div className="brand-mark large">T</div><p className="eyebrow">YOUR PEOPLE. YOUR SPACE.</p><h1>Welcome to <span>TvCord</span></h1>
    <p className="muted auth-copy">Communities, conversations, and your own style.</p>
    <form onSubmit={signIn} className="stack">
      {authMode === 'signup' && <label>Username<input value={username} onChange={e=>setUsername(e.target.value)} placeholder="How people will know you" maxLength="32" required /></label>}
      <label>Email<input type="email" value={email} onChange={e=>setEmail(e.target.value)} placeholder="you@example.com" autoComplete="email" required /></label>
      <label>Password<input type="password" value={password} onChange={e=>setPassword(e.target.value)} placeholder="At least 6 characters" minLength="6" autoComplete={authMode==='signup'?'new-password':'current-password'} required /></label>
      <button className="primary full" disabled={busy}>{busy ? <LoaderCircle className="spin" size={17}/> : null}{authMode==='signup'?'Create account':'Log in'}</button>
    </form>
    <p className="switch-auth">{authMode==='signup'?'Already have an account?':'New to TvCord?'} <button className="text-button" onClick={()=>setAuthMode(authMode==='signup'?'login':'signup')}>{authMode==='signup'?'Log in':'Create an account'}</button></p>
    <p className="tiny muted">By continuing, you agree to use TvCord respectfully.</p>
  </div>{notice && <div className="toast">{notice}</div>}</div>;

  return <div className="app-shell" style={{'--accent': profile?.accent_color || accent}}>
    <aside className={'server-rail '+(mobileNav?'open':'')}>
      <button className="rail-home brand-mark" title="Home" onClick={()=>{setActiveServer(servers[0]||null);setMobileNav(false)}}>T</button>
      <div className="rail-divider"/>
      {servers.map(s=><button key={s.id} title={s.name} className={'server-icon '+(activeServer?.id===s.id?'selected':'')} onClick={()=>{setActiveServer(s);setMobileNav(false)}}>{s.icon_url?<img src={s.icon_url} alt=""/>:initials(s.name)}</button>)}
      <button className="server-icon add-server" title="Create server" onClick={()=>{setModal('create-server');setMobileNav(false)}}><Plus/></button>
      <button className="server-icon join-server" title="Join server" onClick={()=>setModal('join-server')}><Compass/></button>
    </aside>
    <aside className={'channel-rail '+(mobileNav?'open':'')}>
      <button className="server-heading" onClick={()=>setModal('server-info')}><span>{activeServer?.name || 'Your spaces'}</span><ChevronDown size={16}/></button>
      <div className="channel-scroll">
        {!activeServer ? <div className="empty-side"><Sparkles size={25}/><h3>Find your people</h3><p>Create a server or join one with an invite code.</p><button className="primary" onClick={()=>setModal('create-server')}>Create a server</button><button className="secondary" onClick={()=>setModal('join-server')}>Join a server</button></div> : <>
          <div className="section-label"><span>TEXT CHANNELS</span><button title="Add channel" onClick={()=>setModal('create-channel')}><Plus size={15}/></button></div>
          {channels.filter(c=>c.type==='text').map(c=><button key={c.id} className={'channel-row '+(activeChannel?.id===c.id?'active':'')} onClick={()=>{setActiveChannel(c);setMobileNav(false)}}><Hash size={17}/><span>{c.name}</span></button>)}
          <div className="section-label voice-label"><span>VOICE CHANNELS</span></div>
          {channels.filter(c=>c.type==='voice').map(c=><button key={c.id} className="channel-row"><Volume2 size={17}/><span>{c.name}</span></button>)}
          <div className="server-tools"><button onClick={()=>setModal('server-info')}><Users size={15}/> Invite & server info</button></div>
        </>}
      </div>
      <div className="user-bar">
        <button className="avatar small" onClick={()=>setModal('profile')} title="Edit profile">{profile?.avatar_url?<img src={profile.avatar_url} alt=""/>:initials(profile?.username)}</button>
        <button className="user-summary" onClick={()=>setModal('profile')}><strong>{profile?.username || 'User'}</strong><span>{profile?.status_text || 'Online'}</span></button>
        <button className="icon-button" title="Profile settings" onClick={()=>setModal('profile')}><Settings size={18}/></button>
        <button className="icon-button" title="Log out" onClick={signOut}><LogOut size={17}/></button>
      </div>
    </aside>
    <main className="chat-panel">
      <header className="chat-header">
        <button className="icon-button mobile-only" onClick={()=>setMobileNav(!mobileNav)}><Menu size={20}/></button>
        {activeChannel ? <><Hash size={20} className="header-hash"/><strong>{activeChannel.name}</strong><span className="header-separator"></span><span className="muted header-topic">Welcome to #{activeChannel.name}</span></> : <><MessageCircle size={20}/><strong>TvCord</strong><span className="muted header-topic">Pick a channel to get started</span></>}
        <div className="header-actions"><button className={'icon-button '+(rightOpen?'toggled':'')} title="Toggle members" onClick={()=>setRightOpen(!rightOpen)}><Users size={19}/></button><button className="icon-button" title="Server invite" onClick={()=>setModal('server-info')}><UserPlus size={19}/></button></div>
      </header>
      <section className="messages-area">
        {!activeChannel ? <div className="welcome-state"><div className="welcome-orb"><MessageCircle size={32}/></div><h1>Make yourself at home.</h1><p>Create a server, join a community, or choose a channel to start chatting.</p><button className="primary" onClick={()=>setModal('create-server')}><Plus size={17}/> Create a server</button></div> :
          <><div className="channel-intro"><div className="intro-hash"><Hash size={27}/></div><h1>Welcome to #{activeChannel.name}!</h1><p>This is the beginning of the <strong>#{activeChannel.name}</strong> channel.</p></div>
          {messages.map(m=><article key={m.id} className="message-row">
            <div className="avatar message-avatar">{m.profiles?.avatar_url?<img src={m.profiles.avatar_url} alt=""/>:initials(m.profiles?.username)}</div>
            <div className="message-body"><div className="message-meta"><strong style={{color:m.profiles?.accent_color||'var(--text)'}}>{m.profiles?.username || 'Unknown user'}</strong><time>{stamp(m.created_at)}</time></div>
              {m.content && <p className="message-content">{m.content.split(/(https?:\/\/[^\s]+)/g).map((part,i)=>/^https?:\/\//.test(part)?<a key={i} href={part} target="_blank" rel="noreferrer">{part}</a>:part)}</p>}
              {m.attachment_url && (m.attachment_name?.match(/\.(png|jpe?g|gif|webp|avif)$/i) ? <a href={m.attachment_url} target="_blank" rel="noreferrer" className="attachment-image"><img src={m.attachment_url} alt={m.attachment_name}/></a> : <a className="attachment-file" href={m.attachment_url} target="_blank" rel="noreferrer"><ImageIcon size={20}/>{m.attachment_name||'Open attachment'}</a>)}
            </div>
          </article>)}
          <div ref={bottomRef}/></>}
      </section>
      {activeChannel && <form className="composer" onSubmit={sendMessage}>
        <button type="button" className="composer-plus" title="Upload file" onClick={()=>uploadRef.current?.click()} disabled={uploading}><Plus size={21}/></button>
        <input ref={uploadRef} type="file" hidden accept="image/*,.pdf,.txt,.zip" onChange={e=>{uploadFile(e.target.files?.[0]);e.target.value=''}}/>
        <input className="message-input" value={draft} onChange={e=>setDraft(e.target.value)} placeholder={'Message #'+activeChannel.name} maxLength="4000" aria-label="Message" />
        <button type="button" className="composer-tool" title="Upload image or GIF" onClick={()=>uploadRef.current?.click()} disabled={uploading}>{uploading?<LoaderCircle className="spin" size={19}/>:<ImageIcon size={19}/>}</button>
        <button type="button" className="composer-tool" title="Emoji" onClick={()=>setDraft(d=>d+' ✨')}><Smile size={19}/></button>
        <button type="submit" className="send-button" title="Send message" disabled={!draft.trim()}><Send size={18}/></button>
      </form>}
    </main>
    {rightOpen && <aside className="members-panel">
      <div className="members-heading">MEMBERS — {members.length}</div>
      {['owner','admin','member'].map(role=>{
        const group=members.filter(m=>m.role===role);
        return group.length ? <div key={role} className="member-group"><div className="role-label">{role==='owner'?'SERVER OWNER':role==='admin'?'ADMINISTRATORS':'MEMBERS'} — {group.length}</div>{group.map(m=><div className="member-row" key={m.id}><div className="avatar member-avatar">{m.avatar_url?<img src={m.avatar_url} alt=""/>:initials(m.username)}<span className="online-dot"/></div><div className="member-info"><strong>{m.username||'User'}</strong><span>{m.status_text||'Online'}</span></div>{m.id===session.user.id&&<span className="you-label">YOU</span>}</div>)}</div>:null;
      })}
      {!members.length&&<p className="muted no-members">Members appear here when you join a server.</p>}
    </aside>}
    {mobileNav&&<button className="mobile-scrim" onClick={()=>setMobileNav(false)} aria-label="Close menu"/>}
    {modal && <div className="modal-backdrop" onMouseDown={e=>{if(e.target===e.currentTarget)setModal('')}}>
      <div className="modal-card">
        <button className="modal-close icon-button" onClick={()=>setModal('')}><X size={19}/></button>
        {modal==='create-server'&&<><div className="modal-icon"><Plus/></div><h2>Create a server</h2><p className="muted">Start a space for friends, a club, or your community.</p><form onSubmit={createServer} className="stack"><label>Server name<input autoFocus value={serverName} onChange={e=>setServerName(e.target.value)} placeholder="My awesome server" maxLength="80" required/></label><button className="primary full" disabled={busy||!serverName.trim()}>{busy?'Creating…':'Create server'}</button></form></>}
        {modal==='join-server'&&<><div className="modal-icon"><Compass/></div><h2>Join a server</h2><p className="muted">Paste the invite code shared by a server member.</p><form onSubmit={joinServer} className="stack"><label>Invite code<input autoFocus value={inviteCode} onChange={e=>setInviteCode(e.target.value)} placeholder="Paste invite code" required/></label><button className="primary full">Join server</button></form></>}
        {modal==='create-channel'&&<><div className="modal-icon"><Hash/></div><h2>Create a channel</h2><p className="muted">Add a text channel to {activeServer?.name}.</p><form onSubmit={createChannel} className="stack"><label>Channel name<input autoFocus value={channelName} onChange={e=>setChannelName(e.target.value)} placeholder="general-chat" maxLength="60" required/></label><button className="primary full">Create channel</button></form></>}
        {modal==='server-info'&&<><div className="modal-icon"><Shield/></div><h2>{activeServer?.name||'Server details'}</h2>{activeServer?<><p className="muted">Share this invite code with people you want to join.</p><div className="invite-code"><code>{activeServer.invite_code||'Invite unavailable'}</code><button className="secondary" onClick={copyInvite}>{copied?<Check size={16}/>:<Copy size={16}/>} {copied?'Copied':'Copy'}</button></div><p className="tiny muted">Anyone with this code may be able to join. Only share it with people you trust.</p></>:<p className="muted">Choose a server first.</p>}</>}
        {modal==='profile'&&<><div className="modal-icon"><Palette/></div><h2>Your profile</h2><p className="muted">Make your corner of TvCord feel like yours.</p><form onSubmit={saveProfile} className="stack">
          <label>Display name<input value={settingsName} onChange={e=>setSettingsName(e.target.value)} placeholder={profile?.username||'Display name'} maxLength="32"/></label>
          <label>Status<input value={statusText} onChange={e=>setStatusText(e.target.value)} placeholder="What are you up to?" maxLength="80"/></label>
          <label>Accent color<div className="color-control"><input type="color" value={accent} onChange={e=>setAccent(e.target.value)}/><span>{accent.toUpperCase()}</span><button type="button" className="text-button" onClick={()=>setAccent('#e34b64')}>Reset</button></div></label>
          <div className="avatar-upload"><div className="avatar profile-preview">{profile?.avatar_url?<img src={profile.avatar_url} alt=""/>:initials(profile?.username)}</div><label className="secondary upload-label"><Camera size={16}/> Change avatar<input type="file" hidden accept="image/png,image/jpeg,image/webp,image/gif" onChange={e=>{uploadAvatar(e.target.files?.[0]);e.target.value=''}}/></label></div>
          <button className="primary full">Save profile</button>
        </form><p className="tiny muted">GIF avatars are supported when the chosen browser and storage settings allow them. Animated banners and profile themes are planned for a later update.</p></>}
      </div>
    </div>}
    {notice&&<div className="toast">{notice}</div>}
  </div>;
}

function SetupScreen() {
  return <div className="setup-page"><div className="brand-mark large">T</div><p className="eyebrow">ONE QUICK SETUP</p><h1>Connect TvCord to Supabase</h1><p className="muted">The site code is ready, but the public Supabase settings still need to be filled in before accounts and chat can work.</p><ol><li>Create a free project at <a href="https://supabase.com" target="_blank" rel="noreferrer">supabase.com</a>.</li><li>Run the SQL in <code>supabase/schema.sql</code> in the project's SQL Editor.</li><li>In <code>public/config.js</code>, replace the example URL and key with your project's Project URL and anon/public key.</li><li>In Supabase Authentication settings, add your GitHub Pages site URL to the allowed redirect URLs.</li></ol><p className="setup-warning">Never put a Supabase service-role key in frontend code.</p><a className="primary link-button" href="https://github.com/Tvmanisback/TvCord">Open TvCord on GitHub</a></div>;
}

createRoot(document.getElementById('root')).render(<App />);
