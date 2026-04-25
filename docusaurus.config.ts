import {themes as prismThemes} from 'prism-react-renderer';
import type {Config} from '@docusaurus/types';
import type * as Preset from '@docusaurus/preset-classic';

const config: Config = {
  title: 'NoETL E2E',
  tagline: 'End-to-end integration fixtures, playbooks, and local kind test workflows for NoETL.',
  favicon: 'img/favicon.ico',

  future: {
    v4: true,
  },

  url: 'https://e2e.noetl.dev',
  baseUrl: '/',
  organizationName: 'noetl',
  projectName: 'e2e',
  onBrokenLinks: 'warn',
  markdown: {
    hooks: {
      onBrokenMarkdownLinks: 'warn',
    },
  },

  i18n: {
    defaultLocale: 'en',
    locales: ['en'],
  },

  plugins: [
    [
      '@cmfcmf/docusaurus-search-local',
      {
        indexBlog: false,
      },
    ],
  ],

  presets: [
    [
      'classic',
      {
        docs: {
          routeBasePath: '/',
          sidebarPath: './sidebars.ts',
          editUrl: 'https://github.com/noetl/e2e/edit/main/',
          exclude: ['**/*.yaml', '**/*.yml'],
        },
        blog: false,
        theme: {
          customCss: './src/css/custom.css',
        },
      } satisfies Preset.Options,
    ],
  ],

  themeConfig: {
    colorMode: {
      respectPrefersColorScheme: true,
    },
    navbar: {
      title: 'NoETL E2E',
      items: [
        {
          type: 'docSidebar',
          sidebarId: 'docsSidebar',
          position: 'left',
          label: 'Docs',
        },
        {
          to: '/playbooks/',
          position: 'left',
          label: 'Playbooks',
        },
        {
          to: '/credentials/',
          position: 'left',
          label: 'Credentials',
        },
        {
          href: 'https://noetl.dev',
          label: 'NoETL Docs',
          position: 'right',
        },
        {
          href: 'https://github.com/noetl/e2e',
          label: 'GitHub',
          position: 'right',
        },
      ],
    },
    footer: {
      style: 'dark',
      links: [
        {
          title: 'E2E',
          items: [
            {
              label: 'Quickstart',
              to: '/',
            },
            {
              label: 'Playbook Inventory',
              to: '/playbooks/',
            },
            {
              label: 'Registration',
              to: '/registration/',
            },
          ],
        },
        {
          title: 'NoETL',
          items: [
            {
              label: 'Main Documentation',
              href: 'https://noetl.dev',
            },
            {
              label: 'Core Repository',
              href: 'https://github.com/noetl/noetl',
            },
          ],
        },
      ],
      copyright: `Copyright © ${new Date().getFullYear()} NoETL Project. Built with Docusaurus.`,
    },
    prism: {
      theme: prismThemes.github,
      darkTheme: prismThemes.dracula,
    },
  } satisfies Preset.ThemeConfig,
};

export default config;
