// The list the menu under a field and the popup both draw, from ids, titles
// and usernames, the words the vault already uses, and the row that makes a
// password. A row is built with `textContent`, so a title is never markup.

const sentences = {
  empty: "No logins for this site.",
  locked: "OriPass is locked. Unlock it to see this site's logins.",
  closed: "OriPass is not open.",
  unknown: "OriPass has not allowed this browser yet.",
  nosite: "This page has no logins.",
  noform: "There is no login form on this page.",
  waiting: "Waiting for OriPass…",
  passkey: "OriPass has a passkey for this site, and offers it when the site asks.",
  generator: "It goes into each new password field, and OriPass asks to save it once the site takes it.",
  used: "Used in your vault",
};

const refusals = {
  page: "That login is not for this page.",
  gone: "That login is no longer in the vault.",
  insecure: "This page is not secure, and the login is saved for a secure one.",
  declined: "OriPass was not told to fill that login.",
  unmade: "OriPass could not make a password just now.",
};

function sentence(answer) {
  if (answer.state === "ready") return sentences.empty;
  if (answer.state === "refused") return refusals[answer.reason] ?? refusals.page;
  return sentences[answer.state] ?? sentences.closed;
}

function element(tag, className, words) {
  const made = document.createElement(tag);
  if (className) made.className = className;
  if (words !== undefined) made.textContent = words;
  return made;
}

// `AppMark`: the pass with its corner folded and three dots cut out of it.
function drawnMark() {
  const space = "http://www.w3.org/2000/svg";
  const svg = document.createElementNS(space, "svg");
  svg.setAttribute("viewBox", "0 0 100 100");
  svg.setAttribute("aria-hidden", "true");
  const path = document.createElementNS(space, "path");
  path.setAttribute("fill-rule", "evenodd");
  path.setAttribute("d", "M17 17H76L96 37V70Q96 83 83 83H17Q4 83 4 70V30Q4 17 17 17Z"
    + ["M28 54a6.5 6.5 0 1 0 0 .01Z", "M50 54a6.5 6.5 0 1 0 0 .01Z", "M72 54a6.5 6.5 0 1 0 0 .01Z"].join(""));
  svg.append(path);
  return svg;
}

function drawnLine(className, viewBox, shape) {
  const space = "http://www.w3.org/2000/svg";
  const svg = document.createElementNS(space, "svg");
  svg.setAttribute("viewBox", viewBox);
  svg.setAttribute("class", className);
  svg.setAttribute("aria-hidden", "true");
  const path = document.createElementNS(space, "path");
  path.setAttribute("d", shape);
  svg.append(path);
  return svg;
}

// The key a mark carries on a site with a passkey.
const drawnKey = () => drawnLine("key", "0 0 10 10", "M3.2 1.2a2 2 0 1 0 .01 0ZM4.6 4.6L8.8 8.8M7.2 7.2L8.4 6");

// The generator's row: a wand and the two sparks it leaves.
const drawnWand = () => drawnLine("wand", "0 0 14 14", "M2.5 11.5L8.5 5.5M9 1.5V3.5M8 2.5H10M12 5V6.5M11.25 5.75H12.75");

// What a list holds, whichever kind it was handed.
function offersIn(answer) {
  const used = (answer.usernames ?? []).map((word) => ({ word }));
  return [...(answer.generator ? [{ generate: true }] : []), ...used, ...(answer.logins ?? [])];
}

class LoginList {
  constructor(parent, choose, leave) {
    this.choose = choose;
    this.leave = leave;
    this.offers = [];
    this.at = 0;
    this.card = element("div", "card");
    // A press here must not take the keys from the page's field.
    this.card.addEventListener("mousedown", (event) => event.preventDefault());
    this.heading = element("div", "heading", sentences.used);
    this.rows = element("div", "rows");
    this.rows.setAttribute("role", "listbox");
    this.line = element("div", "line");
    this.keys = element("div", "keys");
    this.keys.setAttribute("aria-hidden", "true");
    for (const [key, word] of [["↑↓", "Choose"], ["↩", "Fill"], ["esc", "Close"]]) {
      this.keys.append(element("kbd", null, key), element("span", null, word));
    }
    // The keys stay in the page's field, so VoiceOver is told the row here.
    this.voice = element("div", "voice");
    this.voice.setAttribute("role", "status");
    this.voice.setAttribute("aria-live", "polite");
    this.passkeyLine = element("div", "passkey-line", sentences.passkey);
    this.passkeyLine.hidden = true;
    this.note = element("div", "note", sentences.generator);
    this.card.append(this.heading, this.rows, this.line, this.note, this.passkeyLine, this.keys, this.voice);
    parent.append(this.card);
  }

