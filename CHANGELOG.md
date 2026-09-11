# Changelog

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
