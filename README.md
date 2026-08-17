# TAK Server Setup Scripts

Scripts to automate a dockerised TAK Server deployment for local development and testing and configure the parts of TAK Server setup that are normally manual: database bootstrapping, self-signed CA + cert generation, and admin/client provisioning.

> Inspired by [Cloud-RF/tak-server](https://github.com/Cloud-RF/tak-server)

## Prerequisites

- Docker Engine and docker compose
- A TAK Server docker release unpacked into `.tak-download/` (see [Directory layout](#directory-layout) below). Get this from [TAK.gox](https://tak.gov/products/tak-server)

> This repo does not include the TAK Server binaries themselves.

### Tested versions

These scripts are only verified against the releases below. Other releases may work, but the layout of `CoreConfig.xml`, the bundled Dockerfiles, and the `makeCert.sh`/`UserManager` tooling do change between versions, so treat anything untested as unknown.

| Release        | Variation  | Filename                              | Status     | Notes                                                 |
| -------------- | ---------- | ------------------------------------- | ---------- | ----------------------------------------------------- |
| 5.7-RELEASE-43 | unhardened | `takserver-docker-5.7-RELEASE-43.zip` | ✅ Verified | Reference version the scripts were developed against. |

Hardened releases are **not** currently supported, they ship different provisioning steps that `setup.sh` doesn't account for.

## Setup server

```bash
sh ./setup.sh <server-url>
```

The `setup.sh` script builds and starts both tak server and tak database containers, then fully provisions the server:

1. Waits for Postgres to accept connections.
2. Waits for the `tak` container to generate `CoreConfig.xml` (it only ships `CoreConfig.example.xml` and the server's own "config" microservice writes the real file on first boot).
3. Sets a random password for the `martiuser` Postgres role in `CoreConfig.xml`, then restarts `db` so it (re)creates that role with the matching password.
4. Restarts `tak` to pick up the new DB password.
5. Generates a fresh self-signed CA and certs: a `takserver` server cert, plus an `admin` client cert.
6. Restarts `tak` again so the server picks up its new TLS/JWT keystore (`takserver.jks`), the server won't fully start without it.
7. Adds `admin` as a TAK user (`ROLE_ADMIN`) with both a password login and the generated `admin` client certificate, and runs a schema upgrade.

Run it with a reachable address as the first argument to also fix up the URLs TAK Server bakes into `CoreConfig.xml` (see below):

```bash
sh ./setup.sh 203.0.113.10          # a public/private IP
sh ./setup.sh takserver.example.com # or a DNS name
```

Without an argument, those URLs are left pointing at `localhost`, which only works if TAK clients connect from the same machine the server runs on.

```bash
sh ./setup.sh  # defaults to 'localhost'
```

### How the address is used

TAK Server auto-detects its own Docker bridge IP (e.g. `172.x.x.x`) on first boot and writes it into two `CoreConfig.xml` fields:

- `<urladd host="...">`: used in generated links (e.g. enterprise sync package downloads).
- `<federation-server webBaseUrl="...">`: used for federation.

That internal IP is unreachable from outside the Docker host. Passing a real address to `setup.sh` rewrites both fields and restarts the server so the change takes effect.

## Directory layout

| Path                    | Purpose                                                                                                                                                                                                                                                                                                        |
| ----------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `.tak-download/`        | The pristine, unpacked TAK Server release. Never modified by any script, treat as read-only. This should be a `docker` folder with the compose files, and a `tak` folder with the tak server files                                                                                                             |
| `.runtime_do_not_edit/` | The actual working copy bind-mounted into both containers as `/opt/tak` (plus the two Dockerfiles). Gets written to at runtime (generated `CoreConfig.xml`, certs, logs, DB schema). **Don't hand-edit anything in here**, `setup.sh` will blow it away and re-copy from `.tak-download/` each time it is run. |
| `.data/db/`             | Postgres data directory bind mount.                                                                                                                                                                                                                                                                            |
| `certs/`                | Client credentials extracted for distribution, created by `get-certs.sh` / `create-client-cert.sh` (see below). Safe to delete/regenerate any time. Also gets removed when (re)running `setup.sh`.                                                                                                             |

## Scripts

| Script                                | What it does                                                                                                                                           |
| ------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `setup.sh [server-address]`           | Full provisioning — see [Setup server](#setup-server). Safe to re-run; each step is idempotent or restart-driven.                                      |
| `get-certs.sh`                        | Extracts the `admin` client cert (`admin.p12`), the CA (`root-ca.pem`), and the CA as a PKCS12 truststore (`truststore-root.p12`) into `certs/admin/`. |
| `create-client-cert.sh <client-name>` | Generates a new client cert (`./makeCert.sh client <client-name>` inside the container) and extracts it the same way into `certs/<client-name>.p12`.   |

Both cert-extraction scripts use `docker compose cp`, not a raw file copy. This writes the extracted files as _your_ user, not root, so they're immediately safe to `scp` off a remote server.

> **Never `scp` directly from `.runtime_do_not_edit/tak/certs/files/`** as they are root-owned on native Linux Docker hosts and a non-root SSH user will get `Permission denied`.

## Env Vars

There are several optional variables that can be set via a `.env` file for certificate creation and user credentials.

### Certs

Set details for the certificates that will be generated. If not provided the tak server defaults will be used:

- COUNTRY=
- STATE=
- CITY=
- ORGANIZATIONAL_UNIT=

### Credentials

Set a password for the admin user and db user. If not provided, `setup.sh` will generate random passwords and print them to the console.

- DB_USER_PASSWORD=
- ADMIN_USER_PASSWORD=

### Example `.env` file

```
# CERT
COUNTRY=GB
STATE=YORKSHIRE
CITY=YORK
ORGANIZATIONAL_UNIT=ORG

# CREDS
DB_USER_PASSWORD=SecretP@ssword1
ADMIN_USER_PASSWORD=SecretP@ssword2
```

## Connecting clients

### Admin web UI (`https://<server>:8443`)

Port 8443 requires mutual TLS. The browser must present a client certificate before the TLS handshake even completes (this is enforced by TAK Server itself, not something specific to this setup).

Run `./get-admin-cert.sh`, then get `certs/admin/admin.p12` and `certs/admin/root-ca.pem` onto whatever machine's browser you'll use. Fully quit and reopen the browser, then visit `https://<server>:8443` and select the `admin` cert when prompted. Admin can also log in with username/password (`admin` / `SecretP@ssword1`, set by `setup.sh`) once past the TLS handshake.

### ATAK / WinTAK / iTAK clients (port 8089)

1. `./create-client-cert.sh <name>` (e.g. `device123`) to generate a dedicated identity per device.
2. Transfer `certs/<name>.p12` and `certs/admin/truststore-root.p12` to the device.
3. In the client's server setup:
   - address = your server's reachable host/IP
   - port = `8089`
   - client cert = `<name>.p12` (password `atakatak`, unless changed)
   - truststore = `truststore-root.p12` (password `atakatak`, unless changed)

Port 8089 (`stdssl`) is the CoT streaming input clients actually use for data.

## Deploying to a remote server (e.g. Ubuntu)

Everything above works the same on a remote Linux host, with a few things to keep in mind:

- **Open the ports you need** in the firewall/security group, `8443` for the admin UI, `8089` for TAK clients, others as needed.
- **Pass the server's real address to `setup.sh`**, `localhost` only works for same-machine clients.
- **File ownership**: the containers write certs/config/logs as root. `reset.sh` and the cert-extraction scripts already account for this (via a throwaway root container and `docker compose cp`, respectively) — just don't bypass them with raw `rm`/`cp`/`scp` against `.runtime_do_not_edit/`.
- **Cert/credential distribution to your own machine**: pull files from `certs/<name>/` (not the raw bind mount) via `scp`, as described above.

## Security note

This setup is designed to be used for development and testing purposes. This setup generates its own self-signed CA per environment and uses TAK's own script defaults (e.g. `atakatak` as the default cert password) unless overridden via the `CAPASS`/`PASS` environment variables. Fine for local development and testing; change these defaults before using this for anything beyond that.
