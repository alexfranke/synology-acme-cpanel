# Configuration and Installation Guide

This guide explains how to configure the Synology, Docker container, acme.sh, cPanel API access, and certificate automation.

For an overview of the project, see [README.md](README.md).

---

## 1. Prerequisites

You will need:

- A Synology NAS running DSM 7.x
- Docker installed on the Synology
- A cPanel-hosted account
- Access to the cPanel account
- A cPanel API token
- DNS managed through cPanel
- One or more domains that you want to secure with Let's Encrypt certificates

The hosting account used to develop this project was a shared/legacy cPanel account where the `uapi` command-line utility was not available.

This is why certificate deployment is performed through the cPanel HTTPS API rather than acme.sh's `cpanel_uapi` deploy hook.

---

## 2. Create the Persistent Directory

Create a directory on the Synology for acme.sh's persistent data.

For example:

```text
/volume1/docker/acmesh
```

The directory can be created using File Station or the Synology command line.

The important part is that it is persistent storage outside the Docker container.

The container will mount this directory as:

```text
/acme.sh
```

This means certificates and acme.sh configuration survive container restarts, upgrades, and recreation.

---

## 3. Create the Docker Container

Create a container using:

```text
neilpang/acme.sh:latest
```

Configure a volume mapping:

```text
Host path:       /volume1/docker/acmesh
Container path:  /acme.sh
```

The container needs Internet access because it communicates with:

- Let's Encrypt
- cPanel DNS API
- cPanel SSL API

### Environment Variables

Configure the environment variables required by the cPanel DNS plugin.

For example:

```text
CPANEL_USER=your_cpanel_username
CPANEL_API_TOKEN=your_api_token
CPANEL_Hostname=https://cpanel.example.com:2083
```

The exact environment variable names required by the installed `dns_cpanel` plugin should be verified against the plugin version being used.

---

## 4. Configure cPanel Credentials

Create a cPanel API token with sufficient permissions to:

1. Manage DNS records for the domains being validated.
2. Install SSL certificates on those domains.

Do not put the token directly into the scripts or Git repository.

The deployment script should obtain credentials from environment variables:

```sh
CPUSER="${CPANEL_USER:?CPANEL_USER is not set}"
CPTOKEN="${CPANEL_API_TOKEN:?CPANEL_API_TOKEN is not set}"
HOST="${CPANEL_HOST:?CPANEL_HOST is not set}"
```

Never commit an actual API token to this repository.

If a token is accidentally committed, revoke it and create a new one.

---

## 5. Verify curl

The acme.sh Docker image includes `curl`.

Verify it from the container:

```sh
curl --version
```

A working installation should return the curl version.

---

## 6. Verify cPanel API Access

Before attempting to issue certificates, verify that the cPanel API is accessible.

The cPanel API is normally available on port `2083`:

```text
https://cpanel.example.com:2083
```

The API uses an HTTP Authorization header in this format:

```text
Authorization: cpanel USER:TOKEN
```

For example:

```sh
curl -sS \
  -H "Authorization: cpanel ${CPANEL_USER}:${CPANEL_API_TOKEN}" \
  "${CPANEL_HOST}/execute/SSL/list_certs"
```

A successful response confirms that the token can authenticate to the cPanel API.

---

## 7. Install the Scripts

Copy these files into the persistent `/acme.sh` directory:

```text
/acme.sh/issue-certs.sh
/acme.sh/install-certs.sh
```

From inside the container:

```sh
chmod 700 /acme.sh/issue-certs.sh
chmod 700 /acme.sh/install-certs.sh
```

The scripts are stored in persistent storage so they remain available if the container is recreated.

---

## 8. Configure `install-certs.sh`

The deployment script takes the primary domain as its argument.

It expects these environment variables:

```text
CPANEL_USER
CPANEL_API_TOKEN
CPANEL_HOST
```

The beginning of the script should look like:

