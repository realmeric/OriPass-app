// Draws the mark on whatever `fields.js` finds, and the menu and the toast, in
// closed shadow roots. It holds ids, titles and usernames until a row is chosen
// by the person, and a username and a password only for as long as it takes to
// set them or to hand what was typed to the background page. In the top frame
// it puts `wrapper.js` in the page's world, and answers what that says with a
// toast. `menu.js`, `fields.js`, `typed.js` and `toast.js` are loaded before it.

(() => {
  const setValue = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, "value").set;
  const ask = (message) => browser.runtime.sendMessage(message);

  // How long a menu has to have been up before a row of it can be chosen, so
  // that the second half of a double click lands on nothing.
  const settle = 250;
  const markSide = 16;
  const markInset = 6;
  const menuGap = 4;
  const menuWidth = { least: 280, most: 400 };

  const marks = new Map();
  const drawn = new WeakSet();
  let forms = [];
  let menu = null;
  let opening = 0;
  let sheet = null;
  let mayDraw = window === window.top ? Promise.resolve(true) : null;
  let refreshing = null;

  // How long a page has to be still before it is looked at, and how much of
  // its time a look may have: a look that took 5 ms waits 100 before the next.
  const lookAfter = 150;
  const shareOfThePage = 20;
  let nextLook = lookAfter;

  // How often a page with something held is looked at, how many looks in a row
  // the password has to be gone for, how long a form may stand there before
  // what was sent to it counts as refused, and how long it may stand on the
  // next page, which has already answered. How long "saved" stays, and how often
  // a toast over a shut vault asks again.
  const watchEvery = 250;
  const goneFor = 3;
  const patience = 20000;
  const cameBackWithin = 2000;
  const savedStays = 2600;
  const askAgainEvery = 3000;
  const isTop = window === window.top;
  let watching = null;
  let stage = null;
  let toast = null;

  // The wrapper's end of the talk, the element that reaches it at once, the call
  // the toast is up for, and whether this page has been told Not Now or asked for
  // what the vault does not have, after which its calls are the browser's. The
  // last thing the wrapper was told. How long a toast may hold a call that gave
  // no time of its own.
  let wrapper = null;
  let bell = null;
  let passkey = null;
  let letBe = false;
  const stopped = new Set();
  let near = null;
  let passkeyIsNear = false;
  let told;
  const holdsACall = 120000;

  // MARK: Drawing

  function styleSheet() {
    sheet ??= ask({ kind: "style" }).then((text) => {
      const made = new CSSStyleSheet();
      made.replaceSync(text);
      return made;
    });
    return sheet;
  }

  // The page's rules and its scripts can reach this element and nothing under
  // it. It has no size, so that even how many rows there are is not its to see.
  function surface(adopted, layer) {
    const host = document.createElement("div");
    host.style.setProperty("all", "initial", "important");
    for (const [name, value] of [["position", "fixed"], ["display", "block"], ["width", "0"], ["height", "0"],
      ["margin", "0"], ["inset", "auto auto auto auto"], ["overflow", "visible"], ["z-index", "2147483647"]]) {
      host.style.setProperty(name, value, "important");
    }
    const root = host.attachShadow({ mode: "closed" });
    root.adoptedStyleSheets = [adopted];
    drawn.add(host);
    if (layer) host.popover = "manual";
    document.documentElement.append(host);
    if (layer) host.showPopover();
    return { host, root };
  }

  function drawMark(field, adopted) {
    const { host, root } = surface(adopted, false);
    const button = document.createElement("button");
    button.className = "mark";
    button.tabIndex = -1;
    button.setAttribute("aria-label", "Show OriPass logins");
    button.append(drawnMark());
    button.addEventListener("mousedown", (event) => event.preventDefault());
    button.addEventListener("click", (event) => {
      if (!event.isTrusted) return;
      field.focus();
      if (menu?.field === field) close();
      else open(field, true);
    });
    root.append(button);
    if (passkeyIsNear) saysPasskey(button);
    return { host, button };
  }

  function saysPasskey(button) {
    button.classList.add("with-passkey");
    button.append(drawnKey());
    button.setAttribute("aria-label", "Show OriPass logins. OriPass has a passkey for this site.");
  }

  function place() {
    for (const [field, mark] of marks) {
      const box = field.getBoundingClientRect();
      mark.host.style.setProperty("left", `${box.right - markSide - markInset}px`, "important");
      mark.host.style.setProperty("top", `${box.top + (box.height - markSide) / 2}px`, "important");
    }
    if (!menu) return;
    const box = menu.field.getBoundingClientRect();
    const width = Math.min(Math.max(box.width, menuWidth.least), menuWidth.most);
    const left = Math.max(0, Math.min(box.left, innerWidth - width));
    menu.list.card.style.width = `${width}px`;
    const height = menu.list.card.offsetHeight;
    const fits = box.bottom + menuGap + height <= innerHeight;
    menu.host.style.setProperty("left", `${left}px`, "important");
    menu.host.style.setProperty("top", `${fits ? box.bottom + menuGap : box.top - menuGap - height}px`, "important");
  }

  // MARK: The menu

  function close() {
    opening += 1;
    menu?.host.remove();
    menu = null;
  }

  const groupOf = (field) => forms.find((form) => fieldsOf(form).includes(field));

  // What a field is offered. A password being made has the generator, and a
  // login where it is the only password of its form. Any other password has
  // the site's logins, and the generator when there are none and it was asked
  // for by hand. A field for a name or an address with no login for the site
  // has what the vault already uses, unless a click landed on something typed.
  async function offered(field, byHand) {
    const form = groupOf(field);
    const answer = await ask({ kind: "list" });
    if (answer.state !== "ready") return answer;
    if (isPassword(field)) {
      const logins = form?.password === field ? answer.logins : [];
      return { ...answer, logins, generator: form?.fresh?.includes(field) || (byHand && logins.length === 0) };
    }
    if (answer.logins.length > 0 || (!byHand && field.value)) return answer;
    const used = await ask({ kind: "usernames", address: wantsAnAddress(field) });
    return used.state === "ready" ? { ...answer, usernames: used.usernames } : answer;
  }

  // A field's click opens the menu only to show rows. The mark and the arrow
  // are asked for by hand, so they say what is wrong as well.
  async function open(field, byHand) {
    close();
    const turn = opening;
    const [answer, adopted] = await Promise.all([offered(field, byHand), styleSheet()]);
    if (turn !== opening) return;
    if (!byHand && !answer.generator && !answer.logins?.length && !answer.usernames?.length) return;
    const { host, root } = surface(adopted, true);
    const list = new LoginList(root, choose, close);
    menu = { field, host, list, shownAt: performance.now() };
    list.show(answer);
    if (passkeyIsNear) list.saysPasskey();
    place();
  }

  // A page can leave the menu where it is and make it unseen, so that a click
  // meant for something else lands on a row.
  function canBeSeen(host) {
    if (!host.checkVisibility({ opacityProperty: true, visibilityProperty: true })) return false;
    return [host, document.documentElement, document.body].filter(Boolean).every((part) => {
      const style = getComputedStyle(part);
      return style.opacity === "1" && style.filter === "none" && style.clipPath === "none"
        && style.mixBlendMode === "normal";
    });
  }

  async function choose(offer) {
    if (!menu || performance.now() - menu.shownAt < settle) return;
    if (!canBeSeen(menu.host)) {
      close();
      return;
    }
    const { field, list } = menu;
    const form = groupOf(field);
    if (!form) {
      close();
      return;
    }
    if (offer.word) {
      set(field, offer.word);
      close();
      return;
    }
    list.wait();
    const turn = opening;
    if (offer.generate) {
      makePassword(form.fresh?.length ? form.fresh : [field], turn);
      return;
    }
    const answer = await ask({ kind: "fill", id: offer.id, wants: wanted(form) });
    if (turn !== opening) return;
    if (answer.state === "filled") {
      put(form, answer);
      close();
    } else if (answer.state === "stale") {
      list.show(await ask({ kind: "list" }));
    } else {
      list.show(answer);
    }
  }

  // Goes into every field that asks for it, and a toast asks to save it when
  // the site takes it, as it does for one typed.
  async function makePassword(fields, turn) {
    const limits = fields.map((field) => field.maxLength).filter((most) => most > 0);
    const answer = await ask({ kind: "generate", most: limits.length > 0 ? Math.min(...limits) : undefined });
    if (turn !== opening) return;
    if (answer.state === "generated") {
      for (const field of fields) set(field, answer.password);
      close();
    } else {
      menu.list.show(answer);
    }
  }

  function wanted(form) {
    return ["username", "password"].filter((part) => form[part]);
  }

  function set(field, value) {
    if (!field?.isConnected || value === undefined) return;
    setValue.call(field, value);
    field.dispatchEvent(new InputEvent("input", { bubbles: true, composed: true, inputType: "insertReplacementText" }));
    field.dispatchEvent(new Event("change", { bubbles: true }));
  }

  function put(form, answer) {
    set(form.username, answer.username);
    if (form.password?.type === "password") set(form.password, answer.password);
  }

  // MARK: What was typed

  // On the document as soon as there is something to hold, and before anyone
  // knows whether a toast will come of it, so that a page sees the same thing
  // either way: a host of no size, and nothing that ever happens under it. In
  // a frame there is nothing to make, since the top frame draws the toast.
  async function makeStage() {
    if (!isTop) return null;
    stage ??= styleSheet().then((adopted) => surface(adopted, false));
    const made = await stage;
    if (!made.host.isConnected) document.documentElement.append(made.host);
    return made;
  }

  // Handed over at once: a submit that navigates ends this script, and what
  // comes of it is read on the next page.
  function take(start) {
    if (navigator.userActivation?.hasBeenActive === false) return;
    const typed = typedBeside(start);
    if (!typed) return;
    ask({ kind: "typed", ...typed });
    makeStage();
    if (typed.password) watch(patience);
  }

  function onSubmit(event) {
    take(event.target);
  }

  function onButton(event) {
    if (!event.isTrusted) return;
    const button = inner(event).closest?.("button, input[type=submit], input[type=image], [role=button]");
    if (button && sendsAForm(button)) take(button);
  }

  // A page with no form has nothing to submit, and takes Return in a field.
  function onReturn(event) {
    const field = inner(event);
    if (event.isTrusted && event.key === "Enter" && field.localName === "input" && !formOf(field) && isPassword(field)) take(field);
  }

  // Typing in a password field again says the last one did not go through.
  function onInput(event) {
    if (watching && inner(event).localName === "input" && isPassword(inner(event))) refused();
  }

  // The sign-in went through once the password is gone from the page, and a
  // page that is still asking for it refused it, which is said to nobody.
  function watch(mayStand) {
    clearInterval(watching);
    let looks = 0;
    let gone = 0;
    watching = setInterval(() => {
      looks += 1;
      gone = aPasswordIsShowing() ? 0 : gone + 1;
      if (gone >= goneFor) {
        stopWatching();
        settled();
      } else if (looks * watchEvery >= mayStand) {
        refused();
      }
    }, watchEvery);
  }

  function stopWatching() {
    clearInterval(watching);
    watching = null;
  }

  function refused() {
    stopWatching();
    ask({ kind: "dismiss" });
  }

  async function settled() {
    const offer = await ask({ kind: "settled" }).catch(() => null);
    if (isTop) show(offer);
  }

  async function landed() {
    if (!isTop) return;
    const { held } = await ask({ kind: "landed" }).catch(() => ({ held: false }));
    if (!held) return;
    makeStage();
    watch(cameBackWithin);
  }

  // MARK: The toast

  async function show(offer) {
    if (!offer || offer.state === "none") return passkey ? undefined : leave();
    if (passkey && !isForAPasskey(offer)) letGo();
    const made = await makeStage();
    if (isForAPasskey(offer) && !passkey) return undefined;
    if (!toast) {
      const stand = element("div", "stand");
      stand.popover = "manual";
      made.root.append(stand);
      stand.showPopover();
      const view = new Toast(act);
      stand.append(view.element);
      toast = { stand, view, host: made.host };
    }
    clearTimeout(toast.ending);
    clearTimeout(toast.again);
    if (toast.state !== offer.state) {
      toast.view.show(offer);
      toast.state = offer.state;
      toast.shownAt = performance.now();
    }
    if (offer.state === "saved") {
      toast.ending = setTimeout(leave, savedStays);
      return;
    }
    toast.ending = setTimeout(dismiss, offer.until - Date.now());
    if (offer.state === "locked" || offer.state === "closed") toast.again = setTimeout(settled, askAgainEvery);
  }

  function leave() {
    if (!toast) return;
    const { stand, ending, again } = toast;
    clearTimeout(ending);
    clearTimeout(again);
    toast = null;
    stand.classList.add("leaving");
    const gone = () => stand.remove();
    stand.addEventListener("animationend", gone, { once: true });
    setTimeout(gone, 400);
  }

  function dismiss() {
    if (passkey) {
      leaveAlone();
      letGo();
    } else {
      ask({ kind: "dismiss" });
    }
    leave();
  }

  // What a press of a button on the toast asks for. It has been held to
  // `isTrusted` by whoever called, and a page that has made the toast unseen,
  // or a second half of a double click, gets nothing from it. Nothing before
  // Not Now's `dismiss` waits, so that the call goes inside the press.
  async function act(what, login) {
    if (!toast || performance.now() - toast.shownAt < settle || !canBeSeen(toast.host)) return;
    if (what === "later") return dismiss();
    if (what === "sign") return signIn(login);
    if (what === "never") {
      ask({ kind: "never" });
      return leave();
    }
    toast.view.wait();
    const answer = await ask({ kind: "save", id: login?.id }).catch(() => ({ state: "refused", reason: "unsaved" }));
    if (!toast) return;
    if (answer.state === "refused") toast.view.refuse(answer.reason);
    else show(answer);
  }

  // MARK: A passkey

  const isForAPasskey = (offer) => offer.state === "passkey" || offer.state === "passkeys";

  // The port arrives before any answer can be owed on it. This listener was
  // here before anything of the page's, so nothing of the page's hears the
  // message that brings it. A page that forges this first talks to itself: what
  // comes down a port is a request, and a page may ask for its own sign-in. What
  // goes back up is near or not, for this page's own site, which a page that
  // goes to that trouble can time from a `get` as well (`docs/notes.md`).
  function takePort(event) {
    if (event.source !== window || event.data?.oripass !== "port" || !event.ports[0]) return;
    event.stopImmediatePropagation();
    removeEventListener("message", takePort, true);
    wrapper = event.ports[0];
    wrapper.onmessage = ({ data }) => {
      if (data.abandoned) abandoned(data.call);
      else offerPasskey(data);
    };
    lookForPasskey();
  }

  // Not in a frame, whose calls the browser answers: a frame of the same site
  // would be a second origin to speak for, and it can reach no toast of its own.
  function putWrapper() {
    if (!isTop || !isSecureContext || document.contentType !== "text/html") return;
    addEventListener("message", takePort, true);
    bell = document.createElement("script");
    bell.src = browser.runtime.getURL("wrapper.js");
    bell.async = false;
    bell.addEventListener("load", () => bell.remove());
    bell.addEventListener("error", () => bell.remove());
    document.documentElement.append(bell);
  }

  function tell(isNear) {
    if (!wrapper || isNear === told) return;
    told = isNear;
    wrapper.postMessage({ near: isNear });
  }

  // From here its calls reach the browser's own in the tick they are made.
  function leaveAlone() {
    letBe = true;
    tell(false);
  }

  const handBack = (call) => bell.dispatchEvent(new Event(call));

  // Whatever is holding the toast's call goes to the browser's own.
  function letGo() {
    if (!passkey) return;
    handBack(passkey.call);
    passkey = null;
  }

  function abandoned(call) {
    stopped.add(call);
    if (passkey?.call !== call) return;
    passkey = null;
    leave();
  }

  // A toast that is saying something else stands, and a page told Not Now is
  // left alone. So is one with no passkey here, and over a shut vault, where
  // there is no knowing: a toast never promises a sign-in it cannot do.
  async function offerPasskey({ call, challenge, rp, allowed, timeout }) {
    const taken = () => letBe || passkey?.signing || (toast && !passkey);
    if (taken()) return handBack(call);
    const answer = await ask({ kind: "passkeys", rp, allowed }).catch(() => null);
    if (stopped.has(call)) return undefined;
    if (!answer || !isForAPasskey(answer)) {
      leaveAlone();
      return handBack(call);
    }
    if (taken()) return handBack(call);
    letGo();
    passkey = { call, request: { challenge, rp, allowed } };
    if (toast) toast.state = null;
    const stays = timeout > 0 ? Math.min(timeout, holdsACall) : holdsACall;
    show({ ...answer, until: Date.now() + stays });
  }

  // A finger refused is the page's to hear, as the browser's own would say it.
  // Anything else that goes wrong is no reason to end its sign-in, and the
  // browser may yet have a way.
  async function signIn(login) {
    const { call, request } = passkey;
    passkey.signing = true;
    clearTimeout(toast.ending);
    toast.view.wait();
    const answer = await ask({ kind: "sign", id: login.id, ...request }).catch(() => ({ state: "closed" }));
    if (passkey?.call !== call) return;
    passkey = null;
    if (answer.state === "signed") {
      wrapper.postMessage({ call, made: answer.made });
      show({ state: "saved", passkey: true, title: login.title, username: login.username });
      return;
    }
    if (answer.state === "refused" && answer.reason === "declined") wrapper.postMessage({ call, refused: true });
    else handBack(call);
    leave();
  }

  // Asked once for a document, as soon as there is a wrapper to tell, or a mark
  // for one with no wrapper. Until the answer, and if it never comes, the wrapper
  // stands aside.
  async function lookForPasskey() {
    near ??= ask({ kind: "passkeyNear" }).catch(() => ({ near: false, shut: true }));
    const answer = await near;
    tell(answer.near && !letBe);
    if (!answer.near || passkeyIsNear) return;
    passkeyIsNear = true;
    for (const mark of marks.values()) saysPasskey(mark.button);
    menu?.list.saysPasskey();
  }

  // A door that could not say may be open by now, and one that said yes may have
  // locked. A person coming back to the page is when either is worth asking, and
  // a no stands for the document.
  async function lookAgain() {
    const last = await near;
    if (!last?.near && !last?.shut) return;
    near = null;
    lookForPasskey();
  }

  // MARK: What the page does

  // What was pressed or typed in, which an event has turned into the shadow
  // host by the time it reaches this window.
  const inner = (event) => event.composedPath()[0];

  function stop(event) {
    event.preventDefault();
    event.stopImmediatePropagation();
  }

  function onKey(event) {
    if (!event.isTrusted) return;
    if (!menu) {
      const plain = !(event.altKey || event.ctrlKey || event.metaKey || event.shiftKey);
      if (event.key === "ArrowDown" && plain && marks.has(inner(event))) {
        stop(event);
        open(inner(event), true);
      }
      return;
    }
    if (event.key === "Tab") close();
    else if (menu.list.press(event.key)) stop(event);
  }

  function onClick(event) {
    if (event.isTrusted && marks.has(inner(event)) && menu?.field !== inner(event)) open(inner(event), false);
  }

  function onPress(event) {
    if (menu && !event.composedPath().includes(menu.host)) close();
  }

  function onLeave(event) {
    if (inner(event) === menu?.field) close();
  }

  async function refresh() {
    const started = performance.now();
    const found = loginGroups();
    nextLook = Math.max(lookAfter, (performance.now() - started) * shareOfThePage);
    if (found.length > 0) {
      mayDraw ??= ask({ kind: "may" }).then((answer) => answer.may, () => false);
      if (!(await mayDraw)) return;
    }
    const fields = new Set(found.flatMap(fieldsOf));
    const adopted = fields.size > 0 ? await styleSheet() : null;
    forms = found;
    for (const [field, mark] of marks) {
      if (fields.has(field)) continue;
      mark.host.remove();
      marks.delete(field);
    }
    for (const field of fields) {
      if (!marks.has(field)) marks.set(field, drawMark(field, adopted));
    }
    if (menu && !fields.has(menu.field)) close();
    place();
    if (isTop && fields.size > 0) lookForPasskey();
  }

  // Safari has no idle callback, and a timer with nothing to wait for is what
  // it has in its place.
  const whenIdle = window.requestIdleCallback
    ? (work) => requestIdleCallback(work, { timeout: 1000 })
    : (work) => setTimeout(work);

  function soon() {
    refreshing ??= setTimeout(() => whenIdle(() => {
      refreshing = null;
      refresh();
    }), nextLook);
  }

  // Moving a mark, and drawing one, is no news of the page's.
  const isDrawn = (node) => drawn.has(node);
  const isNews = ({ target, addedNodes, removedNodes }) => !isDrawn(target)
    && (addedNodes.length + removedNodes.length === 0 || ![...addedNodes, ...removedNodes].every(isDrawn));

  function changed(records) {
    const news = records.filter(isNews);
    if (news.length === 0) return;
    for (const { addedNodes } of news) {
      for (const node of addedNodes) {
        if (node.nodeType === Node.ELEMENT_NODE) unread.add(node);
      }
    }
    soon();
  }

  function onFocus(event) {
    takeRootsAbove(inner(event));
    soon();
  }

  addEventListener("keydown", onKey, true);
  addEventListener("keydown", onReturn, true);
  addEventListener("input", onInput, true);
  addEventListener("click", onClick, true);
  addEventListener("click", onButton, true);
  addEventListener("submit", onSubmit, true);
  addEventListener("mousedown", onPress, true);
  addEventListener("focusout", onLeave, true);
  addEventListener("focusin", onFocus, true);
  addEventListener("focus", lookAgain);
  addEventListener("pagehide", close);
  addEventListener("resize", place);
  addEventListener("scroll", place, { capture: true, passive: true });
  document.addEventListener("DOMContentLoaded", soon);
  document.addEventListener("DOMContentLoaded", landed);
  const watcher = new MutationObserver(changed);
  const looksFor = {
    subtree: true,
    childList: true,
    attributes: true,
    attributeFilter: ["class", "style", "hidden", "type", "disabled", "readonly"],
  };
  onRoot = (root) => watcher.observe(root, looksFor);
  watcher.observe(document, looksFor);
  soon();

  function focused() {
    let at = document.activeElement;
    while (at?.shadowRoot?.activeElement) at = at.shadowRoot.activeElement;
    return at;
  }

  // The popup's row and a frame's toast, for the top frame.
  browser.runtime.onMessage.addListener((message, sender, answer) => {
    const form = forms.find((found) => fieldsOf(found).includes(focused())) ?? forms.find((found) => found.password) ?? forms[0];
    if (message.kind === "wants") {
      answer(form ? wanted(form) : []);
    } else if (message.kind === "put" && form) {
      put(form, message);
      answer(true);
    } else if (message.kind === "toast") {
      show(message.offer);
      answer(true);
    }
  });

  putWrapper();
})();
