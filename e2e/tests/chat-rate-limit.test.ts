/**
 * Agent Console chat rate-limit e2e tests.
 *
 * chat-orch enforces burst=20, 1 req/s per tenant_id. These tests verify:
 * 1. Normal messages succeed and get a bot reply.
 * 2. After exhausting the burst bucket (>20 rapid messages), the frontend
 *    shows a "Too many requests" message with a cooldown countdown.
 * 3. The cooldown UI appears (send button disabled / countdown label).
 *
 * Run only when the full stack is up: `docker compose up -d`
 */
import { test, expect } from '@playwright/test';

const CONSOLE_URL = '/console';
const LOGIN_URL = '/login';

// Credentials that exist in the seed data.
const ADMIN_EMAIL = process.env['TEST_EMAIL'] ?? 'admin@unagent.local';
const ADMIN_PASSWORD = process.env['TEST_PASSWORD'] ?? 'admin123';
const TENANT_ID = process.env['TEST_TENANT_ID'] ?? 'demo-tenant';

async function login(page: import('@playwright/test').Page) {
  await page.goto(LOGIN_URL);
  await page.getByPlaceholder('you@example.com').fill(ADMIN_EMAIL);
  await page.getByPlaceholder('Your password').fill(ADMIN_PASSWORD);
  await page.getByRole('button', { name: /sign in/i }).click();
  await page.waitForURL(/\/dashboard|\/admin|\/operator/, { timeout: 10_000 });
}

test.describe('Agent Console rate limiting', () => {
  test.skip(
    ({ browserName }) => browserName !== 'chromium',
    'only runs on chromium (uses JS intercept)',
  );

  test('console page is accessible after login', async ({ page }) => {
    await login(page);
    await page.goto(CONSOLE_URL);
    // Input field and send button should be visible
    await expect(page.getByRole('textbox')).toBeVisible({ timeout: 8_000 });
    await expect(page.getByRole('button', { name: /send/i })).toBeVisible();
  });

  test('sending a message shows a bot reply', async ({ page }) => {
    await login(page);
    await page.goto(CONSOLE_URL);

    // Type a simple message and send
    await page.getByRole('textbox').fill('Hola');
    await page.getByRole('button', { name: /send/i }).click();

    // A bot response should appear within 15s
    const botMessage = page.locator('[data-from="bot"], .chat-message--bot').first();
    await expect(botMessage.or(page.getByText(/hola|bienvenido|ayud/i))).toBeVisible({
      timeout: 15_000,
    });
  });

  test('rapid requests beyond burst show Too-many-requests message', async ({ page }) => {
    await login(page);
    await page.goto(CONSOLE_URL);

    // Intercept /v1/chat and short-circuit: return 429 for requests > 20.
    // This avoids burning real LLM budget while verifying the UI path.
    let chatCallCount = 0;
    await page.route('**/v1/chat', (route, request) => {
      chatCallCount++;
      if (chatCallCount > 20) {
        route.fulfill({
          status: 429,
          contentType: 'application/json',
          body: JSON.stringify({
            error: 'rate limit exceeded',
            retry_after_secs: 5,
          }),
          headers: { 'Retry-After': '5' },
        });
      } else {
        route.continue();
      }
    });

    const input = page.getByRole('textbox');
    const sendBtn = page.getByRole('button', { name: /send/i });

    // Flood 22 messages (the first 20 pass through, 21st onwards are 429).
    for (let i = 0; i <= 21; i++) {
      if (await sendBtn.isEnabled()) {
        await input.fill(`msg ${i}`);
        await sendBtn.click({ force: true });
        await page.waitForTimeout(50);
      }
    }

    // The rate-limit UI message should appear
    await expect(
      page.getByText(/too many requests/i).or(page.getByText(/wait \d+s/i)),
    ).toBeVisible({ timeout: 5_000 });
  });
});
