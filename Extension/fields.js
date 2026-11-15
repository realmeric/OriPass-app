// What on a page could hold a login, read from a field and what stands around
// it, in the two languages he reads. It keeps no value. `typed.js` and
// `content.js` are what use it.

const leastField = { width: 30, height: 12 };

// Every other `type` is a tick box, a button or a date.
const typedInto = new Set(["text", "email", "tel", "password"]);

// A name as words, so that `loginEmail`, `login_email` and `Login E-mail` read
// alike, and with no accents, so that E-POSTA, Kullanıcı and KULLANICI do too.
// Every list of words below is written in this form.
function spoken(text) {
  return text.replace(/([a-z])([A-Z])/g, "$1 $2").normalize("NFD").replace(/\p{M}/gu, "")
    .replace(/ı/g, "i").toLowerCase().replace(/([a-z])(\d)/g, "$1 $2")
    .replace(/[^a-z0-9]+/g, " ").trim();
}

const usernameWords = /email|e mail|eposta|e posta|username|user name|login|\blog in\b|sign ?in\b|kullanici|\b(mail|user|userid|account|identifier|giris|uye)\b/;
const addressWords = /email|e mail|eposta|e posta|\bmail\b/;
const nameWords = /username|user name|kullanici/;
const mailingWords = /subscri|newsletter|mailing list|abone|bulten/;
const notALogin = /\bsearch|\b(query|q|find|filter|ara|arama|filtre)\b|coupon|promo|voucher|discount|kupon|indirim/;
const aCode = /\b(otp|one time|onetime|2fa|mfa|totp|sms|code|kod|kodu|token|captcha|dogrulama|verification)\b/;
const aCard = /card|\b(cc|ccnum|cvv|cvc|ccv|csc|iban|expiry|expiration|kart|karti|kredi|son kullanma|account (number|no)|hesap (no|numarasi))\b/;
const oldWords = /\b(current|old|existing|mevcut|eski)\b/;
const signingUp = /sign ?up|regist|create (an |your )?account|\bjoin\b|kayit|uye ol|hesap olustur/;

const signingIn = /sign ?in|log ?in|giris/;

// Not on the page's `html` or `body`, which can say anything about a visitor.
const saidLikeANewsletter = ["id", "class", "action"].flatMap((name) => ["newsletter", "subscribe", "bulten"]
  .map((word) => `[${name}*=${word} i]:not(html, body)`)).join(",");

// One a person could not read as the password or the username of anything:
// a short field is a PIN, a card's code or a box for one digit of a code.
const mostOfACode = 4;

const autocompleteOf = (field) => (field.getAttribute("autocomplete") ?? "").toLowerCase().split(/\s+/);

// Also a field the page has turned to text so that its owner can read it.
const isPassword = (field) => field.type === "password"
  || autocompleteOf(field).some((word) => word === "current-password" || word === "new-password");

function usable(field) {
  const box = field.getBoundingClientRect();
  return !field.disabled && !field.readOnly
    && box.width >= leastField.width && box.height >= leastField.height
    && field.checkVisibility({ opacityProperty: true, visibilityProperty: true });
}

// `closest` that goes on past the edge of an open shadow root.
function closestOut(node, selector) {
  for (let at = node; at; at = at.getRootNode().host) {
    const found = at.closest(selector);
    if (found) return found;
  }
  return null;
}

// A field in a root of its own, which is how some sites wrap every input, is
// still in the form around that root, whatever `field.form` says of it.
const formOf = (node) => (node.localName === "form" ? node : node.form) ?? closestOut(node, "form");

const textOf = (element) => element?.textContent ?? "";

// What says what a field is when no `<label>` is tied to it: the element before
// it, or before the box it is in, if that is short enough to be a label.
function wordsBefore(field) {
  const before = field.previousElementSibling ?? field.parentElement?.previousElementSibling;
  const words = textOf(before);
  return words.length <= 60 ? words : "";
}

function labelled(field) {
  const tied = Array.from(field.labels ?? []).map(textOf);
  const named = (field.getAttribute("aria-labelledby") ?? "").split(/\s+/).filter(Boolean)
    .map((id) => textOf(field.getRootNode().getElementById?.(id)));
  const said = [...tied, ...named];
  return said.length > 0 ? said : [wordsBefore(field)];
}

function describe(field) {
  return spoken([field.type, field.name, field.id, field.placeholder, field.getAttribute("autocomplete"),
    field.getAttribute("aria-label"), ...labelled(field)].filter(Boolean).join(" "));
}

const saysACode = (said) => aCode.test(said) || aCard.test(said);
const saysNothingOfALogin = (said) => notALogin.test(said) || mailingWords.test(said) || saysACode(said);

function isACodeOrACard(field) {
  return autocompleteOf(field).some((word) => word.startsWith("cc-") || word === "one-time-code")
    || (field.maxLength >= 1 && field.maxLength <= mostOfACode);
}

function isLeftAlone(field) {
  return isACodeOrACard(field) || field.matches("[role=searchbox]") || closestOut(field, "[role=search]") !== null
    || saysNothingOfALogin(describe(field));
}

function isText(field) {
  return ["text", "email", "tel"].includes(field.type) && !isLeftAlone(field);
}

// A password field can hold nothing else, unless it is hiding a card's code.
const couldHoldAPassword = (field) => isPassword(field) && !isACodeOrACard(field) && !saysACode(describe(field));

function couldHoldALogin(field) {
  if (isACodeOrACard(field)) return false;
  if (autocompleteOf(field).some((word) => ["username", "email", "webauthn"].includes(word))) return !isPassword(field);
  return isText(field) && (field.type === "email" || usernameWords.test(describe(field)));
}

