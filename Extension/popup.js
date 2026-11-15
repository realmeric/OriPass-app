// The list for the tab behind the toolbar's button. The keys are this page's,
// and a row's click is the person's: nothing on a web page can reach a popup.

async function choose(login) {
  list.wait();
  const answer = await browser.runtime.sendMessage({ kind: "tabFill", id: login.id });
  if (answer.state === "filled") window.close();
  else list.show(answer.state === "stale" ? await browser.runtime.sendMessage({ kind: "tabList" }) : answer);
}

const list = new LoginList(document.body, choose, () => window.close());

addEventListener("keydown", (event) => {
  if (list.press(event.key)) event.preventDefault();
});

list.wait();
browser.runtime.sendMessage({ kind: "tabList" }).then((answer) => list.show(answer));
