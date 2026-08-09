import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { readFile } from 'node:fs/promises';
import test from 'node:test';

const text = async (path) => readFile(new URL(`../${path}`, import.meta.url), 'utf8');

test('resource lock pins OH2P ABI, firmware and upstream commits', async () => {
  const lock = JSON.parse(await text('resources.lock.json'));
  assert.equal(lock.target.model, 'OH2P');
  assert.equal(lock.target.architecture, 'armv7-unknown-linux-gnueabihf');
  assert.equal(lock.target.glibc, '2.25');
  assert.equal(lock.target.firmwareValidated, '1.56.20');
  assert.equal(lock.target.compatibilityProfile, 'compatibility/oh2p-1.56.20.json');
  assert.equal(lock.firmware.version, '1.62.2');
  assert.equal(lock.firmware.endToEndValidated, false);
  assert.match(lock.firmware.md5, /^[a-f0-9]{32}$/);
  assert.match(lock.firmware.sha256, /^[a-f0-9]{64}$/);
  for (const upstream of lock.upstreams) {
    assert.match(upstream.commit, /^[a-f0-9]{40}$/);
  }
});

test('public compatibility profile pins the validated native filter inputs', async () => {
  const profile = JSON.parse(await text('compatibility/oh2p-1.56.20.json'));
  assert.equal(profile.model, 'OH2P');
  assert.equal(profile.firmware, '1.56.20');
  assert.equal(profile.status, 'end-to-end-validated');
  assert.match(profile.nativeFilterInputs['/usr/bin/mico_aivs_lab'].sha256, /^[a-f0-9]{64}$/);
  assert.match(profile.nativeFilterInputs['/usr/lib/libaivs_sdk.so'].sha256, /^[a-f0-9]{64}$/);
});

test('canonical coexist patch has the locked hash and preserves native voice', async () => {
  const lock = JSON.parse(await text('resources.lock.json'));
  const patchBytes = await readFile(new URL('../patches/xiaoai-agent-coexist.patch', import.meta.url));
  const hash = createHash('sha256').update(patchBytes).digest('hex');
  const coexistLock = lock.localPatches.find((entry) => entry.repo === 'xiaoai-agent');
  assert.equal(hash, coexistLock.sha256);

  const patch = patchBytes.toString('utf8');
  assert.match(patch, /XIAOAI_MODE/);
  assert.match(patch, /05-asound-mute-native\.patch/);
  assert.match(patch, /-ttyS0::askfirst:\/bin\/login/);
  assert.match(patch, /-\+ttyS0::askfirst:\/bin\/ash --login/);
});

test('librespot local control patch is locked and uses Spirc directly', async () => {
  const lock = JSON.parse(await text('resources.lock.json'));
  const patchBytes = await readFile(new URL('../patches/librespot-local-control.patch', import.meta.url));
  const hash = createHash('sha256').update(patchBytes).digest('hex');
  const patchLock = lock.localPatches.find((entry) => entry.repo === 'librespot');
  assert.equal(hash, patchLock.sha256);
  const patch = patchBytes.toString('utf8');
  assert.match(patch, /LIBRESPOT_CONTROL_SOCKET/);
  assert.match(patch, /spirc\.play_pause\(\)/);
  assert.match(patch, /spirc\.transfer\(None\)/);
  assert.match(patch, /Permissions::from_mode\(0o600\)/);

  const keybridge = await text('components/keybridge/xiaoaimusic-keybridge.c');
  assert.match(keybridge, /AF_UNIX/);
  assert.match(keybridge, /send_control/);
  assert.match(keybridge, /using fallback/);
});

