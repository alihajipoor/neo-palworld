const $ = (selector, root = document) => root.querySelector(selector);
const $$ = (selector, root = document) => [...root.querySelectorAll(selector)];
const bind = (selector, eventName, handler) => {
  const element = $(selector);
  if (element) element.addEventListener(eventName, handler);
};

let bootstrap = null;
let me = null;
let adminState = null;
let slideIndex = 0;
let slideTimer = null;

const heroSlides = [
  {
    title: "Palworld 1.0 Launch",
    kicker: "OFFICIAL ART",
    src: "https://shared.fastly.steamstatic.com/store_item_assets/steam/apps/1623730/6912f19c43a95ff5fe514eedd35e68bf12335459/header_2x.jpg"
  },
  {
    title: "New Horizons Across Palpagos",
    kicker: "WORLD VIEW",
    src: "https://shared.fastly.steamstatic.com/store_item_assets/steam/apps/1623730/f9a00f2d47265bf1d3d50bfa59aaf45b66440441/library_hero_2x.jpg"
  },
  {
    title: "Official Launch Trailer",
    kicker: "TRAILER STILL",
    src: "https://shared.fastly.steamstatic.com/store_item_assets/steam/apps/1623730/257373728/7e13113e161160ac94f46ef35ac809e374f7ab7e/movie_full.jpg"
  },
  {
    title: "Cinematic Palworld",
    kicker: "TRAILER STILL",
    src: "https://shared.fastly.steamstatic.com/store_item_assets/steam/apps/1623730/257351727/aa6c1eb3713c2e6707bba09081ec940168052ab8/movie_full.jpg"
  },
  {
    title: "Tides of Terraria Update",
    kicker: "TRAILER STILL",
    src: "https://shared.fastly.steamstatic.com/store_item_assets/steam/apps/1623730/257161157/cc767bd10cc47563631ab24e71ed811ac2f4d4e0/movie_full.jpg"
  }
];

const api = async (path, options = {}) => {
  const response = await fetch(path, {
    headers: { "Content-Type": "application/json", ...(options.headers || {}) },
    credentials: "same-origin",
    ...options
  });
  const data = await response.json().catch(() => ({}));
  if (!response.ok || data.ok === false) throw new Error(data.error || `Request failed: ${response.status}`);
  return data;
};

const fmtTime = (seconds) => {
  const s = Number(seconds || 0);
  const d = Math.floor(s / 86400);
  const h = Math.floor((s % 86400) / 3600);
  const m = Math.floor((s % 3600) / 60);
  if (d) return `${d}d ${h}h`;
  if (h) return `${h}h ${m}m`;
  return `${m}m`;
};

function initHeroSlider() {
  const stage = $("#slideStage");
  const dots = $("#slideDots");
  if (!stage || !dots) return;
  stage.innerHTML = heroSlides.map((slide, index) => `<img class="slide-image${index === 0 ? " active" : ""}" src="${slide.src}" alt="${escapeAttr(slide.title)}" loading="${index === 0 ? "eager" : "lazy"}" />`).join("");
  dots.innerHTML = heroSlides.map((slide, index) => `<button class="slide-dot${index === 0 ? " active" : ""}" type="button" data-slide="${index}" aria-label="Show ${escapeAttr(slide.title)}"></button>`).join("");
  $$(".slide-image").forEach((image) => {
    image.addEventListener("error", () => {
      image.remove();
      if (!$(".slide-image.active")) setSlide(slideIndex + 1);
    });
  });
  setSlide(0);
  startSlider();
  const slider = $("#heroSlider");
  slider?.addEventListener("mouseenter", stopSlider);
  slider?.addEventListener("mouseleave", startSlider);
}

