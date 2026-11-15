// A toast: its words, its drawing and its buttons, as one element. Where it
// stands and how it comes and goes are `.stand` in `style.css`, around it, so a
// narrow screen changes those and nothing here. It is made of what the
// background page sends, never of what a page said, with `textContent`, so no
// title is ever markup. `menu.js` is loaded before it.

// MARK: The drawing

// The app's own, in the line of Password Health's drawings: stroked and never
// filled, on a grid of 372 by 96 that the vault stands in at the same place in
// every scene, so that one state turns into the next.
const ring = (x, y, r) => `M${x - r} ${y}a${r} ${r} 0 1 0 ${r * 2} 0a${r} ${r} 0 1 0 ${-r * 2} 0Z`;

function box(x, y, wide, tall, r) {
  return `M${x + r} ${y}h${wide - r * 2}a${r} ${r} 0 0 1 ${r} ${r}v${tall - r * 2}a${r} ${r} 0 0 1 ${-r} ${r}`
    + `h${r * 2 - wide}a${r} ${r} 0 0 1 ${-r} ${-r}v${r * 2 - tall}a${r} ${r} 0 0 1 ${r} ${-r}Z`;
}

const plus = (x, y) => `M${x - 3.5} ${y}h7M${x} ${y - 3.5}v7`;

// A key with its bow here and its tip to the right.
function key(x, y, size = 1) {
  const at = (length) => length * size;
  return [ring(x, y, at(10.5)), ring(x - at(3.6), y, at(2.5)), `M${x + at(10.5)} ${y}h${at(47.5)}`,
    `M${x + at(44)} ${y}v${at(7.5)}`, `M${x + at(53)} ${y}v${at(6)}`].join("");
}

const dots = (x, y) => [0, 11, 22].map((along) => ring(x + along, y, 1.8)).join("");

const safe = { x: 236, y: 48 };

const walls = [
  ["", box(200, 12, 72, 72, 12) + `M200 30h-4M200 66h-4M214 84v4M258 84v4`],
  ["faint", box(207, 19, 58, 58, 8)],
];

const dial = [
  ["", ring(safe.x, safe.y, 19) + ring(safe.x, safe.y, 5)],
  ["", [[1, 1], [1, -1], [-1, 1], [-1, -1]]
    .map(([across, down]) => `M${safe.x + across * 3.6} ${safe.y + down * 3.6}L${safe.x + across * 13.4} ${safe.y + down * 13.4}`).join("")],
];

const sparks = [
  ["faint", plus(298, 26) + ring(314, 50, 1.5) + plus(302, 74) + ring(66, 42, 1.5) + plus(52, 72)],
];

const scenes = {
  new: [...sparks, ...walls, ...dial, ["goes-in", key(128, 48)], ["goes-in faint", dots(86, 48)]],
  update: [...sparks, ...walls, ...dial, ["goes-in", key(128, 32)], ["comes-out dashed", key(86, 64)]],
  choose: [...sparks, ...walls, ...dial, ["faint", key(112, 25, 0.8)], ["goes-in", key(128, 48)], ["faint", key(112, 71, 0.8)]],
  // The key on its way out of the safe to the person it opens for.
  passkey: [...sparks, ...walls, ...dial, ["comes-out", key(136, 48)],
    ["", ring(100, 33, 9) + "M80 71a20 20 0 0 1 40 0"]],
  shut: [
    ...walls,
    ["", box(219, 46, 34, 26, 6) + "M226 46v-8a10 10 0 0 1 20 0v8" + ring(236, 56.5, 3) + "M236 59.5v5"],
    ["faint", key(112, 48)],
  ],
  saved: [
    ["faint", plus(298, 26) + ring(314, 50, 1.5) + plus(302, 74) + ring(158, 26, 1.5) + plus(166, 72)
      + ring(112, 58, 1.5) + plus(122, 34)],
    ...walls,
    ["", ring(safe.x, safe.y, 19)],
    ["draws", "M226.5 48.5l7 7 13-14.5"],
  ],
};

