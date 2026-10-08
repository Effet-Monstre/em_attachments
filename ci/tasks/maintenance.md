# Dependency maintenance for this library

This is a library that applications install by Git tag. That changes what a safe bump is, so these rules add to the shared maintenance task.

## Requirements and the lockfile

- `mix.lock` only pins what this repository develops and tests against. Update it freely.
- A requirement in `mix.exs` is what every consuming application must satisfy. Never narrow one. Raise a lower bound only when the code here now needs a newer API, and name that dependency and the reason in `CHANGELOG.md`, because it can break an application on its next upgrade.
- The optional dependencies (`ecto`, `plug`, `vix`, `mogrify`, `phoenix`) are chosen by the application. Test against their latest versions, but keep their requirements as wide as the code allows.
- `package.json` only builds the documentation site. Treat it like any other Node project.

## Gates

Bring the project up per `ci/tasks/setup.md`, then run all of these, in full, and get each one green:

```sh
MIX_ENV=test mix compile --warnings-as-errors
mix test
mix hex.audit
mix deps.unlock --check-unused
npm run docs:build
```

`mix test` only counts with Postgres up: its output must not contain `Postgres unavailable`, and its summary must report 0 failures.

## Where the summary goes

Write the run summary to `maintenance/YYYY-MM.md` at the repository root, not under `docs/`, which is the published documentation site. Everything else about that file follows the shared task.

## Versioning

Only when the run committed a dependency change, so never for a summary alone:

1. Take the highest tag, `git tag --list 'v*' --sort=-v:refname | head -1`, and add one to its patch: `v0.3.1` gives `0.3.2`.
2. Set `version` in `mix.exs` to it.
3. Add a `## <version>` section at the top of `CHANGELOG.md` listing what changed for an application: raised lower bounds first, then the notable updates, then the advisories fixed.
4. Commit with the subject `chore: release v<version>`.
5. Write the version, alone, to `ci-artifacts/version`. The workflow tags `v<version>` on the merged commit; do not create the tag yourself.
