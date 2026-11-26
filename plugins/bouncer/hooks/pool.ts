import type { Pool } from '../types'

export const EMPTY: Pool = { isOn: false, bartenders: {}, waiting: 0, queue: 0 }

export type Bartender = { cta: boolean; status: string; type: string; emoji: string; ticket: string; repo: string }

// `![Dev] 🍸 MIDI-1 repo` or `[Idle] 🔧 repo` (made by bouncer-title); a repo is a folder name with no space.
// The emoji is the type: 🍸 Ticket, 🔧 Skill, 🧹 Cleanup.
const TYPES: Record<string, string> = { '🍸': 'Ticket', '🔧': 'Skill', '🧹': 'Cleanup' }
const BARTENDER = /^(!)?\[([^\]]+)\] (🍸|🔧|🧹) (?:(\S+) )?(\S+)$/u
// `!2 🚪 Bouncer rounds`; a title from before 0.10.4 has no repo.
const BOUNCER = /^(?:!(\d+) )?🚪 Bouncer(?: \S+)?$/

export const parseBartender = (title: string): Bartender | undefined => {
  const m = BARTENDER.exec(title)
  return m ? { cta: m[1] === '!', status: m[2] ?? '', type: TYPES[m[3] ?? ''] ?? 'Ticket', emoji: m[3] ?? '🍸', ticket: m[4] ?? '', repo: m[5] ?? '' } : undefined
}

/** The pool after the Bouncer renamed a session; unchanged for any other title. */
export const renamed = (pool: Pool, sessionId: string, title: string): Pool => {
  const own = BOUNCER.exec(title)
  if (sessionId === 'self' && own) return { ...pool, isOn: true, waiting: Number(own[1] ?? 0) }
  const b = parseBartender(title)
  if (!b) return pool
  // A last report belongs to the old task: drop it when the session goes idle or takes another ticket.
  const old = parseBartender(pool.bartenders[sessionId] ?? '')
  const isNew = b.status === 'Idle' || old?.ticket !== b.ticket
  const { [sessionId]: _, ...reports } = pool.reports ?? {}
  const { [sessionId]: __, ...notes } = pool.notes ?? {}
  const { [sessionId]: ___, ...reportTexts } = pool.reportTexts ?? {}
  return { ...pool, isOn: true, bartenders: { ...pool.bartenders, [sessionId]: title },
    reports: isNew ? reports : pool.reports, notes: isNew ? notes : pool.notes, reportTexts: isNew ? reportTexts : pool.reportTexts }
}

export const archived = (pool: Pool, sessionId: string): Pool => {
  const { [sessionId]: _, ...rest } = pool.bartenders
  return { ...pool, bartenders: rest }
}

/** One band column: an active Bartender, or all idle Bartenders. `label` grey, `value` bold, the sub-line comes from its last report. */
export type Column = { key: string; dot: string; label: string; value: string; ticket: string; ids: string[] }

// Traffic light, in band order: needs the user, works (or waits on others), idle and free for work.
const DOTS = ['🔴', '🟡', '🟢']

/** A Bartender's dot from its title, its last report STATUS and whether its session runs a turn (the mapping is in SKILL.md, "Band"). */
export const dot = (b: Bartender, report?: string, isRunning?: boolean) =>
  b.cta ? '🔴'
  : b.status === 'Idle' ? '🟢'
  : report === 'NEEDS_INPUT' || report === 'BLOCKED' ? '🔴'
  : isRunning === false ? '🟢'
  : '🟡'

const byDot = <T extends { dot: string }>(a: T, b: T) => DOTS.indexOf(a.dot) - DOTS.indexOf(b.dot)

/** Each Bartender's dot, in band order. */
export const dots = (bartenders: Readonly<Record<string, string>>, reports: Readonly<Record<string, string>> = {}, running: Readonly<Record<string, boolean>> = {}) =>
  Object.entries(bartenders).flatMap(([id, t]) => { const b = parseBartender(t); return b ? [{ dot: dot(b, reports[id], running[id]) }] : [] })
    .sort(byDot).map(d => d.dot)

/** Active Bartenders one card each, red first (title `🟡 MIDI-1`, subtitle `Dev`); all idle ones in one `N idle` card, last. */
export const columns = (bartenders: Readonly<Record<string, string>>, reports: Readonly<Record<string, string>> = {}, running: Readonly<Record<string, boolean>> = {}): Column[] => {
  const active: Column[] = []
  const idle: string[] = []
  for (const [id, title] of Object.entries(bartenders)) {
    const b = parseBartender(title)
    if (!b) continue
    if (b.status === 'Idle' && !b.cta) { idle.push(id); continue }
    const d = dot(b, reports[id], running[id])
    // A task with no ticket shows its repo as the value.
    active.push({ key: `act:${id}`, dot: d, label: b.status, value: `${d} ${b.ticket || b.repo}`, ticket: b.ticket, ids: [id] })
  }
  active.sort(byDot)
  return idle.length ? [...active, { key: 'idle', dot: '🟢', label: '', value: `🟢 ${idle.length} idle`, ticket: '', ids: idle }] : active
}

/** A report's sub-line: the wait reason (its QUESTION) when the Bartender waits on the user, else its RESULT. */
export const reportLine = (r: Report) =>
  ((r.status === 'NEEDS_INPUT' || r.status === 'BLOCKED') && r.question ? r.question : r.result) ?? ''

