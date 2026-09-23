import assert from 'node:assert/strict'
import { afterEach, test } from 'node:test'
import { apply, selectCandidate } from './router.mjs'

const originalKey = process.env.TYPESAFE_API_KEY
const originalFetch = globalThis.fetch

afterEach(() => {
  if (originalKey === undefined) delete process.env.TYPESAFE_API_KEY
  else process.env.TYPESAFE_API_KEY = originalKey
  globalThis.fetch = originalFetch
})

function harness() {
  const listeners = new Map()
  return {
    listeners,
    on(event, handler) { listeners.set(event, handler) },
  }
}

const routes = [
  { provider: 'synthetic-provider', model: 'fast-model', efforts: ['low'] },
  { provider: 'synthetic-provider', model: 'deep-model', efforts: ['high'] },
]
const base = { provider: 'synthetic-provider', model: 'fast-model', reasoningEffort: 'low' }

test('enabled plugin applies the typed Jev choice to model and effort', async () => {
  process.env.TYPESAFE_API_KEY = 'synthetic-test-key'
  const ctx = harness()
  apply(ctx, { enabled: true, routes, autoRoute: base, minConfidence: 0.6 })
  assert.deepEqual([...ctx.listeners.keys()], ['agent/pre-step', 'agent/request'])

  let requests = 0
  globalThis.fetch = async (_url, options) => {
    requests++
    const body = JSON.parse(options.body)
    assert.equal(body.model, 'jev-latest')
    assert.equal(body.questions.route.type, 'choice')
    assert.deepEqual(Object.keys(body.questions.route.criteria), ['keep_current', 'route_0', 'route_1'])
    assert.equal(body.state, 'Review synthetic fixture')
    assert.equal(options.headers.Authorization, 'Bearer synthetic-test-key')
    return { ok: true, async json() {
      return { answers: { route: { type: 'choice', choice: 'route_1', confidence: 0.91 } } }
    } }
  }

  const agent = {}
  const signal = new AbortController().signal
  await ctx.listeners.get('agent/pre-step')({ agent, signal }, async () => ({
    kind: 'enter', messages: [{ content: [{ type: 'text', text: 'Review synthetic fixture' }] }],
  }))
  const actual = await ctx.listeners.get('agent/request')({ agent, signal }, async () => base)
  assert.deepEqual(actual, {
    provider: 'synthetic-provider', model: 'deep-model', reasoningEffort: 'high',
  })
  assert.equal(requests, 1)
})

test('disabled or missing user key registers no hooks', () => {
  delete process.env.TYPESAFE_API_KEY
  const disabled = harness()
  apply(disabled, { enabled: false, routes })
  assert.equal(disabled.listeners.size, 0)
  const missingKey = harness()
  apply(missingKey, { enabled: true, routes, autoRoute: base })
  assert.equal(missingKey.listeners.size, 0)
})

test('uncertain or invalid choices retain deterministic downstream route', async () => {
  process.env.TYPESAFE_API_KEY = 'synthetic-test-key'
  const ctx = harness()
  apply(ctx, { enabled: true, routes, autoRoute: base, minConfidence: 0.8 })
  globalThis.fetch = async () => ({ ok: true, async json() {
    return { answers: { route: { type: 'choice', choice: 'route_1', confidence: 0.79 } } }
  } })
  const agent = {}
  const signal = new AbortController().signal
  await ctx.listeners.get('agent/pre-step')({ agent, signal }, async () => ({
    kind: 'enter', messages: [{ content: [{ type: 'text', text: 'Synthetic request' }] }],
  }))
  assert.deepEqual(await ctx.listeners.get('agent/request')({ agent, signal }, async () => base), base)

  globalThis.fetch = async () => ({ ok: true, async json() {
    return { answers: { route: { type: 'choice', choice: 'route_999', confidence: 1 } } }
  } })
  assert.deepEqual(await ctx.listeners.get('agent/request')({ agent, signal }, async () => base), base)

  globalThis.fetch = async () => ({ ok: true, async json() {
    return { answers: { route: { type: 'choice', choice: 'keep_current', confidence: 1 } } }
  } })
  assert.deepEqual(await ctx.listeners.get('agent/request')({ agent, signal }, async () => base), base)
})

test('network failure and cancellation do not change the DSH route', async () => {
  const candidates = [
    { provider: 'synthetic-provider', model: 'fast-model', reasoningEffort: 'low' },
    { provider: 'synthetic-provider', model: 'deep-model', reasoningEffort: 'high' },
  ]
  const signal = new AbortController().signal
  assert.equal(await selectCandidate({
    state: 'Synthetic task', candidates, apiKey: 'synthetic-test-key', signal,
    fetcher: async () => { throw new Error('Synthetic offline') },
  }), undefined)
  const controller = new AbortController()
  controller.abort()
  assert.equal(await selectCandidate({
    state: 'Synthetic task', candidates, apiKey: 'synthetic-test-key', signal: controller.signal,
    fetcher: async () => { throw new Error('Must not be called') },
  }), undefined)

  assert.deepEqual(await selectCandidate({
    state: 'Synthetic task', candidates, apiKey: 'synthetic-test-key',
    fetcher: async () => ({ ok: true, async json() {
      return { answers: { route: { type: 'choice', choice: 'route_1', confidence: 0.9 } } }
    } }),
  }), candidates[1])
})

test('a manually selected route bypasses Jev', async () => {
  process.env.TYPESAFE_API_KEY = 'synthetic-test-key'
  const ctx = harness()
  apply(ctx, { enabled: true, routes, autoRoute: base })
  let calls = 0
  globalThis.fetch = async () => { calls++; throw new Error('unexpected Jev call') }
  const agent = {}
  const signal = new AbortController().signal
  await ctx.listeners.get('agent/pre-step')({ agent, signal }, async () => ({
    kind: 'enter', messages: [{ content: [{ type: 'text', text: 'Synthetic task' }] }],
  }))
  const manual = { provider: 'synthetic-provider', model: 'deep-model', reasoningEffort: 'high' }
  assert.deepEqual(await ctx.listeners.get('agent/request')({ agent, signal }, async () => manual), manual)
  assert.equal(calls, 0)
})
