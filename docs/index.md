---
layout: home

hero:
  name: EmAttachments
  text: File attachments for Elixir
  tagline: Upload to cache, promote to store, run plugins, save metadata — inspired by Shrine for Rails.
  actions:
    - theme: brand
      text: Get Started
      link: /guide/getting-started
    - theme: alt
      text: View on GitHub
      link: https://github.com/Effet-Monstre/em_attachments

features:
  - title: Two-phase lifecycle
    details: Files land in cache on upload and move to permanent storage on save — always via a clean, auditable pipeline.
  - title: Plugin system
    details: MIME detection, dimension validation, and derivative generation hook into every phase without coupling your uploader code.
  - title: Ecto-native
    details: Each uploader is an Ecto.Type — use cast_attachments/3 in your changeset like any other field.
  - title: Multiple backends
    details: Local filesystem for development, S3 (no ExAws) for production, or bring your own backend with a five-function behaviour.
---