const fingerArcs = "M8 13.5c-1.6-1.2-2.4-3-2.4-5a2.4 2.4 0 0 1 4.8 0M10.6 13c-.7-1-1.1-2.4-1.1-3.9"
  + "M3.6 11.4c-.4-1-.6-2-.6-3a5 5 0 0 1 10 0c0 1.2 0 2.4.4 3.4M4 3.6A5.8 5.8 0 0 1 8 2c1.5 0 2.9.5 4 1.6";

function drawn(viewBox, className, parts) {
  const space = "http://www.w3.org/2000/svg";
  const svg = document.createElementNS(space, "svg");
  svg.setAttribute("viewBox", viewBox);
  svg.setAttribute("class", className);
  svg.setAttribute("aria-hidden", "true");
  for (const [kind, shape] of parts) {
    const path = document.createElementNS(space, "path");
    if (kind) path.setAttribute("class", kind);
    path.setAttribute("d", shape);
    path.setAttribute("pathLength", "1");
    svg.append(path);
  }
  return svg;
}

// MARK: What it says

const toastSentences = {
  page: "That login is not for this page.",
  gone: "That login is no longer in the vault.",
  insecure: "This page is not secure, and the login is saved for a secure one.",
  declined: "Nothing was changed, since nobody answered for it.",
  unsaved: "OriPass could not save this. Nothing was changed.",
  stale: "OriPass no longer holds what was typed here.",
};

// Each state's scene, its heading, and its lines under the heading.
const toastStates = {
  new: { scene: "new", head: "Save this login?" },
  another: { scene: "new", head: "Save this login?", note: "Or give one of these the new password:" },
  update: { scene: "update", head: "Change this password?", note: "OriPass has another password for this login." },
  choose: { scene: "choose", head: "Which login is this for?" },
  locked: { scene: "shut", head: "OriPass is locked", note: "Unlock it to save this login. This stays for two minutes." },
  closed: { scene: "shut", head: "OriPass is not open", note: "Open it to save this login. This stays for two minutes." },
  passkey: { scene: "passkey", head: "Sign in with your passkey?" },
  passkeys: { scene: "passkey", head: "Which passkey?" },
};

class Toast {
  constructor(act) {
    this.act = act;
    this.element = element("section", "toast");
    this.element.setAttribute("aria-label", "OriPass");
    // A press here must not take the keys from the page.
    this.element.addEventListener("mousedown", (event) => event.preventDefault());
    this.drawing = element("div", "band");
    this.body = element("div", "said");
    this.voice = element("div", "voice");
    this.voice.setAttribute("role", "status");
    this.voice.setAttribute("aria-live", "polite");
    this.element.append(this.drawing, this.body, this.voice);
  }

  show(offer) {
    this.waiting = false;
    this.element.classList.remove("waiting");
    this.element.dataset.state = offer.state;
    if (offer.state === "saved") this.saved(offer);
    else this.ask(offer);
  }

  saved(offer) {
    const head = offer.passkey ? "Passkey sent" : offer.updated ? "Password changed" : "Login saved";
    this.draw("saved");
    this.body.replaceChildren(this.who(head, [offer.title, offer.username].filter(Boolean), offer.title));
    this.voice.textContent = `${head}, ${offer.title}`;
  }

  ask(offer) {
    const state = toastStates[offer.state];
    const login = offer.state === "update" || offer.state === "passkey" ? offer.logins[0] : null;
    const named = offer.state === "update";
    const lines = named ? [login.title, login.username]
      : [offer.site, login ? login.username ?? login.title : offer.username];
    const who = this.who(state.head, lines.filter(Boolean), named ? login.title : offer.site, offer.icon);
    const parts = [who];
    if (state.note) parts.push(element("div", "note", state.note));
    this.line = element("div", "note refused");
    this.line.hidden = true;
    parts.push(this.line);
    if (offer.state === "choose" || offer.state === "another") parts.push(this.rows(offer.logins, "update"));
    if (offer.state === "passkeys") parts.push(this.rows(offer.logins, "sign"));
    parts.push(...this.buttons(offer, login));
    this.draw(state.scene);
    this.body.replaceChildren(...parts);
    this.voice.textContent = [state.head, ...lines.filter(Boolean), state.note].filter(Boolean).join(", ");
  }