```sh
#!/bin/sh

DOMAIN="$1"

if [ -z "$DOMAIN" ]; then
    echo "Usage: $0 domain"
    exit 1
fi

CPUSER="${CPANEL_USER:?CPANEL_USER is not set}"
CPTOKEN="${CPANEL_API_TOKEN:?CPANEL_API_TOKEN is not set}"
HOST="${CPANEL_HOST:?CPANEL_HOST is not set}"
```

The certificate files are expected in the normal acme.sh ECC directory:

```text
/acme.sh/${DOMAIN}_ecc/
```

Specifically:

```text
${DOMAIN}.cer
${DOMAIN}.key
ca.cer
```

For example:

```text
/acme.sh/wiki.example.com_ecc/
├── wiki.example.com.cer
├── wiki.example.com.key
└── ca.cer
```

### Complete `install-certs.sh`

```sh
#!/bin/sh

DOMAIN="$1"

if [ -z "$DOMAIN" ]; then
    echo "Usage: $0 domain"
    exit 1
fi

CPUSER="${CPANEL_USER:?CPANEL_USER is not set}"
CPTOKEN="${CPANEL_API_TOKEN:?CPANEL_API_TOKEN is not set}"
HOST="${CPANEL_HOST:?CPANEL_HOST is not set}"

CERT="/acme.sh/${DOMAIN}_ecc/${DOMAIN}.cer"
KEY="/acme.sh/${DOMAIN}_ecc/${DOMAIN}.key"
CA="/acme.sh/${DOMAIN}_ecc/ca.cer"

if [ ! -f "$CERT" ] || [ ! -f "$KEY" ] || [ ! -f "$CA" ]; then
    echo "ERROR: Certificate files not found for $DOMAIN"
    exit 1
fi

echo "Installing certificate for $DOMAIN..."

curl -sS \
  -H "Authorization: cpanel ${CPUSER}:${CPTOKEN}" \
  --data-urlencode "domain=${DOMAIN}" \
  --data-urlencode "cert=$(cat "${CERT}")" \
  --data-urlencode "key=$(cat "${KEY}")" \
  --data-urlencode "cabundle=$(cat "${CA}")" \
  "${HOST}/execute/SSL/install_ssl"
```

Make it executable:

```sh
chmod 700 /acme.sh/install-certs.sh
```

---

## 9. Why the CA Bundle Matters

The cPanel API expects an appropriate CA bundle.

A certificate may be successfully issued by Let's Encrypt but still fail installation if the supplied CA bundle does not contain the appropriate certificate chain.

The deployment script therefore supplies the `ca.cer` file generated by acme.sh:

```text
/acme.sh/${DOMAIN}_ecc/ca.cer
```

Do not substitute an unrelated CA bundle.

---

## 10. Configure `issue-certs.sh`

The main script issues or renews certificates using Let's Encrypt.

It only calls `install-certs.sh` when the certificate file actually changes.

### Complete `issue-certs.sh`

```sh
#!/bin/sh

issue_and_deploy() {
    DOMAIN="$1"
    shift

    CERT="/acme.sh/${DOMAIN}_ecc/${DOMAIN}.cer"

    OLD_MTIME=$(stat -c %Y "$CERT" 2>/dev/null || echo 0)

    echo ""
    echo "=========================================="
    echo "=== Checking $DOMAIN ==="
    echo "=========================================="

    OUTPUT=$(acme.sh --issue --dns dns_cpanel \
      "$@" \
      --server letsencrypt 2>&1)

    RESULT=$?

    echo "$OUTPUT"

    NEW_MTIME=$(stat -c %Y "$CERT" 2>/dev/null || echo 0)

    # acme.sh actually issued or renewed the certificate.
    if [ "$NEW_MTIME" -gt "$OLD_MTIME" ]; then
        echo "New certificate detected for $DOMAIN."
        echo "Deploying to cPanel..."

        /acme.sh/install-certs.sh "$DOMAIN"
        return $?
    fi

    # Normal acme.sh behavior when renewal is not yet needed.
    if echo "$OUTPUT" | grep -q "Skipping. Next renewal time is"; then
        echo "$DOMAIN is not due for renewal."
        return 0
    fi

    # Anything else with a non-zero status is an actual failure.
    if [ $RESULT -ne 0 ]; then
        echo "ERROR: acme.sh failed for $DOMAIN."
        return $RESULT
    fi

    echo "Certificate unchanged for $DOMAIN."
    return 0
}

issue_and_deploy \
  "example.com" \
  -d example.com \
  -d '*.example.com'

issue_and_deploy \
  "example.net" \
  -d example.net \
  -d '*.example.net'

issue_and_deploy \
  "wiki.example.com" \
  -d wiki.example.com
```

