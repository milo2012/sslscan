# sslscan2

sslscan version 2 has now been released. This includes a major rewrite of the backend scanning code, which means that it is no longer reliant on the version of OpenSSL for many checks. This means that it is possible to support legacy protocols (SSLv2 and SSLv3), as well as supporting TLSv1.3 - regardless of the version of OpenSSL that it has been compiled against.

This has been made possible largely by the work of [jtesta](https://github.com/jtesta), who has been responsible for most of the backend rewrite.

Other key changes include:

* Enumeration of server key exchange groups.
* Enumeration of server signature algorithms.
* SSLv2 and SSLv3 protocol support is scanned, but individual ciphers are not.
* A test suite is included using Docker, to verify that sslscan is functionality correctly.
* Removed the `--http` option, as it was broken and had very little use in the first place.
* Support for new post-quantum groups.

## XML Output Changes
A potentially breaking change has been made to the XML output in version **2.0.0-beta4**. Previously, multiple `<certificate>` elements could be returned (one by default, and a second one if `--show-certificate` was used).

The key changes are:

* A new parent `<certificates>` element that will contain the `<certificate>` elements.
* `<certificate>` elements have a new `type` attribute, which can either be:
  * `short` for the default output.
  * `full` for when `--show-certificate` is used.
* There will potentially be more than one certificate of each type returned on servers that have multiple certificates with different signature algorithms (see discussion in issue [#208](https://github.com/rbsec/sslscan/issues/208)).
* The `<signature-algorithm>` element in a `<certificate>` no longer contains the "Signature Algorithm:" prefix, or the spacing and newline.

If you are using the XML output, then you may need to make changes to your parser.

# README

[![ci](https://github.com/rbsec/sslscan/actions/workflows/ci.yml/badge.svg)](https://github.com/rbsec/sslscan/actions/workflows/ci.yml)

This is a fork of ioerror's version of sslscan (the original readme of which is included below) by rbsec (robin@rbsec.net).

Key changes are as follows:

* Added `--oneline` mode, which prints a single summary line per host, and a `--targets` option to scan a list of hosts from a file (see [New in this fork](#new-in-this-fork) below).
* Highlight SSLv2 and SSLv3 ciphers in output.
* Highlight CBC ciphers on SSLv3 (POODLE).
* Highlight 3DES and RC4 ciphers in output.
* Highlight PFS+GCM ciphers as good in output.
* Highlight NULL (0 bit), weak (<40 bit) and medium (40 < n <= 56) ciphers in output.
* Highlight anonymous (ADH and AECDH) ciphers in output (purple).
* Hide certificate information by default (display with `--show-certificate`).
* Hide rejected ciphers by default (display with `--failed`).
* Added TLSv1.1, TLSv1.2 and TLSv1.3 support.
* Supports IPv6  (can be forced with `--ipv6`).
* Check for TLS compression (CRIME, disable with `--no-compression`).
* Disable cipher suite checking `--no-ciphersuites`.
* Disable coloured output `--no-colour`.
* Removed undocumented -p output option.
* Added check for OpenSSL HeartBleed (CVE-2014-0160, disable with `--no-heartbleed`).
* Flag certificates signed with MD5 or SHA-1, or with short (<2048 bit) RSA keys.
* Support scanning RDP servers with `--rdp` (credit skettler).
* Added option to specify socket timeout.
* Added option for static compilation (credit dmke).
* Added `--sleep` option to pause between requests.
* Disable output for anything than specified checks `--no-preferred`.
* Determine the list of CAs acceptable for client certificates `--show-client-cas`.
* Experimental build support on OS X (credit MikeSchroll).
* Flag some self-signed SSL certificates.
* Experimental Windows support (credit jtesta).
* Display EC curve names and DHE key lengths with OpenSSL >= 1.0.2 `--no-cipher-details`.
* Flag weak DHE keys with OpenSSL >= 1.0.2 `--cipher-details`.
* Flag expired certificates.
* Flag TLSv1.0 and TLSv1.1 protocols in output as weak.
* Experimental OS X support (static building only).
* Support for scanning PostgreSQL servers (credit nuxi).
* Check for TLS Fallback SCSV support.
* Added StartTLS support for LDAP `--starttls-ldap`.
* Added SNI support `--sni-name` (credit Ken).
* Support STARTTLS for MySQL (credit bk2017).
* Check for supported key exchange groups.
* Check for supported server signature algorithms.
* Display IANA/RFC cipher names `--iana-names`
* Display the full certifiate chain `--show-certificates`
* Added option to scan groups on all supported protocols `--all-groups`.

## New in this fork

This fork adds a `--oneline` mode for quickly checking specific protocols/ciphers against one or many hosts, and a `--targets` option for scanning a list of hosts from a file.

### `--oneline`

`--oneline` prints a single summary line per host instead of the full scan report. It's intended to be combined with one of the protocol or cipher filter flags below, so you can quickly test whether a specific protocol, cipher class, or certificate condition is present.

```
✗ ./sslscan-mac-arm64 --oneline --tls12 cnx-software.com:443
cnx-software.com:443, TLSv1.2
```

Hosts with no matching findings are silent (no output), which makes `--oneline` well suited to scanning large target lists and only seeing the hosts that matter.

`--oneline` also skips the renegotiation, compression, Heartbleed, group, and certificate checks, so scans complete faster.

### `--targets=<file>`

`--targets=<file>` allows you to scan multiple hosts from a file instead of specifying a single target on the command line. Hosts can optionally include a port (`host:port`); if no port is given, the default port is used.

### Filter flags

The following flags restrict `sslscan` to checking a single protocol, cipher class, or certificate condition. They can be used on their own, or combined with `--oneline` to get a compact one-line result per host:

```
  --targets=<file>     A file containing a list of hosts to check.
                       Hosts can  be supplied  with ports (host:port)
  --ssl2               Only check if SSLv2 is enabled
  --ssl3               Only check if SSLv3 is enabled
  --tls10              Only check TLSv1.0 ciphers
  --tls11              Only check TLSv1.1 ciphers
  --tls12              Only check TLSv1.2 ciphers
  --tls13              Only check TLSv1.3 ciphers
  --tlsall             Only check TLS ciphers (all versions)
  --rc4                 Only check RC4 ciphers
  --3des                Only check triple-DES (3DES) ciphers
  --des                 Only check single-DES (DES) ciphers
  --anon                Only check anonymous (no authentication) ciphers
  --dh1024              Only check DHE ciphers with weak (<= 1024 bit) DH params
  --cert-md5            Only check for MD5-signed certificates
  --cert-sha1           Only check for SHA-1-signed certificates
  --cert-short-rsa      Only check for short (<2048 bit) RSA keys
  --cert-self-signed    Only check for self-signed certificates
  --cert-untrusted      Only check for certificates untrusted by the system CA store
  --cert-expired        Only check for expired (or not yet valid) certificates
  --cert-expiring       Only check for certificates expiring within 30 days
  --cert-expiring-days=N  Only check for certificates expiring within N days
  --oneline             Print one line per host with findings (host:port, result);
                        hosts with no findings are silent; skips renegotiation,
                        compression, heartbleed, groups and certificate checks
```

### Building on Linux

It is recommended to ignore the OpenSSL system installation and statically build against your own version. Although this results in a more resource-heavy `sslscan` binary (file size, memory consumption, etc.), this allows some additional checks such as TLS compression. Note that as of sslscan version 2.2.0, the minimum OpenSSL version required by sslscan is 3.5.0 (LTS), so if your distro ships an older version then building against it will not work, and you will have to do a static build.

To compile your own OpenSSL version, you'll probably need to install the OpenSSL build dependencies. The commands below can be used to do this on Debian.

    apt install git zlib1g-dev make gcc

Then run

    make static

This will clone the [OpenSSL repository](https://github.com/openssl/openssl), and configure/compile/test OpenSSL prior to compiling `sslscan`.

**Please note:** By default, OpenSSL is compiled with `gcc` without further customization. To compile with `clang`, install build dependencies using the commands below.

    apt install git zlib1g-dev make clang

Then run

    make static CC=clang

You can verify whether you have a statically linked OpenSSL version, by checking whether the version listed by `sslscan --version` has the `-static` suffix.

### Building with Docker

Ensure that you local Docker installation is functional, and the build the container with:

    make docker

Or manually with:

    docker build -t sslscan:sslscan .

You can then run sslscan with:

    docker run --rm -ti sslscan:sslscan --help

### Building on Windows

Thanks to a patch by jtesta, sslscan can now be compiled on Windows. This can either be done natively or by cross-compiling from Linux. See INSTALL for instructions.

Note that sslscan was originally written for Linux, and has not been extensively tested on Windows. As such, the Windows version should be considered experimental.

Pre-build cross-compiled Windows binaries are available on the [GitHub Releases Page](https://github.com/rbsec/sslscan/releases).

### Building on macOS (formerly named OS X)
There is experimental support for statically building on macOS (formerly named OS X), however this should be considered unsupported. You may need to install any dependencies required to compile OpenSSL from source on macOS (formerly named OS X). Once you have, just run:

    make static

# Original (ioerror) README
This is a fork of sslscan.c to better support STARTTLS.

The original home page of sslscan is:

    http://www.titania.co.uk

sslscan was originally written by:

    Ian Ventura-Whiting

The current home page of this fork (until upstream merges a finished patch) is:

    http://www.github.com/ioerror/sslscan

Most of the pre-TLS protocol setup was inspired by the OpenSSL s_client.c
program. The goal of this fork is to eventually merge with the original
project after the STARTTLS setup is polished.

Some of the OpenSSL setup code was borrowed from The Tor Project's Tor program.
Thus it is likely proper to comply with the BSD license by saying:
    Copyright (c) 2007-2010, The Tor Project, Inc.
