# Security reports

Do not post credentials, agent prompts, or details of an unpatched vulnerability in a public issue. Use the repository's private vulnerability reporting feature when it is enabled. If it is unavailable, ask a maintainer to enable a private reporting channel without disclosing the vulnerability itself.

Include the affected version, a minimal reproduction using synthetic data, and the security impact. Never test against another person's dashboard. Reports and fixes are reviewed before coordinated disclosure.

Use separate ingest and client tokens, restrict allowed browser origins, and rotate credentials after exposure. A client token authorizes state changes and administrative operations as well as reads.
