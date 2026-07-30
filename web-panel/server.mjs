import { createServer } from "node:http";
import { readFile, writeFile, mkdir, stat } from "node:fs/promises";
import { createReadStream, existsSync, readFileSync } from "node:fs";
import { extname, join, normalize } from "node:path";
import { fileURLToPath } from "node:url";
import { randomBytes, pbkdf2Sync, timingSafeEqual } from "node:crypto";
import { execFile } from "node:child_process";

const rootDir = fileURLToPath(new URL(".", import.meta.url));
const publicDir = join(rootDir, "public");

loadDotEnv(join(rootDir, ".env"));

const env = process.env;
const config = {
  host: env.WEB_PANEL_HOST || "0.0.0.0",
  port: Number(env.WEB_PANEL_PORT || 8080),
  publicUrl: env.WEB_PANEL_PUBLIC_URL || "",
  adminUser: env.WEB_ADMIN_USER || "admin",
  adminPassword: env.WEB_ADMIN_PASSWORD || "",
  sessionSecret: env.SESSION_SECRET || randomBytes(32).toString("hex"),
  allowRegistration: (env.ALLOW_REGISTRATION || "true").toLowerCase() !== "false",
  palRestUrl: (env.PALWORLD_REST_URL || "http://127.0.0.1:8212").replace(/\/+$/, ""),
  palRestUser: env.PALWORLD_REST_USER || "admin",
  palAdminPassword: env.PALWORLD_ADMIN_PASSWORD || env.ADMIN_PASSWORD || "",
  publicGameHost: env.PUBLIC_GAME_HOST || env.PUBLIC_GAME_IP || "",
  publicGamePort: env.PUBLIC_GAME_PORT || "8211",
  discordGuildId: env.DISCORD_GUILD_ID || "",
  discordInviteUrl: env.DISCORD_INVITE_URL || "",
  steamAuthEnabled: (env.STEAM_AUTH_ENABLED || "true").toLowerCase() !== "false",
  microsoftClientId: env.MICROSOFT_CLIENT_ID || "",
  microsoftClientSecret: env.MICROSOFT_CLIENT_SECRET || "",
  microsoftTenant: env.MICROSOFT_TENANT || "consumers",
  controlPath: env.PALWORLD_CONTROL || "/opt/palworld/web-panel/bin/palctl",
  dataDir: env.PANEL_DATA_DIR || join(rootDir, "data")
};

const sessions = new Map();
const oauthStates = new Map();
const statePath = join(config.dataDir, "panel.json");
let state = await loadState();
await saveState();

const server = createServer(async (req, res) => {
  try {
    if (req.url.startsWith("/api/")) {
      await routeApi(req, res);
      return;
    }
    await serveStatic(req, res);
  } catch (error) {
    json(res, error.status || 500, { ok: false, error: error.message || "Server error" });
  }
});

server.listen(config.port, config.host, () => {
  console.log(`Neo Palworld web panel listening on http://${config.host}:${config.port}`);
});

