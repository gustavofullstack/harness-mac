# Integration contract

DSH.app is a native macOS host for the installed DeepSeek Harness Web UI. Its Swift code owns
the window and the local `dsh --profile web` process. The UI, model catalog, agent runtime,
permissions, and plugin registry come from the installed `dsh` version.

```text
DSH.app (AppKit + WKWebView)
  └── dsh web on 127.0.0.1 (owned for the app lifetime)
       ├── models: DSH provider adapters or an authorized local gateway
       ├── full agents: DSH subagent plugins, CLI, SDK, or ACP adapters
       └── tools and data: DSH plugins and MCP connectors
```

The app starts a fresh server, loads the authenticated URL printed by that server, and stops
it when the app quits. It never reads a provider's OAuth tokens or credentials. A subscription
to one coding app does not imply API access to its model. Configure each transport with the
provider's supported client or the installed DSH settings; test a real request before calling
the route connected.

## Optional public integrations

**Settings…** (⌘,) starts Jev and OmniRoute disabled. A user can save their own API keys
in macOS Keychain and then enable each integration. The app filters `TYPESAFE_API_KEY`,
`JEV_API_KEY`, `OMNI_ROUTER_API_KEY`, and `OMNIROUTER_API_KEY` from the login shell's
environment before starting `dsh`. It only supplies `TYPESAFE_API_KEY` or
`OMNI_ROUTER_API_KEY` from the enabled Keychain entry. The public bundle contains no owner
credential, profile, endpoint, or default key. Removing a key turns its switch off.

The switches authorize key forwarding; they do not install a Jev adapter or OmniRoute
model provider. A Jev adapter must actually call TypeSafe and apply a typed decision at
the correct gate. An OmniRoute route needs a DSH provider configuration that uses
`apiKeyEnv: OMNI_ROUTER_API_KEY`. A saved key is not proof of a successful request.
Restart Harness after changing either switch. Existing user-owned `$DSH_HOME` settings
may still reference local gateways or credentials outside these two settings; the app
does not silently rewrite those files.

RAG, rerank, brain, memory, summaries, graph, and extension registries remain dependent
on actual DSH plugins or services. The Settings panel identifies that boundary and the
installed DSH Web settings remain available for those adapters. There is no built-in
first-party runtime implementation of these features in the Swift shell yet.

## Model and effort selection

DSH stores a provider and model as separate fields. A custom model has no Effort menu until
`reasoningEfforts` is declared for that model in `$DSH_HOME/settings.yaml`. The menu keys
supported by the installed `dsh-llm-pi-ai` version are `off`, `minimal`, `low`, `medium`,
`high`, `xhigh`, and `max`. The values are the actual wire spellings for that route.
Do not create one model ID per effort. Leaving effort unset is the route's automatic mode;
whether that invokes Jev depends on the configured gateway.

For example, after verifying that a local gateway honors these values:

```yaml
llm-pi-ai:
  providers:
    local-gateway:
      api: openai-completions
      baseURL: http://127.0.0.1:PORT/v1
      apiKeyEnv: LOCAL_GATEWAY_KEY
      models:
        - id: verified-model-id
          reasoningEfforts:
            low: low
            medium: medium
            high: high
            xhigh: xhigh
```

The `max` key is displayed as Max by upstream DSH. An exact “Ultra Code” label would require
an upstream UI change. Only expose a maximum level for a route that supports it and only
select it explicitly. Jev cannot be used as a generative code model.

## Jev and agent coverage

An authorized Jev gateway may classify the request before dispatch and score the result after
it returns. Deterministic code still decides permissions, process lifetime, and budgets.
Coverage is recorded independently for each adapter:

| Gate | Evidence required |
|---|---|
| `JEV_PRE_DISPATCH` | Decision trace and actual selected route before the request |
| `JEV_TOOL_GATE` | An adapter exposes internal tool actions and enforces the returned decision |
| `JEV_POSTCHECK` | Result trace and a scored output actually available to the gateway |

The shell alone provides none of these gates. A local proxy's pre-dispatch and postcheck
do not imply supervision of tools inside Codex, Claude Code, or another delegated agent.

## Current product boundary

This release proves the native web lifecycle and SDK smoke route, with a reproducible
off-screen reconnect test. It does not yet include a first-party OAuth connection wizard,
a one-click extension marketplace, a native Swift agent executor, or mobile remote control.
The installed DSH Web UI already offers model, plugin, and agent-preset settings; this app
loads those screens unchanged. Add a new integration only with a specific protocol,
authentication flow, capability list, failure behavior, and end-to-end test.

For a controlled model check, run `harness-smoke` with `HARNESS_SMOKE_EXPECT` set to the exact
synthetic reply. A successful process exit without that assertion is only evidence that an
assistant message arrived. `webserver-smoke` and `scripts/reconnect-smoke.py` exercise the real
server lifecycle without using the foreground display.