function setSlide(index) {
  const images = $$(".slide-image");
  if (!images.length) {
    const kicker = $("#slideKicker");
    const title = $("#slideTitle");
    if (kicker) kicker.textContent = "PALPAGOS LIVE";
    if (title) title.textContent = "Gallery unavailable";
    stopSlider();
    return;
  }
  slideIndex = (index + heroSlides.length) % heroSlides.length;
  images.forEach((image, i) => image.classList.toggle("active", i === slideIndex % images.length));
  $$(".slide-dot").forEach((dot, i) => dot.classList.toggle("active", i === slideIndex));
  const kicker = $("#slideKicker");
  const title = $("#slideTitle");
  if (kicker) kicker.textContent = heroSlides[slideIndex].kicker;
  if (title) title.textContent = heroSlides[slideIndex].title;
}

function startSlider() {
  stopSlider();
  slideTimer = setInterval(() => setSlide(slideIndex + 1), 5200);
}

function stopSlider() {
  if (slideTimer) clearInterval(slideTimer);
  slideTimer = null;
}

function toast(message) {
  const el = $("#toast");
  el.textContent = message;
  el.classList.add("show");
  clearTimeout(toast.timer);
  toast.timer = setTimeout(() => el.classList.remove("show"), 3600);
}

async function refresh() {
  bootstrap = await api("/api/bootstrap");
  me = bootstrap.me;
  renderAll();
  applyRoute();
}

function renderAll() {
  renderShell();
  renderOverview();
  renderPlayers();
  renderDiscord();
  renderShop();
  renderAccount();
}

function renderOffline(error) {
  bootstrap = {
    server: {
      name: "Neo Palworld",
      description: "Panel API is not reachable from this page yet.",
      online: false,
      metrics: {}
    },
    players: [],
    discord: {
      enabled: false,
      error: "Discord status will load after the panel API responds."
    },
    shop: [],
    authProviders: []
  };
  me = null;
  renderAll();
  const directConnect = $("#directConnect");
  const serverDetails = $("#serverDetails");
  const providerButtons = $("#providerButtons");
  if (directConnect) directConnect.textContent = "Panel API offline";
  if (serverDetails) {
    serverDetails.innerHTML = dl({
      "Panel status": "The web UI loaded, but /api/bootstrap did not respond.",
      "Error": error?.message || "Unknown API error",
      "Next step": "Restart or update the web panel service, then refresh this page."
    });
  }
  if (providerButtons) {
    providerButtons.innerHTML = `<p class="muted">Platform login will appear after the panel API is reachable.</p>`;
  }
}

function renderShell() {
  const isAdmin = me?.role === "admin";
  $$("[data-admin-only]").forEach((el) => (el.hidden = !isAdmin));
  document.body.classList.toggle("admin-route", location.pathname.startsWith("/admin"));
}

function renderOverview() {
  const { server } = bootstrap;
  const metrics = server.metrics || {};
  const gameHost = server.publicGameHost || server.publicGameIp || "";
  const direct = [gameHost, server.publicGamePort].filter(Boolean).join(":") || "Set PUBLIC_GAME_HOST in .env";
  $("#directConnect").textContent = direct;
  $("#stats").innerHTML = [
    stat("Status", server.online ? "Online" : "Offline", server.online ? "good" : "bad"),
    stat("Players", `${metrics.currentplayernum ?? 0}/${metrics.maxplayernum ?? "-"}`),
    stat("Server FPS", metrics.serverfps ?? "-"),
    stat("Uptime", metrics.uptime ? fmtTime(metrics.uptime) : "-")
  ].join("");
  $("#serverDetails").innerHTML = dl({
    "Server": server.name || "Neo Palworld",
    "Description": server.description || "No description set",
    "Direct connect": direct,
    "Base camps": metrics.basecampnum ?? "-",
    "World days": metrics.days ?? "-",
    "Frame time": metrics.serverframetime ? `${Number(metrics.serverframetime).toFixed(2)} ms` : "-"
  });
}

