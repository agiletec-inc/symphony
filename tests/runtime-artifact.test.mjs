import assert from 'node:assert/strict'
import { mkdtemp, readFile, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import test from 'node:test'
import { verifyRuntimeArtifact } from '../scripts/verify-runtime-artifact.mjs'

const sourceManifest = new URL('../instances/agiletec-pilot/instance.json', import.meta.url)

async function fixture() {
  const root = await mkdtemp(join(tmpdir(), 'symphony-artifact-'))
  const manifest = JSON.parse(await readFile(sourceManifest, 'utf8'))
  manifest.runtime.status = 'approved'
  const manifestPath = join(root, 'instance.json')
  const binary = join(root, 'symphony')
  await writeFile(manifestPath, JSON.stringify(manifest))
  await writeFile(binary, 'fixture')
  await writeFile(join(root, 'build-manifest.json'), JSON.stringify({
    repository: manifest.runtime.upstreamRepository,
    commit: manifest.runtime.commit,
    buildImage: manifest.runtime.buildImage,
  }))
  return { binary, manifest, manifestPath, root }
}

test('accepts only an artifact built from the pinned source and image', async () => {
  const options = await fixture()
  await verifyRuntimeArtifact(options)
})

test('rejects an artifact from another commit', async () => {
  const options = await fixture()
  await writeFile(join(options.root, 'build-manifest.json'), JSON.stringify({
    repository: options.manifest.runtime.upstreamRepository,
    commit: '0'.repeat(40),
    buildImage: options.manifest.runtime.buildImage,
  }))
  await assert.rejects(verifyRuntimeArtifact(options), /commit mismatch/)
})