test('device service uses subprocess audio and persistent credential cache only', async () => {
  const supervisor = await text('device/oh2p/supervise-librespot.sh');
  assert.match(supervisor, /--backend "\$SPOTIFY_AUDIO_BACKEND"/);
  assert.match(supervisor, /--system-cache "\$CACHE_DIR"/);
  assert.match(supervisor, /--disable-audio-cache/);
  assert.doesNotMatch(supervisor, /--cache "\$CACHE_DIR"/);

  const config = await text('config/oh2p-device.env.example');
  assert.match(config, /SPOTIFY_DEVICE_NAME='XiaoAI Music'/);
  assert.match(config, /SPOTIFY_VOLUME_CTRL=linear/);
  assert.match(config, /SPOTIFY_ENABLE_NORMALISATION=0/);
  assert.match(config, /-D default -t raw -f S16_LE -r 44100 -c 2/);
});

test('legacy LAN takeover bridge is retired after restricted SSH activation', async () => {
  const build = await text('host/build-oh2p.sh');
  assert.doesNotMatch(build, /build-home-bridge\.sh/);
  assert.doesNotMatch(build, /cp .*xiaoaimusic-home-bridge/);

  const verifier = await text('host/verify-artifacts.sh');
  assert.match(verifier, /retired LAN home bridge/);
  assert.match(verifier, /stop-home-bridge\.sh/);
  assert.match(verifier, /refusing artifact containing credentials, a phone public key, or a token/);

  const installer = await text('device/oh2p/install.sh');
  assert.doesNotMatch(installer, /bin\/xiaoaimusic-home-bridge/);
  assert.doesNotMatch(installer, /run-home-bridge\.sh/);
  assert.match(installer, /stop-home-bridge\.sh/);
  assert.match(installer, /拒绝安装：安装包缺少/);

  const deployment = await text('scripts/deploy-oh2p.ps1');
  assert.doesNotMatch(deployment, /bin\\xiaoaimusic-home-bridge/);
  assert.doesNotMatch(deployment, /run-home-bridge\.sh/);
  assert.match(deployment, /设备包不完整/);

  const autostart = await text('device/oh2p/install-autostart.sh');
  assert.doesNotMatch(autostart, /\/data\/xiaoaimusic\/run-home-bridge\.sh >>/);
  assert.match(autostart, /stop-home-bridge\.sh/);
  assert.match(autostart, /AUTOSTART_INSTALLED_SSH_TAKEOVER_ONLY/);
  assert.ok(
    autostart.indexOf('mv "$TMP" "$INIT"')
      < autostart.lastIndexOf('"$ROOT/stop-home-bridge.sh"'),
    'legacy must stop only after the new boot block is committed',
  );

  const remover = await text('device/oh2p/remove-autostart.sh');
  assert.match(remover, /stop-home-bridge\.sh/);
  assert.ok(
    remover.indexOf('stop-home-bridge.sh') < remover.indexOf('stop-librespot.sh'),
    'the LAN entry point must close before librespot stops',
  );

  const healthcheck = await text('device/oh2p/healthcheck.sh');
  assert.match(healthcheck, /netstat -lnt/);
  assert.match(healthcheck, /legacy_home_bridge=inactive port=18789/);
  assert.doesNotMatch(healthcheck, /cat .*home-takeover-token/);

  const hostStatus = await text('host/device-status.sh');
  assert.match(hostStatus, /legacy_home_bridge=inactive port=18789/);
  assert.doesNotMatch(hostStatus, /\/health/);
});

