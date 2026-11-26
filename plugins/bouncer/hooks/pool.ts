import type { Pool } from '../types'

export const EMPTY: Pool = { isOn: false, bartenders: {}, waiting: 0, queue: 0 }

export type Bartender = { cta: boolean; status: string; ticket: string; repo: string }

// `![Dev] MIDI-1 - Bartender - repo` or `[Idle] Bartender - repo` (made by bouncer-title).
const BARTENDER = /^(!)?\[([^\]]+)\] (?:(\S+) - )?Bartender - (.+)$/
const BOUNCER = /^(?:!(\d+) )?Bouncer$/

export const parseBartender = (title: string): Bartender | undefined => {
  const m = BARTENDER.exec(title)
  return m ? { cta: m[1] === '!', status: m[2] ?? '', ticket: m[3] ?? '', repo: m[4] ?? '' } : undefined
}

/** The pool after the Bouncer renamed a session; unchanged for any other title. */
export const renamed = (pool: Pool, sessionId: string, title: string): Pool => {
  const own = BOUNCER.exec(title)
  if (sessionId === 'self' && own) return { ...pool, isOn: true, waiting: Number(own[1] ?? 0) }
  if (!parseBartender(title)) return pool
  return { ...pool, isOn: true, bartenders: { ...pool.bartenders, [sessionId]: title } }
}

export const archived = (pool: Pool, sessionId: string): Pool => {
  const { [sessionId]: _, ...rest } = pool.bartenders
  return { ...pool, bartenders: rest }
}

export const queueLength = (text: string) => text.split('\n').filter(l => l.trim() !== '').length
