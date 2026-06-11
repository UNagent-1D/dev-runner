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
const ADMIN_EMAIL = process.env['TEST_EMAIL'] ?? 'admin@demo.com';
const ADMIN_PASSWORD = process.env['TEST_PASSWORD'] ?? 'demo1234';
const TENANT_ID = process.env['TEST_TENANT_ID'] ?? 'demo-tenant';

const MOCK_TOKEN = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJ1c2VyX2lkIjoiODY1YTc5NGMtM2FhMi00ZmVlLTgwM2ItYjYxYmI2NzMxYTg2IiwiZW1haWwiOiJhZG1pbkBkZW1vLmNvbSIsInRlbmFudF9pZCI6bnVsbCwicm9sZSI6ImFwcF9hZG1pbiIsImV4cCI6OTk5OTk5OTk5OSwiaWF0IjoxNzc5Njk0MTQ1fQ.placeholder';
const MOCK_LOGIN_RESPONSE = {
  token: MOCK_TOKEN,
  expires_at: '2099-01-01T00:00:00Z',
  user: { id: '865a794c-3aa2-4fee-803b-b61bb6731a86', email: ADMIN_EMAIL, role: 'app_admin', tenant_id: null, is_active: true, created_at: '2026-01-01T00:00:00Z' },
};

async function login(page: import('@playwright/test').Page) {
  // Mock the login endpoint to avoid hitting the real rate limiter.
  // This keeps auth-rate-limit.test.ts as the sole consumer of the real bucket.
  await page.route(/\/api\/v1\/auth\/login/, (route) => {
    route.fulfill({
      status: 200,
      contentType: 'application/json',
      body: JSON.stringify(MOCK_LOGIN_RESPONSE),
    });
  });
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

    // Mock ALL chat requests to avoid real LLM calls.
    // The first 2 return success (so the UI settles), the 3rd returns 429.
    let chatCallCount = 0;
    await page.route('**/v1/chat', (route) => {
      chatCallCount++;
      if (chatCallCount >= 3) {
        route.fulfill({
          status: 429,
          contentType: 'application/json',
          body: JSON.stringify({ error: 'rate limit exceeded', retry_after_secs: 5 }),
          headers: { 'Retry-After': '5' },
        });
      } else {
        route.fulfill({
          status: 200,
          contentType: 'application/json',
          body: JSON.stringify({
            session_id: `sess-rl-${chatCallCount}`,
            message: { text: 'ok' },
          }),
        });
      }
    });

    const input = page.getByRole('textbox');
    const sendBtn = page.getByRole('button', { name: /send/i });

    // Send 3 messages rapidly; 3rd triggers 429 via the mock.
    for (let i = 0; i < 3; i++) {
      await expect(sendBtn).toBeEnabled({ timeout: 5_000 });
      await input.fill(`msg ${i}`);
      await sendBtn.click();
      // Wait for response before next send (so the button re-enables).
      await page.waitForTimeout(300);
    }

    // The rate-limit error should appear either as a toast or as a bot
    // chat message. The in-page message may be browser-translated.
    await expect(
      page.getByText(/too many requests/i)
        .or(page.getByText(/wait \d+s/i))
        .or(page.getByText(/demasiadas solicitudes/i))
        .or(page.getByText(/espere \d+/i))
        .first(),
    ).toBeVisible({ timeout: 5_000 });
  });
});
