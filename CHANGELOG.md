# Changelog

## 0.3.2

Dependency maintenance. No requirement in `mix.exs` changed: every lower bound stays where
it was, so this release asks nothing new of an application.

### Tested against

The library is now developed and tested against Req 0.7.5 (was 0.5.17), Ecto 3.14.2 and
Ecto SQL 3.14.0 (were 3.13.5), Phoenix 1.8.15 (was 1.8.5), Plug 1.20.3 (was 1.19.1),
Vix 0.42.0 (was 0.38.0), Postgrex 0.22.4 (was 0.22.0), Finch 0.24.0, Mint 1.11.0 and
Decimal 3.1.1. The `~> 0.5` requirement on Req already allowed 0.6 and 0.7, and the S3
backend and the `UrlUpload` plugin work unchanged on both sides of that line.

If you pass `:req_options` to the S3 backend or to `UrlUpload`, note that Req 0.6 made
response decompression opt-in (`compressed: true`) and archive decoding opt-in
(`decoders:`), and Req 0.7 deprecated `finch: name` in favour of `finch: [name: name]`.

### Advisories

The versions above carry the fixes for advisories against Req (decompression bomb,
multipart header injection), Mint, HPAX, Plug, Phoenix, Postgrex and Decimal. This
library's lockfile does not reach your application: run `mix hex.audit` in your own
project and update what it reports.

## 0.3.0

### Storage keys and asset IDs

Asset IDs are now UUIDv7 with the detected file extension appended, so objects land at
`uploads/019bf3c2-7a41-7c9e-b8d2-3f1a2b4c5d6e.jpg` instead of
`uploads/Xk3-q_9ZaTbW8vNc2LdRfg`. Derivatives use the same scheme; they previously used a
shorter, weaker 64-bit ID.

**No migration is required and no existing object moves.** An asset's ID has always been
its storage key's basename, and that still holds, so legacy keys keep resolving.

### Content types

Objects are now written with the `Content-Type` detected from their bytes. Previously
nothing was sent and everything served as `binary/octet-stream`, which made browsers
download files instead of rendering them.

Detection runs whether or not the `Mime` plugin is declared — the plugin adds validation
and the `metadata.plugins.mime` entry on top of it. Files whose format is unrecognised are
stored with no content type and no extension rather than a guessed one.

S3 `CopyObject` (used by `reprocess/2` and same-bucket uploads) now sets
`x-amz-metadata-directive: REPLACE`, so a copy no longer inherits a missing content type
from its source.

Objects uploaded before 0.3.0 keep their missing content type until they are re-uploaded or
reprocessed.

New optional S3 backend option `content_disposition: :inline | :attachment`, which sends a
`Content-Disposition` header carrying the original filename. Omitted entirely by default.

### Removed

- `EmAttachments.Signer` — dead code. It signed IDs for the cache phase removed in 0.2, was
  referenced by nothing outside its own test, and its `"id.signature"` format could not
  survive IDs containing a dot.
- `EmAttachments.Config.secret_key!/0`, the only consumer of the `:secret_key` config key.
  Leaving `secret_key:` in your config is harmless; nothing reads it. Serialized file
  payloads are plain JSON and never were signed, despite what the README claimed.
