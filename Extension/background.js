// The only thing here that speaks to the app. A page's address comes from what
// the browser says of the sender, never from what a script said, and what a
// frame was listed is kept in memory: the browser may unload this page at any
// time, and then a fill is answered "stale" and the menu lists again.
//
// What a page was just given is held here for one tab until it is answered,
// dismissed or two minutes old, in the browser's session storage where it has
// one, which is in memory and goes with the browser, and otherwise in this
// page's memory. It is never written anywhere that lasts.

const bridge = "com.meric.oripass.bridge";
const lists = new Map();
const holdFor = 120000;

const inMemory = new Map();
const shelf = browser.storage?.session ?? {
  get: async () => Object.fromEntries(inMemory),
  set: async (held) => Object.entries(held).forEach(([key, value]) => inMemory.set(key, value)),
  remove: async (key) => inMemory.delete(key),
};

async function door(message) {
  try {
    return await browser.runtime.sendNativeMessage(bridge, { v: 1, ...message });
  } catch {
    return { v: 1, type: "closed" };
  }
}

const isWeb = (url) => /^https?:/.test(url ?? "");
const withoutFragment = (url) => url.split("#")[0];

async function pageOf(sender) {
  if (!isWeb(sender.url) || !isWeb(sender.tab?.url)) return null;
  if (sender.frameId !== 0 && !(await sameSite(sender.url, sender.tab.url))) return null;
  return { key: `${sender.tab.id}:${sender.frameId}`, url: sender.url, top: sender.tab.url };
}

// The tab in front, for the popup, which is no page and has no tab of its own.
async function pageInFront(sender) {
  if (sender.tab || !sender.url?.startsWith(browser.runtime.getURL(""))) return null;
  const [tab] = await browser.tabs.query({ active: true, currentWindow: true });
  if (!isWeb(tab?.url)) return null;
  return { key: `${tab.id}:0`, url: tab.url, top: tab.url, tab: tab.id };
}

async function list(page) {
  lists.delete(page.key);
  const status = await door({ type: "hello" });
  if (status.type !== "ready") return { state: status.type };
  const answer = await door({ type: "logins", url: page.url });
  if (answer.type !== "logins") return { state: answer.type, reason: answer.reason };
  const logins = answer.logins.map(({ id, title, username }) => ({ id, title, username }));
  lists.set(page.key, {
    url: withoutFragment(page.url),
    top: withoutFragment(page.top),
    ids: new Set(logins.map((login) => login.id)),
  });
  return { state: "ready", site: answer.site, logins };
}

async function fill(page, id, wants) {
  const made = lists.get(page.key);
  if (!made) return { state: "stale" };
  if (made.url !== withoutFragment(page.url) || made.top !== withoutFragment(page.top) || !made.ids.has(id)) {
    return { state: "refused", reason: "page" };
  }
  const answer = await door({ type: "fill", id, url: page.url });
  if (answer.type !== "filled") return { state: answer.type, reason: answer.reason };
  const filled = { state: "filled" };
  for (const part of wants) filled[part] = answer[part];
  return filled;
}

// What the vault already uses, for a field with no login for the site. Those
// words and no others leave here.
async function usernames(page, address) {
  const answer = await door({ type: "usernames", url: page.url, ...(address ? { address } : {}) });
  if (answer.type !== "usernames") return { state: answer.type, reason: answer.reason };
  return { state: "ready", usernames: answer.usernames.filter((word) => typeof word === "string") };
}

// A password nobody has yet, for a field that asks for a new one.
async function generate(page, most) {
  const answer = await door({ type: "generate", url: page.url, ...(Number.isInteger(most) && most > 0 ? { most } : {}) });
  if (answer.type !== "generated") return { state: answer.type, reason: answer.reason };
  return { state: "generated", password: answer.password };
}

// MARK: What a page was given

const heldKey = (tab) => `held:${tab}`;

async function held(tab) {
  const key = heldKey(tab);
  const found = (await shelf.get(key))[key];
  if (!found || Date.now() - found.at < holdFor) return found;
  await shelf.remove(key);
  return undefined;
}

// Whatever a page was given that nobody answered for. The alarm is what wakes
// a background page that has been unloaded in the meantime.
async function sweep() {
  const all = await shelf.get(null);
  const old = Object.keys(all).filter((key) => key.startsWith("held:") && Date.now() - all[key].at >= holdFor);
  await Promise.all(old.map((key) => shelf.remove(key)));
}

async function hold(tab, typed) {
  await shelf.set({ [heldKey(tab)]: typed });
  browser.alarms?.create("sweep", { when: Date.now() + holdFor });
  setTimeout(sweep, holdFor);
}

browser.alarms?.onAlarm.addListener(sweep);