  show(answer) {
    this.waiting = false;
    this.offers = offersIn(answer);
    this.at = 0;
    this.rows.replaceChildren(...this.offers.map((offer, place) => this.row(offer, place)));
    this.rows.hidden = this.offers.length === 0;
    this.keys.hidden = this.offers.length === 0;
    this.heading.hidden = !answer.usernames?.length;
    this.note.hidden = !answer.generator;
    if (this.offers.length > 0) {
      this.rows.setAttribute("aria-label", answer.usernames?.length ? sentences.used
        : `Logins for ${answer.site ?? "this site"}`);
      this.line.hidden = true;
      this.light();
      return;
    }
    this.line.hidden = false;
    this.line.textContent = sentence(answer);
    this.voice.textContent = this.line.textContent;
  }

  tile(offer) {
    if (offer.generate) {
      const made = element("span", "tile");
      made.append(drawnWand());
      return made;
    }
    if (offer.word) return element("span", "tile used", offer.word.includes("@") ? "@" : this.letter(offer.word));
    return element("span", "tile", this.letter(offer.title));
  }

  letter(words) {
    return Array.from(words)[0]?.toLocaleUpperCase() ?? "";
  }

  words(offer) {
    const words = element("span", "words");
    if (offer.title) {
      words.append(element("span", "title", offer.title));
      if (offer.username) words.append(element("span", "username", ` – ${offer.username}`));
    } else {
      words.append(element("span", "title", this.named(offer)));
    }
    return words;
  }

  row(offer, place) {
    const row = element("div", "row");
    row.setAttribute("role", "option");
    row.setAttribute("aria-posinset", place + 1);
    row.setAttribute("aria-setsize", this.offers.length);
    row.setAttribute("aria-label", this.named(offer));
    const tile = this.tile(offer);
    const action = element("span", "action", "Fill");
    tile.setAttribute("aria-hidden", "true");
    action.setAttribute("aria-hidden", "true");
    row.append(tile, this.words(offer), action);
    row.addEventListener("mousemove", () => {
      if (this.at !== place) this.moveTo(place);
    });
    row.addEventListener("click", (event) => {
      if (event.isTrusted) this.choose(offer);
    });
    return row;
  }

  named(offer) {
    if (offer.generate) return "Make a strong password";
    if (offer.word) return offer.word;
    return offer.username ? `${offer.title}, ${offer.username}` : offer.title;
  }

  moveTo(place) {
    this.at = place;
    this.light();
  }

  light() {
    Array.from(this.rows.children).forEach((row, place) => {
      row.setAttribute("aria-selected", place === this.at);
      if (place === this.at) row.scrollIntoView({ block: "nearest" });
    });
    const offer = this.offers[this.at];
    this.voice.textContent = `${this.named(offer)}, ${this.at + 1} of ${this.offers.length}`;
  }

  // What a key does to the list, and whether it was one of the list's. While a
  // fill waits for a finger, Return must not reach the page's form.
  press(key) {
    const count = this.offers.length;
    if (key === "Escape") this.leave();
    else if (this.waiting) return true;
    else if (count === 0) return false;
    else if (key === "ArrowDown") this.moveTo((this.at + 1) % count);
    else if (key === "ArrowUp") this.moveTo((this.at + count - 1) % count);
    else if (key === "Enter") this.choose(this.offers[this.at]);
    else return false;
    return true;
  }

  saysPasskey() {
    this.passkeyLine.hidden = false;
  }

  wait() {
    this.show({ state: "waiting" });
    this.waiting = true;
  }
}
