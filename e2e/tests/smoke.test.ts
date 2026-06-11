/**
 * Smoke tests for the full stack.
 * These run as a basic health check before deeper tests are executed.
 *
 * Run only when the full stack is up: `docker compose up -d`
 */
import { test, expect } from '@playwright/test';

test.describe('Stack smoke tests', () => {
  test('chat-orch /health returns ok', async ({ request }) => {
    const resp = await request.get('http://localhost:8000/health');
    expect(resp.status()).toBe(200);
    const body = await resp.json();
    expect(body).toMatchObject({ status: 'ok' });
  });

  test('agent-runtime /health returns ok', async ({ request }) => {
    const resp = await request.get('http://localhost:3100/health');
    expect(resp.status()).toBe(200);
    const body = await resp.json();
    expect(body).toMatchObject({ status: 'ok' });
  });

  test('frontend serves login page at /login', async ({ page }) => {
    await page.goto('/login');
    await expect(page.getByPlaceholder('you@example.com')).toBeVisible({ timeout: 10_000 });
  });

  test('unauthenticated / redirects to /login', async ({ page }) => {
    await page.goto('/');
    // Either already on login, or gets redirected
    await page.waitForURL(/\/login|\/unauthorized/, { timeout: 8_000 });
  });
});