// A step that only had the username waits for the step with the password, and
// a form sent twice, by its button and then as a form, has it as well.
async function typed(message, sender) {
  const page = await pageOf(sender);
  if (!page) return { held: false };
  const tab = sender.tab.id;
  const before = await held(tab);
  if (!message.password && before?.password) return { held: true };
  const stepped = before && await sameSite(before.url, page.url);
  await hold(tab, {
    url: page.url,
    username: message.username ?? (stepped ? before.username : undefined),
    password: message.password,
    at: Date.now(),
  });
  return { held: true };
}

const base64 = (bytes) => btoa(String.fromCharCode(...bytes));

// The password under a key made for this one question, which the app can make
// of the logins it has. The key goes with the mark, so the two say nothing
// about any other answer.
async function marked(password) {
  const key = crypto.getRandomValues(new Uint8Array(32));
  const made = await crypto.subtle.importKey("raw", key, { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const mark = await crypto.subtle.sign("HMAC", made, new TextEncoder().encode(password));
  return { key: base64(key), mark: base64(new Uint8Array(mark)) };
}

const siteAt = async (url) => {
  const host = new URL(url).hostname;
  return siteOf(host, await loadSuffixes()) ?? host;
};

// What a toast is to say about what this tab holds, or nothing. The door shut
// is said, and asked again.
async function offer(tab) {
  const found = await held(tab);
  if (!found?.password) return { state: "none" };
  const answer = await door({
    type: "known",
    url: found.url,
    ...(found.username ? { username: found.username } : {}),
    ...await marked(found.password),
  });
  const until = found.at + holdFor;
  const username = found.username;
  if (answer.type === "locked" || answer.type === "closed") {
    return { state: answer.type, site: await siteAt(found.url), username, until };
  }
  if (answer.type !== "known" || answer.state === "same" || answer.state === "never") {
    await shelf.remove(heldKey(tab));
    return { state: "none" };
  }
  const logins = answer.logins.map(({ id, title, username: name }) => ({ id, title, username: name }));
  return { state: answer.state, site: answer.site ?? await siteAt(found.url), username, logins, icon: answer.icon, until };
}

async function settled(message, sender) {
  const page = await pageOf(sender);
  if (!page) return { state: "none" };
  const made = await offer(sender.tab.id);
  if (sender.frameId !== 0 && made.state !== "none") {
    await browser.tabs.sendMessage(sender.tab.id, { kind: "toast", offer: made }, { frameId: 0 });
  }
  return made;
}

async function save(message, sender) {
  if (sender.frameId !== 0 || !isWeb(sender.tab?.url)) return { state: "refused", reason: "page" };
  const tab = sender.tab.id;
  const found = await held(tab);
  if (!found?.password) return { state: "refused", reason: "stale" };
  const answer = await door({
    type: "save",
    url: found.url,
    password: base64(new TextEncoder().encode(found.password)),
    ...(found.username ? { username: found.username } : {}),
    ...(message.id ? { id: message.id } : {}),
  });
  if (answer.type === "saved") {
    await shelf.remove(heldKey(tab));
    return { state: "saved", title: answer.title, updated: Boolean(message.id), username: found.username };
  }
  if (answer.type === "locked" || answer.type === "closed") {
    return { state: answer.type, site: await siteAt(found.url), username: found.username, until: found.at + holdFor };
  }
  return { state: "refused", reason: answer.reason ?? "unsaved" };
}

async function never(message, sender) {
  if (sender.frameId !== 0 || !isWeb(sender.tab?.url)) return {};
  const found = await held(sender.tab.id);
  await shelf.remove(heldKey(sender.tab.id));
  if (found) await door({ type: "never", url: found.url });
  return {};
}

// MARK: A passkey

// What a wrapper says comes from a page and is read as that: the relying party
// is held to the sender's address here and again at the door, the ids and the
// challenge have to be what they say, and nothing else it said is sent on. Only
// the top frame is answered, so there is no frame's origin to speak for.
const mostWritten = 8192;
const mostAllowed = 64;
const isWritten = (text) => typeof text === "string" && text.length <= mostWritten && /^[A-Za-z0-9+/]+={0,2}$/.test(text);
const forJSON = (text) => text.replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");

async function relyingParty(named, url) {
  const { hostname: host, protocol } = new URL(url);
  if ((protocol !== "https:" && host !== "localhost") || isAddress(host)) return null;
  if (named !== undefined && typeof named !== "string") return null;
  const party = named?.toLowerCase() ?? host;
  if (party === host) return party;
  if (!host.endsWith(`.${party}`)) return null;
  const site = siteOf(host, await loadSuffixes());
  return site !== null && (party === site || party.endsWith(`.${site}`)) ? party : null;
}

async function asked(message, sender) {
  if (sender.frameId !== 0 || !isWeb(sender.url) || !isWeb(sender.tab?.url)) return null;
  const allowed = message.allowed ?? [];
  if (!Array.isArray(allowed) || allowed.length > mostAllowed || !allowed.every(isWritten)) return null;
  const rp = await relyingParty(message.rp, sender.url);
  return rp && { url: sender.url, rp, allowed };
}

async function passkeys(message, sender) {
  const ask = await asked(message, sender);
  if (!ask) return { state: "none" };
  const answer = await door({ type: "passkeys", ...ask });
  if (answer.type !== "logins" || !answer.logins.length) return { state: "none" };
  const logins = answer.logins.map(({ id, title, username }) => ({ id, title, username }));
  const site = answer.site ?? await siteAt(sender.url);
  return { state: logins.length === 1 ? "passkey" : "passkeys", site, logins, icon: answer.icon };
}

// The client data is made here, of the sender's origin and the page's
// challenge, so that a page has no way to say it is anyone else. What the app
// signs is its hash.
async function sign(message, sender) {
  const ask = await asked(message, sender);
  if (!ask || !isWritten(message.challenge) || !isWritten(message.id)) return { state: "refused", reason: "page" };
  const clientData = new TextEncoder().encode(JSON.stringify({
    type: "webauthn.get",
    challenge: forJSON(message.challenge),
    origin: new URL(sender.url).origin,
    crossOrigin: false,
  }));
  const hash = await crypto.subtle.digest("SHA-256", clientData);
  const answer = await door({ type: "assert", id: message.id, ...ask, hash: base64(new Uint8Array(hash)) });
  if (answer.type !== "asserted") return { state: answer.type, reason: answer.reason };
  const { credential, userHandle, authenticatorData, signature } = answer.assertion;
  return {
    state: "signed",
    made: { id: forJSON(credential), rawId: credential, clientData: base64(clientData), authenticatorData, signature, userHandle },
  };
}

// MARK: What is asked of it

const asks = {
  style: async () => (await fetch(browser.runtime.getURL("style.css"))).text(),

  may: async (message, sender) => ({ may: (await pageOf(sender)) !== null }),

  list: async (message, sender) => {
    const page = await pageOf(sender);
    return page ? list(page) : { state: "refused", reason: "page" };
  },

  fill: async (message, sender) => {
    const page = await pageOf(sender);
    return page ? fill(page, message.id, message.wants) : { state: "refused", reason: "page" };
  },

  usernames: async (message, sender) => {
    const page = await pageOf(sender);
    return page ? usernames(page, message.address === true) : { state: "refused", reason: "page" };
  },

  generate: async (message, sender) => {
    const page = await pageOf(sender);
    return page ? generate(page, message.most) : { state: "refused", reason: "page" };
  },

  tabList: async (message, sender) => {
    const page = await pageInFront(sender);
    return page ? list(page) : { state: "nosite" };
  },

  tabFill: async (message, sender) => {
    const page = await pageInFront(sender);
    if (!page) return { state: "nosite" };
    const frame = { frameId: 0 };
    const wants = await browser.tabs.sendMessage(page.tab, { kind: "wants" }, frame).catch(() => []);
    if (!wants?.length) return { state: "noform" };
    const filled = await fill(page, message.id, wants);
    if (filled.state !== "filled") return filled;
    await browser.tabs.sendMessage(page.tab, { kind: "put", ...filled }, frame);
    return { state: "filled" };
  },

  typed,
  settled,
  save,
  never,
  passkeys,
  sign,

  passkeyNear: async (message, sender) => {
    if (sender.frameId !== 0 || !isWeb(sender.url)) return { near: false };
    const answer = await door({ type: "passkeys", url: sender.url });
    if (answer.type !== "logins") return { near: false, shut: answer.type !== "refused" };
    return { near: answer.logins.length > 0 };
  },

  landed: async (message, sender) => {
    if (sender.frameId !== 0 || !sender.tab) return { held: false };
    return { held: Boolean((await held(sender.tab.id))?.password) };
  },

  dismiss: async (message, sender) => {
    if (await pageOf(sender)) await shelf.remove(heldKey(sender.tab.id));
    return {};
  },
};

// One at a time: a page going on to the next one asks what is held the moment
// it loads, and what it handed over is still being written.
const holding = new Set(["typed", "landed", "settled", "save", "never", "dismiss"]);
let inTurn = Promise.resolve();

function run(ask, message, sender) {
  if (!holding.has(message.kind)) return ask(message, sender);
  const answered = inTurn.then(() => ask(message, sender));
  inTurn = answered.catch(() => {});
  return answered;
}

browser.runtime.onMessage.addListener((message, sender, answer) => {
  const ask = asks[message?.kind];
  if (!ask) return false;
  run(ask, message, sender).then(answer, () => answer({ state: "refused", reason: "page" }));
  return true;
});