test('mobile authorization updater is packaged without pairing material and mounted first', async () => {
  const build = await text('host/build-oh2p.sh');
  assert.match(build, /build-spotify-auth-updater\.sh/);
  assert.match(build, /build-authorized-keys-verify\.sh/);
  assert.match(build, /xiaoaimusic-spotify-auth-updater/);
  assert.match(build, /xiaoaimusic-authorized-keys-verify/);

  const verifier = await text('host/verify-artifacts.sh');
  assert.match(verifier, /bin\/xiaoaimusic-spotify-auth-updater/);
  assert.match(verifier, /bin\/xiaoaimusic-authorized-keys-verify/);
  assert.match(verifier, /mount-mobile-auth\.sh/);
  assert.match(verifier, /authorized_keys/);
  assert.match(verifier, /\.pub/);
  assert.match(verifier, /spotify-refresh-token/);

  const installer = await text('device/oh2p/install.sh');
  assert.match(installer, /bin\/xiaoaimusic-spotify-auth-updater/);
  assert.match(installer, /bin\/xiaoaimusic-authorized-keys-verify/);
  assert.match(installer, /mount-mobile-auth\.sh/);
  assert.match(installer, /install_file\(\)/);
  assert.match(installer, /mktemp .*\.install\.XXXXXX/);
  assert.doesNotMatch(installer, /\.\$\$/);

  const mount = await text('device/oh2p/mount-mobile-auth.sh');
  assert.match(mount, /\[ ! -e "\$SOURCE" \].*exit 0/);
  assert.match(mount, /xiaoaimusic-authorized-keys-verify/);
  assert.match(mount, /--require-mobile/);
  assert.match(mount, /proc\/self\/mountinfo/);
  assert.match(mount, /device "\|" root/);
  assert.doesNotMatch(mount, /stat -c/);
  assert.match(mount, /Refusing to replace a foreign authorized_keys mount/);

  for (const path of ['device/oh2p/init-snippet.sh', 'device/oh2p/install-autostart.sh']) {
    const startup = await text(path);
    if (path.endsWith('install-autostart.sh')) {
      assert.match(startup, /# BEGIN XIAOAIMUSIC\n\/data\/xiaoaimusic\/mount-mobile-auth\.sh/);
    }
    const mountIndex = startup.indexOf('/data/xiaoaimusic/mount-mobile-auth.sh');
    assert.ok(mountIndex >= 0, `${path} must mount mobile auth`);
    for (const service of [
      'activate-native-filters.sh',
      'run-librespot.sh',
      'run-voice-bridge.sh',
      'run-keybridge.sh',
    ]) {
      const serviceIndex = startup.indexOf(`/data/xiaoaimusic/${service}`);
      if (serviceIndex >= 0) assert.ok(mountIndex < serviceIndex, `${path}: mount must precede ${service}`);
    }
  }

  const remover = await text('device/oh2p/remove-autostart.sh');
  assert.match(remover, /MOBILE_AUTH_SOURCE=\/data\/etc\/dropbear\/authorized_keys/);
  assert.match(remover, /is_mobile_auth_bind/);
  assert.match(remover, /proc\/self\/mountinfo/);
  assert.match(remover, /xiaoaimusic-authorized-keys-verify/);
  assert.doesNotMatch(remover, /stat -c/);
  assert.match(remover, /cmp -s "\$MOBILE_AUTH_SOURCE" "\$MOBILE_AUTH_TARGET"/);
  assert.match(remover, /umount "\$MOBILE_AUTH_TARGET"/);
  assert.match(remover, /MOBILE_AUTH_UNMOUNTED/);
  assert.match(remover, /leaving it and all startup state untouched/);
  assert.match(remover, /begins != ends/);
  assert.match(remover, /mktemp \/data\/\.xiaoaimusic-init-remove\.XXXXXX/);
  assert.doesNotMatch(remover, /\/tmp\/xiaoaimusic-init\.\$\$/);
  assert.doesNotMatch(remover, /rm .*authorized_keys/);
  assert.doesNotMatch(remover, /rm .*mobile-auth/);

  for (const path of ['device/oh2p/healthcheck.sh', 'host/device-status.sh']) {
    const status = await text(path);
    assert.match(status, /mobile_auth_bind/);
    assert.doesNotMatch(status, /cat .*authorized_keys/);
  }
});

test('deployment is gated and does not enable autostart', async () => {
  const deployment = await text('scripts/deploy-oh2p.ps1');
  assert.match(deployment, /\[switch\]\$Install/);
  assert.match(deployment, /if \(-not \$Install\)/);
  assert.doesNotMatch(deployment, /init-snippet\.sh/);

  const installer = await text('device/oh2p/install.sh');
  assert.match(installer, /grep -q "OH2P"/);
  assert.doesNotMatch(installer, /(?:>>|cp ).*\/data\/init\.sh/);
});

test('local voice bridge only takes over confirmed music instructions', async () => {
  const bridge = await text('device/oh2p/voice-bridge.sh');
  assert.match(bridge, /SpeechRecognizer/);
  assert.match(bridge, /RecognizeResult/);
  assert.match(bridge, /AudioPlayer/);
  assert.match(bridge, /\[ "\$audio_type" = MUSIC \]/);
  assert.match(bridge, /PENDING_DIALOG/);
  assert.match(bridge, /play-auto/);
  assert.match(bridge, /stop_native_music/);
  assert.match(bridge, /闭嘴/);
  assert.match(bridge, /关闭音乐/);
  assert.match(bridge, /MUSIC_INTENT_EARLY/);
  assert.match(bridge, /SUPPRESS_NATIVE_TTS/);
  assert.match(bridge, /mico_aivs_lab restart/);

  const api = await text('device/oh2p/spotify-web-api.sh');
  assert.match(api, /grant_type=refresh_token/);
  assert.match(api, /user-modify-playback-state|me\/player\/play/);
  assert.match(api, /type=artist,track/);
  assert.match(api, /SPOTIFY_DEVICE_NAME/);
  assert.match(api, /--data ''/);
  assert.match(api, /GET "\$API_BASE\/me\/tracks"/);
  assert.match(api, /play-liked/);
  assert.match(api, /toggle_playback/);
  assert.match(api, /active_device_id/);
  assert.match(api, /sync_liked_mirror/);
  assert.match(api, /playlist-modify-private|LIKED_MIRROR_NAME/);
  assert.match(api, /play-my-playlist/);
  assert.match(api, /me\/player\/shuffle/);
  assert.match(api, /me\/player\/repeat/);
  assert.match(api, /DEVICE_ID_CACHE_FILE=\$ROOT\/spotify-device-id/);
  assert.match(api, /DEVICE_CACHE_REFRESH reason=play-failed/);
  assert.match(api, /time_total/);
  assert.doesNotMatch(api, /client_secret/i);

  const authDeployment = await text('host/deploy-spotify-auth.sh');
  assert.match(authDeployment, /\.spotify-token\.json/);
  assert.match(authDeployment, /spotify-refresh-token/);
  assert.match(authDeployment, /spotify-web-api\.sh/);
  assert.match(authDeployment, /run-librespot\.sh/);
  assert.match(authDeployment, /DEVICE_ENV\.pre-xiaoai-music/);
  assert.match(authDeployment, /chmod 600/);
  assert.doesNotMatch(authDeployment, /echo \"\$REFRESH_TOKEN\"/);

  const installer = await text('device/oh2p/install.sh');
  for (const name of [
    'spotify-web-api.sh',
    'voice-bridge.sh',
    'run-voice-bridge.sh',
    'stop-voice-bridge.sh',
    'supervise-liked-sync.sh',
    'stop-liked-sync.sh',
  ]) {
    assert.match(installer, new RegExp(name.replace('.', '\\.')));
  }

  const likedSupervisor = await text('device/oh2p/supervise-liked-sync.sh');
  assert.match(likedSupervisor, /XIAOAI_LIKED_SYNC_CHECK_INTERVAL:-3600/);
  const staleSync = await text('device/oh2p/sync-liked-if-stale.sh');
  assert.match(staleSync, /XIAOAI_LIKED_SYNC_MAX_AGE:-86400/);
  assert.match(bridge, /同步点赞音乐/);
  assert.match(bridge, /xiaoaimusic-log-follower/);

  const build = await text('host/build-oh2p.sh');
  assert.match(build, /build-log-follower\.sh/);
  assert.match(build, /xiaoaimusic-log-follower/);
});
