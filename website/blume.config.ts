import { projectLinks } from "@henryqw/theme/projects";
import { colors } from "@henryqw/theme/tokens";
import { defineConfig } from "blume";

const site = "https://rounds.henry.wang";

export default defineConfig({
  title: "Rounds",
  description:
    "Your agents work in parallel. You need to stay sober. Rounds keeps a tab on every Claude Code, Codex and herdr session and calls you when one needs you.",
  feedback: false,
  footer: {
    links: [
      { label: "About Henry", href: "https://henry.wang" },
      ...projectLinks(site),
      { label: "MIT License", href: "https://github.com/HenryQW/rounds/blob/main/LICENSE" },
      { label: "GitHub", href: "https://github.com/HenryQW/rounds" },
    ],
  },
  logo: { image: "/icon.png", text: "Rounds" },
  // Share cards in the colours of the dark site, with the app icon; the home page has its own picture (pages/index.astro).
  seo: {
    og: {
      logo: "/icon.svg",
      palette: {
        accent: colors.accentSoft,
        background: colors.inverseBackground,
        foreground: colors.inverseForeground,
        muted: colors.inverseMuted,
        border: colors.inverseBorder,
      },
    },
  },
  deployment: {
    site,
  },
  github: {
    owner: "HenryQW",
    repo: "rounds",
    dir: "website",
  },
  navigation: {
    sidebar: [
      "/overview",
      "/how-it-works",
      "/glossary",
      "/agents",
      "/tickets",
      "/notifications",
      "/install",
      "/keys",
      "/build",
      "/release",
    ],
  },
  theme: {
    accent: { dark: colors.accentSoft, light: colors.accent },
    background: { dark: colors.inverseBackground, light: colors.background },
    fonts: { body: "geist", display: "geist", mono: "geist-mono" },
    radius: "sm",
  },
});