function loadDotEnv(path) {
  try {
    if (!existsSync(path)) return;
    const text = readFileSync(path, "utf8");
    for (const line of text.split(/\r?\n/)) {
      const trimmed = line.trim();
      if (!trimmed || trimmed.startsWith("#") || !trimmed.includes("=")) continue;
      const i = trimmed.indexOf("=");
      const key = trimmed.slice(0, i).trim();
      let value = trimmed.slice(i + 1).trim();
      value = value.replace(/^['"]|['"]$/g, "");
      if (!(key in process.env)) process.env[key] = value;
    }
  } catch {
    // .env is optional.
  }
}

async function loadState() {
  await mkdir(config.dataDir, { recursive: true });
  let loaded = null;
  try {
    loaded = JSON.parse(await readFile(statePath, "utf8"));
  } catch {
    loaded = {};
  }
  const next = {
    users: Array.isArray(loaded.users) ? loaded.users : [],
    shop: Array.isArray(loaded.shop) ? loaded.shop : defaultShop(),
    orders: Array.isArray(loaded.orders) ? loaded.orders : [],
    announcements: Array.isArray(loaded.announcements) ? loaded.announcements : [],
    audit: Array.isArray(loaded.audit) ? loaded.audit : []
  };
  if (config.adminPassword) {
    syncConfiguredAdmin(next);
  }
  return next;
}

async function saveState() {
  await mkdir(config.dataDir, { recursive: true });
  await writeFile(statePath, JSON.stringify(state, null, 2), "utf8");
}

function defaultShop() {
  return [
    {
      id: "starter-builder",
      name: "Builder Starter Pack",
      category: "Convenience",
      price: 0,
      currency: "Request",
      status: "active",
      description: "Admin-reviewed starter support for new base builders. Delivery is manual until a safe grant hook is added."
    },
    {
      id: "event-title",
      name: "Event Title Reservation",
      category: "Community",
      price: 0,
      currency: "Request",
      status: "active",
      description: "Reserve a public title/name for server events, Discord shoutouts, or scoreboard-style posts."
    },
    {
      id: "cosmetic-future",
      name: "Future Cosmetic Slot",
      category: "Future",
      price: 0,
      currency: "Coming soon",
      status: "draft",
      description: "Prepared catalog slot for cosmetics or mod-supported rewards if Palworld/server tooling later supports safe delivery."
    }
  ];
}

function makeUser(username, password, role = "player", displayName = "") {
  const salt = randomBytes(16).toString("hex");
  return {
    id: randomId(),
    username: cleanUsername(username),
    displayName: displayName || username,
    role,
    salt,
    passwordHash: hashPassword(password, salt),
    platform: "",
    gameUserId: "",
    discordName: "",
    externalAccounts: [],
    createdAt: new Date().toISOString()
  };
}

function syncConfiguredAdmin(next) {
  const username = cleanUsername(config.adminUser);
  let admin = next.users.find((u) => u.username === username);
  if (!admin) {
    next.users.push(makeUser(username, config.adminPassword, "admin", "Owner"));
    return;
  }
  admin.role = "admin";
  admin.displayName = admin.displayName || "Owner";
  setUserPassword(admin, config.adminPassword);
}

function setUserPassword(user, password) {
  user.salt = randomBytes(16).toString("hex");
  user.passwordHash = hashPassword(password, user.salt);
}

function hashPassword(password, salt) {
  return pbkdf2Sync(password, salt, 150000, 32, "sha256").toString("hex");
}

function verifyPassword(user, password) {
  if (!user.passwordHash || !user.salt) return false;
  const a = Buffer.from(user.passwordHash, "hex");
  const b = Buffer.from(hashPassword(password, user.salt), "hex");
  return a.length === b.length && timingSafeEqual(a, b);
}

function randomId() {
  return randomBytes(12).toString("hex");
}

function cleanUsername(value) {
  return String(value || "").trim().toLowerCase().replace(/[^a-z0-9_.-]/g, "").slice(0, 32);
}

function authProviders(req) {
  const providers = [];
  if (config.steamAuthEnabled) {
    providers.push({
      id: "steam",
      name: "Steam",
      loginUrl: "/api/auth/steam",
      description: "Uses Valve Steam OpenID and returns your public 64-bit SteamID."
    });
  }
  if (config.microsoftClientId && config.microsoftClientSecret) {
    providers.push({
      id: "microsoft",
      name: "Xbox / Microsoft",
      loginUrl: "/api/auth/microsoft",
      description: "Uses Microsoft OpenID Connect. Xbox gamertag lookup can be added later if you receive Xbox API access."
    });
  }
  return providers.map((provider) => ({
    ...provider,
    callbackUrl: `${publicBaseUrl(req)}/api/auth/${provider.id}/callback`
  }));
}

function publicBaseUrl(req) {
  if (config.publicUrl) return config.publicUrl.replace(/\/+$/, "");
  const proto = req.headers["x-forwarded-proto"] || (config.host === "127.0.0.1" ? "http" : "http");
  const host = req.headers["x-forwarded-host"] || req.headers.host || `127.0.0.1:${config.port}`;
  return `${String(proto).split(",")[0]}://${String(host).split(",")[0]}`.replace(/\/+$/, "");
}

function redirect(res, target) {
  res.writeHead(302, { Location: target, "Cache-Control": "no-store" });
  res.end();
}

function oauthState(provider, user) {
  const token = randomBytes(24).toString("hex");
  oauthStates.set(token, {
    provider,
    userId: user?.id || "",
    expiresAt: Date.now() + 1000 * 60 * 10
  });
  return token;
}

function consumeOauthState(token, provider) {
  const stateRecord = oauthStates.get(token);
  oauthStates.delete(token);
  if (!stateRecord || stateRecord.provider !== provider || stateRecord.expiresAt < Date.now()) {
    throw httpError(400, "Sign-in session expired. Try again.");
  }
  return stateRecord;
}

function returnToAccount(res, status = "ok") {
  redirect(res, `/?auth=${encodeURIComponent(status)}#account`);
}

async function startSteamLogin(req, res, user) {
  if (!config.steamAuthEnabled) throw httpError(404, "Steam login is disabled.");
  const base = publicBaseUrl(req);
  const stateToken = oauthState("steam", user);
  const returnTo = `${base}/api/auth/steam/callback?state=${stateToken}`;
  const params = new URLSearchParams({
    "openid.ns": "http://specs.openid.net/auth/2.0",
    "openid.mode": "checkid_setup",
    "openid.return_to": returnTo,
    "openid.realm": base,
    "openid.identity": "http://specs.openid.net/auth/2.0/identifier_select",
    "openid.claimed_id": "http://specs.openid.net/auth/2.0/identifier_select"
  });
  redirect(res, `https://steamcommunity.com/openid/login?${params}`);
}

async function finishSteamLogin(req, res, url) {
  const stateRecord = consumeOauthState(url.searchParams.get("state"), "steam");
  const verifyParams = new URLSearchParams();
  for (const [key, value] of url.searchParams) {
    if (key.startsWith("openid.")) verifyParams.set(key, value);
  }
  verifyParams.set("openid.mode", "check_authentication");
  const response = await fetch("https://steamcommunity.com/openid/login", {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: verifyParams,
    signal: AbortSignal.timeout(8000)
  });
  const text = await response.text();
  if (!response.ok || !/\bis_valid\s*:\s*true\b/.test(text)) {
    throw httpError(401, "Steam could not verify this login.");
  }
  const claimed = url.searchParams.get("openid.claimed_id") || "";
  const steamId = claimed.match(/\/openid\/id\/(\d+)$/)?.[1];
  if (!steamId) throw httpError(401, "Steam did not return a SteamID.");
  const user = await linkOrCreateExternalUser(stateRecord, "steam", steamId, {
    displayName: `Steam ${steamId.slice(-6)}`,
    platform: "Steam",
    gameUserId: steamId
  });
  setSession(res, user);
  audit("steam-login", `${user.username} ${steamId}`);
  returnToAccount(res);
}

async function startMicrosoftLogin(req, res, user) {
  if (!config.microsoftClientId || !config.microsoftClientSecret) {
    throw httpError(404, "Microsoft login is not configured.");
  }
  const base = publicBaseUrl(req);
  const stateToken = oauthState("microsoft", user);
  const redirectUri = `${base}/api/auth/microsoft/callback`;
  const params = new URLSearchParams({
    client_id: config.microsoftClientId,
    response_type: "code",
    redirect_uri: redirectUri,
    response_mode: "query",
    scope: "openid profile email",
    state: stateToken
  });
  redirect(res, `https://login.microsoftonline.com/${encodeURIComponent(config.microsoftTenant)}/oauth2/v2.0/authorize?${params}`);
}

async function finishMicrosoftLogin(req, res, url) {
  const stateRecord = consumeOauthState(url.searchParams.get("state"), "microsoft");
  const code = url.searchParams.get("code");
  if (!code) throw httpError(400, url.searchParams.get("error_description") || "Microsoft login did not return a code.");
  const base = publicBaseUrl(req);
  const redirectUri = `${base}/api/auth/microsoft/callback`;
  const tokenResponse = await fetch(`https://login.microsoftonline.com/${encodeURIComponent(config.microsoftTenant)}/oauth2/v2.0/token`, {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      client_id: config.microsoftClientId,
      client_secret: config.microsoftClientSecret,
      grant_type: "authorization_code",
      code,
      redirect_uri: redirectUri,
      scope: "openid profile email"
    }),
    signal: AbortSignal.timeout(8000)
  });
  const token = await tokenResponse.json();
  if (!tokenResponse.ok || !token.access_token) {
    throw httpError(401, token.error_description || "Microsoft token exchange failed.");
  }
  const infoResponse = await fetch("https://graph.microsoft.com/oidc/userinfo", {
    headers: { Authorization: `Bearer ${token.access_token}` },
    signal: AbortSignal.timeout(8000)
  });
  const info = await infoResponse.json();
  if (!infoResponse.ok || !info.sub) throw httpError(401, "Microsoft user profile lookup failed.");
  const user = await linkOrCreateExternalUser(stateRecord, "microsoft", info.sub, {
    displayName: info.name || info.preferred_username || "Microsoft Player",
    platform: "Xbox",
    gameUserId: info.sub,
    discordName: ""
  });
  setSession(res, user);
  audit("microsoft-login", `${user.username} ${info.sub}`);
  returnToAccount(res);
}

