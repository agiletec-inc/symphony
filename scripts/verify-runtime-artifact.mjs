import { readFile } from 'node:fs/promises'
import { dirname, resolve } from 'node:path'
import { pathToFileURL } from 'node:url'
import { readAndVerifyInstance } from './verify-instance.mjs'

export async function verifyRuntimeArtifact({ manifestPath, binary }) {
  const instance = await readAndVerifyInstance(manifestPath, { runtime: true })
  let build
  try { build = JSON.parse(await readFile(resolve(dirname(binary), 'build-manifest.json'), 'utf8')) }
  catch (error) { throw new Error(`[symphony-artifact] cannot read build manifest: ${error.message}`) }
  const expected = { repository: instance.runtime.upstreamRepository, commit: instance.runtime.commit, buildImage: instance.runtime.buildImage }
  for (const [field, value] of Object.entries(expected)) if (build[field] !== value) throw new Error(`[symphony-artifact] ${field} mismatch: expected ${value}`)
  return build
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const [manifestPath, binary] = process.argv.slice(2)
  if (!manifestPath || !binary) throw new Error('usage: verify-runtime-artifact.mjs <instance.json> <symphony-binary>')
  await verifyRuntimeArtifact({ manifestPath, binary })
  console.log('[symphony-artifact] OK')
}
