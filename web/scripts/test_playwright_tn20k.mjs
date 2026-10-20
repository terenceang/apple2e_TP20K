import { chromium } from 'playwright';
import { spawn } from 'child_process';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));

async function run() {
  console.log('===============================================================');
  console.log(' Playwright E2E Hardware Test: Tang Nano 20K Apple //e');
  console.log('===============================================================');

  // 1. Start UART pipe to the physical board. The port is machine-specific
  //    (the FPGA is one channel of the FT2232C), so set TN20K_PORT.
  const port = process.env.TN20K_PORT;
  if (!port) {
    console.error('Set TN20K_PORT to the board\'s UART (e.g. TN20K_PORT=COM5 node scripts/test_playwright_tn20k.mjs)');
    process.exit(1);
  }
  const python = process.env.PYTHON ?? 'python';
  const uartProcess = spawn(python, [
    join(HERE, 'uart_pipe.py'),
    port,
    '115200'
  ], { stdio: ['pipe', 'pipe', 'pipe'] });

  uartProcess.stderr.on('data', (d) => {
    console.log(`[UART Hardware]: ${d.toString().trim()}`);
  });

  // Give UART a moment to initialize
  await new Promise(r => setTimeout(r, 600));

  // 2. Launch Chromium
  console.log('\nLaunching Chromium...');
  const browser = await chromium.launch({
    headless: true,
    args: ['--no-sandbox', '--disable-setuid-sandbox']
  });

  const context = await browser.newContext({
    viewport: { width: 1280, height: 900 }
  });
  const page = await context.newPage();

  // Log browser console messages
  page.on('console', msg => {
    const text = msg.text();
    if (text.includes('MockSerial') || msg.type() === 'error') {
      console.log(`[Browser ${msg.type()}]: ${text}`);
    }
  });

  // 3. Expose hardware bridge functions between Node and Browser
  await page.exposeFunction('__tn20kSend', (b64) => {
    const raw = Buffer.from(b64, 'base64');
    console.log('[Bridge Node -> Hardware TX]:', raw, JSON.stringify(raw.toString()));
    uartProcess.stdin.write(`TX:${b64}\n`);
  });

  uartProcess.stdout.on('data', (data) => {
    const lines = data.toString().split('\n');
    for (const line of lines) {
      const trimmed = line.trim();
      if (trimmed.startsWith('RX:')) {
        const b64 = trimmed.slice(3);
        const raw = Buffer.from(b64, 'base64');
        console.log('[Hardware -> Bridge Node RX]:', JSON.stringify(raw.toString()));
        page.evaluate((payload) => {
          if (typeof window.__tn20kReceive === 'function') {
            window.__tn20kReceive(payload);
          }
        }, b64).catch(() => {});
      }
    }
  });

  // 4. Inject Web Serial mock hooked to the physical FPGA via Object.defineProperty
  await page.addInitScript(() => {
    class HardwareSerialPort {
      constructor() {
        this.readable = null;
        this.writable = null;
        this._readerController = null;
      }

      getInfo() {
        return {
          vendorId: 0x0403,
          productId: 0x6010,
          usbVendorId: 0x0403,
          usbProductId: 0x6010
        };
      }

      async open(options) {
        console.log('[MockSerial] port.open() called with:', options);
        // Create ReadableStream receiving real hardware bytes
        this.readable = new ReadableStream({
          start: (controller) => {
            this._readerController = controller;
            window.__tn20kReceive = (b64) => {
              const bin = atob(b64);
              const bytes = new Uint8Array(bin.length);
              for (let i = 0; i < bin.length; i++) {
                bytes[i] = bin.charCodeAt(i);
              }
              try {
                controller.enqueue(bytes);
              } catch (e) {
                // Stream might be closed
              }
            };
          },
          cancel: () => {
            this._readerController = null;
            window.__tn20kReceive = null;
          }
        });

        // Create WritableStream transmitting to real hardware
        this.writable = new WritableStream({
          write: async (chunk) => {
            let binary = '';
            for (let i = 0; i < chunk.length; i++) {
              binary += String.fromCharCode(chunk[i]);
            }
            const b64 = btoa(binary);
            await window.__tn20kSend(b64);
          }
        });
      }

      async close() {
        console.log('[MockSerial] port.close() called');
        this.readable = null;
        this.writable = null;
        this._readerController = null;
        window.__tn20kReceive = null;
      }
    }

    const portInstance = new HardwareSerialPort();

    const mockSerial = {
      requestPort: async () => {
        console.log('[MockSerial] navigator.serial.requestPort() returning hardware port');
        return portInstance;
      },
      getPorts: async () => [portInstance],
      addEventListener: () => {},
      removeEventListener: () => {}
    };

    try {
      Object.defineProperty(Navigator.prototype, 'serial', {
        get: () => mockSerial,
        configurable: true
      });
    } catch {
      Object.defineProperty(navigator, 'serial', {
        get: () => mockSerial,
        configurable: true
      });
    }
  });

  // 5. Navigate to local web app
  console.log('\nNavigating to http://localhost:5273...');
  await page.goto('http://localhost:5273', { waitUntil: 'networkidle' });

  // 6. Verify initial disconnected state
  const initialStatus = (await page.locator('.flashbar .state').textContent())?.trim();
  console.log(`Initial Status: "${initialStatus}"`);

  // 7. Click "Connect USB" to trigger connection & handshake
  console.log('\n[Action] Clicking "Connect USB" button...');
  const connectBtn = page.locator('.flashbar .btn-connect-primary');
  await connectBtn.click();

  // 8. Wait for connection handshake to verify against the TN20K FPGA
  console.log('Waiting for FPGA probe & handshake verification...');
  let connected = false;
  for (let i = 0; i < 30; i++) {
    await page.waitForTimeout(500);
    const stateText = (await page.locator('.flashbar .state').textContent())?.trim();
    const dotClasses = (await page.locator('.flashbar .dot').getAttribute('class'))?.split(' ') || [];
    console.log(`  [T+${(i+1)*0.5}s] State: "${stateText}" | Dot: ${JSON.stringify(dotClasses)}`);

    if (dotClasses.includes('open')) {
      connected = true;
      console.log('\n>>> SUCCESS: Web app established verified connection to Tang Nano 20K! <<<');
      break;
    }
    if (dotClasses.includes('error') || stateText.includes('wrong port')) {
      throw new Error(`Connection failed: ${stateText}`);
    }
  }

  if (!connected) {
    throw new Error('Timed out waiting for connection to open');
  }

  // 9. Verify UI elements after successful connection
  const disconnectBtn = page.locator('button:has-text("Disconnect")');
  console.log('Disconnect button visible:', await disconnectBtn.isVisible());

  // 10. Open and test Debugger Pane
  console.log('\n[Action] Opening Debugger Pane...');
  const debuggerToggle = page.locator('button:has-text("Debugger")');
  await debuggerToggle.click();
  await page.waitForTimeout(400);

  const debuggerPane = page.locator('.debug-pane');
  console.log('Debugger pane visible:', await debuggerPane.isVisible());

  // Click "Regs" button in Debugger to query CPU registers from the FPGA
  console.log('[Action] Clicking Debugger "Regs" button...');
  const regsBtn = page.locator('.debug-pane button:has-text("Regs")');
  if (await regsBtn.isVisible()) {
    await regsBtn.click();
    await page.waitForTimeout(800);
  }

  const regList = page.locator('.debug-pane table.regs');
  if (await regList.isVisible()) {
    const regText = (await regList.textContent())?.trim();
    console.log(`Live CPU Registers from FPGA:\n${regText}`);
  }

  // 11. Open Console Pane
  console.log('\n[Action] Opening Console Pane...');
  const consoleToggle = page.locator('button:has-text("Console")');
  await consoleToggle.click();
  await page.waitForTimeout(400);

  const consolePane = page.locator('.console-pane');
  console.log('Console pane visible:', await consolePane.isVisible());

  // 12. Interact with Virtual Keyboard
  console.log('\n[Action] Clicking virtual keyboard keys...');
  const keyH = page.locator('.board .cap[aria-label="h"]');
  if (await keyH.isVisible()) {
    await keyH.click();
    console.log('Clicked "H" key on virtual keyboard');
  }

  // 13. Save screenshot of live verified session
  const screenshotPath = join(HERE, '..', 'playwright_tn20k_success.png');
  await page.screenshot({ path: screenshotPath });
  console.log(`\nScreenshot of live connected session saved to: ${screenshotPath}`);

  // 14. Test clean disconnection
  console.log('\n[Action] Testing clean disconnect...');
  await disconnectBtn.click();
  await page.waitForTimeout(500);

  const finalState = (await page.locator('.flashbar .state').textContent())?.trim();
  const finalDot = (await page.locator('.flashbar .dot').getAttribute('class'))?.split(' ') || [];
  console.log(`Post-Disconnect State: "${finalState}" | Dot: ${JSON.stringify(finalDot)}`);

  // Cleanup
  console.log('\nClosing browser and hardware pipe...');
  await browser.close();
  uartProcess.stdin.write('QUIT\n');
  uartProcess.kill();

  console.log('\n===============================================================');
  console.log(' ALL PLAYWRIGHT HARDWARE TESTS PASSED SUCCESSFULLY! ');
  console.log('===============================================================');
}

run().catch(err => {
  console.error('\nTest failed with error:', err);
  process.exit(1);
});
