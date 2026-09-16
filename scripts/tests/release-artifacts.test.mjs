import assert from 'node:assert/strict';
import test from 'node:test';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { createHash } from 'node:crypto';
import { verifyReleaseArtifacts } from '../verify-release-artifacts.mjs';

test('publishing requires both intact packages without an update feed', async () => {
  const dir = await fs.mkdtemp(path.join(os.tmpdir(), 'switcher-assets-'));
  const mac = 'Codex-Account-Switcher-macos-arm64.dmg';
  const win = 'Codex-Account-Switcher-windows-x64.exe';
  try {
    for (const name of [mac, win]) {
      await fs.writeFile(path.join(dir, name), name);
      await fs.writeFile(path.join(dir, name + '.sha256'), createHash('sha256').update(name).digest('hex') + '  ' + name + '\n');
    }
    await verifyReleaseArtifacts(dir, 'v1.2.3');
    await assert.rejects(verifyReleaseArtifacts(dir, 'invalid'), /unified release tag/);
    await fs.writeFile(path.join(dir, win), 'corrupt');
    await assert.rejects(verifyReleaseArtifacts(dir, 'v1.2.3'), /Checksum mismatch/);
    await fs.unlink(path.join(dir, win));
    await assert.rejects(verifyReleaseArtifacts(dir, 'v1.2.3'), /ENOENT/);
  } finally { await fs.rm(dir, { recursive: true }); }
});