async function linkOrCreateExternalUser(stateRecord, provider, providerId, profile) {
  const existing = state.users.find((u) =>
    (u.authProvider === provider && u.providerId === providerId) ||
    (u.externalAccounts || []).some((account) => account.provider === provider && account.providerId === providerId)
  );
  if (stateRecord.userId) {
    const current = state.users.find((u) => u.id === stateRecord.userId);
    if (current && existing && existing.id !== current.id) return existing;
    if (current) {
      attachExternal(current, provider, providerId, profile);
      await saveState();
      return current;
    }
  }
  if (existing) return existing;
  const usernameBase = cleanUsername(`${provider}_${providerId.slice(-12)}`) || `${provider}_${randomId().slice(0, 8)}`;
  const user = {
    id: randomId(),
    username: uniqueUsername(usernameBase),
    displayName: profile.displayName || usernameBase,
    role: "player",
    salt: "",
    passwordHash: "",
    platform: profile.platform || "",
    gameUserId: profile.gameUserId || "",
    discordName: profile.discordName || "",
    authProvider: provider,
    providerId,
    externalAccounts: [],
    createdAt: new Date().toISOString()
  };
  attachExternal(user, provider, providerId, profile);
  state.users.push(user);
  await saveState();
  return user;
}

function attachExternal(user, provider, providerId, profile) {
  user.externalAccounts = Array.isArray(user.externalAccounts) ? user.externalAccounts : [];
  const existing = user.externalAccounts.find((account) => account.provider === provider && account.providerId === providerId);
  const account = existing || { provider, providerId, linkedAt: new Date().toISOString() };
  account.displayName = profile.displayName || account.displayName || providerId;
  account.updatedAt = new Date().toISOString();
  if (!existing) user.externalAccounts.push(account);
  user.authProvider = user.authProvider || provider;
  user.providerId = user.providerId || providerId;
  user.displayName = user.displayName || profile.displayName || user.username;
  user.platform = user.platform || profile.platform || "";
  user.gameUserId = user.gameUserId || profile.gameUserId || "";
  user.discordName = user.discordName || profile.discordName || "";
}

