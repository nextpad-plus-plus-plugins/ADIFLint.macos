# Security

ADIF Lint keeps logins for several online services and sends your QSOs to them, so
security reports are taken seriously.

## Reporting a vulnerability

Please report privately, not in a public issue: use **Report a vulnerability** on the
repository's [Security tab](https://github.com/ssamjung2/Nextpad_plus_plus_ADIFLint/security).
Include the version (Plugins → ADIF Lint → About ADIF Lint…), what an attacker could do,
and how to reproduce it. Fixes go into the next release; only the latest release is
supported.

## How ADIF Lint handles your data

- **Credentials** (usernames, passwords, API keys, the TQSL certificate password) are
  stored only in your macOS login Keychain, as items named "ADIF Lint: …". They are never
  written to `ADIFLint.ini`, to logs or to any other file, and a saved password is never
  shown again. Settings → Remove deletes them.
- **Network requests** use HTTPS and go only to the service you chose, when you ask:
  Enrich, Import, Upload, Test Sign-In, a callbook lookup you turned on in New QSO, an open
  Spots window, or Settings → Country Data → Update. The README lists every address. The
  QRZ.com sign-in is sent as a POST; HamQTH's sign-in, LoTW's report API and eQSL's
  DownloadInBox take the login in the HTTPS address, as those services document it.
- **Programs run**: TQSL, which you choose, for LoTW uploads (with the certificate
  password on its command line when you save one, where other programs on your Mac could
  see it while TQSL runs), and `/usr/bin/unzip` to unpack a downloaded country file.
- **Uploads** list exactly what would be sent, and nothing is sent until you press Upload.
- **Monitor** listens for QSOs from other programs only while you have started it, on the
  UDP and TCP ports you ticked, bound to `127.0.0.1` unless you tick Accept from other
  computers (then any computer that can reach yours can add QSOs to the chosen log). It
  never sends anything. Messages are limited to 64 KB, TCP to 4 connections closed after
  30 idle seconds, and QSOs to 20 a second per source; a message with a QSO can only add,
  change (N1MM's edits, matched by its own ID) or delete records in the log you chose, or
  wait in its queue file in the plugin config folder, never touch another file. Everything it reads is parsed by code covered by the fuzz tests.
