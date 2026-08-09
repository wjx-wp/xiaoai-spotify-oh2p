import { lstat, readFile, readdir } from 'node:fs/promises';
import { execFileSync } from 'node:child_process';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
let gitCandidates = null;
try {
  const output = execFileSync(
    'git',
    ['-C', root, 'ls-files', '-z', '--cached', '--others', '--exclude-standard'],
    { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] },
  );
  gitCandidates = new Set(output.split('\0').filter(Boolean));
} catch {
  // The first export is checked before git init. In that case scan the tree.
}
const allowedTopLevel = new Set([
  '.env.example', '.gitattributes', '.github', '.githooks', '.gitignore',
  '.xiaoaimusic-public-export',
  'CONTRIBUTING.md', 'LICENSE', 'LICENSES', 'NOTICE', 'README.md',
  'SECURITY.md', 'THIRD_PARTY_NOTICES.md', 'android', 'compatibility',
  'components', 'config', 'device', 'docs', 'host', 'package-lock.json',
  'package.json', 'patches', 'resources.lock.json', 'scripts', 'src', 'test',
]);

const deniedSegments = new Set([
  '.cache', '.gradle', '.idea', '.secrets', '.vscode', 'artifacts', 'build',
  'coverage', 'node_modules', 'target', 'upstream',
]);
const deniedBasenames = [
  /^\.env(?!\.example$)/i,
  /^\.mi\.json$/i,
  /^\.spotify-token\.json$/i,
  /^authorized_keys$/i,
  /^id_(?:rsa|ed25519)/i,
  /^known_hosts/i,
  /^local\.properties$/i,
];
const deniedExtensions = new Set([
  '.7z', '.a', '.aab', '.apk', '.bin', '.core', '.db', '.dll', '.dump',
  '.elf', '.exe', '.img', '.jks', '.key', '.keystore', '.log', '.o',
  '.p12', '.pem', '.pfx', '.plist', '.so', '.sqlite', '.squashfs', '.tar',
  '.tgz', '.zip',
]);

const contentRules = [
  ['private key', /-----BEGIN (?:OPENSSH |RSA |EC |DSA )?PRIVATE KEY-----/],
  ['literal SSH public key', /(?:^|\s)ssh-rsa[ \t]+[A-Za-z0-9+/]{100,}={0,2}(?:\s|$)/m],
  ['literal bearer token', /Authorization:\s*Bearer\s+[A-Za-z0-9._~+/=-]{16,}/i],
  ['literal Spotify Client ID', /SPOTIFY_CLIENT_ID\s*=\s*["']?[A-Za-z0-9]{32}["']?/],
  ['literal Spotify client secret', /client_secret\s*[=:]\s*["'][^"'<>${}\s]{8,}["']/i],
  ['literal OAuth token JSON', /"(?:access_token|refresh_token)"[ \t]*:[ \t]*"[^"<>${}\s]{16,}"/i],
  ['literal OAuth token environment', /^(?:SPOTIFY_)?(?:ACCESS_TOKEN|REFRESH_TOKEN)[ \t]*=[ \t]*["'][^"'<>${}\s]{16,}["'][ \t]*$/im],
  ['literal password', /^(?:MI_PASSWORD|XIAOAI_ANDROID_STORE_PASSWORD|XIAOAI_ANDROID_KEY_PASSWORD)[ \t]*=[ \t]*(?!$|<)[^\r\n]+$/im],
  ['OAuth callback/query material', /accounts\.spotify\.com\/authorize\?[^\r\n]*(?:state|code_challenge|code)=/i],
  ['personal Windows home path', /[A-Za-z]:\\Users\\(?!USERNAME(?:\\|$))[^\\\s]+\\/i],
  ['embedded speaker host fingerprint', /SPEAKER_HOST_KEY_SHA256\s*=\s*"SHA256:[A-Za-z0-9+/]{43}"/],
];

const failures = [];

async function walk(directory) {
  for (const entry of await readdir(directory, { withFileTypes: true })) {
    if (directory === root && !allowedTopLevel.has(entry.name) && entry.name !== '.git') {
      const normalizedPrefix = `${entry.name}/`;
      const isCandidate = !gitCandidates || [...gitCandidates].some(
        (candidate) => candidate === entry.name || candidate.startsWith(normalizedPrefix),
      );
      if (isCandidate) failures.push(`unexpected top-level entry: ${entry.name}`);
      continue;
    }
    if (entry.name === '.git') continue;

    const absolute = path.join(directory, entry.name);
    const relative = path.relative(root, absolute).replaceAll('\\', '/');
    if (gitCandidates && entry.isFile() && !gitCandidates.has(relative)) continue;
    const info = await lstat(absolute);
    if (info.isSymbolicLink()) {
      failures.push(`link/reparse point is forbidden: ${relative}`);
      continue;
    }
    if (relative.split('/').some((part) => deniedSegments.has(part))) {
      if (!gitCandidates || gitCandidates.has(relative)) {
        failures.push(`denied path segment: ${relative}`);
      }
      continue;
    }
    if (entry.isDirectory()) {
      await walk(absolute);
      continue;
    }
    if (!entry.isFile()) {
      failures.push(`non-regular file: ${relative}`);
      continue;
    }
    if (deniedBasenames.some((rule) => rule.test(entry.name))) {
      failures.push(`denied filename: ${relative}`);
      continue;
    }
    if (deniedExtensions.has(path.extname(entry.name).toLowerCase())) {
      failures.push(`denied extension: ${relative}`);
      continue;
    }
    if (info.size > 5 * 1024 * 1024) {
      failures.push(`file larger than 5 MiB: ${relative}`);
      continue;
    }

    const bytes = await readFile(absolute);
    if (bytes.includes(0)) {
      failures.push(`binary/NUL content: ${relative}`);
      continue;
    }
    const content = bytes.toString('utf8');
    for (const [name, rule] of contentRules) {
      if (rule.test(content)) failures.push(`${name}: ${relative}`);
    }
  }
}

await walk(root);
if (failures.length > 0) {
  console.error('PUBLIC_SAFETY_FAILED');
  for (const failure of failures) console.error(`- ${failure}`);
  process.exitCode = 1;
} else {
  console.log('PUBLIC_SAFETY_OK');
}