function uniqueUsername(base) {
  let username = base;
  let i = 2;
  while (state.users.some((u) => u.username === username)) {
    username = `${base}_${i}`;
    i += 1;
  }
  return username;
}

async function routeApi(req, res) {
  const url = new URL(req.url, publicBaseUrl(req));
  const session = getSession(req);
  const user = session ? state.users.find((u) => u.id === session.userId) : null;

  if (req.method === "GET" && url.pathname === "/api/bootstrap") {
    const [info, metrics, players, discord] = await Promise.all([
      rest("GET", "info").catch(toOffline),
      rest("GET", "metrics").catch(toOffline),
      rest("GET", "players").catch(() => ({ players: [] })),
      discordWidget().catch((error) => ({
        enabled: false,
        inviteUrl: config.discordInviteUrl,
        error: error.message
      }))
    ]);
    json(res, 200, {
      ok: true,
      server: {
        publicGameHost: config.publicGameHost,
        publicGameIp: config.publicGameHost,
        publicGamePort: config.publicGamePort,
        name: info.servername || info.serverName || "Neo Palworld",
        description: info.description || "",
        online: !info.offline,
        info,
        metrics
      },
      players: sanitizePlayers(players.players || []),
      discord,
      shop: state.shop.filter((item) => item.status !== "hidden"),
      me: publicUser(user),
      authProviders: authProviders(req),
      registrationOpen: config.allowRegistration
    });
    return;
  }

  if (req.method === "GET" && url.pathname === "/api/auth/steam") {
    return startSteamLogin(req, res, user);
  }

  if (req.method === "GET" && url.pathname === "/api/auth/steam/callback") {
    return finishSteamLogin(req, res, url);
  }

  if (req.method === "GET" && url.pathname === "/api/auth/microsoft") {
    return startMicrosoftLogin(req, res, user);
  }

  if (req.method === "GET" && url.pathname === "/api/auth/microsoft/callback") {
    return finishMicrosoftLogin(req, res, url);
  }

  if (req.method === "POST" && url.pathname === "/api/auth/register") {
    if (!config.allowRegistration) return json(res, 403, { ok: false, error: "Registration is closed." });
    const body = await bodyJson(req);
    const username = cleanUsername(body.username);
    if (username.length < 3) return json(res, 400, { ok: false, error: "Username must be at least 3 characters." });
    if (!body.password || String(body.password).length < 8) return json(res, 400, { ok: false, error: "Password must be at least 8 characters." });
    if (state.users.some((u) => u.username === username)) return json(res, 409, { ok: false, error: "Username already exists." });
    const newUser = makeUser(username, String(body.password), "player", body.displayName || username);
    state.users.push(newUser);
    await saveState();
    setSession(res, newUser);
    audit("register", newUser.username);
    return json(res, 201, { ok: true, me: publicUser(newUser) });
  }

  if (req.method === "POST" && url.pathname === "/api/auth/login") {
    const body = await bodyJson(req);
    const username = cleanUsername(body.username);
    const found = state.users.find((u) => u.username === username);
    if (!found || !verifyPassword(found, String(body.password || ""))) {
      return json(res, 401, { ok: false, error: "Wrong username or password." });
    }
    setSession(res, found);
    audit("login", found.username);
    return json(res, 200, { ok: true, me: publicUser(found) });
  }

  if (req.method === "POST" && url.pathname === "/api/auth/admin-login") {
    const body = await bodyJson(req);
    const username = cleanUsername(body.username);
    const found = state.users.find((u) => u.username === username);
    if (!found || !verifyPassword(found, String(body.password || "")) || found.role !== "admin") {
      return json(res, 401, { ok: false, error: "Wrong admin username or password." });
    }
    setSession(res, found);
    audit("admin-login", found.username);
    return json(res, 200, { ok: true, me: publicUser(found) });
  }

  if (req.method === "POST" && url.pathname === "/api/auth/logout") {
    clearSession(req, res);
    return json(res, 200, { ok: true });
  }

  if (req.method === "GET" && url.pathname === "/api/me") {
    requireUser(user);
    return json(res, 200, { ok: true, me: publicUser(user), orders: state.orders.filter((o) => o.userId === user.id) });
  }

  if (req.method === "PATCH" && url.pathname === "/api/me/link") {
    requireUser(user);
    const body = await bodyJson(req);
    user.platform = String(body.platform || "").slice(0, 24);
    user.gameUserId = String(body.gameUserId || "").slice(0, 80);
    user.discordName = String(body.discordName || "").slice(0, 80);
    await saveState();
    audit("link-account", user.username);
    return json(res, 200, { ok: true, me: publicUser(user) });
  }

  if (req.method === "POST" && url.pathname === "/api/shop/order") {
    requireUser(user);
    const body = await bodyJson(req);
    const item = state.shop.find((x) => x.id === body.itemId && x.status !== "hidden");
    if (!item) return json(res, 404, { ok: false, error: "Shop item not found." });
    const order = {
      id: randomId(),
      itemId: item.id,
      itemName: item.name,
      userId: user.id,
      username: user.username,
      status: "requested",
      note: String(body.note || "").slice(0, 500),
      createdAt: new Date().toISOString()
    };
    state.orders.unshift(order);
    await saveState();
    audit("shop-order", `${user.username} -> ${item.name}`);
    return json(res, 201, { ok: true, order });
  }

  if (url.pathname.startsWith("/api/admin/")) {
    requireAdmin(user);
    await routeAdmin(req, res, url, user);
    return;
  }

  json(res, 404, { ok: false, error: "Not found" });
}

