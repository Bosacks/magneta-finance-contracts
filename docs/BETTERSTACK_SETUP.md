# BetterStack — Uptime Setup

Runbook for setting up BetterStack uptime monitoring on the 3 production sites.

**Free tier reality check** — SSL/TLS expiration monitoring is paywalled (Teams
plan, $25/mo). Until we upgrade, we rely on Certbot's auto-renewal cron (+ the
`certbot renew --dry-run` health check during weekly ops review) for cert health.
We use 3 HTTPS monitors out of the 10 free-tier slots.

## 1. Create the account + team

1. Go to https://betterstack.com/uptime → Sign up with `info@magneta.finance`
2. Create a team named `Magneta Finance`
3. Verify email + set a strong password

## 2. Wire up notification channels

Notification setup in BetterStack is in **two places** (both in the left sidebar,
NOT under Settings):

### 2a — Add Discord as a channel (left sidebar → Integrations)

1. In Discord: Server Settings → Integrations → Webhooks → New Webhook
2. Name it `BetterStack`, channel `#alerts`, copy the Webhook URL
3. In BetterStack: left sidebar → **Integrations** → **Discord** → Paste the webhook URL

### 2b — Create the escalation policy (left sidebar → Escalation policies)

- Click **Create policy**, name it `Magneta Primary`
- **Step 0 min**: Email `info@magneta.finance` + Discord (added in 2a)
- **Step 5 min**: nothing (single-person on-call for now)

Email on `info@magneta.finance` is filled in by default.

Optionally later: SMS via Twilio integration (paid tier only) — only worth it
when you're actively on-call during mainnet launch.

## 3. Create the 6 monitors

Settings → Monitors → New monitor. For each:

| # | Type | URL | Check frequency | Expected status | Keyword check |
|---|---|---|---|---|---|
| 1 | HTTPS | `https://magneta.finance` (= Tokens) | 3m (free tier) | 200 | `Magneta` |
| 2 | HTTPS | `https://app.magneta.finance` (= DEX) | 3m | 200 | `Magneta` |
| 3 | HTTPS | `https://scope.magneta.finance` (= Scope) | 3m | 200 | `Scope` |
| — | ~~SSL~~ | ~~all 3 domains~~ | — | — | **Paid-tier only — deferred** |

**Notes:**
- Free tier only allows 3-minute intervals on HTTPS checks. For 30s you'd need
  the Teams plan ($25/mo). 3m is fine for early ops; tighten later if needed.
- SSL/TLS expiration monitoring is Teams-plan only. Interim workaround:
  `sudo certbot renew --dry-run` as part of weekly ops review on the VPS.
  Let's Encrypt certs are 90-day validity with auto-renewal at 30 days remaining.

For each HTTPS monitor, in **Advanced settings**:
- Request timeout: `10s`
- Confirm after `2` consecutive failures (avoids flapping on one-off 502s)
- Regions: pick 3 diverse ones (EU-Central, US-East, Asia-SE) — multi-region avoids false positives from a single probe
- Keyword check: body must contain the keyword above — detects cases where Next.js returns 200 but the page is broken

## 4. Attach the escalation policy to each monitor

For each of the 3 HTTPS monitors (`magneta.finance`, `app.magneta.finance`,
`scope.magneta.finance`):

- **Edit** the monitor → scroll to **On-call escalation**
- Pick the `Magneta Primary` policy created in step 2b
- **Save changes**

(Skip the dedicated "On-call schedule" feature — it's for rotations between
multiple team members, which we don't have yet. Single-person ops uses the
escalation policy directly.)

## 5. Status page (optional but recommended)

Pages → New public status page:
- Subdomain: `status.magneta.finance` (BetterStack auto-provisions SSL)
- Add the 6 monitors
- Theme: dark, Magneta logo + primary color
- Post to your site footer: `status.magneta.finance`

Publicly visible uptime helps with community trust.

## 6. What triggers an alert

After setup, you'll get an alert for:
- **HTTPS down** — 2+ consecutive failures across regions
- **HTTPS wrong content** — keyword missing (site returned broken HTML)
- **SSL expiring** — cert < 14 days from expiry (gives Certbot time to renew)
- **SSL invalid** — wrong CN, self-signed, chain broken, revoked

## 7. Verification

After creating all monitors:
1. Check each shows a green `200 OK` in the dashboard
2. Manually break one (e.g., `sudo systemctl stop magneta-tokens` on the VPS) for 90s — you should get a Discord + email alert
3. Restart the service — "Resolved" notification should arrive
4. Delete the test incident from the history

## Cost

- Up to 10 monitors: **$0/month** (free tier)
- Going above: Teams plan ($25/mo for 50 monitors, phone/SMS included)
