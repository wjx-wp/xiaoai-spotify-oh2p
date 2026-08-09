import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';

const text = async (path) => readFile(new URL(`../${path}`, import.meta.url), 'utf8');

test('keybridge exposes a constrained one-shot local control client', async () => {
  const source = await text('components/keybridge/xiaoaimusic-keybridge.c');

  assert.match(source, /--send-command COMMAND/);
  assert.match(source, /static int valid_control_command/);
  for (const command of ['play', 'pause', 'toggle', 'next', 'previous', 'transfer']) {
    assert.match(source, new RegExp(`!strcmp\\(command, "${command}"\\)`));
  }
  assert.match(
    source,
    /if \(one_shot\)[\s\S]*send_control\(control_socket, command\)[\s\S]*return 0;/,
  );
  assert.ok(
    source.indexOf('if (one_shot)') < source.indexOf('open(input_path'),
    'one-shot commands must not open the input device',
  );
});

test('voice transport prefers local Spirc and keeps Web API as fallback', async () => {
  const script = await text('device/oh2p/spotify-web-api.sh');
  const localStart = script.indexOf('\nlocal_transport()') + 1;
  const transportStart = script.indexOf('\ntransport()') + 1;
  const toggleStart = script.indexOf('\ntoggle_playback()') + 1;
  const localBlock = script.slice(localStart, transportStart);
  const transportBlock = script.slice(transportStart, toggleStart);

  assert.ok(localStart >= 0 && transportStart > localStart && toggleStart > transportStart);
  assert.match(localBlock, /resume\) local_command=play/);
  assert.match(localBlock, /pause\|next\|previous\) local_command=\$action/);
  assert.match(localBlock, /--send-command "\$local_command"/);
  assert.match(transportBlock, /if local_transport "\$action"; then/);
  assert.match(transportBlock, /source=local-spirc/);
  assert.match(transportBlock, /fallback=web-api/);
  assert.match(transportBlock, /device_id=\$\(target_device_id\)/);
  assert.match(transportBlock, /source=web-api/);
  assert.ok(
    transportBlock.indexOf('if local_transport "$action"; then')
      < transportBlock.indexOf('device_id=$(target_device_id)'),
    'local control must run before device discovery or any Web API request',
  );
});
