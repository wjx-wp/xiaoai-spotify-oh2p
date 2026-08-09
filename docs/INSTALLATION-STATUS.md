# Installation status

The runtime, native voice filter, physical-key bridge, Spotify library sync,
restricted mobile SSH channel and Android OAuth handoff have been validated on
one OH2P running firmware 1.56.20.

The repository does not yet provide a consumer-safe zero-click flashing tool.
Current host scripts are engineering tools and assume that the operator can:

- identify the exact device model and firmware;
- preserve the active factory slot and create read-only backups;
- verify SSH host keys through a trusted physical connection;
- stop when a hash or partition layout differs;
- recover the original boot slot.

The planned guided installer will use a persistent state machine with explicit
checkpoints. It can automate device discovery, polling, hash verification,
backup validation, build/download selection, deployment, health checks and
rollback. It cannot physically plug or unplug USB/power, approve Android system
permissions, accept Spotify authorization or make an unknown firmware version
compatible.

Until that installer is complete, do not describe this repository as a
one-click consumer product and do not publish pre-patched Xiaomi firmware.
