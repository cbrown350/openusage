# Qwen

Tracks [Qwen Cloud](https://home.qwencloud.com) **Token Plan** usage — the rolling 5-hour and weekly
token quotas shown on the individual token-plan billing page.

## What it tracks

| Metric | Meaning |
|---|---|
| 5-Hour Window | Rolling 5-hour token usage (percentage) |
| Weekly | Rolling 7-day token usage (percentage) |

When Qwen reports your plan tier (Lite / Standard / Pro), OpenUsage shows it beside the provider name.

## Where credentials come from

Qwen's billing console has no companion CLI/app that stashes a credential in a known spot, so OpenUsage
reads your **web session ticket** (the `login_qwencloud_ticket` SSO cookie your browser uses on
home.qwencloud.com). It checks these sources, in order:

1. `~/.config/openusage/qwen.json` — `{"apiKey":"…"}` (the file Settings writes to)
2. The `QWEN_SESSION_COOKIE` environment variable (the bare ticket value)
3. The `QWEN_COOKIE` environment variable (a full `Cookie:` header; the `login_qwencloud_ticket` value is
   pulled out automatically)

You can also add and rotate the ticket from **Settings → API Keys** (labeled **Session Key**) without
touching a file. Nothing leaves your Mac except the same requests the billing console makes with your
own session.

## Setup

1. Sign in to the [Qwen Cloud billing console](https://home.qwencloud.com/billing/subscription/token-plan-individual)
   in your browser.
2. Open DevTools → **Application** → **Cookies** → `https://home.qwencloud.com`, and copy the value of
   the `login_qwencloud_ticket` cookie.
3. Paste it into OpenUsage via **Settings → API Keys** (the Session Key field), **or** export it:

```bash
export QWEN_SESSION_COOKIE="YOUR_TICKET_VALUE"
```

4. Qwen appears on the dashboard and (after you star a metric) the menu bar on the next refresh.

## Under the hood

The billing console is a single-page app that fetches data through Alibaba Cloud's internal gateway, so
OpenUsage makes the same two-step call the page does:

1. `GET https://home.qwencloud.com/billing/subscription/token-plan-individual` with
   `Cookie: login_qwencloud_ticket=…` — lifts the CSRF `SEC_TOKEN` embedded in the page.
2. `POST https://cs-data.qwencloud.com/data/api.json` (with the ticket cookie and that token) for:
   - **usage** — the 5-hour and weekly windows as used-fractions, with epoch-millisecond reset times;
   - **subscription** — the plan tier (`specCode`), fetched best-effort for the plan name only.

A ticket that no longer authenticates lands on the login page (no `SEC_TOKEN`), which OpenUsage reports
as an expired session. Missing usage values are reported as an invalid response instead of being shown
as zero.

## Troubleshooting

- **"No Qwen session ticket"** — add the `login_qwencloud_ticket` cookie in Settings → API Keys, or
  export `QWEN_SESSION_COOKIE`.
- **"Qwen session expired"** — the ticket no longer authenticates. Sign in to the billing console again
  and re-copy the cookie.
- **"Could not parse Qwen Token Plan usage"** — you're signed in, but the usage response didn't carry the
  expected values. Refresh; if it persists the console's data format may have changed and OpenUsage needs
  an update.
