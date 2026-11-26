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
  /** Open items in the records' LEDGER sections (`bouncer-ledger list`); absent in a value an earlier version stored. */
  ledger?: number
  /** The `bouncer-ledger list` lines; absent in a value an earlier version stored. */
  ledgerLines?: readonly string[]
  /** True while the band lists the ledger's open items. */
  ledgerOpen?: boolean
  /** True while another session holds the Bouncer (`bouncer` in the plugin's data folder names it). */
  isOther?: boolean
  /** Bartender session id to the STATUS of its last turn-end report (`bouncer-report`). */
  reports?: Readonly<Record<string, string>>
  /** True when the band shows the chips (Details); false is Compact. Kept across sessions in `$.store` `details`. */
  details?: boolean
  /** The chip whose action row is open (its key). */
  menu?: string
}

declare module 'claude-code' {
  interface PluginState {
    'bouncer': { pool: Pool }
  }
}
