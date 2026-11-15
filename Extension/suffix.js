// Which part of a host is the site, as `PublicSuffix` works it out in the app.
// `com.tr` is a suffix, so two names under it are two sites, which keeping the
// last two labels would call one. The list is read only when a frame's host is
// not the top page's, which most pages never ask.

function asciiName(name) {
  return /^[\x00-\x7f]*$/.test(name) ? name : new URL(`https://${name}`).hostname;
}

function readSuffixes(list) {
  const rules = { plain: new Set(), wild: new Set(), kept: new Set() };
  for (const line of list.split(/\r?\n/)) {
    const rule = line.trim().split(/\s/)[0];
    if (!rule || rule.startsWith("//")) continue;
    if (rule.startsWith("!")) rules.kept.add(asciiName(rule.slice(1)));
    else if (rule.startsWith("*.")) rules.wild.add(asciiName(rule.slice(2)));
    else rules.plain.add(asciiName(rule));
  }
  return rules;
}

function siteOf(host, rules) {
  const labels = host.toLowerCase().split(".");
  if (labels.length < 2 || labels.includes("")) return null;
  const from = (place) => labels.slice(place).join(".");
  let suffix = labels.length - 1;
  for (let place = 0; place < labels.length; place += 1) {
    if (rules.kept.has(from(place))) return from(place);
    if (rules.plain.has(from(place)) || (place + 1 < labels.length && rules.wild.has(from(place + 1)))) {
      suffix = place;
      break;
    }
  }
  return suffix > 0 ? from(suffix - 1) : null;
}

let suffixes = null;

function loadSuffixes() {
  suffixes ??= fetch(browser.runtime.getURL("public_suffix_list.dat"))
    .then((answer) => answer.text())
    .then(readSuffixes);
  return suffixes;
}

const isAddress = (host) => /^[\d.]+$|^\[/.test(host);

// Schemes count: an `http:` frame in an `https:` page is another site to a
// browser too. An address has no site, only itself.
async function sameSite(one, other) {
  const [first, second] = [new URL(one), new URL(other)];
  if (first.protocol !== second.protocol) return false;
  if (first.hostname === second.hostname) return true;
  if (isAddress(first.hostname) || isAddress(second.hostname)) return false;
  const rules = await loadSuffixes();
  const site = siteOf(first.hostname, rules);
  return site !== null && site === siteOf(second.hostname, rules);
}
