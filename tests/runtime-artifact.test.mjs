import assert from 'node:assert/strict'
import { mkdtemp, readFile, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import test from 'node:test'
import { verifyRuntimeArtifact } from '../scripts/verify-runtime-artifact.mjs'
const sourceManifest = new URL('../instances/agiletec-pilot/instance.json', import.meta.url)
async function fixture() { const root = await mkdtemp(join(tmpdir(), 'symphony-artifact-')); const manifest = JSON.parse(await readFile(sourceManifest, 'utf8')); manifest.runtime.status = 'approved'; const manifestPath = join(root, 'instance.json'), binary = join(root, 'symphony'); await writeFile(manifestPath, JSON.stringify(manifest)); await writeFile(binary, 'fixture'); await writeFile(join(root, 'build-manifest.json'), JSON.stringify({ repository: manifest.runtime.repository, commit: manifest.runtime.commit, buildImage: manifest.runtime.buildImage })); return { root, binary, manifest, manifestPath } }
test('accepts pinned artifact', async () => { await verifyRuntimeArtifact(await fixture()) })
test('rejects another commit', async () => { const options = await fixture(); await writeFile(join(options.root, 'build-manifest.json'), JSON.stringify({ repository: options.manifest.runtime.repository, commit: '0'.repeat(40), buildImage: options.manifest.runtime.buildImage })); await assert.rejects(verifyRuntimeArtifact(options), /commit mismatch/) })
