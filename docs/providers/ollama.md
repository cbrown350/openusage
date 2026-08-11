# Ollama

Tracks [Ollama Cloud](https://ollama.com/pricing) usage quotas — the rolling session and weekly limits
shown on your Ollama account settings page.

## What it tracks

| Metric | Meaning |
|---|---|
| Session | 5-hour rolling window usage (percentage) |
| Weekly | 7-day rolling window usage (percentage) |

When Ollama reports your plan (Free / Pro / Max / Team), OpenUsage shows it beside the provider name.

## Where credentials come from

Ollama has no companion CLI/app that stashes a cloud-session credential in a known spot, and Ollama does
not yet document a cloud quota API — so OpenUsage reads your **web session cookie** (the
`__Secure-session` cookie your browser uses on ollama.com) and reads the same settings page you would.
It checks these sources, in order:

1. `~/.config/openusage/ollama.json` — `{"apiKey":"…"}` (the file Settings writes to)
2. The `OLLAMA_SESSION_COOKIE` environment variable (the bare cookie value)
3. The `OLLAMA_COOKIE` environment variable (a full `Cookie:` header; the `__Secure-session` value is
   pulled out automatically)

You can also add and rotate the cookie from **Settings → API Keys** (labeled **Session Key**) without
touching a file. Either way, nothing leaves your Mac except the one request to your own account's
settings page.

> **Heads-up:** because Ollama offers no official usage API, this provider scrapes the account settings
> page. That works today but is an unofficial contract — if Ollama redesigns the page the meters may
> temporarily show a parse error until OpenUsage is updated. Ollama has since exposed an undocumented
> `GET /api/usage`, and OpenUsage uses it with an `OLLAMA_API_KEY` when no session cookie is set. The
> scrape stays the primary source because that endpoint is not public yet, returns no reset times, and
> Ollama has said the data isn't final.

## Setup

1. Sign in to [ollama.com](https://ollama.com) in your browser.
2. Open DevTools → **Application** → **Cookies** → `https://ollama.com`, and copy the value of the
   `__Secure-session` cookie.
3. Paste it into OpenUsage via **Settings → API Keys** (the Session Key field), **or** export it:

```bash
export OLLAMA_SESSION_COOKIE="YOUR_SESSION_COOKIE_VALUE"
```

4. Ollama appears on the dashboard and (after you star a metric) the menu bar on the next refresh.

## Multiple accounts

If you use more than one Ollama Cloud login, add each one as a separate **account** and OpenUsage gives
each its own card, with its own session and weekly limits. Unlike Claude (which discovers extra logins on
this Mac), Ollama accounts are ones you add yourself: open the Ollama card's **Customize** view and use
**Add Account**, pasting that login's `__Secure-session` cookie.

Each card is named from the account's username on ollama.com (for example, "ollama_user"). If the name
can't be read, it falls back to **Account 1**, **Account 2**, and so on, numbered by position — so
removing an account renumbers the ones after it. Rename an account from the account list (the pencil
action) to call it whatever you like. Removing an account deletes it for good; it won't come back on its
own. Your first account is the default `ollama` card, and a fresh cookie you add to
`~/.config/openusage/ollama.json` (or via Settings) is folded in as an account on the next launch.

In the [CLI](../cli.md) and [local API](../local-http-api.md), additional accounts appear under ids like
`ollama@1` and `ollama@2`, alongside the default `ollama`.

## Under the hood

- `GET https://ollama.com/settings` with `Cookie: __Secure-session=…`. The returned HTML is parsed for
  the first two `N% used` values (Session, then Weekly), the `data-time` reset timestamps (or relative
  "Resets in …" text as a fallback), and the plan label that follows the "Cloud Usage" heading.
- Fallback when only an `OLLAMA_API_KEY` is present: `GET https://ollama.com/api/usage`
  (live but undocumented; reports each window as a used-fraction and carries no reset times).

A logged-out cookie follows the redirect to the login page (no "Cloud Usage" section), which OpenUsage
reports as an expired session rather than blank meters. Missing usage values are reported as an invalid
response instead of being shown as zero.

## Troubleshooting

- **"No Ollama session cookie"** — add the `__Secure-session` cookie in Settings → API Keys, or export
  `OLLAMA_SESSION_COOKIE`.
- **"Ollama session expired"** — the cookie no longer authenticates (you were redirected to the login
  page). Sign in to ollama.com again and re-copy the cookie.
- **"Could not parse Ollama Cloud usage from settings"** — you're signed in, but the settings page shape
  changed and OpenUsage couldn't find the meters. Update OpenUsage; the meters return once it recognizes
  the new layout.
