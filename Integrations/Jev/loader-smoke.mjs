import assert from 'node:assert/strict'
import { spawn } from 'node:child_process'
import { mkdtemp, writeFile, rm } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import net from 'node:net'

const root = dirname(fileURLToPath(import.meta.url))
const plugin = join(root, 'router.mjs')
const home = await mkdtemp(join(tmpdir(), 'dsh-jev-loader-'))
const overlay = join(home, 'jev.patch.yml')
const server = net.createServer()
await new Promise((resolve, reject) => server.once('error', reject).listen(0, '127.0.0.1', resolve))
const port = server.address().port
await new Promise((resolve) => server.close(resolve))

await writeFile(overlay, `- insert:\n    - id: jev-route-selector\n      name: '${plugin}'\n      config:\n        enabled: true\n        autoRoute:\n          provider: synthetic-provider\n          model: fast-model\n          reasoningEffort: low\n        routes:\n          - provider: synthetic-provider\n            model: fast-model\n            efforts: [low]\n          - provider: synthetic-provider\n            model: deep-model\n            efforts: [high]\n`)

let child
try {
  child = spawn(process.env.DSH_BIN || 'dsh', [
    '--profile', 'web', '--patch', overlay, '--no-open', '--host', '127.0.0.1',
    '--port', String(port),
  ], {
    cwd: home,
    env: {
      PATH: process.env.PATH,
      HOME: home,
      DSH_HOME: home,
      TYPESAFE_API_KEY: 'synthetic-loader-key',
    },
    stdio: ['ignore', 'pipe', 'pipe'],
  })
  let output = ''
  let error = ''
  child.stdout.on('data', (part) => { output += part.toString().slice(0, 4096) })
  child.stderr.on('data', (part) => { error += part.toString().slice(0, 4096) })
  const result = await new Promise((resolve) => {
    const finish = (value) => {
      clearInterval(check)
      clearTimeout(deadline)
      resolve(value)
    }
    const check = setInterval(() => {
      if (output.includes(`dsh web: http://127.0.0.1:${port}/`)) finish('started')
    }, 100)
    const deadline = setTimeout(() => finish('timeout'), 45_000)
    child.once('exit', (code) => finish(`exit ${code}`))
  })
  assert.equal(result, 'started', `DSH did not start with Jev overlay: ${result}; ${error.slice(-500)}`)
  console.log('DSH isolated Web profile started with Jev Cordis overlay')
} finally {
  if (child && child.exitCode === null) {
    child.kill('SIGTERM')
    await Promise.race([
      new Promise((resolve) => child.once('exit', resolve)),
      new Promise((resolve) => setTimeout(resolve, 5000)),
    ])
    if (child.exitCode === null) child.kill('SIGKILL')
  }
  await rm(home, { recursive: true, force: true })
}
