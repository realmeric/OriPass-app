// A stand-in for `browser`, run in whichever world the real one would be seen
// from: `ExtensionStage` answers each of these as a browser would, and hands
// `deliver` what it says of the sender. `roots` is every shadow root made in
// this world, which a page's own world never sees: a test reads the menu
// through it, as `content.js` does.
const roots = [];
const listeners = [];
const attachShadow = Element.prototype.attachShadow;
Element.prototype.attachShadow = function (init) {
  const root = attachShadow.call(this, init);
  roots.push(root);
  return root;
};

let looks = 0;
const querySelectorAll = Document.prototype.querySelectorAll;
Document.prototype.querySelectorAll = function (selector) {
  if (selector === "input") looks += 1;
  return querySelectorAll.call(this, selector);
};

// How long the observer's callback and a look at the page have held the main
// thread, by the two ways `content.js` can be called for them. The first look
// is the only one that walks the whole page.
const timings = { watching: [], looking: [] };
const timed = (part, work) => (...given) => {
  const started = performance.now();
  const result = work(...given);
  timings[part].push(performance.now() - started);
  return result;
};
const Watcher = MutationObserver;
window.MutationObserver = class extends Watcher {
  constructor(work) { super(timed("watching", work)); }
};
const whenIdleBy = window.requestIdleCallback;
if (whenIdleBy) window.requestIdleCallback = (work, options) => whenIdleBy(timed("looking", work), options);
const after = window.setTimeout;
window.setTimeout = (work, wait) => after(wait === undefined ? timed("looking", work) : work, wait);

// What the browser's session storage holds, what anything tried to write that
// lasts, and every line said to the console, for a test to read.
const session = new Map();
const wroteToDisk = [];
const alarms = [];
const alarmListeners = [];
const logged = [];
for (const name of ["log", "info", "warn", "error", "debug"]) {
  console[name] = (...words) => logged.push(words.join(" "));
}

const browser = {
  runtime: {
    getURL: (path) => `fixture-extension://extension/${path}`,
    sendMessage: (message) => window.webkit.messageHandlers.runtime.postMessage(message),
    sendNativeMessage: (name, message) => window.webkit.messageHandlers.native.postMessage({ name, message }),
    onMessage: { addListener: (listener) => listeners.push(listener) },
  },
  storage: {
    session: {
      get: async (key) => (key === null ? Object.fromEntries(session) : session.has(key) ? { [key]: session.get(key) } : {}),
      set: async (values) => Object.entries(values).forEach(([key, value]) => session.set(key, value)),
      remove: async (key) => session.delete(key),
    },
    local: {
      get: async () => ({}),
      set: async (values) => { wroteToDisk.push(JSON.stringify(values)); },
      remove: async () => {},
    },
  },
  alarms: {
    create: (name, when) => alarms.push({ name, ...when }),
    onAlarm: { addListener: (listener) => alarmListeners.push(listener) },
  },
  tabs: {
    query: (which) => window.webkit.messageHandlers.tabs.postMessage({ query: which }),
    sendMessage: (tab, message, options) => window.webkit.messageHandlers.tabs.postMessage({ tab, message, options }),
  },
};

function deliver(message, sender) {
  return new Promise((resolve) => {
    const waits = listeners.map((listener) => listener(message, sender, resolve));
    if (!waits.includes(true) && listeners.length === 1) setTimeout(() => resolve(null));
  });
}

window.close = () => { window.wasClosed = true; };

const live = (selector) => roots.filter((root) => root.host.isConnected)
  .flatMap((root) => Array.from(root.querySelectorAll(selector)));
