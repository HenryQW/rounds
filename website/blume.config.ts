import { colors } from "@henryqw/theme/tokens";
import { defineConfig } from "blume";

export default defineConfig({
  title: "Rounds",
  description:
    "Your agents work in parallel. You need to stay sober. Rounds keeps a tab on every Claude Code, Codex and herdr session and calls you when one needs you.",
  feedback: false,
  footer: {
    links: [
      { label: "About Henry", href: "https://henry.wang" },
      { label: "Henry Pi Harness", href: "https://pi.henry.wang" },
      { label: "MIT License", href: "https://github.com/HenryQW/rounds/blob/main/LICENSE" },
      { label: "GitHub", href: "https://github.com/HenryQW/rounds" },
    ],
  },
  logo: { image: "/icon.png", text: "Rounds" },
  deployment: {
    site: "https://rounds.henry.wang",
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
      "/sources",
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