function stat(label, value, cls = "") {
  return `<div class="stat"><span>${escapeHtml(label)}</span><strong class="${cls}">${escapeHtml(value)}</strong></div>`;
}

function dl(items) {
  return Object.entries(items).map(([key, value]) => `<dt>${escapeHtml(key)}</dt><dd>${escapeHtml(value)}</dd>`).join("");
}

function renderPlayers() {
  const rows = bootstrap.players || [];
  $("#playerRows").innerHTML = rows.length
    ? rows.map((p) => `<tr><td>${escapeHtml(p.name)}</td><td>${escapeHtml(p.accountName || "-")}</td><td>${escapeHtml(p.level ?? "-")}</td><td>${escapeHtml(p.ping ?? "-")}</td><td>${escapeHtml(p.building_count ?? "-")}</td><td>${escapeHtml(p.userId || "-")}</td></tr>`).join("")
    : `<tr><td colspan="6" class="muted">No players online right now.</td></tr>`;
}

function renderDiscord() {
  const discord = bootstrap.discord || {};
  const invite = discord.instantInvite || discord.inviteUrl || "#";
  $("#discordInvite").href = invite;
  $("#discordInvite").hidden = invite === "#";
  const cards = [
    `<article class="card"><h3>${escapeHtml(discord.name || "Discord")}</h3><p class="muted">${discord.enabled ? `${discord.presenceCount || 0} members online` : escapeHtml(discord.error || "Enable the Discord server widget to show live members.")}</p>${invite !== "#" ? `<p><a class="button-link" href="${escapeAttr(invite)}" target="_blank" rel="noreferrer">Join Discord</a></p>` : ""}</article>`
  ];
  for (const member of discord.members || []) {
    cards.push(`<article class="card avatar-row"><img class="avatar" src="${member.avatarUrl || ""}" alt="" /><div><strong>${escapeHtml(member.username)}</strong><p class="muted">${escapeHtml(member.status || "online")}${member.game ? ` - ${escapeHtml(member.game)}` : ""}</p></div></article>`);
  }
  $("#discordGrid").innerHTML = cards.join("");
}

function renderShop() {
  $("#shopCards").innerHTML = (bootstrap.shop || []).map((item) => `
    <article class="card">
      <span class="chip">${escapeHtml(item.category)}</span>
      <h3>${escapeHtml(item.name)}</h3>
      <p class="muted">${escapeHtml(item.description)}</p>
      <p><strong>${escapeHtml(String(item.price))}</strong> ${escapeHtml(item.currency)}</p>
      <button data-order="${escapeAttr(item.id)}" ${me ? "" : "disabled"}>${me ? "Request" : "Log in to request"}</button>
    </article>
  `).join("");
}

function renderAccount() {
  $("#logoutBtn").hidden = !me;
  $("#providerLogin").hidden = !!me;
  $("#accountSummary").hidden = !me;
  renderProviderButtons();
  if (me) {
    $("#accountDetails").innerHTML = dl({
      "Display name": me.displayName || me.username,
      "Role": me.role,
      "Provider": me.providers?.length ? me.providers.map((p) => p.provider).join(", ") : me.authProvider || "Panel",
      "Platform": me.platform || "-"
    });
  }
}

function renderProviderButtons() {
  const providers = bootstrap.authProviders || [];
  $("#providerButtons").innerHTML = providers.length
    ? providers.map((provider) => `<button class="provider-button provider-${escapeAttr(provider.id)}" data-provider-login="${escapeAttr(provider.loginUrl)}"><span>${escapeHtml(provider.name)}</span><small>${escapeHtml(provider.description)}</small></button>`).join("")
    : `<p class="muted">No platform login provider is enabled yet.</p>`;
  $("#providerHelp").textContent = providers.some((p) => p.id === "microsoft")
    ? "Steam and Xbox/Microsoft sign-in create or link your web account automatically."
    : "Steam sign-in is available. Xbox/Microsoft appears after Microsoft OAuth credentials are configured. PlayStation login requires Sony-approved OAuth access.";
}

