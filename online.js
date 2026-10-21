/* ---------------- Online services (Supabase) ----------------
   Exposes window.SingkaNet. Everything here is optional: with no config, or if the
   Supabase script failed to load, SingkaNet.enabled is false and the game stays local. */
(function(){
const cfg = window.SINGKA_CONFIG || {};
const enabled = !!(window.supabase && cfg.supabaseUrl && cfg.supabaseKey);
const client = enabled ? window.supabase.createClient(cfg.supabaseUrl, cfg.supabaseKey) : null;

// Guests get an anonymous account only when they first go online, so casual visitors
// don't create users. Signing up later upgrades the same account and keeps its history.
async function session(){
  if(!client) throw new Error('Online play is not set up');
  const cur = await client.auth.getSession();
  if(cur.data.session) return cur.data.session;
  const res = await client.auth.signInAnonymously();
  if(res.error) throw res.error;
  return res.data.session;
}
async function user(){
  const res = client ? await client.auth.getUser() : {data:{user:null}};
  return res.data.user;
}
// Turns the current guest into a full account (email confirmation link is sent).
async function signUp(email, password){
  await session();
  const res = await client.auth.updateUser({email, password});
  if(res.error) throw res.error;
  return res.data.user;
}
async function signIn(email, password){
  if(!client) throw new Error('Online play is not set up');
  const res = await client.auth.signInWithPassword({email, password});
  if(res.error) throw res.error;
  return res.data.user;
}
async function signOut(){ if(client) await client.auth.signOut(); }

/* ----- Rooms ----- */
async function rpc(fn, args){
  await session();
  const res = await client.rpc(fn, args || {});
  if(res.error) throw new Error(res.error.message);
  return res.data;
}
// Build timers run on server time, so both devices count down to the same moment.
let clockOffset = 0;
async function syncClock(){
  const t0 = Date.now(), s = await rpc('server_now'), t1 = Date.now();
  clockOffset = Date.parse(s) - (t0 + t1) / 2;
}
const serverTime = ()=> Date.now() + clockOffset;
async function getRoom(id){
  const res = await client.from('rooms').select('*').eq('id', id).single();
  if(res.error) throw new Error(res.error.message);
  return res.data;
}
function watchRoom(id, onChange){
  const ch = client.channel('room-' + id)
    .on('postgres_changes', {event:'UPDATE', schema:'public', table:'rooms', filter:'id=eq.' + id}, p=>onChange(p.new))
    .subscribe();
  return ()=>client.removeChannel(ch);
}
async function names(ids){
  const res = await client.from('profiles').select('id,display_name').in('id', ids.filter(Boolean));
  const out = {};
  (res.data || []).forEach(r=>{ out[r.id] = r.display_name; });
  return out;
}
async function setName(name){
  const s = await session();
  const res = await client.from('profiles').update({display_name:name}).eq('id', s.user.id);
  if(res.error) throw new Error(res.error.message);
}

window.SingkaNet = {enabled, client, session, user, signUp, signIn, signOut,
  rpc, syncClock, serverTime, getRoom, watchRoom, names, setName};
})();
