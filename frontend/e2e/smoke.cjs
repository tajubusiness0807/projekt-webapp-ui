// End-to-End-Test der gesamten Anwendung im SIMULATIONSMODUS.
//
// Ein Browser (Playwright/Chromium) bedient die echte Oberfläche, ein unabhängiger WebSocket-Beobachter
// prüft die vom Backend bestätigten Zustände. Es werden keine realen Motoren angesteuert.
//
// Voraussetzung: Backend läuft im Simulationsmodus mit gebautem Frontend, z. B.
//   cd backend && AWC_DRIVER_PIN=1234 .venv/bin/python -m app
// Aufruf:
//   E2E_BASE_URL=http://127.0.0.1:8080 E2E_PIN=1234 npm run e2e
// Playwright: `npm i -D playwright && npx playwright install chromium` (oder global installiert).

const { chromium } = require('playwright');

const BASE = process.env.E2E_BASE_URL || 'http://127.0.0.1:8080';
const PIN = process.env.E2E_PIN || '1234';

let failures = 0;
function check(condition, message) {
  if (condition) {
    console.log(`  ✓ ${message}`);
  } else {
    failures += 1;
    console.log(`  ✗ ${message}`);
  }
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

class Observer {
  constructor(token) {
    this.token = token;
    this.telemetry = null;
  }
  async open() {
    const url = BASE.replace(/^http/, 'ws') + '/ws';
    this.ws = new WebSocket(url);
    await new Promise((resolve, reject) => {
      this.ws.onopen = resolve;
      this.ws.onerror = reject;
    });
    this.ws.onmessage = (ev) => {
      const msg = JSON.parse(ev.data);
      if (msg.type === 'telemetry') this.telemetry = msg;
    };
    this.ws.send(JSON.stringify({ type: 'hello', protocol: 1, token: this.token, client_id: 'e2e-observer', device: 'E2E-Beobachter', ts: Date.now() }));
    this.ping = setInterval(() => this.ws.send(JSON.stringify({ type: 'ping', ts: Date.now() })), 1000);
  }
  async waitFor(predicate, timeoutMs = 4000) {
    const end = Date.now() + timeoutMs;
    while (Date.now() < end) {
      if (this.telemetry && predicate(this.telemetry)) return this.telemetry;
      await sleep(50);
    }
    return null;
  }
  close() {
    clearInterval(this.ping);
    this.ws.close();
  }
}

async function login(page) {
  await page.goto(BASE + '/');
  await page.fill('input[type=password]', PIN);
  await page.click('button[type=submit]');
  await page.waitForSelector('[data-testid=pedal-gas]', { timeout: 10000 });
}

async function takeControlAndArm(page) {
  await page.waitForSelector('[data-testid=claim-control], [data-testid=arm], [data-testid=ack-faults], [data-testid=estop-reset]');
  if (await page.$('[data-testid=claim-control]')) await page.click('[data-testid=claim-control]');
  await page.waitForSelector('[data-testid=arm], [data-testid=ack-faults], [data-testid=estop-reset]');
  if (await page.$('[data-testid=estop-reset]')) await page.click('[data-testid=estop-reset]');
  if (await page.$('[data-testid=ack-faults]')) await page.click('[data-testid=ack-faults]');
  const arm = await page.waitForSelector('[data-testid=arm]');
  const box = await arm.boundingBox();
  await page.mouse.move(box.x + box.width / 2, box.y + box.height / 2);
  await page.mouse.down();
  await page.waitForTimeout(1100);
  await page.mouse.up();
  await page.waitForSelector('[data-testid=disarm]', { timeout: 4000 });
}

async function pressGas(page, relHeight = 0.8) {
  const gas = await (await page.$('[data-testid=pedal-gas]')).boundingBox();
  await page.mouse.move(gas.x + gas.width / 2, gas.y + gas.height * (1 - relHeight));
  await page.mouse.down();
}

(async () => {
  const res = await fetch(BASE + '/api/auth/login', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ secret: PIN, role: 'driver' }),
  });
  if (!res.ok) throw new Error(`Login fehlgeschlagen: ${res.status}`);
  const { token } = await res.json();
  const health = await (await fetch(BASE + '/api/health')).json();
  if (health.mode !== 'simulation') throw new Error('E2E-Test nur im Simulationsmodus ausführen!');

  const observer = new Observer(token);
  await observer.open();
  const browser = await chromium.launch();
  const context = await browser.newContext({ viewport: { width: 1280, height: 800 } });
  const page = await context.newPage();
  const errors = [];
  page.on('pageerror', (e) => errors.push(e.message));

  console.log('Anmeldung und Startzustand');
  await login(page);
  check(await page.isVisible('[data-testid=simulation-badge]'), 'SIMULATION ist sichtbar gekennzeichnet');
  const t0 = await observer.waitFor((t) => t.vehicle.state === 'locked' || t.vehicle.state === 'fault');
  check(t0 && !t0.vehicle.armed, 'Motoren nach dem Start nicht freigegeben');

  console.log('Freigabe und Gas (Totmann)');
  await takeControlAndArm(page);
  check(!!(await observer.waitFor((t) => t.vehicle.armed)), 'Freigabe vom Backend bestätigt');
  await pressGas(page);
  const driving = await observer.waitFor((t) => t.control.output.drive_level > 0.05 && t.measurements.speed_kmh.value > 1, 6000);
  check(!!driving, 'Gas erzeugt Motoranforderung und simulierte Geschwindigkeit');
  check(driving && driving.measurements.speed_kmh.status === 'simulated', 'Geschwindigkeit als „simuliert“ gekennzeichnet');
  await page.mouse.up();
  const released = await observer.waitFor((t) => t.control.output.drive_level === 0 && t.control.input.throttle === 0, 1500);
  check(!!released, 'Loslassen setzt die Anforderung sofort auf 0');

  console.log('Fokusverlust während Gas');
  await pressGas(page);
  await observer.waitFor((t) => t.control.output.drive_level > 0.05, 3000);
  await page.evaluate(() => window.dispatchEvent(new Event('blur')));
  const blurred = await observer.waitFor((t) => t.control.input.throttle === 0, 1500);
  check(!!blurred, 'Fokusverlust setzt Gas auf 0, obwohl die Maus noch gedrückt ist');
  await page.waitForTimeout(400);
  const stillZero = observer.telemetry.control.input.throttle === 0;
  check(stillZero, 'Gas bleibt 0, bis das Pedal neu gedrückt wird');
  await page.mouse.up();

  console.log('Bremse');
  await pressGas(page);
  await observer.waitFor((t) => t.measurements.speed_kmh.value > 2, 5000);
  await page.mouse.up();
  const brake = await (await page.$('[data-testid=pedal-brake]')).boundingBox();
  await page.mouse.move(brake.x + brake.width / 2, brake.y + brake.height / 2);
  await page.mouse.down();
  const braking = await observer.waitFor((t) => ['requested', 'confirmed'].includes(t.vehicle.brake_state), 2000);
  check(!!braking, 'Bremsanforderung wird angezeigt (angefordert/bestätigt)');
  const stopped = await observer.waitFor((t) => t.measurements.speed_kmh.value < 0.5, 6000);
  check(!!stopped, 'Fahrzeug kommt mit Bremse zum Stillstand');
  await page.mouse.up();

  console.log('Verbindungsabbruch während der Fahrt');
  await pressGas(page);
  await observer.waitFor((t) => t.control.output.drive_level > 0.05, 3000);
  await page.close();
  const lost = await observer.waitFor((t) => t.vehicle.state === 'fault' && t.faults.some((f) => f.code === 'E007'), 4000);
  check(!!lost, 'Verbindungsverlust → Fehler E007, Fahrzeug gesperrt');
  check(lost && lost.control.output.drive_level === 0, 'Keine Fahranforderung nach Verbindungsverlust');

  console.log('Wiederverbindung ohne automatische Freigabe');
  const page2 = await context.newPage();
  page2.on('pageerror', (e) => errors.push(e.message));
  await page2.goto(BASE + '/');
  await page2.waitForSelector('[data-testid=pedal-gas]');
  await page2.waitForTimeout(800);
  check(!observer.telemetry.vehicle.armed, 'Nach Wiederverbindung bleiben die Motoren gesperrt');

  console.log('Not-Aus');
  await takeControlAndArm(page2);
  await page2.click('[data-testid=estop]');
  const estop = await observer.waitFor((t) => t.vehicle.state === 'emergency_stop', 2000);
  check(!!estop, 'Not-Aus-Taste → Zustand Not-Aus');
  await page2.click('[data-testid=estop-reset]');
  const reset = await observer.waitFor((t) => t.vehicle.state === 'locked', 2000);
  check(!!reset && !reset.vehicle.armed, 'Not-Aus zurückgesetzt → gesperrt, nicht freigegeben');

  check(errors.length === 0, `Keine JavaScript-Fehler (${errors.join('; ') || 'keine'})`);
  observer.close();
  await browser.close();
  console.log(failures === 0 ? '\nE2E: alle Prüfungen bestanden' : `\nE2E: ${failures} Prüfung(en) fehlgeschlagen`);
  process.exit(failures === 0 ? 0 : 1);
})().catch((error) => {
  console.error(error);
  process.exit(1);
});
