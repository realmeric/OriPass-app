// What a form holds as it is sent: which of its fields is the password, and
// which the username. It reads a page's fields and keeps nothing. `content.js`
// is what hands the answer on, and `fields.js` is what it reads them with.

// A button that sends a form it does not submit, which a page that signs in
// from script has, in the two languages he reads.
const sendingWords = /sign|log ?[io]n|continue|next|submit|create|register|join|save|change|update|reset|giri[sş]|devam|kay[ıi]t|üye|oluştur|kaydet|değiştir/i;

function usernameAlone(field, fields) {
  const form = formOf(field);
  if (!form || form.matches("[role=search]")) return false;
  const around = spoken(form.textContent);
  if (notALogin.test(around) || mailingWords.test(around)) return false;
  return usernameWords.test(describe(field))
    && fields.filter((other) => formOf(other) === form && isText(other)).length === 1;
}

const aPasswordIsShowing = () => fieldsOnThePage().some((field) => isPassword(field) && usable(field));

// What sits beside `start`: its form's fields, or with no form every field on
// the page that has none.
function fieldsBeside(start) {
  const form = formOf(start);
  return fieldsOnThePage().filter((field) => formOf(field) === form);
}

// The password that will be the login's. A form that sets one says so, or
// writes it twice, and the one before those is the one it replaces. Two that
// say different things are a form the site is about to refuse.
function passwordAmong(fields) {
  const filled = fields.filter((field) => isPassword(field) && field.value && usable(field));
  const named = filled.filter((field) => field.getAttribute("autocomplete") === "new-password");
  const fresh = named.length > 0 ? named : filled.slice(-2);
  if (fresh.length === 0) return null;
  const last = fresh[fresh.length - 1];
  if (filled.length > 2 && !fresh.every((field) => field.value === last.value)) return null;
  if (named.length > 0 && !named.every((field) => field.value === last.value)) return null;
  return last;
}

function usernameAmong(fields, password) {
  const said = fields.find((field) => /username|email/.test(field.getAttribute("autocomplete") ?? "") && field.value);
  if (said) return said.value;
  const first = fields.findIndex(isPassword);
  const before = fields.slice(0, first).filter((field) => isText(field) && usable(field) && field.value).reverse();
  return (before.find((field) => usernameWords.test(describe(field))) ?? before[0])?.value;
}

// What the fields beside `start` hold: a username and a password, a username
// alone for a form of two steps, or null.
function typedBeside(start) {
  const fields = fieldsBeside(start);
  const password = passwordAmong(fields);
  if (password) return { username: usernameAmong(fields, password)?.trim() || undefined, password: password.value };
  if (fields.some(isPassword)) return null;
  const shown = fields.filter(usable);
  const alone = shown.find((field) => isText(field) && field.value && usernameAlone(field, shown));
  return alone ? { username: alone.value.trim() } : null;
}

function sendsAForm(button) {
  const type = button.getAttribute("type")?.toLowerCase();
  if (button.tagName === "INPUT") return type === "submit" || type === "image";
  if (button.form && (type === null || type === "submit")) return true;
  return sendingWords.test([button.textContent, button.getAttribute("aria-label")].join(" "));
}