/** A linked session as the band uses it (from `list_sessions`). */
export type SessionRow = { id: string; title: string; isRunning: boolean; cwd?: string; branch?: string; at?: string; pr?: { number: number; state?: string } }

/**
 * The Bouncer's linked sessions from `list_sessions {linked: true}` (a JSON array, maybe in MCP text blocks or a JSON
 * string): id, title, whether a turn runs, its folder and branch, its last activity and its PR. Undefined when the text is not such a list.
 */
export const sessionRows = (raw: string): SessionRow[] | undefined => {
  const parse = (t: string): unknown => { try { return JSON.parse(t) } catch { return undefined } }
  let v = parse(raw)
  // A tool result that is a string arrives JSON-encoded once more.
  if (typeof v === 'string') v = parse(v)
  const blocks = (x: unknown) => Array.isArray(x) && x.length > 0 && x.every(b => (b as { type?: unknown })?.type === 'text')
  if (v && typeof v === 'object' && !Array.isArray(v) && blocks((v as { content?: unknown }).content)) v = (v as { content: unknown }).content
  if (blocks(v)) v = parse((v as Array<{ text: string }>).map(b => b.text).join(''))
  if (!Array.isArray(v)) return undefined
  return v.flatMap(r => typeof r?.sessionId === 'string' && typeof r?.title === 'string' ? [{
    id: r.sessionId as string, title: r.title as string, isRunning: r.isRunning === true,
    ...(typeof r.cwd === 'string' ? { cwd: r.cwd } : {}),
    ...(typeof r.branch === 'string' && r.branch ? { branch: r.branch } : {}),
    ...(typeof r.lastActivityAt === 'string' ? { at: r.lastActivityAt } : {}),
    ...(typeof r.prNumber === 'number' ? { pr: { number: r.prNumber, ...(typeof r.prState === 'string' ? { state: r.prState.toLowerCase() } : {}) } } : {}),
  }] : [])
}

/**
 * A PR's full GitHub URL from texts that carry one (a report, the ticket's ledger lines); undefined when none names
 * PR `n`. Never built from a folder's remote: a Bartender's PR may live in another repo than its folder.
 */
export const prUrl = (n: number, texts: readonly string[]) =>
  texts.flatMap(t => [...t.matchAll(/https:\/\/github\.com\/[\w.-]+\/[\w.-]+\/pull\/(\d+)/g)])
    .find(m => Number(m[1]) === n)?.[0]

/** Time since `at`, in the Rounds row's format: `3 sec ago`, `14 min ago`, `2 hr ago`, `3 days ago`. */
export const ago = (at: string, now: number) => {
  const s = Math.max(1, Math.floor((now - Date.parse(at)) / 1000))
  return s < 60 ? `${s} sec ago` : s < 3600 ? `${Math.floor(s / 60)} min ago` : s < 86400 ? `${Math.floor(s / 3600)} hr ago`
    : `${Math.floor(s / 86400)} ${Math.floor(s / 86400) === 1 ? 'day' : 'days'} ago`
}

/** A PR's glyph and colour by its GitHub state, as the Rounds row: green open, purple merged, grey closed. */
export const prMark = (state?: string): [string, string] =>
  state === 'merged' ? ['⤵', 'merged'] : state === 'closed' ? ['×', 'inactive'] : ['⑂', state === 'open' ? 'success' : 'inactive']

/** A queue line (`KEY | repo | mode | note`) as `KEY · repo · mode`. */
export const queueSummary = (line: string) => line.split('|').slice(0, 3).map(s => s.trim()).filter(Boolean).join(' · ')

/** A `bouncer-ledger list` line (`/r/KEY.md: - [open] kind | key | ... | next: x | date`) as `KEY · kind · x`. */
export const ledgerSummary = (line: string) => {
  const m = /([^/]+)\.md: - \[open\] (\S+) \|.*\| next: (.*?) \| \d{4}-\d{2}-\d{2}\s*$/.exec(line)
  return m ? `${m[1]} · ${m[2]} · ${m[3]}` : line
}

export const queueLines = (text: string) => text.split('\n').filter(l => l.trim() !== '')

/** `questions.md` lines (`<TICKET> | <session_id> | <question>`) as session id to its oldest question, in file order. */
export const questionsBySession = (text: string): Record<string, string> => {
  const out: Record<string, string> = {}
  for (const l of queueLines(text)) {
    const [, id, ...q] = l.split('|').map(s => s.trim())
    // The first line of a session wins: `self` holds one line a ticket, and the band shows the head.
    if (id && q.length && !(id in out)) out[id] = q.join(' | ')
  }
  return out
}

/** A Bartender's report fields that the band uses (bouncer-report's JSON). */
export type Report = { status: string; ticket: string; linear: string | null; result?: string | null; question?: string | null }

export const bouncerTitle = (n: number, repo: string) => `${n ? `!${n} ` : ''}🚪 Bouncer${repo ? ` ${repo}` : ''}`

/**
 * The renames that make the titles match the open questions and the latest report: a Bartender has the `!` CTA
 * exactly when `questions.md` has a line for its session, its status code is the report's LINEAR, and the
 * Bouncer's count is the number of question lines (its own questions use the session id `self`).
 */
export const synced = (pool: Pool, questionsText: string, report?: Report, repo = ''): Array<[string, string]> => {
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
  if (n !== pool.waiting) out.push(['self', bouncerTitle(n, repo)])
  return out
}
