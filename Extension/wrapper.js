// The one script in a page's own world. It stands in front of
// `navigator.credentials.get`, and aside: a call goes to the browser's own in the
// tick it was made and nobody hears of it, unless `content.js` has said the vault
// has a passkey near. Then it tells `content.js` what was asked, down a port the
// page never holds. A page can reach anything here and can forge any of it, so
// this holds nothing, decides nothing, and is told only what to do with the
// call: hand it to the browser's own, refuse it, or answer it with a credential
// the page would have been handed anyway. Whatever it cannot read is the
// browser's to answer.

(() => {
  const container = globalThis.CredentialsContainer?.prototype;
  if (typeof container?.get !== "function") return;

  const { port1: port, port2 } = new MessageChannel();
  window.postMessage({ oripass: "port" }, "*", [port2]);

  // The element `content.js` put this script in with, which it takes out of the
  // document at `load` and goes on holding. An event on it runs here inside
  // whatever dispatched it, and a port cannot: a press on Not Now reaches the
  // browser's own inside the press.
  const bell = document.currentScript;

  // A `DataView` of anything that is no buffer throws, which `read` takes as a
  // call for the browser to refuse.
  const written = (source) => {
    const view = ArrayBuffer.isView(source) ? source : new DataView(source);
    return btoa(String.fromCharCode(...new Uint8Array(view.buffer, view.byteOffset, view.byteLength)));
  };
  const buffer = (text) => Uint8Array.from(atob(text), (letter) => letter.charCodeAt(0)).buffer;
  const forJSON = (text) => text.replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");

  function read(options) {
    try {
      const { publicKey, mediation, signal } = options;
      if (!publicKey?.challenge || mediation === "silent" || signal?.aborted) return null;
      return {
        challenge: written(publicKey.challenge),
        rp: publicKey.rpId,
        allowed: Array.from(publicKey.allowCredentials ?? [], ({ id }) => written(id)),
        timeout: publicKey.timeout,
        mediation,
      };
    } catch {
      return null;
    }
  }

  const shaped = (type, values) => Object.setPrototypeOf(values, globalThis[type]?.prototype ?? Object.prototype);

  function credential({ id, rawId, clientData, authenticatorData, signature, userHandle }) {
    const parts = { clientDataJSON: clientData, authenticatorData, signature, ...(userHandle ? { userHandle } : {}) };
    const response = shaped("AuthenticatorAssertionResponse", {
      clientDataJSON: buffer(clientData),
      authenticatorData: buffer(authenticatorData),
      signature: buffer(signature),
      userHandle: userHandle ? buffer(userHandle) : null,
    });
    return shaped("PublicKeyCredential", {
      id,
      rawId: buffer(rawId),
      type: "public-key",
      authenticatorAttachment: "platform",
      response,
      getClientExtensionResults: () => ({}),
      toJSON: () => ({
        id,
        rawId: id,
        type: "public-key",
        authenticatorAttachment: "platform",
        clientExtensionResults: {},
        response: Object.fromEntries(Object.entries(parts).map(([name, text]) => [name, forJSON(text)])),
      }),
    });
  }

  // How long a conditional call may wait to hear whether there is anything to
  // offer, from when this script ran. It waits for no click, and a wait costs
  // only the browser's suggestion in the field coming that much later. A door
  // question is a process start in Orion and a host waking in Safari, so this is
  // room for a slow one, and still over before anyone has reached the field.
  const mostToWait = 1000;

  const calls = new Map();
  let lastCall = 0;
  let near;
  const told = new Promise((heard) => {
    setTimeout(heard, mostToWait);
    port.onmessage = ({ data }) => {
      if (data.near === undefined) {
        calls.get(data.call)?.(data);
      } else {
        near = data.near;
        heard();
      }
    };
  });

  const wrapped = new Proxy(container.get, {
    apply(original, self, args) {
      const asked = near !== false && self === navigator.credentials ? read(args[0]) : null;
      if (!asked || (near === undefined && asked.mediation !== "conditional")) return Reflect.apply(original, self, args);
      return new Promise((resolve, reject) => {
        lastCall += 1;
        const call = lastCall;
        const { signal } = args[0];
        const finished = () => {
          calls.delete(call);
          signal?.removeEventListener("abort", stopped);
          bell.removeEventListener(call, handOver);
        };
        const stopped = () => {
          finished();
          port.postMessage({ call, abandoned: true });
          reject(signal.reason);
        };
        const handOver = () => {
          finished();
          resolve(Reflect.apply(original, self, args));
        };
        signal?.addEventListener("abort", stopped, { once: true });
        bell.addEventListener(call, handOver);
        calls.set(call, ({ made }) => {
          finished();
          if (made) resolve(credential(made));
          else reject(new DOMException("The operation either timed out or was not allowed.", "NotAllowedError"));
        });
        told.then(() => {
          if (!calls.has(call)) return;
          if (near) port.postMessage({ call, ...asked });
          else handOver();
        });
      });
    },
  });

  // A proxy says so to `toString`, so `toString` is one too, and answers for
  // both as what they stand in front of.
  const shown = new WeakMap([[wrapped, container.get]]);
  const toString = new Proxy(Function.prototype.toString, {
    apply: (original, self, args) => Reflect.apply(original, shown.get(self) ?? self, args),
  });
  shown.set(toString, Function.prototype.toString);
  Function.prototype.toString = toString;
  container.get = wrapped;
})();