async function routeAdmin(req, res, url, user) {
  if (req.method === "GET" && url.pathname === "/api/admin/state") {
    const [info, metrics, players, settings, service] = await Promise.all([
      rest("GET", "info").catch(toOffline),
      rest("GET", "metrics").catch(toOffline),
      rest("GET", "players").catch(() => ({ players: [] })),
      rest("GET", "settings").catch(() => ({})),
      control("status").catch((error) => ({ ok: false, output: error.message }))
    ]);
    return json(res, 200, {
      ok: true,
      info,
      metrics,
      players: players.players || [],
      settings,
      service,
      users: state.users.map(publicUser),
      shop: state.shop,
      orders: state.orders,
      announcements: state.announcements.slice(0, 100),
      audit: state.audit.slice(0, 80)
    });
  }

  if (req.method === "POST" && url.pathname === "/api/admin/control") {
    const body = await bodyJson(req);
    const allowed = new Set(["start", "stop", "restart", "update", "backup", "save", "doctor", "settings-diagnostics", "worldoption-status", "worldoption-disable", "global-palbox-enable", "fast-travel-enable"]);
    if (!allowed.has(body.action)) return json(res, 400, { ok: false, error: "Unknown control action." });
    const result = body.action === "save" ? await rest("POST", "save") : await control(body.action);
    audit(`control:${body.action}`, user.username);
    return json(res, 200, { ok: true, result });
  }

  if (req.method === "POST" && url.pathname === "/api/admin/restart-countdown") {
    const body = await bodyJson(req);
    const wait = Math.max(10, Math.min(600, Number(body.waittime || 60)));
    const message = String(body.message || `Server will restart in ${wait} seconds.`).trim().slice(0, 300);
    const result = await control("restart", ["--shutdown-wait", String(wait), "--message", message]);
    state.announcements.unshift({
      id: randomId(),
      type: "restart-countdown",
      message,
      waittime: wait,
      by: user.username,
      createdAt: new Date().toISOString()
    });
    await saveState();
    audit("restart-countdown", `${wait}s ${message}`);
    return json(res, 200, { ok: true, result });
  }

  if (req.method === "POST" && url.pathname === "/api/admin/announce") {
    const body = await bodyJson(req);
    const message = String(body.message || "").trim().slice(0, 300);
    if (!message) return json(res, 400, { ok: false, error: "Announcement is empty." });
    const result = await rest("POST", "announce", { message });
    state.announcements.unshift({ id: randomId(), type: "broadcast", message, by: user.username, createdAt: new Date().toISOString() });
    await saveState();
    audit("announce", message);
    return json(res, 200, { ok: true, result });
  }

  if (req.method === "POST" && url.pathname === "/api/admin/announcement-delete") {
    const body = await bodyJson(req);
    const id = String(body.id || "");
    const before = state.announcements.length;
    state.announcements = state.announcements.filter((item) => item.id !== id);
    if (state.announcements.length === before) return json(res, 404, { ok: false, error: "Announcement was not found." });
    await saveState();
    audit("announcement-delete", id);
    return json(res, 200, { ok: true });
  }

  if (req.method === "POST" && url.pathname === "/api/admin/player-action") {
    const body = await bodyJson(req);
    const action = body.action === "ban" ? "ban" : "kick";
    const userid = String(body.userid || "").trim();
    if (!userid) return json(res, 400, { ok: false, error: "Player userId is required." });
    const result = await rest("POST", action, { userid, message: String(body.message || "") });
    audit(action, userid);
    return json(res, 200, { ok: true, result });
  }

  if (req.method === "POST" && url.pathname === "/api/admin/settings") {
    const body = await bodyJson(req);
    const pairs = Object.entries(body.settings || {})
      .filter(([key]) => /^[A-Za-z0-9_]+$/.test(key))
      .map(([key, value]) => `${key}=${String(value).replace(/\r?\n/g, " ").slice(0, 300)}`);
    if (!pairs.length) return json(res, 400, { ok: false, error: "No valid settings were provided." });
    const result = await control("set", pairs);
    audit("settings", pairs.join(", "));
    return json(res, 200, { ok: true, applied: true, result });
  }

  if (req.method === "POST" && url.pathname === "/api/admin/preset") {
    const body = await bodyJson(req);
    const preset = String(body.preset || "").trim();
    if (!/^[a-z0-9-]+$/.test(preset)) return json(res, 400, { ok: false, error: "Invalid preset name." });
    const result = await control("preset", [preset]);
    audit("preset", preset);
    return json(res, 200, { ok: true, applied: true, result });
  }

  if (req.method === "POST" && url.pathname === "/api/admin/shop") {
    const body = await bodyJson(req);
    const item = {
      id: body.id ? String(body.id).replace(/[^a-z0-9-]/gi, "").slice(0, 40) : randomId(),
      name: String(body.name || "New item").slice(0, 80),
      category: String(body.category || "General").slice(0, 40),
      price: Number(body.price || 0),
      currency: String(body.currency || "Request").slice(0, 24),
      status: String(body.status || "active").slice(0, 20),
      description: String(body.description || "").slice(0, 500)
    };
    const idx = state.shop.findIndex((x) => x.id === item.id);
    if (idx >= 0) state.shop[idx] = item;
    else state.shop.unshift(item);
    await saveState();
    audit("shop-save", item.name);
    return json(res, 200, { ok: true, item });
  }

  if (req.method === "POST" && url.pathname === "/api/admin/order") {
    const body = await bodyJson(req);
    const order = state.orders.find((x) => x.id === body.orderId);
    if (!order) return json(res, 404, { ok: false, error: "Order not found." });
    order.status = String(body.status || order.status).slice(0, 30);
    order.adminNote = String(body.adminNote || order.adminNote || "").slice(0, 500);
    order.updatedAt = new Date().toISOString();
    await saveState();
    audit("order-update", `${order.id}: ${order.status}`);
    return json(res, 200, { ok: true, order });
  }

  json(res, 404, { ok: false, error: "Not found" });
}