Make it executable:

```sh
chmod 700 /acme.sh/issue-certs.sh
```

---

## 11. Use Let's Encrypt

The script explicitly selects the Let's Encrypt ACME server:

```text
--server letsencrypt
```

For example:

```sh
acme.sh --issue \
  --dns dns_cpanel \
  -d example.com \
  --server letsencrypt
```

The `issue-certs.sh` script does this automatically.

This avoids relying on whichever CA happens to be configured as the current acme.sh default.

---

## 12. Do Not Use `--force` in the Scheduled Script

Do not put:

```text
--force
```

into the normal certificate issuance command.

Without `--force`, acme.sh determines whether the certificate needs to be renewed.

When the certificate is still valid and isn't due for renewal, acme.sh will report something similar to:

```text
Domains not changed.
Skipping. Next renewal time is: ...
Add '--force' to force renewal.
```

That is normal behavior.

`--force` is useful when deliberately testing the renewal and deployment process, but it should not be used for normal scheduled operation.

---

## 13. Configure the First Certificate

Start with one domain.

For example:

```sh
acme.sh --issue \
  --dns dns_cpanel \
  -d wiki.example.com \
  --server letsencrypt
```

The first run may require acme.sh account configuration.

If acme.sh asks for an email address, configure one:

```sh
acme.sh --update-account --accountemail your@email.example
```

---

## 14. Verify the Certificate

After issuance, verify that the expected files exist:

```sh
ls -la /acme.sh/wiki.example.com_ecc/
```

You should see files including:

```text
wiki.example.com.cer
wiki.example.com.key
ca.cer
```

Verify the certificate issuer:

```sh
openssl x509 \
  -in /acme.sh/wiki.example.com_ecc/wiki.example.com.cer \
  -noout \
  -issuer
```

For a Let's Encrypt certificate, the issuer should identify Let's Encrypt.

You can also inspect the CA bundle:

```sh
grep -c "BEGIN CERTIFICATE" \
  /acme.sh/wiki.example.com_ecc/ca.cer
```

The exact number of certificates in the CA bundle may change as certificate chains change.

---

## 15. Test cPanel Installation

Once a certificate has been issued, manually test the deployment script:

```sh
/acme.sh/install-certs.sh wiki.example.com
```

A successful installation should produce a cPanel response indicating that the certificate was successfully installed.

If cPanel reports:

```text
This certificate was already installed on this host.
The system made no changes.
```

that is also a successful result.

It means cPanel already has the same certificate installed.

---

## 16. Test the Complete Script

Run:

```sh
/acme.sh/issue-certs.sh
```

The script should:

1. Check each configured domain.
2. Ask acme.sh to issue or renew its certificate.
3. Detect whether the certificate file changed.
4. Deploy the certificate only if it changed.
5. Skip deployment when the certificate is not due for renewal.

For example, a certificate that is not due should produce output similar to:

```text
=== Checking wiki.example.com ===

Domains not changed.
Skipping. Next renewal time is: 2026-10-19T16:45:57Z

wiki.example.com is not due for renewal.
```

A renewal should look more like:

```text
=== Checking wiki.example.com ===

Certificate renewed.

New certificate detected for wiki.example.com.
Deploying to cPanel...

The certificate was successfully installed on the domain
“wiki.example.com”.
```

---

## 17. Why Check the Certificate Modification Time?

acme.sh can return a non-zero status when it skips a certificate because renewal isn't necessary.

Therefore, checking only:

