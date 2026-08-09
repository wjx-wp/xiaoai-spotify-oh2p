# Contributing

Contributions are welcome, especially compatibility profiles, reproducible build improvements, tests and safer recovery paths.

Requirements:

1. Do not submit Xiaomi firmware, proprietary libraries, device dumps, credentials, signed APKs or third-party flashing tools.
2. Add a compatibility profile and fail-closed hash gate for every new firmware variant.
3. Preserve upstream licenses for patches and copied code.
4. Run `npm run public-check` and `npm test` before opening a pull request.
5. Describe real-device testing without including serial numbers, MAC addresses, DID values, account names or private keys.

This checkout uses the repository-owned `.githooks/pre-commit` hook. If it was
not configured automatically, run:

```text
git config core.hooksPath .githooks
```
