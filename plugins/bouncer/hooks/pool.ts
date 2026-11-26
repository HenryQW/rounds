import type { Pool } from '../types'

export const EMPTY: Pool = { isOn: false, bartenders: {}, waiting: 0, queue: 0 }

export type Bartender = { cta: boolean; status: string; type: string; emoji: string; ticket: string; repo: string }

// `![Dev] 🍸 MIDI-1 repo` or `[Idle] 🔧 repo` (made by bouncer-title); a repo is a folder name with no space.
// The emoji is the type: 🍸 Ticket, 🔧 Skill, 🧹 Cleanup.
const TYPES: Record<string, string> = { '🍸': 'Ticket', '🔧': 'Skill', '🧹': 'Cleanup' }
const BARTENDER = /^(!)?\[([^\]]+)\] (🍸|🔧|🧹) (?:(\S+) )?(\S+)$/u
const BOUNCER = /^(?:!(\d+) )?🚪 Bouncer$/

export const parseBartender = (title: string): Bartender | undefined => {
  const m = BARTENDER.exec(title)
  return m ? { cta: m[1] === '!', status: m[2] ?? '', type: TYPES[m[3] ?? ''] ?? 'Ticket', emoji: m[3] ?? '🍸', ticket: m[4] ?? '', repo: m[5] ?? '' } : undefined
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

export const queueLines = (text: string) => text.split('\n').filter(l => l.trim() !== '')

/** `questions.md` lines (`<TICKET> | <session_id> | <question>`) as session id to question. */
export const questionsBySession = (text: string): Record<string, string> =>
  Object.fromEntries(queueLines(text).flatMap(l => {
    const [, id, ...q] = l.split('|').map(s => s.trim())
    return id && q.length ? [[id, q.join(' | ')]] : []
  }))

/** A Bartender's report fields that set titles (bouncer-report's JSON). */
export type Report = { status: string; ticket: string; linear: string | null }

export const bouncerTitle = (n: number) => (n ? `!${n} 🚪 Bouncer` : '🚪 Bouncer')

/**
 * The renames that make the titles match the open questions and the latest report: a Bartender has the `!` CTA
 * exactly when `questions.md` has a line for its session, its status code is the report's LINEAR, and the
 * Bouncer's count is the number of question lines (its own questions use the session id `self`).
 */
export const synced = (pool: Pool, questionsText: string, report?: Report): Array<[string, string]> => {
  const waiting = questionsBySession(questionsText)
  const out: Array<[string, string]> = []
  for (const [id, title] of Object.entries(pool.bartenders)) {
    const b = parseBartender(title)
    if (!b) continue
    const status = report?.linear && b.ticket && b.ticket === report.ticket ? report.linear : b.status
    const next = `${id in waiting ? '!' : ''}[${status}] ${b.emoji} ${b.ticket ? `${b.ticket} ` : ''}${b.repo}`
    if (next !== title) out.push([id, next])
  }
  const n = queueLines(questionsText).length
  if (n !== pool.waiting) out.push(['self', bouncerTitle(n)])
  return out
}
