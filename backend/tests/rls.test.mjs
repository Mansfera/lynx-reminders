// Access rules and sync behaviour (docs/SPEC.md §3–§4).
// Local:  cd backend/tests && bun install && bun run test   (needs `bunx supabase@2 start`)
// Cloud:  SUPABASE_URL=… SUPABASE_ANON_KEY=… SUPABASE_SERVICE_ROLE_KEY=… bun run test
// Users are created already confirmed through the admin API and deleted at the end.
import { test, after } from 'node:test';
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { createClient } from '@supabase/supabase-js';

const URL = process.env.SUPABASE_URL ?? 'http://127.0.0.1:54321';
const LOCAL = /^http:\/\/(127\.0\.0\.1|localhost)[:/]/.test(URL);
const ANON = process.env.SUPABASE_ANON_KEY ??
  'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZS1kZW1vIiwicm9sZSI6ImFub24iLCJleHAiOjE5ODM4MTI5OTZ9.CRXP1A7WOeoJeXxjNni43kdQwgnWNReilDMblYTn_I0';
// The local stack's well-known service key; on the cloud pass your own via the environment.
const SERVICE = process.env.SUPABASE_SERVICE_ROLE_KEY ??
  'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZS1kZW1vIiwicm9sZSI6InNlcnZpY2Vfcm9sZSIsImV4cCI6MTk4MzgxMjk5Nn0.EGIM96RAZx35lJzdJsyH-qQwv8Hdp7fsn3W0YpN81IU';
const admin = createClient(URL, SERVICE, { auth: { persistSession: false, autoRefreshToken: false } }).auth.admin;
const run = Date.now().toString(36);
const mail = (n) => `${n}.${run}@lynx.test`;
const PASSWORD = 'correct-horse-battery';

const clients = [];
const createdUsers = [];
after(async () => {
  for (const c of clients) { await c.removeAllChannels(); c.realtime.disconnect(); }
  for (const id of createdUsers) await admin.deleteUser(id); // already-deleted ones just return an error
});

const anonClient = () => {
  const c = createClient(URL, ANON, { auth: { persistSession: false, autoRefreshToken: false } });
  clients.push(c);
  return c;
};

async function signIn(email) {
  const c = anonClient();
  const { data, error } = await c.auth.signInWithPassword({ email, password: PASSWORD });
  assert.ifError(error);
  return { c, id: data.user.id, email };
}

async function user(name) {
  const { data, error } = await admin.createUser({ email: mail(name), password: PASSWORD, email_confirm: true });
  assert.ifError(error);
  createdUsers.push(data.user.id);
  return signIn(mail(name));
}

const now = (offsetMs = 0) => new Date(Date.now() + offsetMs).toISOString();
const list = (fields = {}) => ({ id: randomUUID(), name: 'List', color: 'blue', icon: 'list', updated_at: now(), ...fields });
const rem = (list_id, fields = {}) => ({ id: randomUUID(), list_id, title: 'Task', time_zone: 'Europe/Bratislava', updated_at: now(), ...fields });

async function ok(p) {
  const { data, error } = await p;
  assert.ifError(error);
  return data;
}
async function denied(p) {
  const { data, error } = await p;
  assert.ok(error || (Array.isArray(data) && data.length === 0), `expected denial, got ${JSON.stringify(data)}`);
}
const ids = (rows) => rows.map((r) => r.id).sort();

const A = await user('ann');
const B = await user('bob');
const C = await user('cat');

test('owner creates a list and becomes its member', async () => {
  const l = list();
  const [row] = await ok(A.c.from('lists').upsert(l).select());
  assert.equal(row.owner_id, A.id);
  assert.ok(row.version > 0);
  const members = await ok(A.c.from('list_members').select('*').eq('list_id', l.id));
  assert.deepEqual(members.map((m) => [m.user_id, m.role]), [[A.id, 'owner']]);
});