async function refreshMe() {
  if (!me) return;
  const data = await api("/api/me");
  $("#myOrders").innerHTML = data.orders.length
    ? data.orders.map((o) => `<article class="card"><span class="chip">${escapeHtml(o.status)}</span><h3>${escapeHtml(o.itemName)}</h3><p class="muted">${escapeHtml(o.note || "No note")}</p></article>`).join("")
    : `<article class="card muted">No shop requests yet.</article>`;
}

async function loadAdmin() {
  if (me?.role !== "admin") return;
  adminState = await api("/api/admin/state");
  renderAdmin();
}

function renderAdmin() {
  const players = adminState.players || [];
  $("#adminPlayerRows").innerHTML = players.length
    ? players.map((p) => `<tr><td>${escapeHtml(p.name || p.accountName || "Player")}</td><td>${escapeHtml(p.userId || "-")}</td><td>${escapeHtml(p.ip || "-")}</td><td>${escapeHtml(p.ping ?? "-")}</td><td><button data-kick="${escapeAttr(p.userId)}">Kick</button> <button data-ban="${escapeAttr(p.userId)}">Ban</button></td></tr>`).join("")
    : `<tr><td colspan="5" class="muted">No players online.</td></tr>`;
  $("#adminOrders").innerHTML = (adminState.orders || []).map((o) => `
    <div class="order-item">
      <strong>${escapeHtml(o.itemName)} -> ${escapeHtml(o.username)}</strong>
      <span class="muted">${escapeHtml(o.status)} / ${escapeHtml(o.note || "No note")}</span>
      <div class="button-row">
        <button data-order-status="${escapeAttr(o.id)}" data-status="approved">Approve</button>
        <button data-order-status="${escapeAttr(o.id)}" data-status="delivered">Delivered</button>
        <button data-order-status="${escapeAttr(o.id)}" data-status="rejected">Reject</button>
      </div>
    </div>
  `).join("") || `<p class="muted">No shop orders yet.</p>`;
}

