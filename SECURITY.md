# Security reports

Do not post credentials, agent prompts, or details of an unpatched vulnerability in a public issue. Use the repository's private vulnerability reporting feature when it is enabled. If it is unavailable, ask a maintainer to enable a private reporting channel without disclosing the vulnerability itself.

Include the affected version, a minimal reproduction using synthetic data, and the security impact. Never test against another person's dashboard. Reports and fixes are reviewed before coordinated disclosure.

Give hooks an `INGEST_TOKEN` for sending events and dashboard apps a separate `CLIENT_TOKEN` for reading data and changing session state or settings. Restrict allowed browser origins and rotate credentials after exposure.

Starting with server `0.1.0-alpha.8`, only operators performing a manual projection rebuild need a third secret, `MAINTENANCE_TOKEN`. The server allows `POST /dashboard/admin/rebuild` only when that token is configured and distinct from all other tokens, including the legacy `AUTH_TOKEN`. [Server authentication and setup](server/README.md#connect-an-existing-worker)
