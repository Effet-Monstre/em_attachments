import { defineConfig } from 'vitepress'

export default defineConfig({
  title: 'EmAttachments',
  description: 'File attachment library for Elixir, inspired by Shrine for Rails.',

  // Keep '/em_attachments/' for GitHub Pages (github.io/<repo> subdirectory).
  // Change to '/' only if you add a custom domain.
  base: '/em_attachments/',

  themeConfig: {
    nav: [
      { text: 'Guide', link: '/guide/getting-started' },
      // Update this URL once the package is published on Hex.pm
      { text: 'Hex.pm', link: 'https://hex.pm/packages/em_attachments' },
    ],

    sidebar: [
      {
        text: 'Guide',
        items: [
          { text: 'Getting Started', link: '/guide/getting-started' },
          { text: 'Configuration', link: '/guide/configuration' },
        ],
      },
    ],

    socialLinks: [
      { icon: 'github', link: 'https://github.com/Effet-Monstre/em_attachments' },
    ],

    footer: {
      // Update if your license differs — check for a LICENSE file in the repo
      message: 'Released under the MIT License.',
    },
  },
})
