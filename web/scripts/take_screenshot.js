import { chromium } from 'playwright';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));

const browser = await chromium.launch();
const page = await browser.newPage();
await page.setViewportSize({ width: 1300, height: 950 });
await page.goto('http://localhost:5273');
await page.waitForTimeout(1000);

// Screenshot with full view (Screen + Paddles + Keyboard)
await page.screenshot({ path: join(HERE, '..', 'screenshot_filled_full.png') });

// Now hide Screen and Paddles to match user's exact state in image.png
const screenToggle = await page.$('.view-toggles button:has-text("Screen")');
if (screenToggle) await screenToggle.click();
const paddlesToggle = await page.$('.view-toggles button:has-text("Paddles")');
if (paddlesToggle) await paddlesToggle.click();
await page.waitForTimeout(500);

// Screenshot in the exact state as user's image.png (only keyboard active)
await page.screenshot({ path: join(HERE, '..', 'screenshot_filled_keyboard.png') });

await browser.close();
console.log('Successfully captured screenshots!');
