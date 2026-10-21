# sslscan2

**A fork of [sslscan](https://github.com/rbsec/sslscan) built for scanning many hosts and getting straight to the findings.**

Upstream `sslscan` is great for a deep look at one server. `sslscan2` keeps all of that and adds *targeted check flags* and a *one-line-per-host output mode*, so you can sweep a whole estate for a single class of weakness and get output you can read, `grep`, or diff.

---

## What's different from upstream

| | Upstream sslscan | sslscan2 |
|---|---|---|
| Output | Full multi-section report per host | Optional `--oneline`: one line per host, **only hosts with findings** |
| Scope | Runs every check | `--oneline` alone runs the protocol, weak cipher and certificate checks; add filters to narrow it |
| Multi-host | Supported via `--targets` | Same, but paired with silent-when-clean output for large sweeps |
| Build | Makefile | Makefile **plus** `build.sh` with cross-compilation (Linux amd64/arm64, Windows x86-64) |
| OpenSSL | System or static | Static build recommended; **OpenSSL 3.5.0 (LTS) minimum** |

Everything else from upstream still works as normal.

---

## Quick start

```bash
# Every check in one pass: protocols, weak ciphers and certificates
./sslscan --oneline --targets=ssl.hosts

# Which hosts still speak TLS 1.0?
./sslscan --tls10 --oneline --targets=ssl.hosts

# Which hosts offer 3DES?
./sslscan --3des --oneline --targets=ssl.hosts

# Self-signed or untrusted certificates, in one pass
./sslscan --cert-self-signed --cert-untrusted --oneline --targets=ssl.hosts

# Hosts that accept insecure legacy renegotiation (CVE-2009-3555)
./sslscan --insecure-reneg --oneline --targets=ssl.hosts
```

Targets can be `host` or `host:port`, one per line in the file.

---

## New options

Filter flags restrict the scan to just that check. **They can be combined**, and each one you add widens the set of checks that run. With `--oneline` and **no** filter flags at all, every check below runs: the supported protocols, all weak ciphers, and all certificate conditions.

### Protocol checks

| Flag | Checks for |
|---|---|
| `--ssl2` | SSLv2 enabled |
| `--ssl3` | SSLv3 enabled |
| `--tls10` | TLSv1.0 ciphers |
| `--tls11` | TLSv1.1 ciphers |
| `--tls12` | TLSv1.2 ciphers |
| `--tls13` | TLSv1.3 ciphers |
| `--tlsall` | TLS ciphers, all versions |

### Renegotiation check

| Flag | Checks for |
|---|---|
| `--insecure-reneg` | Insecure legacy renegotiation accepted (CVE-2009-3555); aliases `--insecure-renegotiation`, `--reneg` |

This check is **opt-in** even with `--oneline` (unlike the other filters): because
it needs an extra TLS 1.0 connection per host and can be slow on large target
lists, plain `--oneline` does not run it.

### Weak cipher checks

| Flag | Checks for |
|---|---|
| `--rc4` | RC4 ciphers |
| `--3des` | Triple-DES (3DES) ciphers |
| `--des` | Single-DES ciphers |
| `--anon` | Anonymous (no authentication) ciphers |
| `--dh1024` | DHE ciphers with weak (<= 1024 bit) DH parameters |
| `--export-ciphers` | Export-grade (40/56-bit) ciphers (FREAK/Logjam-era; alias `--export`) |

### Certificate checks

| Flag | Checks for |
|---|---|
| `--cert-md5` | MD5-signed certificates |
| `--cert-sha1` | SHA-1-signed certificates |
| `--cert-short-rsa` | RSA keys shorter than 2048 bits |
| `--cert-self-signed` | Self-signed certificates |
| `--cert-untrusted` | Certificates not trusted by the system CA store |
| `--cert-expired` | Expired (or not yet valid) certificates |
| `--cert-expiring` | Certificates expiring within 30 days |
| `--cert-expiring-days=N` | Certificates expiring within *N* days |

### Output

| Flag | Behaviour |
|---|---|
| `--oneline` | One line per host with findings (`host:port, result`). On its own it runs the protocol, weak cipher and certificate checks (reporting the protocols, any weak ciphers, and any certificate findings); filter flags restrict the checks that run. Hosts with no findings print nothing. Compression, Heartbleed and groups are always skipped; renegotiation runs only with `--insecure-reneg` (and is reported as `insecure-reneg`). |

### STARTTLS

For services where TLS is negotiated as part of another protocol, use the
matching `--starttls-*` flag (the default port is set automatically):

| Flag | Service | Default port |
|---|---|---|
| `--starttls-ftp` | FTP | 21 |
| `--starttls-imap` | IMAP | 143 |
| `--starttls-irc` | IRC | 6667 |
| `--starttls-ldap` | LDAP | 389 |
| `--starttls-pop3` | POP3 | 110 |
| `--starttls-smtp` | SMTP | 25 |
| `--starttls-mysql` | MySQL | 3306 |
| `--starttls-psql` | PostgreSQL | 5432 |
| `--starttls-mssql` | Microsoft SQL Server (TDS) | 1433 |
| `--starttls-xmpp` | XMPP | 5222 |
| `--rdp` | RDP | 3389 |

`--starttls-mssql` performs the TDS PRELOGIN exchange with SQL Server and
tunnels the TLS handshake inside TDS PRELOGIN (`0x12`) packets, which is what
TDS 7.x (all current SQL Server releases) requires. Without it, pointing
sslscan at port 1433 will not complete a handshake, because SQL Server does
not speak plain TLS there.

```console
$ ./sslscan --starttls-mssql --oneline 10.0.0.5:1433
10.0.0.5:1433, TLSv1.2; 3des: DES-CBC3-SHA; self-signed: sql01, ...
```

Run `./sslscan -h` for the full option list, including the upstream options.

---

## Sample output

**Everything, one line per host**

```console
$ ./sslscan-linux-amd64-static --oneline --targets=ssl.hosts
10.17.18.131:443, TLSv1.0,TLSv1.1,TLSv1.2,TLSv1.3; 3des: ECDHE-RSA-DES-CBC3-SHA; self-signed: root, untrusted: self-signed certificate, subject: root
10.17.18.134:443, TLSv1.2,TLSv1.3; 3des+anon: ECDHE-RSA-DES-CBC3-SHA, AECDH-DES-CBC3-SHA, DES-CBC3-SHA
```

**Weak ciphers across a target list**

```console
$ ./sslscan-linux-amd64-static --3des --oneline --targets=ssl.hosts
10.17.18.131:443, 3des: ECDHE-RSA-DES-CBC3-SHA
10.17.18.132:443, 3des: ECDHE-RSA-DES-CBC3-SHA
10.17.18.134:443, 3des: ECDHE-RSA-DES-CBC3-SHA, DHE-RSA-DES-CBC3-SHA, AECDH-DES-CBC3-SHA
10.17.18.184:5634, 3des: DES-CBC3-SHA
```

**Insecure legacy renegotiation (CVE-2009-3555)**

```console
$ ./sslscan-linux-amd64-static --insecure-reneg --oneline --targets=ssl.hosts
10.17.18.131:443, insecure-reneg
10.17.18.184:5634, insecure-reneg
```

**Combined certificate checks**

```console
$ ./sslscan-mac-arm64 --cert-untrusted --cert-self-signed --oneline --targets=ssl.hosts
10.17.18.184:5634, self-signed: root, untrusted: self-signed certificate, subject: root
10.17.18.185:5634, self-signed: root, untrusted: self-signed certificate, subject: root
```

**Legacy protocol sweep**

```console
$ ./sslscan-linux-amd64-static --tls10 --oneline --targets=ssl.hosts
10.17.26.13:443, TLSv1.0
10.17.26.16:8888, TLSv1.0
10.17.26.34:443, TLSv1.0
10.17.26.31:443, TLSv1.0
```

---

## Building

The recommended approach is a **static build against your own OpenSSL**. The binary is larger and uses more memory, but it enables extra checks such as TLS compression.

> **OpenSSL requirement:** as of sslscan 2.2.0 the minimum OpenSSL version is **3.5.0 (LTS)**. If your distro ships something older, use a static build.

### With `build.sh`

`build.sh` wraps the Makefile targets and adds cross-compilation. Run `./build.sh --help` for all options.

| Command | Result | Dependencies |
|---|---|---|
| `./build.sh` | Native static build *(recommended)* | Linux: `apt install git perl make gcc zlib1g-dev`<br>macOS: Xcode CLT (`xcode-select --install`) |
| `./build.sh --dynamic` | Native dynamic build (uses system OpenSSL 3.5+) | As above, plus OpenSSL 3.5+ headers (Linux: `libssl-dev`; macOS: `brew install openssl`) |
| `./build.sh --fully-static` | Fully static binary *(Linux only)* | As native static, plus `curl` and `ca-certificates` |
| `./build.sh --os linux --arch amd64` | Linux amd64 from any Linux host | `apt install gcc-x86-64-linux-gnu libc6-dev-amd64-cross` (or `--install-deps` as root) |
| `./build.sh --os linux --arch arm64` | Linux arm64 from any Linux host | `apt install gcc-aarch64-linux-gnu libc6-dev-arm64-cross` (or `--install-deps`) |
| `./build.sh --os windows --arch amd64` | Windows x86-64 `.exe` (MinGW cross-compile) | `apt install gcc-mingw-w64-x86-64` (or `--install-deps`) |

Static, fully-static and cross builds compile their own zlib and OpenSSL (newest 3.5.x) from source into `build/`, so no system OpenSSL is needed.

**Platform notes**
- macOS builds must be done on a Mac. Cross-compiling *to* macOS is not supported.
- Fully static binaries aren't possible on macOS (no static libc), so use the default static build there.