test('others cannot see, write into, or claim a private list', async () => {
  const l = list();
  await ok(A.c.from('lists').upsert(l));
  const r = rem(l.id);
  await ok(A.c.from('reminders').upsert(r));
  assert.deepEqual(await ok(B.c.from('lists').select().eq('id', l.id)), []);
  assert.deepEqual(await ok(B.c.from('reminders').select().eq('id', r.id)), []);
  await denied(B.c.from('reminders').insert(rem(l.id)));
  // Upserting someone else's list id must not take it over.
  await denied(B.c.from('lists').upsert({ ...l, name: 'mine now', updated_at: now(1000) }).select());
  const [still] = await ok(A.c.from('lists').select().eq('id', l.id));
  assert.equal(still.name, 'List');
  assert.equal(still.owner_id, A.id);
});

test('sharing a list by email gives full access to its reminders and subtasks', async () => {
  const l = list();
  await ok(A.c.from('lists').upsert(l));
  const goal = rem(l.id, { title: 'Goal' });
  await ok(A.c.from('reminders').upsert(goal));
  const sub = rem(l.id, { parent_id: goal.id, title: 'Step 1' });
  await ok(A.c.from('reminders').upsert(sub));

  const res = await ok(A.c.rpc('share_list', { p_list: l.id, p_email: B.email.toUpperCase() }));
  assert.deepEqual(res, { status: 'added', user_id: B.id });
  assert.equal((await ok(A.c.rpc('share_list', { p_list: l.id, p_email: B.email }))).status, 'already');

  assert.deepEqual(ids(await ok(B.c.from('reminders').select().eq('list_id', l.id))), [goal.id, sub.id].sort());
  // B edits and completes a subtask, and adds a new reminder.
  await ok(B.c.from('reminders').upsert({ ...sub, completed_at: now(), completed_by: B.id, updated_at: now(5) }));
  await ok(B.c.from('reminders').insert(rem(l.id, { title: 'From Bob' })));
  // B can rename but cannot delete the list, cannot reshare it, cannot remove A.
  await ok(B.c.from('lists').upsert({ ...l, name: 'Renamed', updated_at: now(10) }));
  const del = await B.c.from('lists').upsert({ ...l, deleted_at: now(), updated_at: now(20) });
  assert.ok(del.error, 'member must not delete the list');
  await assert.rejects(async () => { const { error } = await B.c.rpc('share_list', { p_list: l.id, p_email: C.email }); if (error) throw error; });
  await assert.rejects(async () => { const { error } = await B.c.rpc('unshare_list', { p_list: l.id, p_user: A.id }); if (error) throw error; });
  // Profiles: A and B see each other, C is a stranger to both.
  assert.deepEqual(ids(await ok(B.c.from('profiles').select('id').in('id', [A.id, C.id]))), [A.id]);
  // Members with embedded profiles, as the clients fetch them.
  const members = await ok(B.c.from('list_members').select('*, profile:profiles(*)').eq('list_id', l.id));
  assert.equal(members.length, 2);
  assert.ok(members.every((m) => m.profile && m.profile.email));
});

test('unshare and leave take access away; manifest reflects it', async () => {
  const l = list();
  await ok(A.c.from('lists').upsert(l));
  const r = rem(l.id);
  await ok(A.c.from('reminders').upsert(r));
  await ok(A.c.rpc('share_list', { p_list: l.id, p_email: B.email }));
  let manifest = await ok(B.c.rpc('sync_manifest'));
  assert.ok(manifest.some((m) => m.t === 'lists' && m.id === l.id));
  assert.ok(manifest.some((m) => m.t === 'reminders' && m.id === r.id && m.v > 0));

  await ok(A.c.rpc('unshare_list', { p_list: l.id, p_user: B.id }));
  manifest = await ok(B.c.rpc('sync_manifest'));
  assert.ok(!manifest.some((m) => m.id === l.id || m.id === r.id));

  await ok(A.c.rpc('share_list', { p_list: l.id, p_email: B.email }));
  await ok(B.c.rpc('leave_list', { p_list: l.id }));
  assert.deepEqual(await ok(B.c.from('lists').select().eq('id', l.id)), []);
  await assert.rejects(async () => { const { error } = await A.c.rpc('leave_list', { p_list: l.id }); if (error) throw error; });
});

