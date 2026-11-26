export type Pool = {
  /** True once this session acts as the Bouncer. */
  isOn: boolean
  /** Bartender session id to its last title, as the Bouncer set it. */
  bartenders: Record<string, string>
  /** Questions that wait on the user: the n of the Bouncer's own `!<n> Bouncer` title. */
  waiting: number
  /** Lines in `.context/bouncer-queue.md`. */
  queue: number
}

declare module 'claude-code' {
  interface PluginState {
    'bouncer': { pool: Pool }
  }
}