async function rest(method, endpoint, body) {
  if (!config.palAdminPassword) throw new Error("PALWORLD_ADMIN_PASSWORD is missing in web panel .env.");
  const auth = Buffer.from(`${config.palRestUser}:${config.palAdminPassword}`).toString("base64");
  const paths = [`/v1/api/${endpoint.replace(/^\/+/, "")}`, `/${endpoint.replace(/^\/+/, "")}`];
  let lastError;
  for (const path of paths) {
    try {
      const response = await fetch(`${config.palRestUrl}${path}`, {
        method,
        headers: {
          Authorization: `Basic ${auth}`,
          "Content-Type": "application/json"
        },
        body: body ? JSON.stringify(body) : undefined,
        signal: AbortSignal.timeout(4500)
      });
      if (!response.ok) throw new Error(`Palworld REST ${endpoint} returned ${response.status}`);
      const text = await response.text();
      return text ? JSON.parse(text) : { ok: true };
    } catch (error) {
      lastError = error;
    }
  }
  throw lastError;
}

function toOffline(error) {
  return { offline: true, error: error.message };
}

async function discordWidget() {
  if (!config.discordGuildId) {
    return {
      inviteUrl: config.discordInviteUrl,
      enabled: false,
      error: "Discord guild ID is not set."
    };
  }
  const response = await fetch(`https://discord.com/api/v10/guilds/${config.discordGuildId}/widget.json`, {
    headers: { Accept: "application/json" },
    signal: AbortSignal.timeout(4500)
  });
  if (!response.ok) {
    if (response.status === 403 || response.status === 404) {
      throw new Error("Discord widget is not public. Enable Server Settings -> Widget -> Enable Server Widget, then choose an invite channel.");
    }
    throw new Error(`Discord widget returned HTTP ${response.status}.`);
  }
  const widget = await response.json();
  return {
    enabled: true,
    name: widget.name,
    instantInvite: widget.instant_invite || config.discordInviteUrl,
    presenceCount: widget.presence_count || 0,
    channels: widget.channels || [],
    members: (widget.members || []).slice(0, 40).map((m) => ({
      username: m.username,
      status: m.status,
      avatarUrl: m.avatar_url,
      game: m.game?.name || ""
    }))
  };
}

