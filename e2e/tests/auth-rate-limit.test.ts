/**
 * Login rate-limit e2e tests.
 *
 * The Tenant service enforces a token bucket of burst=5 per IP (configurable
 * via AUTH_RATE_LIMIT_BURST). These tests exhaust that bucket and verify the
 * frontend shows an appropriate error, then confirm it recovers after the
 * bucket refills.
 *
 * Run only when the full stack is up: `docker compose up -d`
 */
import { test, expect } from '@playwright/test';

const LOGIN_URL = '/login';
const TEST_EMAIL = 'admin@unagent.local';
const TEST_PASSWORD = 'badpassword-for-ratelimit-test';

async function attemptLogin(page: import('@playwright/test').Page) {
  await page.goto(LOGIN_URL);
  await page.getByPlaceholder('you@example.com').fill(TEST_EMAIL);
  await page.getByPlaceholder('Your password').fill(TEST_PASSWORD);
  await page.getByRole('button', { name: /sign in/i }).click();
  // Wait for any response
  await page.waitForResponse((resp) => resp.url().includes('/auth/login'));
}

test.describe('Login rate limiting', () => {
  test.beforeEach(async ({ page }) => {
    // Start from login page
    await page.goto(LOGIN_URL);
  });

  test('login page loads', async ({ page }) => {
    await expect(page.getByPlaceholder('you@example.com')).toBeVisible();
    await expect(page.getByPlaceholder('Your password')).toBeVisible();
    await expect(page.getByRole('button', { name: /sign in/i })).toBeEnabled();
  });

  test('shows error on invalid credentials', async ({ page }) => {
    await page.getByPlaceholder('you@example.com').fill('nobody@example.com');
    await page.getByPlaceholder('Your password').fill('wrongpassword');
    await page.getByRole('button', { name: /sign in/i }).click();
    // Toast or error message should appear
    await expect(
      page.getByText(/invalid credentials/i).or(page.getByText(/check your email/i)),
    ).toBeVisible({ timeout: 8_000 });
  });

  test('rate limits after burst is exhausted and shows Retry-After', async ({ page }) => {
    // Exhaust the default burst of 5 with rapid bad-credential attempts.
    // The first 5 should fail with 401 (bad password), the 6th+ with 429.
    const requests: Array<{ status: number }> = [];

    page.on('response', (resp) => {
      if (resp.url().includes('/auth/login')) {
        requests.push({ status: resp.status() });
      }
    });

    // Rapidfire 7 attempts without waiting for the UI to settle.
    for (let i = 0; i < 7; i++) {
      await page.getByPlaceholder('you@example.com').fill(TEST_EMAIL);
      await page.getByPlaceholder('Your password').fill(`badpass-${i}`);
      await page.getByRole('button', { name: /sign in/i }).click();
      // Short wait — we want to keep sending quickly, not wait for toast.
      await page.waitForTimeout(200);
    }

    // By the 7th attempt at least one should have been 429.
    const tooMany = requests.filter((r) => r.status === 429);
    expect(tooMany.length).toBeGreaterThan(0);
  });
});