function escapeHtml(value) {
  return String(value ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#039;" }[c]));
}

function escapeAttr(value) {
  return escapeHtml(value).replace(/`/g, "&#096;");
}

$$(".tabs button").forEach((button) => {
  button.addEventListener("click", async () => {
    if (location.pathname.startsWith("/admin")) history.pushState({}, "", "/");
    activatePanel(button.dataset.tab);
    if (button.dataset.tab === "admin") await loadAdmin().catch((error) => toast(error.message));
    if (button.dataset.tab === "account") await refreshMe().catch(() => {});
  });
});

function activatePanel(id) {
  document.body.classList.toggle("admin-route", location.pathname.startsWith("/admin"));
  $$(".tabs button").forEach((b) => b.classList.toggle("active", b.dataset.tab === id));
  $$(".tab-panel").forEach((p) => p.classList.toggle("active", p.id === id));
}

function applyRoute() {
  if (location.pathname.startsWith("/admin")) {
    document.body.classList.add("admin-route");
    if (me?.role === "admin") {
      activatePanel("admin");
      loadAdmin().catch((error) => toast(error.message));
    } else {
      activatePanel("adminLogin");
    }
    return;
  }
  document.body.classList.remove("admin-route");
}

document.addEventListener("click", async (event) => {
  const target = event.target.closest("button");
  if (!target) return;
  if (target.matches("[data-refresh]")) {
    await refresh().then(() => toast("Refreshed")).catch((error) => toast(error.message));
  }
  if (target.dataset.slide) {
    setSlide(Number(target.dataset.slide));
    startSlider();
  }
  if (target.id === "copyConnect") {
    await navigator.clipboard.writeText($("#directConnect").textContent);
    toast("Direct connect copied");
  }
  if (target.dataset.providerLogin) {
    window.location.href = target.dataset.providerLogin;
  }
  if (target.dataset.order) {
    await api("/api/shop/order", { method: "POST", body: JSON.stringify({ itemId: target.dataset.order }) })
      .then(() => toast("Request sent"))
      .catch((error) => toast(error.message));
    await refreshMe().catch(() => {});
  }
  if (target.dataset.control) {
    target.disabled = true;
    $("#controlOutput").textContent = "Working...";
    await api("/api/admin/control", { method: "POST", body: JSON.stringify({ action: target.dataset.control }) })
      .then((data) => { $("#controlOutput").textContent = data.result?.output || "Done"; toast("Action finished"); })
      .catch((error) => { $("#controlOutput").textContent = error.message; toast(error.message); })
      .finally(() => { target.disabled = false; });
  }
  if (target.dataset.kick || target.dataset.ban) {
    const action = target.dataset.ban ? "ban" : "kick";
    const userid = target.dataset.ban || target.dataset.kick;
    const message = prompt(`${action} message`, action === "ban" ? "Banned by admin." : "Kicked by admin.");
    if (message === null) return;
    await api("/api/admin/player-action", { method: "POST", body: JSON.stringify({ action, userid, message }) })
      .then(() => toast(`${action} sent`))
      .catch((error) => toast(error.message));
    await loadAdmin().catch(() => {});
  }
  if (target.dataset.orderStatus) {
    await api("/api/admin/order", { method: "POST", body: JSON.stringify({ orderId: target.dataset.orderStatus, status: target.dataset.status }) })
      .then(() => toast("Order updated"))
      .catch((error) => toast(error.message));
    await loadAdmin().catch(() => {});
  }
});

bind("#adminLoginForm", "submit", async (event) => {
  event.preventDefault();
  const data = Object.fromEntries(new FormData(event.target));
  await api("/api/auth/admin-login", { method: "POST", body: JSON.stringify(data) })
    .then(async () => { toast("Admin login successful"); await refresh(); })
    .catch((error) => toast(error.message));
});

bind("#registerForm", "submit", async (event) => {
  event.preventDefault();
  const data = Object.fromEntries(new FormData(event.target));
  await api("/api/auth/register", { method: "POST", body: JSON.stringify(data) })
    .then(async () => { toast("Account created"); await refresh(); })
    .catch((error) => toast(error.message));
});

bind("#logoutBtn", "click", async () => {
  await api("/api/auth/logout", { method: "POST" }).catch(() => {});
  me = null;
  await refresh();
  toast("Logged out");
});

bind("#announceForm", "submit", async (event) => {
  event.preventDefault();
  const data = Object.fromEntries(new FormData(event.target));
  await api("/api/admin/announce", { method: "POST", body: JSON.stringify(data) })
    .then(() => { toast("Announcement sent"); event.target.reset(); })
    .catch((error) => toast(error.message));
});

bind("#presetForm", "submit", async (event) => {
  event.preventDefault();
  const data = Object.fromEntries(new FormData(event.target));
  await api("/api/admin/preset", { method: "POST", body: JSON.stringify(data) })
    .then(() => toast("Preset applied. Restart required."))
    .catch((error) => toast(error.message));
});

bind("#settingsForm", "submit", async (event) => {
  event.preventDefault();
  const settings = Object.fromEntries([...new FormData(event.target)].filter(([, value]) => value !== ""));
  await api("/api/admin/settings", { method: "POST", body: JSON.stringify({ settings }) })
    .then(() => toast("Settings saved. Restart required."))
    .catch((error) => toast(error.message));
});

bind("#adminRefresh", "click", () => loadAdmin().then(() => toast("Admin data refreshed")).catch((error) => toast(error.message)));

initHeroSlider();
refresh().then(refreshMe).catch((error) => {
  renderOffline(error);
  toast(error.message);
});
setInterval(() => refresh().catch(() => {}), 30000);