function sanitizePlayers(players) {
  return players.map((p) => ({
    name: p.name || p.accountName || "Player",
    accountName: p.accountName || "",
    userId: maskId(p.userId || ""),
    playerId: maskId(p.playerId || ""),
    ping: p.ping,
    level: p.level,
    building_count: p.building_count
  }));
}

function maskId(value) {
  const s = String(value || "");
  if (s.length <= 8) return s;
  return `${s.slice(0, 5)}...${s.slice(-4)}`;
}

function control(command, args = []) {
  return new Promise((resolve, reject) => {
    const useSudo = typeof process.getuid === "function" && process.getuid() !== 0;
    const bin = useSudo ? "sudo" : config.controlPath;
    const fullArgs = useSudo ? ["-n", config.controlPath, command, ...args] : [command, ...args];
    execFile(bin, fullArgs, { timeout: 240000, maxBuffer: 1024 * 1024 }, (error, stdout, stderr) => {
      const output = `${stdout || ""}${stderr || ""}`.trim();
      if (error) {
        error.message = output || error.message;
        reject(error);
        return;
      }
      resolve({ ok: true, output });
    });
  });
}

async function bodyJson(req) {
  let raw = "";
  for await (const chunk of req) raw += chunk;
  if (!raw) return {};
  try {
    return JSON.parse(raw);
  } catch {
    throw httpError(400, "Invalid JSON body.");
  }
}

