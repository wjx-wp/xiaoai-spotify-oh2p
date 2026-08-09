import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';

const text = async (path) => readFile(new URL(`../${path}`, import.meta.url), 'utf8');

test('restricted updater accepts only fixed SSH actions and the four-line auth protocol', async () => {
  const source = await text(
    'components/spotify-auth-updater/xiaoaimusic-spotify-auth-updater.c',
  );

  assert.match(source, /#define AUTH_UPDATE_COMMAND "spotify-auth-update"/);
  assert.match(source, /#define AUTH_STATUS_COMMAND "spotify-auth-status"/);
  assert.match(source, /#define TAKEOVER_COMMAND "takeover"/);
  assert.match(source, /#define PROTOCOL_MAGIC "XIAOAIMUSIC_AUTH_V1"/);
  assert.match(source, /#define PROTOCOL_END "END"/);
  assert.match(source, /require_eof_until/);
  assert.match(source, /TOKEN_MAX_LENGTH 4096U/);
  assert.match(source, /byte < 0x21U \|\| byte > 0x7eU/);
  assert.match(source, /PR_SET_DUMPABLE/);
  assert.match(source, /PR_SET_NO_NEW_PRIVS/);
  assert.match(source, /RLIMIT_CORE/);
  assert.match(source, /OK takeover_queued/);
  assert.match(source, /OK auth_status %s/);
  assert.match(source, /sendto\(/);
  assert.match(source, /XIAOAIMUSIC_CONTROL_SOCKET_PATH/);
  assert.match(source, /reject_immediate_input/);
});

test('restricted updater commits only the phone-verified pair with a durable local transaction', async () => {
  const source = await text(
    'components/spotify-auth-updater/xiaoaimusic-spotify-auth-updater.c',
  );

  assert.match(source, /TRANSACTION_MAGIC "XIAOAIMUSIC_AUTH_TXN_V1"/);
  assert.match(source, /copy_trusted_file_to_new/);
  assert.match(source, /create_transaction_marker/);
  assert.match(source, /recover_interrupted_transaction/);
  assert.match(source, /A durable marker is the commit decision: always roll forward/);
  assert.match(source, /O_EXCL \| O_NOFOLLOW/);
  assert.match(source, /renameat\(root_fd, TOKEN_STAGE_NAME, root_fd, TOKEN_NAME\)/);
  assert.match(source, /renameat\(root_fd, AUTHORIZED_STAGE_NAME, root_fd,/);
  assert.match(source, /fsync\(root_fd\)/);
  assert.match(source, /flock\(fd, LOCK_EX \| LOCK_NB\)/);
  assert.match(source, /remove_stale_stages\(root_fd\)/);
  assert.match(source, /metadata\.st_nlink != 1/);
  assert.match(source, /\(metadata\.st_mode & 0777\) != 0600/);
  assert.match(source, /sigprocmask\(SIG_BLOCK/);
  assert.match(source, /SIGHUP/);
  assert.match(source, /SIGTERM/);
  assert.match(source, /SIGINT/);
  assert.doesNotMatch(source, /auth-validate|validate_staged_token/);
  assert.doesNotMatch(source, /\bfork\s*\(|\bexecve\s*\(/);
  assert.doesNotMatch(source, /spotify-web-api/);
  assert.doesNotMatch(source, /respond\([^)]*token/);
  assert.doesNotMatch(source, /syslog\([^;]*,\s*token\s*\)/);
});

test('mobile key persistence keeps the administrator key and applies every Dropbear restriction', async () => {
  const deployment = await text('host/deploy-spotify-auth-updater.sh');
  const mount = await text('device/oh2p/mount-mobile-auth.sh');

  for (const restriction of [
    'no-port-forwarding',
    'no-agent-forwarding',
    'no-X11-forwarding',
    'no-pty',
    'command=\\"/data/xiaoaimusic/bin/xiaoaimusic-spotify-auth-updater\\"',
  ]) {
    assert.match(deployment, new RegExp(restriction));
  }
  assert.match(deployment, /Phone key must be RSA 3072/);
  assert.match(deployment, /xiaoaimusic-authorized-keys-verify/);
  assert.match(deployment, /--reject-unrestricted/);
  assert.match(deployment, /--expected-mobile/);
  assert.match(deployment, /install_staged_file\(\)/);
  assert.match(deployment, /mktemp .*\.deploy\.XXXXXX/);
  assert.match(deployment, /mount -o bind/);
  assert.match(deployment, /WAS_OWN_BOUND/);
  assert.match(deployment, /NEW_BIND_CREATED=1/);
  assert.match(
    deployment,
    /\[ "\$NEW_BIND_CREATED" -eq 1 \] &&\s*target_mount_is_project_source; then\s*#[\s\S]*?umount "\$TARGET"/,
  );
  assert.match(deployment, /cmp -s "\$PERSIST" "\$TARGET"/);
  assert.match(deployment, /AUTH_BASE=\$TARGET/);
  assert.match(deployment, /Refusing deployment over a foreign authorized_keys mount/);
  assert.match(deployment, /begins != ends/);
  assert.match(deployment, /StrictHostKeyChecking=yes/);
  assert.doesNotMatch(deployment, /StrictHostKeyChecking=no/);
  assert.match(mount, /xiaoaimusic-authorized-keys-verify/);
  assert.match(mount, /--require-mobile/);
  assert.match(mount, /cmp -s "\$SOURCE" "\$TARGET"/);
  assert.match(mount, /proc\/self\/mountinfo/);
  assert.doesNotMatch(mount, /stat -c/);
  assert.doesNotMatch(mount, /chmod 700 \/data\/etc(?:\s|$)/);
});

test('authorized_keys verifier compares canonical decoded RSA keys', async () => {
  const verifier = await text(
    'components/authorized-keys-verify/xiaoaimusic-authorized-keys-verify.c',
  );

  assert.match(verifier, /O_NOFOLLOW/);
  assert.match(verifier, /metadata\.st_uid != 0/);
  assert.match(verifier, /metadata\.st_nlink != 1/);
  assert.match(verifier, /DROPBEAR_LINE_BUFFER 4200U/);
  assert.match(verifier, /decode_canonical_base64/);
  assert.match(verifier, /validate_ssh_rsa_blob/);
  assert.match(verifier, /MOBILE_RSA_BITS 3072U/);
  assert.match(verifier, /locate_canonical_key/);
  assert.match(verifier, /Every other non-comment line fails closed/);
  assert.match(verifier, /remember_unique_key/);
  assert.match(verifier, /--reject-unrestricted/);
  assert.match(verifier, /--expected-mobile/);
  assert.match(verifier, /contents\[index\] < 0x20U/);
});
