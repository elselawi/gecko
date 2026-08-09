// Minimal CDP driver for the web smoke tests.
//
// Launches against an already-running headless Chrome with
// `--remote-debugging-port=9222`, opens a new tab at [target], then polls in
// real time until `document.title` or the #out element contains [marker]
// (success) or [failMarker] (failure). Prints the final #out text and exits
// 0/1.
//
//   node tool/web_smoke/cdp_drive.mjs <url> <marker> [failMarker] [timeoutMs]
//
// No npm dependencies (Node 22+ built-in fetch + WebSocket).
const target = process.argv[2];
const marker = process.argv[3] || 'SMOKE-OK';
const failMarker = process.argv[4] || 'SMOKE-FAIL';
const timeoutMs = Number(process.argv[5] || 60000);
const debugPort = Number(process.env.CDP_PORT || 9222);

if (!target) {
  console.error('usage: node cdp_drive.mjs <url> <marker> [failMarker] [timeoutMs]');
  process.exit(2);
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function main() {
  // Create a new tab.
  const createRes = await fetch(
    `http://127.0.0.1:${debugPort}/json/new?${encodeURIComponent(target)}`,
    { method: 'PUT' },
  );
  if (!createRes.ok) throw new Error(`cannot create tab: ${createRes.status}`);
  const tab = await createRes.json();

  const ws = new WebSocket(tab.webSocketDebuggerUrl);
  await new Promise((resolve, reject) => {
    ws.onopen = resolve;
    ws.onerror = reject;
  });

  let id = 0;
  const pending = new Map();
  ws.onmessage = (event) => {
    const msg = JSON.parse(event.data);
    if (msg.id && pending.has(msg.id)) {
      pending.get(msg.id)(msg);
      pending.delete(msg.id);
    }
  };
  const send = (method, params = {}) =>
    new Promise((resolve) => {
      const msgId = ++id;
      pending.set(msgId, resolve);
      ws.send(JSON.stringify({ id: msgId, method, params }));
    });

  await send('Page.enable');
  await send('Runtime.enable');
  await send('Page.navigate', { url: target });

  const deadline = Date.now() + timeoutMs;
  let lastText = '';
  let title = '';
  while (Date.now() < deadline) {
    await sleep(300);
    const result = await send('Runtime.evaluate', {
      expression:
        "({title: document.title, text: (document.getElementById('out')||{}).textContent || ''})",
      returnByValue: true,
    });
    const value = result.result?.result?.value;
    if (value) {
      title = value.title || '';
      lastText = value.text || '';
    }
    if (title.includes(marker) || lastText.includes(marker)) {
      console.log('SMOKE-RESULT=' + marker);
      console.log(lastText);
      process.exit(0);
    }
    if (title.includes(failMarker) || lastText.includes(failMarker)) {
      console.log('SMOKE-RESULT=' + failMarker);
      console.log(lastText);
      process.exit(1);
    }
  }
  console.log('SMOKE-RESULT=TIMEOUT');
  console.log(lastText);
  process.exit(2);
}

main().catch((error) => {
  console.error('DRIVER-ERROR:', error);
  process.exit(3);
});