```sh
if [ $? -eq 0 ]; then
    ...
fi
```

is not enough to determine whether deployment is necessary.

The script records the certificate modification time before running acme.sh:

```sh
OLD_MTIME=$(stat -c %Y "$CERT" 2>/dev/null || echo 0)
```

It then runs acme.sh and checks the modification time again:

```sh
NEW_MTIME=$(stat -c %Y "$CERT" 2>/dev/null || echo 0)
```

If:

```text
NEW_MTIME > OLD_MTIME
```

the certificate changed and should be deployed.

The rule is therefore:

```text
Certificate unchanged → don't deploy
Certificate changed   → deploy to cPanel
```

This avoids unnecessary cPanel API calls.

---

## 18. Add Additional Certificates

Once the first domain works end-to-end, add the other certificates to `issue-certs.sh`.

For example:

```sh
issue_and_deploy \
  "example.com" \
  -d example.com \
  -d '*.example.com'

issue_and_deploy \
  "example.net" \
  -d example.net \
  -d '*.example.net'

issue_and_deploy \
  "wiki.example.com" \
  -d wiki.example.com

issue_and_deploy \
  "another.example" \
  -d another.example \
  -d '*.another.example'
```

Test the script after adding each certificate.

This makes troubleshooting much easier than adding all domains at once.

---

## 19. Multiple Domains and Wildcard Certificates

Each call to `issue_and_deploy` represents one certificate.

For example:

```sh
issue_and_deploy \
  "example.com" \
  -d example.com \
  -d '*.example.com'
```

requests one certificate containing:

```text
example.com
*.example.com
```

The wildcard argument must be quoted so the shell does not interpret `*` as a filename wildcard.

The first argument is the primary domain and determines the acme.sh certificate directory.

For example:

```text
/acme.sh/example.com_ecc/
```

Multiple certificates can therefore be configured independently.

---

## 20. Configure the Docker Container Command

Once `issue-certs.sh` has been tested, configure the Docker container's command to execute:

```text
/acme.sh/issue-certs.sh
```

The acme.sh Docker image has its own entrypoint. The command supplied to the container is passed through to that entrypoint.

The important result is that starting the container runs:

```text
/acme.sh/issue-certs.sh
```

and the container exits when the script finishes.

Do not configure a restart policy that continuously restarts the container.

The container is intended to be a short-lived job.

---

## 21. Configure Synology Task Scheduler

Once manual execution is working, configure DSM Task Scheduler.

Go to:

**Control Panel → Task Scheduler → Create → Scheduled Task → User-defined script**

Choose an appropriate schedule, such as once per night.

Use:

```sh
docker start YOUR_ACMESH_CONTAINER_NAME
```

Replace:

```text
YOUR_ACMESH_CONTAINER_NAME
```

with the name of the existing acme.sh container.

The Task Scheduler should **start the existing container**, not create a new one.

This is important because the existing container already contains:

- the correct Docker image
- the persistent volume mapping
- the environment variables
- the certificate configuration
- the credentials
- the command

---

## 22. Container Lifecycle

The intended lifecycle is:

```text
Container stopped
       │
       ▼
Task Scheduler
       │
       ▼
docker start
       │
       ▼
issue-certs.sh
       │
       ├── Check certificate #1
       ├── Check certificate #2
       ├── Check certificate #3
       └── Check certificate #N
       │
       ▼
Container exits
```

There is no need for the container to remain running between checks.

This also avoids using the acme.sh container's built-in daemon/cron mode.

Synology Task Scheduler is responsible for scheduling instead.

---

## 23. Recommended Schedule

Running the task once per night is sufficient for most installations.

For example:

```text
Every day
03:00
```

There is no need to run it every few minutes because acme.sh already knows when certificates need renewal.

Running it nightly provides a safety margin in case a renewal fails on one particular day.

---

## 24. Troubleshooting

### Certificate Isn't Being Renewed

Look for:

```text
Skipping. Next renewal time is:
```

This normally means everything is working and the certificate isn't due yet.

Do not add `--force` to the permanent script.

