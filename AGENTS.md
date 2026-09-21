# VibeKit quality gate

## Development

```sh
mix deps.get
mix ci
```

## Conventions

- Use `mix ci` for the full validation suite before finishing changes.
- For Phoenix/web apps, keep Phoenix's generated guidance, but treat this VibeKit section as the final quality gate.
- For non-web Elixir projects, VibeKit is the default project baseline.
- Keep changes small, tested, and formatted.

## Commits

Commit messages follow [Conventional Commits](https://www.conventionalcommits.org):
`type(scope): imperative summary`, lower case, no trailing period.

- Types: `feat`, `fix`, `refactor`, `docs`, `test`, `perf`, `ci`, `chore`.
- Scopes are modules: `http`, `server`, `reply`, `questions`, `telemetry`; omit the
  scope when a change spans them.
- Releases are `chore(release): x.y.z`. Breaking changes carry a `!` after the scope
  and a `BREAKING CHANGE:` footer.
