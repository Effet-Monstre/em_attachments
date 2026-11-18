# Changelog

## 0.4.0

Signed uploads are back, as the library's own: nothing a client sends is trusted unless the
library signed it, and a file reaches one record.

### Breaking

- **`cast_attachments/3` refuses unsigned files.** A serialized file (JSON string or map)
  from params is now an `"is invalid"` error unless it only names the current file again.
  Hand clients `MyUploader.sign(file)`; `to_string(file)` (what `form[:field].value`
  renders) now returns it, so hidden-input resubmission keeps working unchanged. Server code
  attaching a file it stored itself passes the uploader's struct. No atom is created from
  client input any more (`String.to_atom` on decoded keys, `to_existing_atom` on the
  `uploader` field).
- **`config :em_attachments, :config, secret_key:` is required** (32 bytes at least) to sign.
- **A file is claimed once.** Saving a record with a token turns its tracking row from
  `pending` to `permanent`; a second record, an expired upload or a released file is refused
  (`"has already been used or has expired"`). Applications that attached one upload to
  several records must upload (or copy) once per record.
- **`EmAttachments.Plug.Upload` answers `{token, id, filename, size, content_type}`**
  instead of the serialized file, and its errors are `{error, message}` with a code.
- **`Mime` reads the `ftyp` brand.** Only playable brands are `video/mp4`; QuickTime is
  `video/quicktime` (`.mov`), HEIF `image/heic`, AVIF `image/avif`, 3GPP `video/3gpp`, M4A
  `audio/mp4`, an unknown brand no type. Uploaders accepting `video/mp4` for iPhone videos
  should add `video/quicktime`.
- **Stored filenames are sanitized** (`metadata.filename`): last path segment, no control
  characters or quotes, 120 characters at most with the extension kept, `nil` when empty.
- **The S3 presigned POST writes exactly its key** (it allowed any key starting with it) and
  takes `:max_size` as a `content-length-range`.
- `cast/1` of an uploader's Ecto type takes a signed token only.

### Added

- **`EmAttachments.Router.attachments/2`** mounts an uploader's routes in a Phoenix router
  under one path: the upload slot (`POST <path>`, answering its `complete_url` too), the Local
  slot and its completion, and `GET <path>/:token`.
- **Files' URLs** (`EmAttachments.Plug.File`, `url_token/2`, `verify_url_token/1`): a signed
  token names a file and its download name; the plug redirects to the store's short-lived
  URL, a `404` once no record holds the file. Stable for a period, so browsers keep files.
- `EmAttachments.Signer.sign_until/3`: a token with a fixed expiry.

- `EmAttachments.Signer` and `MyUploader.sign/1`, `verify/1`.
- Direct uploads: `MyUploader.presign/1` (a slot, tracked so the Sweeper removes it if never
  completed) and `complete/2` (size and first bytes checked, object copied to its asset id,
  slot removed). `EmAttachments.Plug.Upload` mounts them: `POST /presign`, `POST /local`
  (the Local backend's slot), `POST /complete`, and `POST /` as before, with `:validates`,
  `:max_size` and `:on_storage_error` options; or route by route (`:action`, `:local_url`).
- Backend callbacks `head/2` and `get_range/4` (Local and S3); `BackendFile.read_head/2` and
  `Mime.detect_source/1` sniff a stored file from 16 bytes instead of downloading it.
- Call-time validations and size limit: `MyUploader.upload(input, validates: [...],
  max_size: n)`.
- `EmAttachments.Ecto.release/2` for records deleted without a changeset.
- `EmAttachments.download_name/2`, `EmAttachments.Error.message/1`.

## 0.3.3

Dependency maintenance. No requirement in `mix.exs` changed: every lower bound stays where
it was, so this release asks nothing new of an application.

### Tested against

The library is now developed and tested against Ecto 3.14.3 (was 3.14.2), Phoenix 1.8.16
(was 1.8.15), Vix 0.43.0 (was 0.42.0), Decimal 3.2.0, Plug.Crypto 2.2.1, WebSockAdapter
0.7.2, NimbleOptions 1.2.0 and NimblePool 1.2.0.

### Advisories

The versions above carry the fixes for EEF-CVE-2026-118391 (Ecto, HIGH: unbounded query
cache growth from interpolated JSON paths and splice lists), EEF-CVE-2026-97853 (Decimal,
MEDIUM: unbounded allocation in `Decimal.round/3`) and EEF-CVE-2026-105963 (Plug.Crypto,
MEDIUM: secret key base exposed in stack trace arguments). This library's lockfile does
not reach your application: run `mix hex.audit` in your own project and update what it
reports.

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
