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

window.SingkaNet = {enabled, client, session, user, signUp, signIn, signOut};
})();
