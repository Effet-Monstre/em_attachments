# Bringing this project up in CI

The image built from `Kranqfile` already holds Erlang/OTP and Elixir at the versions `.tool-versions` pins, Hex and rebar, Node at the version `.nvmrc` pins, ImageMagick (`magick`), the Hex cache for `mix.lock`, and the Postgres 17 image. What is left needs the checkout:

```sh
bash ci/tasks/install-beam.sh
bash ci/tasks/install-node.sh
export PATH=/opt/ci/elixir/bin:/opt/ci/otp/bin:/opt/ci/node/bin:$PATH
docker compose up -d --wait db
mix deps.get
npm ci
```

Both install scripts do nothing when the installed version already matches its pin. Run them again after changing `.tool-versions` or `.nvmrc`.

## Traps

- **A green `mix test` without Postgres means nothing.** `test/test_helper.exs` catches the connection failure, prints `WARNING: Postgres unavailable — DB tests skipped.` and excludes about 60 tests. Always start the database first, and treat that warning in the output as a failed run.
- **The database listens on port 5437**, not 5432. `test/test_helper.exs` uses `postgres://dev:dev@localhost:5437/em_attachments_test` unless `DATABASE_URL` says otherwise, which matches `docker-compose.yml`.
- **OTP 27.2 cannot talk to `builds.hex.pm` here.** Its certificate check rejects a root in Debian 13's store (`key_usage_mismatch`), so `mix local.hex` and `mix deps.get` fail. That is why `.tool-versions` pins a later OTP 27; do not move it back.
- **`docs/` is the published documentation site.** VitePress turns every Markdown file under it into a page. Nothing internal goes there.
- **The code is not `mix format` clean yet**, and CI does not check it. Leave formatting alone unless the task is about formatting.