test('a single shared reminder: recipient sees it and its subtasks, nothing else in the list', async () => {
  const l = list({ name: 'Private' });
  await ok(A.c.from('lists').upsert(l));
  const goal = rem(l.id, { title: 'Plan the trip' });
  const other = rem(l.id, { title: 'Secret' });
  await ok(A.c.from('reminders').upsert([goal, other]));
  const sub = rem(l.id, { parent_id: goal.id, title: 'Book flights' });
  await ok(A.c.from('reminders').upsert(sub));

  assert.equal((await ok(A.c.rpc('share_reminder', { p_reminder: goal.id, p_email: C.email }))).status, 'added');
  await assert.rejects(async () => { const { error } = await A.c.rpc('share_reminder', { p_reminder: sub.id, p_email: C.email }); if (error) throw error; });

  assert.deepEqual(ids(await ok(C.c.from('reminders').select())), [goal.id, sub.id].sort());
  assert.deepEqual(await ok(C.c.from('lists').select().eq('id', l.id)), []);
  // C adds a subtask to the shared goal (list_id is forced to the goal's list) and edits the goal.
  const csub = rem(randomUUID(), { parent_id: goal.id, title: 'Pack' });
  const [inserted] = await ok(C.c.from('reminders').insert(csub).select());
  assert.equal(inserted.list_id, l.id);
  await ok(C.c.from('reminders').upsert({ ...goal, notes: 'Bring passports', updated_at: now(50) }));
  // C cannot add top-level reminders to A's list, nor move the goal into a list of their own.
  await denied(C.c.from('reminders').insert(rem(l.id)));
  const own = list();
  await ok(C.c.from('lists').upsert(own));
  const moved = await C.c.from('reminders').upsert({ ...goal, list_id: own.id, updated_at: now(60) });
  assert.ok(moved.error, 'recipient must not move the reminder out of the owner list');
  // C sees A (the sharer) but not B.
  assert.deepEqual(ids(await ok(C.c.from('profiles').select('id').in('id', [A.id, B.id]))), [A.id]);
  // Recipient can remove themself.
  await ok(C.c.rpc('unshare_reminder', { p_reminder: goal.id, p_user: C.id }));
  assert.deepEqual(await ok(C.c.from('reminders').select().eq('id', goal.id)), []);
});

test('subtasks are one level deep', async () => {
  const l = list();
  await ok(A.c.from('lists').upsert(l));
  const g = rem(l.id);
  await ok(A.c.from('reminders').upsert(g));
  const s = rem(l.id, { parent_id: g.id });
  await ok(A.c.from('reminders').upsert(s));
  const { error } = await A.c.from('reminders').insert(rem(l.id, { parent_id: s.id }));
  assert.ok(error, 'sub-subtask must fail');
});

test('last writer wins by updated_at; versions only grow', async () => {
  const l = list();
  await ok(A.c.from('lists').upsert(l));
  const t0 = now();
  const r = rem(l.id, { title: 'v1', updated_at: t0 });
  const [v1] = await ok(A.c.from('reminders').upsert(r).select());
  const [v2] = await ok(A.c.from('reminders').upsert({ ...r, title: 'v2', updated_at: now(1000) }).select());
  assert.ok(v2.version > v1.version);
  // A stale write (older updated_at) is ignored.
  await ok(A.c.from('reminders').upsert({ ...r, title: 'stale', updated_at: t0 }));
  const [cur] = await ok(A.c.from('reminders').select().eq('id', r.id));
  assert.equal(cur.title, 'v2');
  // Delta pull by version.
  const delta = await ok(A.c.from('reminders').select('id,version').gt('version', v1.version));
  assert.ok(delta.some((d) => d.id === r.id));
});

