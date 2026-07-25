// Georama auth Edge Function — username + password signup/login with optional
// email verification. Username auth is backed by Supabase Auth using a per-user
// synthetic email, so passwords are hashed by Supabase and clients get real
// sessions + Row Level Security.
//
// Deploy:  supabase functions deploy auth --no-verify-jwt
// Secrets: SUPABASE_URL and SUPABASE_ANON_KEY are provided automatically.
//          Set SUPABASE_SERVICE_ROLE_KEY (Dashboard -> Edge Functions -> Secrets)
//          and, optionally, RESEND_API_KEY to actually send verification emails.
//
// POST body: { action: "signup" | "login" | "verify", ... }

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const ANON = Deno.env.get("SUPABASE_ANON_KEY")!;
const DOMAIN = "users.georama.app"; // synthetic email domain for username auth

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (b: unknown, status = 200) =>
  new Response(JSON.stringify(b), { status, headers: { ...cors, "content-type": "application/json" } });

const admin = createClient(SUPABASE_URL, SERVICE_ROLE, { auth: { autoRefreshToken: false, persistSession: false } });

const clean = (s: unknown) => (typeof s === "string" ? s.trim() : "");
const validUser = (s: string) => s.length >= 2 && s.length <= 24 && !/[@\s]/.test(s);
const validPass = (s: unknown) => typeof s === "string" && s.length >= 6 && s.length <= 200;

async function sha256Hex(s: string): Promise<string> {
  const buf = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(s));
  return [...new Uint8Array(buf)].map((x) => x.toString(16).padStart(2, "0")).join("");
}

async function passwordSession(email: string, password: string) {
  const c = createClient(SUPABASE_URL, ANON, { auth: { persistSession: false } });
  const { data, error } = await c.auth.signInWithPassword({ email, password });
  if (error || !data.session) return null;
  return { access_token: data.session.access_token, refresh_token: data.session.refresh_token };
}

async function sendCode(id: string, email: string) {
  const code = String(Math.floor(100000 + Math.random() * 900000));
  const codeHash = await sha256Hex(code);
  const expires = new Date(Date.now() + 15 * 60 * 1000).toISOString();
  await admin.from("email_codes").upsert({ id, code_hash: codeHash, expires_at: expires });
  const key = Deno.env.get("RESEND_API_KEY");
  if (key) {
    await fetch("https://api.resend.com/emails", {
      method: "POST",
      headers: { authorization: "Bearer " + key, "content-type": "application/json" },
      body: JSON.stringify({
        from: "Georama <onboarding@resend.dev>",
        to: [email],
        subject: "Georama verification code",
        text: "Your Georama verification code is: " + code + " (valid 15 minutes).",
      }),
    }).catch(() => {});
  }
}

async function signup(b: Record<string, unknown>) {
  const username = clean(b.username);
  const password = b.password as string;
  const email = clean(b.email).toLowerCase() || null;
  if (!validUser(username)) return json({ error: "invalid_username" }, 400);
  if (!validPass(password)) return json({ error: "invalid_password" }, 400);

  const { data: exist } = await admin.from("profiles").select("id").eq("username_lower", username.toLowerCase()).maybeSingle();
  if (exist) return json({ error: "username_taken" }, 409);

  const authEmail = crypto.randomUUID() + "@" + DOMAIN;
  const { data: created, error: cErr } = await admin.auth.admin.createUser({
    email: authEmail, password, email_confirm: true, user_metadata: { username, email },
  });
  if (cErr || !created.user) return json({ error: cErr?.message || "create_failed" }, 400);
  const id = created.user.id;

  const { error: pErr } = await admin.from("profiles").insert({
    id, username, username_lower: username.toLowerCase(), auth_email: authEmail, email, email_verified: false, stats: {},
  });
  if (pErr) { await admin.auth.admin.deleteUser(id); return json({ error: pErr.message }, 400); }

  if (email) await sendCode(id, email).catch(() => {});
  const session = await passwordSession(authEmail, password);
  if (!session) return json({ error: "login_failed" }, 500);
  return json({ ok: true, username, email, email_verified: false, session });
}

async function login(b: Record<string, unknown>) {
  const username = clean(b.username);
  const password = b.password as string;
  if (!username || !password) return json({ error: "missing" }, 400);
  const { data: prof } = await admin.from("profiles").select("auth_email").eq("username_lower", username.toLowerCase()).maybeSingle();
  if (!prof) return json({ error: "no_such_user" }, 404);
  const session = await passwordSession(prof.auth_email, password);
  if (!session) return json({ error: "bad_credentials" }, 401);
  return json({ ok: true, session });
}

async function verify(b: Record<string, unknown>) {
  const token = clean(b.access_token);
  const code = clean(b.code);
  if (!token) return json({ error: "no_token" }, 401);
  const c = createClient(SUPABASE_URL, ANON, { global: { headers: { Authorization: "Bearer " + token } }, auth: { persistSession: false } });
  const { data: u } = await c.auth.getUser();
  if (!u.user) return json({ error: "bad_token" }, 401);
  const id = u.user.id;
  const { data: row } = await admin.from("email_codes").select("code_hash,expires_at").eq("id", id).maybeSingle();
  if (!row) return json({ error: "no_code" }, 400);
  if (new Date(row.expires_at) < new Date()) return json({ error: "expired" }, 400);
  if ((await sha256Hex(code)) !== row.code_hash) return json({ error: "wrong_code" }, 400);
  await admin.from("profiles").update({ email_verified: true }).eq("id", id);
  await admin.from("email_codes").delete().eq("id", id);
  return json({ ok: true, email_verified: true });
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "POST only" }, 405);
  let body: Record<string, unknown>;
  try { body = await req.json(); } catch { return json({ error: "bad_json" }, 400); }
  try {
    switch (body.action) {
      case "signup": return await signup(body);
      case "login": return await login(body);
      case "verify": return await verify(body);
      default: return json({ error: "unknown_action" }, 400);
    }
  } catch (e) {
    return json({ error: String((e as Error)?.message || e) }, 500);
  }
});
