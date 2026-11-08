// The documentation at docs.openarch.app (Starlight). `npm run dev` shows it
// while you write; `npm run build` makes dist/, which wrangler.toml serves.
import { defineConfig } from 'astro/config';
import starlight from '@astrojs/starlight';

const fonts =
  'https://fonts.googleapis.com/css2?family=Bricolage+Grotesque:opsz,wght@12..96,600;12..96,700;12..96,800&family=Instrument+Sans:wght@400;500;600&family=JetBrains+Mono:wght@500&display=swap';

export default defineConfig({
  site: 'https://docs.openarch.app',
  integrations: [
    starlight({
      title: 'OpenArch Docs',
      description:
        'How OpenArch works: the sidebar, spaces, the command bar, split view, sharing, the AI features and how they reach Claude.',
      logo: { src: './src/assets/icon.png' },
      favicon: '/favicon.png',
      social: [{ icon: 'github', label: 'GitHub', href: 'https://github.com/dpfaffenbauer/OpenArch' }],
      editLink: { baseUrl: 'https://github.com/dpfaffenbauer/OpenArch/edit/main/docs-site/' },
      customCss: ['./src/styles/openarch.css'],
      head: [
        { tag: 'link', attrs: { rel: 'preconnect', href: 'https://fonts.googleapis.com' } },
        { tag: 'link', attrs: { rel: 'preconnect', href: 'https://fonts.gstatic.com', crossorigin: true } },
        { tag: 'link', attrs: { rel: 'stylesheet', href: fonts } },
      ],
      sidebar: [
        {
          label: 'Start here',
          items: ['start/install', 'start/tour', 'start/import-from-arc'],
        },
        {
          label: 'Sidebar',
          items: [
            'sidebar/basics',
            'sidebar/spaces',
            'sidebar/tabs',
            'sidebar/live-folders',
            'sidebar/cards',
            'sidebar/appearance',
          ],
        },
        {
          label: 'Browsing',
          items: [
            'browsing/command-bar',
            'browsing/split-view',
            'browsing/peek',
            'browsing/windows',
            'browsing/library',
            'browsing/site-controls',
            'browsing/links',
            'browsing/chrome',
          ],
        },
        {
          label: 'AI',
          items: [
            'ai/how-it-works',
            'ai/page-chat',
            'ai/skills',
            'ai/morning-brief',
            'ai/tidy-tabs',
            'ai/agent-chats',
            'ai/ai-control',
            'ai/web-chats',
          ],
        },
        {
          label: 'Sharing',
          items: ['sharing/share', 'sharing/how-it-works'],
        },
        'iphone-ipad',
        {
          label: 'Reference',
          items: [
            'reference/shortcuts',
            'reference/settings',
            'reference/data-and-privacy',
            'reference/limitations',
          ],
        },
        {
          label: 'Development',
          collapsed: true,
          items: ['development/build', 'development/architecture'],
        },
      ],
    }),
  ],
});
