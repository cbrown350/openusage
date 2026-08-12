# Modal

Tracks [Modal](https://modal.com) serverless-compute billing — how much of your monthly spend limit
and free credit grant you've used. Works for every plan tier, including Starter: these are the same
readouts the dashboard's usage page shows, not the `modal.billing` API (which is Team/Enterprise only).

## What it tracks

| Metric | Meaning |
|---|---|
| Spend | Dollars used this billing cycle against your spend limit |
| Credits | Dollars remaining of your monthly credit grant |

The Spend meter resets at the start of your next billing cycle, shown on the row. When Modal reports
your plan type (Starter / Team / Enterprise), OpenUsage shows it beside the provider name.

## Where credentials come from

Modal's CLI stores its token in `~/.modal.toml`, but that is a gRPC credential for the SDK — the
usage/billing values live behind the dashboard's cookie-based REST API, which the CLI credential cannot
reach. So OpenUsage reads your **web dashboard session** (the `modal-session` cookie your browser uses
on modal.com). It checks these sources, in order:

1. `~/.config/openusage/modal.json` — `{"apiKey":"…"}` (the file Settings writes to)
2. The `MODAL_SESSION_COOKIE` environment variable (the bare cookie value)
3. The `MODAL_COOKIE` environment variable (a full `Cookie:` header; the `modal-session` value is
   pulled out automatically)

You can also add and rotate the cookie from **Settings → API Keys** (labeled **Session Key**) without
touching a file. Nothing leaves your Mac except the same requests the dashboard makes with your own
session.

## Setup

1. Sign in to the [Modal dashboard](https://modal.com) in your browser.
2. Open DevTools → **Application** → **Cookies** → `https://modal.com`, and copy the value of the
   `modal-session` cookie.
3. Paste it into OpenUsage via **Settings → API Keys** (the Session Key field), **or** export it:

```bash
export MODAL_SESSION_COOKIE="YOUR_COOKIE_VALUE"
```

4. Modal appears on the dashboard on the next refresh. Because this reads a cookie rather than a
   credential the CLI leaves behind, the provider is not auto-enabled on first launch — add the cookie
   and it turns on.

## Under the hood

The dashboard is a single-page app that reads its billing data from a plain JSON REST API (not the
gRPC the CLI/SDK use), authenticated with the `modal-session` cookie. OpenUsage makes the same two
calls:

1. `GET https://modal.com/api/user/workspaces` — the workspace billing object
   (`cycleUsage`, `grantedCycleCredits`, `cycleSpendLimit`, `planType`, `username`).
2. `GET https://modal.com/api/workspaces/{username}/billing-cycles` — `{cycles:[{start,end,isCurrent}]}`
   for the reset date the workspace object doesn't carry; routed by the workspace username, and fetched
   best-effort (a failure just means no reset date, never blank meters).

The Spend meter matches the dashboard's own math (`cycleUsage` of `cycleSpendLimit`); Credits is the
grant minus what's been used, floored at zero. An expired cookie is answered with a clean JSON `401`,
which OpenUsage surfaces as "session expired" rather than a parse error.

## Troubleshooting

- **"No Modal session cookie"** — add the `modal-session` cookie in Settings → API Keys, or export
  `MODAL_SESSION_COOKIE`.
- **"Modal session expired"** — the cookie no longer authenticates. Sign in to the dashboard again and
  re-copy the cookie.
- **"Could not parse Modal usage"** — you're signed in, but the workspaces response didn't carry the
  expected values. Refresh; if it persists, Modal's API shape may have changed and OpenUsage needs an
  update.