function getSession(req) {
  const cookies = Object.fromEntries(String(req.headers.cookie || "").split(";").map((part) => {
    const [key, ...rest] = part.trim().split("=");
    return [key, decodeURIComponent(rest.join("=") || "")];
  }));
  const token = cookies.neo_palworld_session;
  if (!token) return null;
  const session = sessions.get(token);
  if (!session || session.expiresAt < Date.now()) {
    sessions.delete(token);
    return null;
  }
  session.expiresAt = Date.now() + 1000 * 60 * 60 * 12;
  return session;
}

function setSession(res, user) {
  const token = randomBytes(32).toString("hex");
  sessions.set(token, { userId: user.id, expiresAt: Date.now() + 1000 * 60 * 60 * 12 });
  res.setHeader("Set-Cookie", `neo_palworld_session=${encodeURIComponent(token)}; HttpOnly; SameSite=Lax; Path=/; Max-Age=43200`);
}

function clearSession(req, res) {
  const session = getSession(req);
  for (const [token, value] of sessions) {
    if (session && value.userId === session.userId) sessions.delete(token);
  }
  res.setHeader("Set-Cookie", "neo_palworld_session=; HttpOnly; SameSite=Lax; Path=/; Max-Age=0");
}

function requireUser(user) {
  if (!user) throw httpError(401, "Login required.");
}

function requireAdmin(user) {
  requireUser(user);
  if (user.role !== "admin") throw httpError(403, "Admin access required.");
}

function publicUser(user) {
  if (!user) return null;
  return {
    id: user.id,
    username: user.username,
    displayName: user.displayName,
    role: user.role,
    platform: user.platform,
    gameUserId: user.gameUserId ? maskId(user.gameUserId) : "",
    discordName: user.discordName,
    authProvider: user.authProvider || "",
    providers: (user.externalAccounts || []).map((account) => ({
      provider: account.provider,
      displayName: account.displayName,
      linkedAt: account.linkedAt
    })),
    createdAt: user.createdAt
  };
}

function audit(action, detail) {
  state.audit.unshift({ id: randomId(), action, detail, at: new Date().toISOString() });
  state.audit = state.audit.slice(0, 250);
  saveState().catch(() => {});
}

function httpError(status, message) {
  const error = new Error(message);
  error.status = status;
  return error;
}

function json(res, status, payload) {
  res.writeHead(status, { "Content-Type": "application/json; charset=utf-8", "Cache-Control": "no-store" });
  res.end(JSON.stringify(payload));
}

async function serveStatic(req, res) {
  const url = new URL(req.url, "http://localhost");
  const requested = (url.pathname === "/" || url.pathname === "/admin" || url.pathname === "/admin/")
    ? "/index.html"
    : decodeURIComponent(url.pathname);
  const safePath = normalize(requested).replace(/^(\.\.[/\\])+/, "");
  const filePath = join(publicDir, safePath);
  if (!filePath.startsWith(publicDir)) return notFound(res);
  try {
    const fileStat = await stat(filePath);
    if (!fileStat.isFile()) return notFound(res);
    const noStore = filePath.endsWith("index.html") || filePath.endsWith(".js") || filePath.endsWith(".css");
    res.writeHead(200, {
      "Content-Type": mime(filePath),
      "Cache-Control": noStore ? "no-store" : "public, max-age=3600"
    });
    createReadStream(filePath).pipe(res);
  } catch {
    notFound(res);
  }
}

function notFound(res) {
  res.writeHead(404, { "Content-Type": "text/plain; charset=utf-8" });
  res.end("Not found");
}

function mime(filePath) {
  return {
    ".html": "text/html; charset=utf-8",
    ".css": "text/css; charset=utf-8",
    ".js": "text/javascript; charset=utf-8",
    ".json": "application/json; charset=utf-8",
    ".png": "image/png",
    ".jpg": "image/jpeg",
    ".jpeg": "image/jpeg",
    ".webp": "image/webp",
    ".svg": "image/svg+xml"
  }[extname(filePath)] || "application/octet-stream";
}
