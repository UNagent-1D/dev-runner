import { defineConfig, devices } from '@playwright/test';

export default defineConfig({
  testDir: './tests',
  timeout: 30_000,
  expect: { timeout: 5_000 },
  // Run all tests serially (single worker) to avoid port contention and
  // to respect the rate-limit tests which exhaust per-tenant buckets.
  workers: 1,
  use: {
    baseURL: 'http://localhost:3000',
    headless: true,
    ...devices['Desktop Chrome'],
    // Never retry on test failure — rate-limit state is shared and retrying
    // after a 429 would pass on refill, hiding the actual behavior.
    actionTimeout: 10_000,
  },
  projects: [
    { name: 'chromium', use: { ...devices['Desktop Chrome'] } },
  ],
});
