/**
 * CSAT widget e2e tests.
 *
 * The Agent Console shows a 5-star rating widget after a session is resolved
 * (booking confirmed). These tests mock the chat backend to return a resolved
 * response, then verify the star rating UI appears and submitting a score
 * shows a confirmation toast.
 *
 * Run only when the full stack is up: `docker compose up -d`
 */
import { test, expect } from '@playwright/test';

const CONSOLE_URL = '/console';
const LOGIN_URL = '/login';

const ADMIN_EMAIL = process.env['TEST_EMAIL'] ?? 'admin@demo.com';
const ADMIN_PASSWORD = process.env['TEST_PASSWORD'] ?? 'demo1234';

const MOCK_LOGIN_RESPONSE = {
  token: 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJ1c2VyX2lkIjoiODY1YTc5NGMtM2FhMi00ZmVlLTgwM2ItYjYxYmI2NzMxYTg2IiwiZW1haWwiOiJhZG1pbkBkZW1vLmNvbSIsInRlbmFudF9pZCI6bnVsbCwicm9sZSI6ImFwcF9hZG1pbiIsImV4cCI6OTk5OTk5OTk5OSwiaWF0IjoxNzc5Njk0MTQ1fQ.placeholder',
  expires_at: '2099-01-01T00:00:00Z',
  user: { id: '865a794c-3aa2-4fee-803b-b61bb6731a86', email: ADMIN_EMAIL, role: 'app_admin', tenant_id: null, is_active: true, created_at: '2026-01-01T00:00:00Z' },
};

async function login(page: import('@playwright/test').Page) {
  // Mock login to avoid consuming the real rate-limit bucket.
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

test.describe('CSAT widget', () => {
  test('star buttons are visible once a session is active', async ({ page }) => {
    await login(page);
    await page.goto(CONSOLE_URL);

    // Mock /v1/chat to simulate a normal reply so the session_id is set.
    await page.route('**/v1/chat', (route) => {
      route.fulfill({
        status: 200,
        contentType: 'application/json',
        body: JSON.stringify({
          session_id: 'sess-e2e-test-001',
          message: { text: 'Hola, ¿en qué te puedo ayudar?' },
        }),
      });
    });

    const input = page.getByRole('textbox');
    await input.fill('Hola');
    await page.getByRole('button', { name: /send/i }).click();

    // CSAT star buttons should be visible (they render once session_id is set)
    // Each button has aria-label "Rate N out of 5"
    await expect(page.getByRole('button', { name: 'Rate 1 out of 5' })).toBeVisible({
      timeout: 8_000,
    });
    await expect(page.getByRole('button', { name: 'Rate 5 out of 5' })).toBeVisible();
  });

  test('clicking a star submits feedback and shows toast', async ({ page }) => {
    await login(page);
    await page.goto(CONSOLE_URL);

    // Mock chat to set session_id
    await page.route('**/v1/chat', (route) => {
      route.fulfill({
        status: 200,
        contentType: 'application/json',
        body: JSON.stringify({
          session_id: 'sess-e2e-test-002',
          message: { text: 'Su cita ha sido confirmada.' },
        }),
      });
    });

    // Track the feedback call
    let feedbackStatus = 0;
    await page.route('**/v1/feedback', (route) => {
      feedbackStatus = 200;
      route.fulfill({
        status: 200,
        contentType: 'application/json',
        body: JSON.stringify({ status: 'ok' }),
      });
    });

    await page.getByRole('textbox').fill('Quiero una cita');
    await page.getByRole('button', { name: /send/i }).click();
    await page.waitForTimeout(500);

    // Click 4-star rating
    const starBtn = page.getByRole('button', { name: 'Rate 4 out of 5' });
    await expect(starBtn).toBeVisible({ timeout: 5_000 });
    await starBtn.click();

    // Toast confirming feedback (use .first() to avoid strict mode when
    // both the inline caption and the toast notification match the text).
    await expect(
      page
        .getByText(/thanks for the feedback/i)
        .or(page.getByText(/gracias/i))
        .first(),
    ).toBeVisible({ timeout: 5_000 });

    // The feedback call should have been made
    expect(feedbackStatus).toBe(200);
  });

  test('star is disabled after rating is submitted (no double submission)', async ({ page }) => {
    await login(page);
    await page.goto(CONSOLE_URL);

    await page.route('**/v1/chat', (route) => {
      route.fulfill({
        status: 200,
        contentType: 'application/json',
        body: JSON.stringify({
          session_id: 'sess-e2e-test-003',
          message: { text: 'OK' },
        }),
      });
    });

    let feedbackCalls = 0;
    await page.route('**/v1/feedback', (route) => {
      feedbackCalls++;
      route.fulfill({
        status: 200,
        contentType: 'application/json',
        body: JSON.stringify({ status: 'ok' }),
      });
    });

    await page.getByRole('textbox').fill('test');
    await page.getByRole('button', { name: /send/i }).click();
    await page.waitForTimeout(500);

    const starBtn = page.getByRole('button', { name: 'Rate 3 out of 5' });
    await expect(starBtn).toBeVisible({ timeout: 5_000 });

    // Click once — the component replaces the star buttons with a confirmation
    // text after submission (csatScore transitions from null to a value).
    await starBtn.click();

    // Stars are replaced by "Thanks for the feedback" — the button is gone.
    await expect(starBtn).not.toBeVisible({ timeout: 3_000 });
    await expect(page.getByText(/thanks for the feedback/i).first()).toBeVisible();

    // Only one feedback call should have been made (the component sets csatScore after first click)
    await page.waitForTimeout(500);
    expect(feedbackCalls).toBe(1);
  });
});
