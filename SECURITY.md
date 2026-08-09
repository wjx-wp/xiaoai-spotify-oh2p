# Security policy

Please do not publish device passwords, OAuth tokens, SSH private keys, Android signing keys, Xiaomi account credentials, firmware dumps or partition backups in issues or pull requests.

Before committing, run:

```text
npm run public-check
npm test
```

Report a vulnerability privately through GitHub Security Advisories after the repository is published. Until then, contact the repository owner privately and include only the minimum reproduction data. Redact IP addresses, device identifiers and all credentials.

The legacy Dropbear algorithms used by OH2P are accepted only inside a host-key-pinned, public-key-authenticated, forced-command channel on a trusted LAN. Do not expose device SSH to the Internet and do not expand the mobile key into a general shell.