test('soft-deleting a list or a goal soft-deletes what is inside', async () => {
  const l = list();
  await ok(A.c.from('lists').upsert(l));
  const g = rem(l.id);
  const loose = rem(l.id);
  await ok(A.c.from('reminders').upsert([g, loose]));
  const s = rem(l.id, { parent_id: g.id });
  await ok(A.c.from('reminders').upsert(s));

  await ok(A.c.from('reminders').upsert({ ...g, deleted_at: now(), updated_at: now(100) }));
  let [sub] = await ok(A.c.from('reminders').select().eq('id', s.id));
  assert.ok(sub.deleted_at);

  await ok(A.c.from('lists').upsert({ ...l, deleted_at: now(), updated_at: now(200) }));
  const [lo] = await ok(A.c.from('reminders').select().eq('id', loose.id));
  assert.ok(lo.deleted_at);
});

test('moving a goal moves its subtasks', async () => {
  const l1 = list(), l2 = list();
  await ok(A.c.from('lists').upsert([l1, l2]));
  const g = rem(l1.id);
  await ok(A.c.from('reminders').upsert(g));
  const s = rem(l1.id, { parent_id: g.id });
  await ok(A.c.from('reminders').upsert(s));
  await ok(A.c.from('reminders').upsert({ ...g, list_id: l2.id, updated_at: now(100) }));
  const [moved] = await ok(A.c.from('reminders').select().eq('id', s.id));
  assert.equal(moved.list_id, l2.id);
});

test('inviting an email without an account converts on sign-up', async () => {
  const l = list({ name: 'Groceries' });
  await ok(A.c.from('lists').upsert(l));
  const solo = rem(list().id); // placeholder to keep ids unique
  void solo;
  const r = rem(l.id, { title: 'Milk' });
  await ok(A.c.from('reminders').upsert(r));
  const other = list();
  await ok(A.c.from('lists').upsert(other));
  const shared = rem(other.id, { title: 'Call the bank' });
  await ok(A.c.from('reminders').upsert(shared));

  const dEmail = mail('dan');
  assert.equal((await ok(A.c.rpc('share_list', { p_list: l.id, p_email: dEmail }))).status, 'invited');
  assert.equal((await ok(A.c.rpc('share_reminder', { p_reminder: shared.id, p_email: dEmail }))).status, 'invited');
  const pending = await ok(A.c.from('invites').select().eq('email', dEmail));
  assert.equal(pending.length, 2);
  // Another user can't see A's invites.
  assert.deepEqual(await ok(B.c.from('invites').select().eq('email', dEmail)), []);

  const D = await user('dan');
  assert.deepEqual(ids(await ok(D.c.from('lists').select().eq('id', l.id))), [l.id]);
  assert.deepEqual(ids(await ok(D.c.from('reminders').select())), [r.id, shared.id].sort());
  assert.deepEqual(await ok(A.c.from('invites').select().eq('email', dEmail)), []);
});

