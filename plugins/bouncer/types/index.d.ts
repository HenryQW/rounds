export type Pool = {
  /** True once this session acts as the Bouncer. */
  isOn: boolean
  /** Bartender session id to its last title, as the Bouncer set it. */
  bartenders: Record<string, string>
  /** Questions that wait on the user: the n of the Bouncer's own `!<n> 🚪 Bouncer` title. */
  waiting: number
  /** Lines in `queue.md` in the plugin's data folder. */
  queue: number
  /** The lines of `queue.md`; absent in a value an earlier version stored. */
  queueLines?: readonly string[]
  /** True while the band lists the queue's lines. */
  queueOpen?: boolean
  /** True from a band prompt until the Bouncer's turn ends: the band sends one prompt at a time. */
  pending?: boolean
  /** Bartender session id to its open question for the user, from `questions.md`. */
  questions?: Readonly<Record<string, string>>
  /** The `bouncer-ledger list --all` lines, open and done (done ones keep their PR URLs); absent in a value an earlier version stored. */
  ledgerLines?: readonly string[]
  /** Each Bartender's last report text, kept for the full PR URLs its EVIDENCE names. */
  reportTexts?: Readonly<Record<string, string>>
  /** The `bouncer-ledger due` lines: open items whose check says the user must act now. Read once a turn. */
  due?: readonly string[]
  /** A PR's full URL to its GitHub state (lower case) and base branch, read with `gh` once a turn for the open pr ledger items. */
  prs?: Readonly<Record<string, { state?: string; base?: string }>>
  /** True while the band lists the due items. */
  ledgerOpen?: boolean
  /** True while another session holds the Bouncer (`bouncer` in the plugin's data folder names it). */
  isOther?: boolean
  /** Bartender session id to the STATUS of its last turn-end report (`bouncer-report`). */
  reports?: Readonly<Record<string, string>>
  /** Bartender session id to whether its session runs a turn now (`list_sessions` `isRunning`). */
  running?: Readonly<Record<string, boolean>>
  /** Bartender session id to its linked session (`list_sessions`): folder, last activity, PR, and the PR's URL when its repo is on GitHub. */
  sessions?: Readonly<Record<string, { cwd?: string; branch?: string; at?: string; pr?: { number: number; state?: string } }>>
  /** Bartender session id to the sub-line of its last report: the wait reason, else the RESULT. */
  notes?: Readonly<Record<string, string>>
  /** True while the system appearance is dark: the band picks Linear's dark tokens, else the light ones. */
  dark?: boolean
  /** True when the band shows the columns (Details); false is Compact. Kept across sessions in `$.store` `details`. */
  details?: boolean
  /** The column whose actions show in place of its sub-line (its key). */
  menu?: string
  /** True once the Bouncer pane could not show: Details then shows in the band, its cards scrolling sideways. */
  paneless?: boolean
  /** The Stop or Reset action (its value) that waits for its second click; cleared after 5 seconds. */
  confirm?: string
}

declare module 'claude-code' {
  interface PluginState {
    'bouncer': { pool: Pool }
  }
}