For a deliberate test, `--force` can be used manually.

---

### cPanel Says the Certificate Chain Is Invalid

If cPanel reports an error such as:

```text
The system did not find the root certificate that corresponds
to the supplied Certificate Authority Bundle's intermediate certificate.
```

verify that the deployment script is sending:

```text
ca.cer
```

from the same acme.sh certificate directory as the certificate.

For example:

```text
/acme.sh/example.com_ecc/example.com.cer
/acme.sh/example.com_ecc/example.com.key
/acme.sh/example.com_ecc/ca.cer
```

Do not substitute an unrelated CA bundle.

---

### `uapi` Is Not Found

This is expected on some shared/legacy cPanel accounts.

The standard acme.sh `cpanel_uapi` hook requires the `uapi` executable.

This project intentionally bypasses that requirement by using:

```text
curl
  ↓
cPanel HTTPS API
  ↓
SSL::install_ssl
```

---

### Certificate Already Installed

cPanel may report:

```text
This certificate was already installed on this host.
The system made no changes.
```

This is not an error.

It means the certificate currently installed in cPanel is already the same certificate being submitted.

---

### Script Can't Find Certificate Files

Check:

```sh
ls -la /acme.sh/example.com_ecc/
```

The expected files are:

```text
example.com.cer
example.com.key
ca.cer
```

If the directory doesn't exist, the certificate has not yet been issued for that primary domain.

---

### The Container Immediately Restarts

Check the container's restart policy.

It should be configured so that the container does not automatically restart after the script exits.

Synology Task Scheduler should be responsible for starting it.

---

## 25. Security Checklist

Before putting the project into production:

- [ ] API token is not stored in Git.
- [ ] Private keys are not stored in Git.
- [ ] `/acme.sh` is persistent.
- [ ] `install-certs.sh` obtains credentials from environment variables.
- [ ] Docker container has no unnecessary restart policy.
- [ ] `--force` has been removed from the scheduled script.
- [ ] At least one certificate has been tested end-to-end.
- [ ] cPanel API installation has been tested.
- [ ] Synology Task Scheduler can start the container successfully.

---

## 26. Recommended Repository Layout

The Git repository should contain the scripts and documentation, but not the live acme.sh state:

```text
synology-acme-cpanel/
│
├── README.md
├── CONFIGURATION.md
├── LICENSE
├── .gitignore
│
├── scripts/
│   ├── issue-certs.sh
│   └── install-certs.sh
│
└── examples/
    └── issue-certs.example.sh
```

The live Synology directory is separate:

```text
/volume1/docker/acmesh/
```

and contains:

```text
/acme.sh/
├── issue-certs.sh
├── install-certs.sh
├── account/
├── ca/
├── dnsapi/
├── deploy/
├── example.com_ecc/
└── ...
```

This separation keeps production certificates, private keys, and ACME account data out of the Git repository.

---

## 27. Final Architecture

The completed system consists of four pieces.

### acme.sh

Handles:

- ACME account management
- Let's Encrypt communication
- DNS-01 validation
- Certificate issuance
- Renewal timing

### `issue-certs.sh`

Handles:

- Checking all configured domains
- Requesting renewals
- Detecting actual certificate changes
- Invoking deployment only when necessary

### `install-certs.sh`

Handles:

- Reading certificate files
- Authenticating to cPanel
- Calling `SSL::install_ssl`
- Installing the certificate in cPanel

### Synology Task Scheduler

Handles:

- Periodically starting the existing Docker container

The resulting system is:

```text
             Synology
                 │
        Task Scheduler
                 │
          docker start
                 │
                 ▼
       ┌─────────────────┐
       │ acme.sh Docker  │
       │    container    │
       └────────┬────────┘
                │
        issue-certs.sh
                │
        ┌───────┴────────┐
        │                │
    not due           renewed
        │                │
       skip              ▼
                 install-certs.sh
                         │
                         ▼
                    cPanel API
                         │
                         ▼
                   HTTPS enabled
```

The container then exits and remains stopped until the next scheduled run.
