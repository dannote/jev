# Changelog

## 0.2.0 (2026-09-21)

The `/v1/systemone` wire format is now served by open decision models as well
as TypeSafe. This release lets one application talk to several of them.

- Named endpoints: `config :jev, endpoints: [laya: [base_url: ...]]` and `endpoint: :laya`
  per call, from `Jev.HTTP.post/3` or a `Jev.Server` reply. `config :jev, endpoint:` changes
  the default from `:typesafe`. `Jev.HTTP.endpoint/1` returns the resolved settings.
- A named endpoint sends no `Authorization` header unless it has an `api_key`, and its
  `usd_per_million_input` defaults to zero. Transport settings are inherited from the
  top-level configuration.
- `Jev.reply/3` and `Jev.cost/2` take the price. When a server omits `confidence`, it is
  computed from the probabilities as TypeSafe defines it.
- Telemetry metadata and `Jev.Error` carry the `endpoint` name.

## 0.1.1 (2026-09-18)

- `Jev.Server` accepts `{:ok, state, timeout | {:continue, term}}` from `init/1`. Previously the
  extra element was passed through unwrapped and the first callback crashed.
- `terminate/2` and `code_change/3` are delegated to the callback module when defined.
- `use Jev.Server` takes child spec options such as `restart:` and `shutdown:`, as `use GenServer` does.
- Default `handle_call/3` and `handle_cast/2` stop the server with GenServer's "no clause was
  provided" error instead of an `UndefinedFunctionError`, and the default `handle_info/2` logs
  the unexpected message instead of dropping it silently.

## 0.1.0 (2026-09-17)

- `Jev.Noul`, `Jev.Choice`, `Jev.Score` question structs with shorthands via `Jev.questions/1`.
- `Jev.reply/2` turns an API response into a plain map with atom labels.
- `Jev.HTTP.post/3` transport on Req with retry on 429 and 529.
- `Jev.Server`: a GenServer where `{:reply, {tag, state, questions}, s}` sends to Jev and
  `handle_answer/3` receives the reply.
- Telemetry spans per request and one event per answer, with cost from the published price.
