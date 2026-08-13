# Security Policy

Thank you for helping keep this project and its users safe.

## Scope

This repository is a **demo / learning lab** for Azure Monitor and Microsoft
Sentinel. It is intended to be deployed into **your own** Azure subscription for
demos, microhacks, and hackathons. It is **not** a production-ready solution and
should not be used as-is to protect real workloads or sensitive data.

## What this repo deliberately does *not* contain

- No secrets, credentials, subscription IDs, tenant IDs, or connection strings
  are committed. All per-user values live in `lab.config.json` and its derived
  files, which are gitignored. See the **Bootstrap** section of the
  [README](README.md).
- If you ever find a real secret committed here, please report it (see below)
  and **do not** open a public issue containing the secret.

## Reporting a vulnerability

If you discover a security issue in this repository (for example, an insecure
default in the IaC, a script that leaks credentials, or an accidentally
committed secret):

1. **Do not** open a public GitHub issue for anything that exposes a secret or
   a working exploit.
2. Instead, use **GitHub's private vulnerability reporting** for this repository
   (Repository → **Security** tab → **Report a vulnerability**), or contact the
   maintainer directly through their GitHub profile.

Please include:

- A description of the issue and its impact.
- Steps to reproduce.
- The affected file(s) / line(s) if known.

We aim to acknowledge reports within a few business days. Because this is a
community demo project maintained on a best-effort basis, please allow
reasonable time for a fix before any public disclosure.

## Your responsibility when deploying

- Deploy only into a subscription you control and are authorized to use.
- The repo ships a subscription guardrail (`.azure-target.json`) — configure it
  so deployments cannot run against the wrong subscription.
- Tear down the lab (`scripts/teardown.ps1`) when you are done to avoid leaving
  internet-exposed demo resources running.
- Rotate any passwords or service-principal secrets you generate while using the
  RBAC demo scripts, and never commit the generated files.
