# Security Policy

Thank you for helping keep the **Hub for TIBCO Flogo®** and its community safe.

This repository contains **illustrative samples, demos, and Claude Code skills** for
TIBCO Flogo® Enterprise. The code here is provided **as-is**, for learning and
demonstration purposes. It is not a supported product, and the samples are not
intended to be deployed to production without review and hardening.

If you have purchased commercial support for TIBCO Flogo®, product security issues
in the shipping product should be raised through your TIBCO Support entitlement at
[https://support.tibco.com/](https://support.tibco.com/). This policy covers the
**contents of this repository** only.

---

## Reporting a Vulnerability

**Please do not open a public GitHub issue for security vulnerabilities.**

Report vulnerabilities **privately** using GitHub's built-in private reporting:

1. Go to the **Security** tab of this repository.
2. Click **Report a vulnerability** (this opens a private GitHub Security Advisory).
3. Provide as much detail as you can:
   - A description of the issue and its potential impact.
   - The file(s), sample, demo, or skill affected.
   - Step-by-step instructions to reproduce.
   - Any suggested remediation, if you have one.

If you are unable to use GitHub's private advisory feature, please contact the
maintainers of this repository directly.

We will acknowledge your report, keep you updated on our progress, and coordinate a
disclosure timeline with you. Please give us a reasonable amount of time to
investigate and remediate before any public disclosure.

---

## Credentials, Secrets, and Sample Data

All sample and demo applications in this repository ship with **placeholder
credentials only**. You will see values such as:

- `sk-REPLACE-WITH-YOUR-OPENAI-KEY` (OpenAI/LLM API key)
- `sk-ant-REPLACE-WITH-YOUR-ANTHROPIC-KEY` (Anthropic API key)
- `SET_YOUR_DB_PASSWORD`, `SET_YOUR_EMAIL_APP_PASSWORD`
- `SET_YOUR_AUTH_TOKEN`, `SET_YOUR_CLIENT_SECRET`, `SET_YOUR_JWT_SECRET`
- `SET_YOUR_...` (any other credential)

These are **intentional placeholders**, not real secrets. To run any sample you
**must supply your own credentials** via **App Properties**, **environment
variables**, or your platform's secret-management mechanism.

> ⚠️ **Scrubbing secrets from a `.flogo` app — do NOT use `SECRET:YOURKEY`.**
> When neutralizing a credential for public release, use a **plain-string
> placeholder from the list above** (no prefix). Do **not** write `SECRET:YOURKEY`
> (or any `SECRET:<non-ciphertext>`): the Flogo designer AES-decrypts everything
> after the `SECRET:` prefix on load, so a fake ciphertext makes the app fail to
> render — *"Can't render this application… An error occurred while attempting to
> decrypt secrets."* Placeholders live in top-level app `properties` (`"value"`,
> keyed by the sibling `name`) or inline in connection settings under `apiKey` /
> `authToken`. Edit them as **surgical text replacements** (never round-trip the
> file through a JSON formatter — it reflows the whole file), and if the app is
> open in the Flogo designer, close/Discard its tabs first or its Sync will write
> the original encrypted blob back over your scrub.

**Never commit real secrets, credentials, API keys, tokens, connection strings,
or customer data to this repository** — in samples, demos, skills, tests, or
documentation.

If you discover a **real credential that appears to have been committed by
mistake**, please **report it privately** using the process above rather than
opening a public issue. The maintainers will treat it as a security incident,
remove it from the codebase, and arrange for the exposed credential to be
**rotated/revoked**.

---

## Supported Scope

- This repository is a collection of **illustrative samples and demos**, provided
  **as-is** with no warranty (see [`LICENSE`](./LICENSE), Apache-2.0).
- There is no formal "supported versions" matrix; fixes are applied to the current
  `master` branch.
- Security reports about the samples, demos, and skills in this repository are
  welcome and will be addressed on a best-effort basis.

Thank you for contributing to the security of the Flogo® community.
