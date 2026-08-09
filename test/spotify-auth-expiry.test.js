import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';

const text = async (path) => readFile(new URL(`../${path}`, import.meta.url), 'utf8');

test('device marks only an explicit invalid_grant and preserves the refresh token', async () => {
  const api = await text('device/oh2p/spotify-web-api.sh');

  assert.match(api, /REAUTHORIZATION_REQUIRED_FILE=.*spotify-reauthorization-required/);
  assert.match(api, /error_code=.*'@\.error'/);
  assert.match(api, /\[ "\$error_code" = invalid_grant \]/);
  assert.match(api, /AUTH_EXPIRED status=\$status error=invalid_grant/);
  assert.match(api, /chmod 600 "\$marker_tmp"/);
  assert.match(api, /Spotify 授权已失效.*重新授权/);
  assert.match(api, /refresh token 已保留/);
  assert.doesNotMatch(api, /rm -f "?\$REFRESH_TOKEN_FILE/);
  assert.doesNotMatch(api, /--data-urlencode "refresh_token=\$refresh_token"/);
  assert.match(api, /printf '%s' "\$refresh_token" \|[\s\\]*\n?\s*curl/);
  assert.match(api, /--data-urlencode 'refresh_token@-'/);
});

test('successful refresh clears the marker and health reports the six-month estimate', async () => {
  const api = await text('device/oh2p/spotify-web-api.sh');

  assert.match(api, /clear_reauthorization_required/);
  assert.match(api, /AUTH_VALIDITY_DAYS=.*180/);
  assert.match(api, /AUTH_WARNING_DAYS=.*30/);
  assert.match(api, /spotify-authorized-at-ms/);
  assert.match(api, /estimated_remaining_days=unknown/);
  assert.match(api, /SPOTIFY_AUTH_WARNING remaining_days=/);
  assert.ok(
    api.indexOf('clear_reauthorization_required ||') > api.indexOf("log_message 'REFRESH_TOKEN_ROTATED'"),
    'the invalid-grant marker should only clear after a successful token response is persisted',
  );
});

test('new authorization deployment and status commands manage the marker without reading secrets', async () => {
  const deployment = await text('host/deploy-spotify-auth.sh');
  const healthcheck = await text('device/oh2p/healthcheck.sh');
  const hostStatus = await text('host/device-status.sh');

  assert.match(deployment, /rm -f \/data\/xiaoaimusic\/spotify-reauthorization-required/);
  assert.match(healthcheck, /authorization_marker=AUTH_EXPIRED/);
  assert.match(hostStatus, /authorization_marker=AUTH_EXPIRED/);
  assert.doesNotMatch(healthcheck, /cat .*spotify-reauthorization-required/);
  assert.doesNotMatch(hostStatus, /cat .*spotify-reauthorization-required/);
});

test('normal refresh shares the updater lock and refuses a pending transaction', async () => {
  const api = await text('device/oh2p/spotify-web-api.sh');

  assert.match(api, /AUTH_LOCK_FILE=\$ROOT\/\.spotify-auth-update\.lock/);
  assert.match(api, /AUTH_TRANSACTION_FILE=\$ROOT\/\.spotify-auth-update\.transaction/);
  assert.match(api, /flock -x 9/);
  assert.match(api, /AUTH_TRANSACTION_PENDING refresh=blocked/);
  assert.ok(
    api.indexOf('AUTH_TRANSACTION_PENDING refresh=blocked') <
      api.indexOf('refresh_access_token_under_lock "$@"'),
    'a pending updater transaction must be rejected before the refresh path runs',
  );
  assert.doesNotMatch(api, /auth-validate|XIAOAIMUSIC_AUTH_LOCK_HELD/);
});