test('an unconfirmed sign-up with someone else\'s email gets nothing until confirmed', async () => {
  const l = list({ name: 'Family' });
  await ok(A.c.from('lists').upsert(l));
  const victim = mail('vic');
  assert.equal((await ok(A.c.rpc('share_list', { p_list: l.id, p_email: victim }))).status, 'invited');

  // Someone signs up with that address but never confirms it. Locally through the public sign-up
  // (Mailpit catches the email); a hosted project would try to mail the fake address, so there the
  // account is created unconfirmed through the admin API, which runs the same database triggers.
  const impostor = anonClient();
  let signed;
  if (LOCAL) {
    const res = await impostor.auth.signUp({ email: victim, password: PASSWORD });
    assert.ifError(res.error);
    assert.equal(res.data.session, null, 'sign-up must require confirmation');
    signed = res.data;
  } else {
    const res = await admin.createUser({ email: victim, password: PASSWORD, email_confirm: false });
    assert.ifError(res.error);
    signed = res.data;
  }
  createdUsers.push(signed.user.id);
  const early = await impostor.auth.signInWithPassword({ email: victim, password: PASSWORD });
  assert.ok(early.error && !early.data.session, 'an unconfirmed address must not sign in');
  // The invite is still pending, and sharing again still only invites.
  assert.equal((await ok(A.c.from('invites').select().eq('email', victim))).length, 1);
  assert.equal((await ok(A.c.rpc('share_list', { p_list: l.id, p_email: victim }))).status, 'invited');
  const members = await ok(A.c.from('list_members').select('user_id').eq('list_id', l.id));
  assert.ok(!members.some((m) => m.user_id === signed.user.id));

  // Once the owner of the address confirms it, the share arrives.
  assert.ifError((await admin.updateUserById(signed.user.id, { email_confirm: true })).error);
  const V = await signIn(victim);
  assert.deepEqual(ids(await ok(V.c.from('lists').select().eq('id', l.id))), [l.id]);
  assert.deepEqual(await ok(A.c.from('invites').select().eq('email', victim)), []);
});

test('cancel an invite', async () => {
  const l = list();
  await ok(A.c.from('lists').upsert(l));
  await ok(A.c.rpc('share_list', { p_list: l.id, p_email: mail('eve') }));
  const [inv] = await ok(A.c.from('invites').select().eq('list_id', l.id));
  await ok(A.c.rpc('cancel_invite', { p_invite: inv.id }));
  assert.deepEqual(await ok(A.c.from('invites').select().eq('list_id', l.id)), []);
});

test('anonymous callers see nothing and cannot call RPCs', async () => {
  const anon = anonClient();
  const { data, error } = await anon.from('reminders').select();
  assert.ok(error || data.length === 0);
  const rpc = await anon.rpc('sync_manifest');
  assert.ok(rpc.error);
});

test('hard deletes are not allowed', async () => {
  const l = list();
  await ok(A.c.from('lists').upsert(l));
  const { error } = await A.c.from('lists').delete().eq('id', l.id);
  assert.ok(error);
});

test('delete_account removes the user and what they own', async () => {
  const Z = await user('zed');
  const l = list();
  await ok(Z.c.from('lists').upsert(l));
  await ok(Z.c.rpc('share_list', { p_list: l.id, p_email: A.email }));
  assert.equal((await ok(A.c.from('lists').select().eq('id', l.id))).length, 1);
  await ok(Z.c.rpc('delete_account'));
  assert.deepEqual(await ok(A.c.from('lists').select().eq('id', l.id)), []);
  const relog = await anonClient().auth.signInWithPassword({ email: Z.email, password: PASSWORD });
  assert.ok(relog.error);
});

test('realtime delivers a change on a shared list to the other member', async () => {
  const l = list();
  await ok(A.c.from('lists').upsert(l));
  await ok(A.c.rpc('share_list', { p_list: l.id, p_email: B.email }));
  // supabase-js hands the session token to realtime itself; RLS decides what B receives.
  // Realtime can take a few seconds after a fresh `db reset`; keep writing until an event arrives.
  const payload = await new Promise((resolve, reject) => {
    let writer;
    const timer = setTimeout(() => { clearInterval(writer); reject(new Error('no realtime event in 30 s')); }, 30000);
    B.c.channel('sync-test')
      .on('postgres_changes', { event: '*', schema: 'public', table: 'reminders' }, (p) => {
        if (p.new?.list_id === l.id) { clearTimeout(timer); clearInterval(writer); resolve(p); }
      })
      .subscribe((status) => {
        if (status !== 'SUBSCRIBED') return;
        // Query builders are lazy: .then() is what sends the request.
        const write = () => A.c.from('reminders').insert(rem(l.id, { title: 'Realtime' })).then(({ error }) => { if (error) reject(error); });
        write();
        writer = setInterval(write, 3000);
      });
  });
  assert.equal(payload.new.title, 'Realtime');
});