// The field wants an address and no bare name: a menu offers it only those.
function wantsAnAddress(field) {
  if (field.type === "email" || autocompleteOf(field).includes("email")) return true;
  const said = describe(field);
  return addressWords.test(said) && !nameWords.test(said);
}

function buttonWords(around) {
  const buttons = around?.querySelectorAll("button, input[type=submit], [role=button]") ?? [];
  return spoken(Array.from(buttons, (button) => `${button.textContent} ${button.value ?? ""}`).join(" "));
}

// With no password beside it, and whatever its own name says. A sign-up with a
// tick box for the newsletter is not one: it is the form's button that counts.
function isANewsletter(field) {
  if (autocompleteOf(field).includes("username")) return false;
  if (closestOut(field, `footer, [role=contentinfo], ${saidLikeANewsletter}`)) return true;
  return mailingWords.test(buttonWords(field.form ?? field.parentElement?.parentElement));
}

// Those of a form's passwords that are being made, and not asked for. A form
// that says so is believed. Otherwise two say the new one twice, past one that
// is called the old one, and one by itself is new under a button that signs up
// and none that signs in.
function newPasswords(passwords, form) {
  const asked = (field) => autocompleteOf(field).includes("current-password") || oldWords.test(describe(field));
  const named = passwords.filter((field) => autocompleteOf(field).includes("new-password"));
  if (named.length > 0) return named;
  const rest = passwords.filter((field) => !asked(field));
  if (rest.length > 1) return rest.slice(-2);
  if (rest.length === 0 || !form) return [];
  const words = `${buttonWords(form)} ${spoken(`${form.id} ${form.className}`)}`;
  return signingUp.test(words) && !signingIn.test(words) ? rest : [];
}

// The fields of one form, or of none, as what a row of a menu fills together:
// a username and the password asked for beside it, and the new passwords. One
// new password by itself is both, since sites put `new-password` on a sign-in
// to keep a browser out of it. Any other field a login could go in is a group
// of its own.
function groupsIn(form, shown) {
  const passwords = shown.filter(couldHoldAPassword);
  const names = shown.filter(couldHoldALogin);
  if (passwords.length === 0) return names.filter((field) => !isANewsletter(field)).map((username) => ({ username }));
  const fresh = newPasswords(passwords, form);
  const password = passwords.find((field) => !fresh.includes(field)) ?? (fresh.length === 1 ? fresh[0] : undefined);
  const before = shown.slice(0, shown.indexOf(passwords[0])).filter(isText);
  const username = before.findLast(couldHoldALogin) ?? (password ? before.at(-1) : undefined);
  const rest = names.filter((field) => field !== username).map((field) => ({ username: field }));
  return [{ username, password, fresh }, ...rest];
}

const fieldsOf = (group) => Array.from(new Set([group.username, group.password, ...(group.fresh ?? [])])).filter(Boolean);

// MARK: Open shadow roots

// A closed root is the page's and nobody else's. Each one found is handed to
// whoever is watching, and what has not been walked yet is all a look has to
// walk, so that a page that changes costs what changed and not its whole size.
const openRoots = new Set();
const unread = new Set([document]);
let onRoot = () => {};

// A parser adds a page an element at a time, and every part walked apart would
// walk what is under it again. Past this many it is cheaper to walk it all once.
const mostWalkedApart = 64;

function takeRoot(root) {
  if (openRoots.has(root)) return;
  openRoots.add(root);
  onRoot(root);
  unread.add(root);
}

function readRoots() {
  if (unread.size > mostWalkedApart) {
    unread.clear();
    for (const part of [document, ...openRoots]) unread.add(part);
  }
  for (const part of unread) {
    if (part.shadowRoot) takeRoot(part.shadowRoot);
    for (const element of part.querySelectorAll("*")) {
      if (element.shadowRoot) takeRoot(element.shadowRoot);
    }
  }
  unread.clear();
  for (const root of openRoots) {
    if (!root.host.isConnected) openRoots.delete(root);
  }
}

// A host that had no root yet when it was walked, as a custom element defined
// late has not: the focus inside it is how its root is found.
function takeRootsAbove(node) {
  for (let root = node.getRootNode(); root.host; root = root.host.getRootNode()) takeRoot(root);
}

const position = (one, other) => (one.compareDocumentPosition(other) & Node.DOCUMENT_POSITION_FOLLOWING ? -1 : 1);

function outermost(node) {
  let at = node;
  while (at.getRootNode().host) at = at.getRootNode().host;
  return at;
}

function inOrder(one, other) {
  const [outerOne, outerOther] = [outermost(one), outermost(other)];
  return outerOne === outerOther ? position(one, other) : position(outerOne, outerOther);
}

function fieldsOnThePage() {
  const fields = Array.from(document.querySelectorAll("input"));
  if (openRoots.size === 0) return fields;
  for (const root of openRoots) fields.push(...root.querySelectorAll("input"));
  return fields.sort(inOrder);
}

// The fields a mark could go on, and every look starts here. Layout is the dear
// part, so a tick box never gets as far as being measured.
function loginGroups() {
  readRoots();
  const forms = new Map();
  for (const field of fieldsOnThePage()) {
    if (!typedInto.has(field.type) || !usable(field)) continue;
    const form = formOf(field);
    forms.set(form, [...(forms.get(form) ?? []), field]);
  }
  return Array.from(forms, ([form, shown]) => groupsIn(form, shown)).flat();
}
