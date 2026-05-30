# e2e — End-to-end tests

Playwright tests for the UNAgent platform. Tests run against the full live
stack at `http://localhost:3000`.

## Prerequisites

```bash
# Install Playwright and browsers
cd e2e
npm install
npx playwright install chromium
```

## Running

```bash
# Start the stack first
docker compose up -d

# Run all e2e tests
npm test

# Run only smoke tests (healthchecks)
npm run test:smoke

# Run headed (useful for debugging)
npm run test:headed
```

## Test files

| File | What it covers |
|------|----------------|
| `smoke.test.ts` | Stack health, login page loads, unauthenticated redirect |
| `auth-rate-limit.test.ts` | Login rate limiting (Tenant service burst=5 per IP) |
| `chat-rate-limit.test.ts` | Console chat rate limiting (chat-orch burst=20 per tenant) |
| `csat-widget.test.ts` | Star rating widget: render, submit, no double-submit |

## Environment variables

Override these to run against a different environment or credentials:

| Var | Default |
|-----|---------|
| `TEST_EMAIL` | `admin@unagent.local` |
| `TEST_PASSWORD` | `admin123` |
| `TEST_TENANT_ID` | `demo-tenant` |
