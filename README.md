# Synology ACME cPanel

Automatically obtain and deploy Let's Encrypt TLS certificates for cPanel-hosted domains using a Synology NAS, Docker, and [acme.sh](https://github.com/acmesh-official/acme.sh).

This project is designed for situations where:

- Certificates are managed from a Synology NAS.
- Certificates are issued using DNS-01 validation through cPanel.
- The hosting account is a shared or legacy cPanel account without AutoSSL.
- SSH access to the cPanel server is unavailable or undesirable.
- The cPanel `uapi` command-line utility is unavailable.
- Certificates need to be installed through the cPanel API.
- The Synology NAS should not need to keep a Docker container running continuously.

## How It Works

Synology Task Scheduler periodically starts an existing, configured acme.sh Docker container:

```text
┌─────────────────────────────┐
│ Synology Task Scheduler     │
│                             │
│ docker start acme.sh        │
└──────────────┬──────────────┘
               │
               ▼
┌─────────────────────────────┐
│ acme.sh Docker container    │
│                             │
│ issue-certs.sh              │
└──────────────┬──────────────┘
               │
               ▼
        acme.sh / Let's Encrypt
               │
               │ certificate changed?
               │
          ┌────┴────┐
          │         │
         no        yes
          │         │
          ▼         ▼
        skip    install-certs.sh
                      │
                      ▼
                cPanel API
                      │
                      ▼
                SSL installed
