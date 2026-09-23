/**
 * Optional Jev route selector for a DSH Cordis profile.
 *
 * The TypeSafe call is a typed classification over an explicit allowlist. It
 * never executes tools, changes approval policy, or supplies an LLM adapter.
 * Nothing is sent when disabled, unconfigured, or missing the user's API key.
 */

export const name = 'dsh-jev-route-selector'
export const inject = ['agents']

const API_URL = 'https://api.typesafe.ai/v1/systemone'
const MAX_STATE_CHARS = 2048
// Choice accepts at most 255 options; reserve one for leaving DSH's route unchanged.
const MAX_CANDIDATES = 254
const MAX_TIMEOUT_MS = 10_000

function nonempty(value) {
  return typeof value === 'string' && value.trim().length > 0
}

function textOf(message) {
  if (!Array.isArray(message?.content)) return ''
  return message.content
    .filter((block) => block?.type === 'text' && typeof block.text === 'string')
    .map((block) => block.text)
    .join('\n')
}

function candidatesFrom(routes) {
  if (!Array.isArray(routes)) return []
  const candidates = []
  for (const route of routes) {
    if (!nonempty(route?.provider) || !nonempty(route?.model)) continue
    const efforts = Array.isArray(route.efforts) && route.efforts.length > 0
      ? route.efforts : [null]
    for (const effort of efforts) {
      if (effort !== null && !nonempty(effort)) continue
      const candidate = {
        provider: route.provider.trim(),
        model: route.model.trim(),
        ...(effort === null ? {} : { reasoningEffort: effort.trim() }),
      }
      if (!candidates.some((other) => sameCandidate(other, candidate))) {
        candidates.push(candidate)
      }
    }
  }
  return candidates.length <= MAX_CANDIDATES ? candidates : []
}

function sameCandidate(left, right) {
  return left.provider === right.provider && left.model === right.model &&
    left.reasoningEffort === right.reasoningEffort
}

function isConfiguredAutoRoute(value) {
  return nonempty(value?.provider) && nonempty(value?.model) &&
    (value.reasoningEffort === undefined || nonempty(value.reasoningEffort))
}

function isFiniteProbability(value) {
  return typeof value === 'number' && Number.isFinite(value) && value >= 0 && value <= 1
}

function signalWithTimeout(parent, timeoutMs) {
  const duration = Number.isSafeInteger(timeoutMs) && timeoutMs > 0
    ? Math.min(timeoutMs, MAX_TIMEOUT_MS) : 2500
  const timeout = AbortSignal.timeout(duration)
  return parent ? AbortSignal.any([parent, timeout]) : timeout
}

/**
 * Returns a candidate from the configured allowlist, or undefined on any
 * unavailable/uncertain response. The caller keeps DSH's downstream config.
 */
export async function selectCandidate({ state, candidates, apiKey, minConfidence = 0.65,
  timeoutMs = 2500, signal, fetcher = globalThis.fetch }) {
  if (!nonempty(state) || !nonempty(apiKey) || !Array.isArray(candidates) ||
      candidates.length < 2 || candidates.length > MAX_CANDIDATES || signal?.aborted ||
      typeof fetcher !== 'function') return undefined

  const threshold = isFiniteProbability(minConfidence) ? minConfidence : 0.65
  const criteria = { keep_current: 'No listed route is clearly better; preserve the existing DSH route.' }
  for (const [index, candidate] of candidates.entries()) {
    criteria[`route_${index}`] =
      `Provider ${candidate.provider}; model ${candidate.model}; reasoning effort ${candidate.reasoningEffort ?? 'provider default'}`
  }
  try {
    const response = await fetcher(API_URL, {
      method: 'POST',
      headers: {
        Authorization: `Bearer ${apiKey}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({
        model: 'jev-latest',
        state: state.slice(0, MAX_STATE_CHARS),
        questions: {
          route: {
            type: 'choice',
            instructions: 'Choose the best configured coding-agent route and reasoning effort for this task. Choose only from the listed options.',
            criteria,
          },
        },
      }),
      signal: signalWithTimeout(signal, timeoutMs),
    })
    if (!response.ok) return undefined
    const answer = (await response.json())?.answers?.route
    if (answer?.type !== 'choice' || !isFiniteProbability(answer.confidence) ||
        answer.confidence < threshold) return undefined
    if (answer.choice === 'keep_current') return undefined
    const match = /^route_(\d+)$/.exec(answer.choice ?? '')
    if (!match) return undefined
    const index = Number(match[1])
    return Number.isSafeInteger(index) ? candidates[index] : undefined
  } catch {
    // Avoid leaking prompts, responses, or credentials into DSH's logs.
    return undefined
  }
}

export function apply(ctx, config = {}) {
  if (config.enabled !== true) return
  const candidates = candidatesFrom(config.routes)
  // The explicit base route is the only signal this plugin has that the Web
  // user's selector is in Auto. Other/manual routes must pass through untouched.
  if (candidates.length < 2 || !isConfiguredAutoRoute(config.autoRoute) ||
      !nonempty(process.env.TYPESAFE_API_KEY)) return

  const acceptedText = new WeakMap()
  ctx.on('agent/pre-step', async ({ agent, signal }, next) => {
    const decision = await next()
    if (decision.kind === 'enter' && !signal.aborted) {
      const latest = decision.messages.map(textOf).filter(nonempty).at(-1)
      if (latest) acceptedText.set(agent, latest.slice(0, MAX_STATE_CHARS))
    }
    return decision
  })

  ctx.on('agent/request', async ({ agent, signal }, next) => {
    const downstream = await next()
    if (signal.aborted) return downstream
    if (!sameCandidate(downstream, config.autoRoute)) return downstream
    const state = acceptedText.get(agent)
    if (!state) return downstream
    const selected = await selectCandidate({
      state,
      candidates,
      apiKey: process.env.TYPESAFE_API_KEY,
      minConfidence: config.minConfidence,
      timeoutMs: config.timeoutMs,
      signal,
    })
    if (!selected || signal.aborted) return downstream
    const { reasoningEffort: _priorEffort, ...withoutPriorEffort } = downstream
    return { ...withoutPriorEffort, ...selected }
  }, { prepend: true })
}