  draw(scene) {
    const brand = element("div", "brand", "OriPass");
    brand.prepend(drawnMark());
    this.drawing.replaceChildren(drawn("0 0 372 96", "scene", scenes[scene]), brand);
  }

  who(head, lines, name, icon) {
    const who = element("div", "who");
    const words = element("div", "lines");
    words.append(element("div", "head", head), ...lines.map((line) => element("div", "line-of", line)));
    who.append(this.face(name, icon), words);
    return who;
  }

  // The icon the app has for the site goes on a canvas, which a page's rules
  // for images do not reach, and a tile with the first letter stands until it
  // is there or for good.
  face(name, icon) {
    const face = element("span", "face", Array.from(name ?? "")[0]?.toLocaleUpperCase() ?? "");
    face.setAttribute("aria-hidden", "true");
    if (icon) this.paint(face, icon).catch(() => {});
    return face;
  }

  async paint(face, icon) {
    const bytes = Uint8Array.from(atob(icon), (letter) => letter.charCodeAt(0));
    const image = await createImageBitmap(new Blob([bytes]));
    const canvas = document.createElement("canvas");
    canvas.width = 84;
    canvas.height = 84;
    const painter = canvas.getContext("2d");
    painter.imageSmoothingQuality = "high";
    painter.drawImage(image, 0, 0, canvas.width, canvas.height);
    face.replaceChildren(canvas);
    face.classList.add("iconed");
  }

  rows(logins, what) {
    const rows = element("div", "choices");
    rows.append(...logins.map((login) => {
      const row = this.button("choice", what, login);
      const words = element("span", "words");
      words.append(element("span", "title", login.title));
      if (login.username) words.append(element("span", "username", ` – ${login.username}`));
      const tile = element("span", "tile", Array.from(login.title)[0]?.toLocaleUpperCase() ?? "");
      tile.setAttribute("aria-hidden", "true");
      row.append(tile, words);
      return row;
    }));
    return rows;
  }

  buttons(offer, login) {
    const held = offer.state === "locked" || offer.state === "closed";
    const row = element("div", "buttons");
    if (offer.state === "new") row.append(this.button("lit", "new", null, "New Login"));
    if (offer.state === "another" || offer.state === "choose" || offer.state === "update") {
      row.append(this.button(offer.state === "another" ? "lit" : "plain", "new", null, "Save as New"));
    }
    if (offer.state === "update") row.append(this.withFinger("update", login, "Update"));
    if (offer.state === "passkey") row.append(this.withFinger("sign", login, "Sign In"));
    const foot = element("div", "foot");
    foot.append(this.button("quiet", "later", null, "Not Now"));
    const isPasskey = offer.state === "passkey" || offer.state === "passkeys";
    if (!held && !isPasskey) foot.append(this.button("quiet", "never", null, "Never for this site"));
    return held || offer.state === "passkeys" ? [foot] : [row, foot];
  }

  // A button that will ask for a finger says so.
  withFinger(what, login, words) {
    const button = this.button("lit", what, login, words);
    button.prepend(drawn("0 0 16 16", "finger", [["", fingerArcs]]));
    return button;
  }

  button(className, what, login, words) {
    const button = element("button", className, words);
    button.type = "button";
    button.tabIndex = -1;
    button.addEventListener("click", (event) => {
      if (!event.isTrusted || this.waiting) return;
      this.act(what, login);
    });
    return button;
  }

  wait() {
    this.waiting = true;
    this.element.classList.add("waiting");
    this.say(sentences.waiting, false);
  }

  refuse(reason) {
    this.waiting = false;
    this.element.classList.remove("waiting");
    this.say(toastSentences[reason] ?? toastSentences.unsaved, true);
  }

  say(words, isRefusal) {
    this.line.textContent = words;
    this.line.classList.toggle("refused", isRefusal);
    this.line.hidden = false;
    this.voice.textContent = words;
  }
}
