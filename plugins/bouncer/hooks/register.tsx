import { atom, read, update } from 'claude-code'
import type { EngineInterface, Register } from 'claude-code'

import { EMPTY, ago, archived, columns, dots, ledgerItem, parseBartender, ledgerNext, openPrUrls, prInfo, prMark, prUrl, prUrls, ticketLedger, queueLines, queueSummary, questionsBySession, renamed, reportLine, sessionRows, synced } from './pool'
import type { Column, Report } from './pool'

const pool = atom({ plugin: 'bouncer', key: 'pool' } as const, EMPTY)
const ACTIONS = [['status', 'Status'], ['stop', 'Stop'], ['reset', 'Reset']] as const

// A Linear-shaped key (ABC-123) links to the tracker; a GitHub issue number does not.
const LINEAR_KEY = /^[A-Z][A-Z0-9]*-\d+$/

// The queue, the open questions and the ledger in the plugin's data folder, the one bouncer-data prints (CLAUDE_PLUGIN_DATA).
// One Bouncer a repo: its repo is the folder name of its folder (the main checkout), and its queue, questions and
// owner file live in <data>/<repo>/ (bouncer-data --repo). Another repo's Bouncer has its own.
const repoOf = async ($: EngineInterface) => (await $.session.cwd()).split('/').pop() ?? ''
const repoDir = async ($: EngineInterface) => {
  const data = (await $.process.hookEnv()).CLAUDE_PLUGIN_DATA
  return data ? `${data}/${await repoOf($)}` : undefined
}
const dataFile = async ($: EngineInterface, name: string) => {
  const dir = await repoDir($)
  return String(dir ? await $.fs.read(`${dir}/${name}`).catch(() => '') : '')
}
// Ledger items live in the ticket records; bouncer-ledger list --all prints one line each (done ones keep their PR URLs),
// and due only the open items to act on.
const ledgerList = async ($: EngineInterface, records: string, cmd: 'list' | 'due' = 'list') => {
  const env = await $.process.hookEnv()
  if (!env.CLAUDE_PLUGIN_ROOT) return undefined
  const ran = await $.process.run([`${env.CLAUDE_PLUGIN_ROOT}/skills/bouncer/scripts/bouncer-ledger`, ...(cmd === 'list' ? ['list', '--all'] : [cmd])],
    { env: records ? { ...env, BOUNCER_RECORDS: records } : env }).catch(() => undefined)
  return ran?.exitCode === 0 ? queueLines(ran.stdout) : undefined
}
// One Bouncer a repo: `bouncer` in <data>/<repo>/ holds the engine session id of that repo's Bouncer.
// A session claims it when it is free; another one takes it over only on the user's Take Over.
const writeOwner = async ($: EngineInterface, id: string) => {
  const dir = await repoDir($)
  if (dir) await $.fs.write(`${dir}/bouncer`, id).catch(() => undefined)
}
const isOtherBouncer = async ($: EngineInterface) => {
  const me = await $.session.id()
  const owner = (await dataFile($, 'bouncer')).trim()
  if (!owner) await writeOwner($, me)
  return owner !== '' && owner !== me
}
// The Bouncer's linked sessions: the Bartenders' current titles, whether each runs a turn, their folder, last activity and PR.
// They also fill the pool after a reload, before the Bouncer renames anything.
const refreshSessions = async ($: EngineInterface) => {
  const ran = await $.tool.call({ tool: 'mcp__ccd_session_mgmt__list_sessions', linked: true, limit: 100 } as any).catch(() => undefined)
  if (!ran || ran.deny !== undefined || ran.isError === true) return
  const rows = sessionRows(ran.text ?? JSON.stringify(ran.result ?? ''))?.filter(r => parseBartender(r.title))
  if (!rows) return
  const sessions = Object.fromEntries(rows.map(r => [r.id, { cwd: r.cwd, branch: r.branch, at: r.at, pr: r.pr }] as const))
  await update($, pool, p => ({
    ...p,
    bartenders: Object.fromEntries(rows.map(r => [r.id, r.title])),
    running: Object.fromEntries(rows.map(r => [r.id, r.isRunning])),
    sessions,
  }))
}
// Linear's tokens (its DESIGN.md), dark and the light inverse. Its light hairline and inks are not in the spec: derived.
const LINEAR = {
  dark: { ink: '#f7f8f8', muted: '#d0d6e0', subtle: '#8a8f98', surface: '#0f1011', hairline: '#23252a', hover: '#34363c', accent: '#5e6ad2' },
  light: { ink: '#000000', muted: '#3c4149', subtle: '#6b6f76', surface: '#f5f6f6', hairline: '#e1e3e6', hover: '#d4d6da', accent: '#5e6ad2' },
}
// The band's elements cannot read the app theme, so the band reads the system appearance.
// shortcut: an app theme set apart from the system's gets the other palette; read the app theme once the engine offers it.
const refreshLook = async ($: EngineInterface) => {
  const ran = await $.process.run(['/usr/bin/defaults', 'read', '-g', 'AppleInterfaceStyle']).catch(() => undefined)
  const dark = ran?.exitCode === 0 && /Dark/.test(ran.stdout)
  await update($, pool, p => (p.dark === dark ? p : { ...p, dark }))
}
const refreshData = async ($: EngineInterface, records = '') => {
  const isOther = await isOtherBouncer($)
  await update($, pool, p => (p.isOther === isOther ? p : { ...p, isOther }))
  if (!isOther) await refreshSessions($).catch(() => undefined)
  const lines = queueLines(await dataFile($, 'queue.md'))
  const questions = questionsBySession(await dataFile($, 'questions.md'))
  const ledger = await ledgerList($, records)
  await update($, pool, p => ({
    ...p, queue: lines.length, queueLines: lines, questions,
    ledgerLines: ledger ?? p.ledgerLines,
  }))
}

// `due` runs each item's check (gh calls), so it runs once a turn, never on a render or a tool call.
const refreshDue = async ($: EngineInterface, records = '') => {
  const due = await ledgerList($, records, 'due')
  if (due) await update($, pool, p => ({ ...p, due }))
  // Each open pr item's state and base for Details; a login shell finds gh where the app's PATH may not.
  const p = await read($, pool)
  const urls = [...new Set(Object.values(p.bartenders).flatMap(t => openPrUrls(p.ledgerLines ?? [], parseBartender(t)?.ticket ?? '')))]
  for (const url of urls) {
    const ran = await $.process.run(['/bin/bash', '-lc', 'gh pr view "$0" --json state,baseRefName', url]).catch(() => undefined)
    const info = ran?.exitCode === 0 ? prInfo(ran.stdout) : undefined
    if (info) await update($, pool, p => ({ ...p, prs: { ...p.prs, [url]: info } }))
  }
}

// Make the titles match the open questions and, given a report, its status code; set_session_title is the Bouncer's own call.
const syncTitles = async ($: EngineInterface, report?: Report) => {
  for (const [session_id, title] of synced(await read($, pool), await dataFile($, 'questions.md'), report, await repoOf($))) {
    const ran = await $.tool.call({ tool: 'mcp__ccd_session_mgmt__set_session_title', session_id, title } as any).catch(() => undefined)
    if (ran && ran.deny === undefined && ran.isError !== true) await update($, pool, p => renamed(p, session_id, title))
  }
}

// A Bartender's turn-end note reaches the Bouncer as a delivery or a prompt: parse it with bouncer-report, then set titles.
const onNote = async ($: EngineInterface, text: string) => {
  if (!(await read($, pool)).isOn || !/^\s*STATUS:/m.test(text) || !/^\s*TICKET:/m.test(text)) return
  const env = await $.process.hookEnv()
  if (!env.CLAUDE_PLUGIN_ROOT) return
  const ran = await $.process.run([`${env.CLAUDE_PLUGIN_ROOT}/skills/bouncer/scripts/bouncer-report`], { stdin: text, env })
    .catch(() => undefined)
  if (!ran || ran.exitCode !== 0) return
  let report: Report
  try { report = JSON.parse(ran.stdout) as Report } catch { return /* not a report */ }
  // Keep the STATUS for the band's dot and the sub-line for its column, on the session whose title has the report's ticket.
  const id = Object.entries((await read($, pool)).bartenders).find(([, t]) => report.ticket && parseBartender(t)?.ticket === report.ticket)?.[0]
  // A turn-end note means its turn ended: the dot leaves 🟡 now, not at the Bouncer's next list_sessions read.
  if (id) await update($, pool, p => ({ ...p, reports: { ...p.reports, [id]: report.status }, notes: { ...p.notes, [id]: reportLine(report) }, reportTexts: { ...p.reportTexts, [id]: text }, running: { ...p.running, [id]: false } }))
  await syncTitles($, report)
}

export const register: Register = (on, options) => {
  const linear = String(options.linear_workspace_url ?? '').replace(/\/+$/, '')
  const records = String(options.records_dir ?? '').trim()

  on('tool.call', async ($, e, next) => {
    const ran = await next(e)
    if (ran.deny !== undefined || ran.isError === true) return ran

    const tool = String(e.tool)
    if (tool === 'Skill' && /(^|:)bouncer$/.test(String((e as { skill?: unknown }).skill ?? ''))) {
      await update($, pool, p => ({ ...p, isOn: true }))
      await refreshData($, records)
      await refreshDue($, records).catch(() => undefined)
    } else if (tool.endsWith('__set_session_title')) {
      const { session_id, title } = e as { session_id?: unknown; title?: unknown }
      const before = (await read($, pool)).waiting
      await update($, pool, p => renamed(p, String(session_id), String(title)))
      const after = (await read($, pool)).waiting
      if (after > before) await $.ui.notify(`${after} waiting on you`, { title: 'Bouncer' }).catch(() => undefined)
    } else if (tool.endsWith('__start_session')) {
      // An offer or a proposal_id start has no title here; renamed() ignores a non-Bartender title.
      const { title, initiation } = e as { title?: unknown; initiation?: unknown }
      // The result reads `Started session "<title>" (session_id: local_..., name: ...)`.
      const id = /session_id: (local_[\w-]+)/.exec(ran.text ?? JSON.stringify(ran.result ?? ''))?.[1]
      if (id && initiation !== 'offer' && typeof title === 'string') await update($, pool, p => renamed(p, id, title))
    } else if (tool.endsWith('__archive_session')) {
      await update($, pool, p => archived(p, String((e as { session_id?: unknown }).session_id)))
    } else if (tool === 'Bash' && /bouncer-(queue|questions|ledger)/.test(String((e as { command?: unknown }).command))) {
      await refreshData($, records)
      if (/bouncer-questions/.test(String((e as { command?: unknown }).command))) await syncTitles($)
    }
    return ran
  })

  on('session.receive', async ($, e, next) => {
    if (!e.agentId) await onNote($, e.text).catch(() => undefined)
    return next(e)
  })
  // A Bartender's turn-end note reaches the Bouncer inside its next turn (a side-sessions event), not always as a
  // report that onNote parses: read list_sessions there too, so a finished Bartender's dot leaves 🟡 at once.
  on('prompt.submit', async ($, e, next) => {
    await onNote($, e.text).catch(() => undefined)
    if ((await read($, pool)).isOn) await refreshSessions($).catch(() => undefined)
    return next(e)
  })

  // The queue, questions and ledger change outside the Bouncer's own calls (a Bartender, a shell, the last session):
  // read them again when the session starts and after each of the Bouncer's turns.
  on('session.start', async ($, e, next) => {
    const details = (await $.store.get('details').catch(() => undefined)) === true
    await update($, pool, p => (p.details === details ? p : { ...p, details }))
    await refreshLook($).catch(() => undefined)
    if ((await read($, pool)).isOn) {
      await refreshData($, records).catch(() => undefined)
      await refreshDue($, records).catch(() => undefined)
    }
    return next(e)
  })
  // The Bouncer's session ends (or a /clear gives it a new id): free the Bouncer for the next session.
  on('session.end', async ($, e, next) => {
    if ((await read($, pool)).isOn && (await dataFile($, 'bouncer')).trim() === e.sessionId) await writeOwner($, '')
    return next(e)
  })
  // A band prompt's turn ended (main's, not a subagent's): the band may send the next one.
  on('turn.complete', async ($, e, next) => {
    if (!e.agentId) {
      await update($, pool, p => (p.pending ? { ...p, pending: false } : p))
      await refreshLook($).catch(() => undefined)
      if ((await read($, pool)).isOn) {
        await refreshData($, records).catch(() => undefined)
        await refreshDue($, records).catch(() => undefined)
      }
    }
    return next(e)
  })

  on('ui.render', { component: 'AbovePrompt' }, async ($, e, next) => {
    const p = await read($, pool)
    if (e.props.hasSurvey || !p.isOn) return next(e)
    // Other mods share this slot (ponytail's band): draw theirs below ours.
    const below = await next(e).catch(() => undefined)

    const { Box, Text, Button } = $.ui.resolve(e)
    const width = e.surface === 'terminal' ? e.props.bodyColumns : undefined
    const bartenders = Object.entries(p.bartenders).flatMap(([id, t]) => {
      const b = parseBartender(t)
      return b ? [{ id, ...b }] : []
    })
    // Only the Bouncer talks to Bartenders: the band asks it with a plain prompt. Prompts are sequential:
    // none while a question waits on the user, while the Bouncer works, or before the last one's turn ended.
    const isWorking = e.props.isWorking
    const ask = async (text: string) => {
      const now = await read($, pool)
      if (now.waiting > 0) return $.ui.toast('Answer the waiting question first')
      if (isWorking || now.pending) return $.ui.toast('Wait for the Bouncer to finish its turn')
      await update($, pool, q => ({ ...q, pending: true }))
      await $.prompt.submit({ text }).catch(() => update($, pool, q => ({ ...q, pending: false })))
    }
    const ownRepo = await repoOf($)
    if (p.isOther) {
      const take = async () => { await writeOwner($, await $.session.id()); await refreshData($, records) }
      const row = (
        <Box flexDirection="row" alignItems="center" gap={2} flexWrap="wrap" width={width}>
          <Text bold>Bouncer</Text>
          <Text>{`another session is the Bouncer of ${ownRepo}`}</Text>
          <Button key="takeover" plain onPress={take}>Take Over</Button>
        </Box>
      )
      return below ? <Box flexDirection="column">{row}{below}</Box> : row
    }
    // Questions block in order: the band shows only the oldest (the head of questions.md); the next shows once it is answered.
    const [headId, headQuestion] = Object.entries(p.questions ?? {})[0] ?? []
    const headB = bartenders.find(b => b.id === headId)
    const ctaB = bartenders.find(b => b.cta)
    const waits = headQuestion !== undefined
      ? { b: headB, name: headB ? headB.ticket || headB.repo : headId === 'self' ? 'Bouncer' : headId ?? '', question: headQuestion }
      : ctaB && { b: ctaB, name: ctaB.ticket || ctaB.repo, question: 'waits on you' }
    const lines = p.queueOpen ? p.queueLines ?? [] : []
    const due = p.due ?? []
    const dueLines = p.ledgerOpen ? due : []
    const all = columns(p.bartenders, p.reports, p.running)
    // Compact (the default) is one line; Details adds the ask row and the columns. Kept across sessions.
    const flip = async () => {
      const details = !(await read($, pool)).details
      await update($, pool, q => ({ ...q, details }))
      await $.store.set('details', details).catch(() => undefined)
    }
    // A column's actions name one session each (a ticket key, else its session id),
    // so an action on the grouped idle column is never ambiguous.
    const actions = (c: Column) => [
      ...c.ids.flatMap(id => ACTIONS.map(([a, label]) =>
        ({ value: `${a} ${id}`, label: c.ids.length > 1 ? `${label} ${id.replace(/^local_/, '').slice(0, 8)}` : label }))),
    ]
    // Stop and Reset send only on a second click: the first shows "Confirm …?" and Cancel, for 5 seconds.
    const menuCells = (c: Column) => {
      const o = actions(c).find(x => x.value === p.confirm)
      if (o) return [
        { value: o.value, label: `Confirm ${o.label.toLowerCase()}?`, red: o.value.startsWith('reset'), press: () => pick(c, o.value) },
        { value: 'cancel', label: 'Cancel', red: false, press: () => update($, pool, q => ({ ...q, confirm: undefined })) },
      ]
      return actions(c).map(x => ({
        ...x, red: x.value.startsWith('reset'),
        press: x.value.startsWith('status') ? () => pick(c, x.value) : async () => {
          await update($, pool, q => ({ ...q, confirm: x.value }))
          $.clock.after(5000, () => { void update($, pool, q => (q.confirm === x.value ? { ...q, confirm: undefined } : q)) })
        },
      }))
    }
    const pick = async (c: Column, v: string) => {
      await update($, pool, q => ({ ...q, menu: undefined, confirm: undefined }))
      const [a, id] = v.split(' ')
      if (a && id) await ask(`${c.ticket || id}: ${a}`)
    }
    const toggle = async (k: 'queueOpen' | 'ledgerOpen') => {
      await update($, pool, q => ({ ...q, [k]: !q[k] }))
      await refreshData($, records)
    }
    // `open claude://…` does not switch the app (tried 2026-11-26), so show the Bartender in split view.
    // The window tool takes only sessions the Bouncer started; when the call fails, the Bouncer opens it.
    const open = async (id: string, name: string) => {
      const ran = await $.tool.call({ tool: 'mcp__ccd_window__open_session_in', session_id: id, target: 'split' } as any)
        .catch(() => undefined)
      if (!ran || ran.deny !== undefined || ran.isError === true) await ask(`${name}: open`)
    }
    const strip = bartenders.length === 0
      ? <Text>no Bartenders yet</Text>
      : <Text key="dots">{dots(p.bartenders, p.reports, p.running).join(' ')}</Text>
    // Row 2 is the most useful fact: the next step of the ticket's open ledger item, else the last report's RESULT or
    // wait reason, else nothing (the dot already says whether a turn runs).
    const sub = (c: Column) => {
      const id = c.ids.length === 1 ? c.ids[0]! : undefined
      // A pr item whose PR is merged or closed is stale (the ledger closes it later), so it is never the next step.
      const live = ticketLedger(p.ledgerLines ?? [], c.ticket).filter(l => {
        const url = /: - \[open\] pr \| (\S+) \|/.exec(l)?.[1]
        const state = url ? p.prs?.[url]?.state : undefined
        return !state || /^open$/i.test(state)
      })
      // Else the last RESULT, else the ticket title, so no card is only its header.
      return id ? ledgerNext(live) ?? p.notes?.[id] ?? parseBartender(p.bartenders[id] ?? '')?.name ?? '' : ''
    }
    const isTerminal = e.surface === 'terminal'
    // Linear's look off the terminal; the terminal keeps its own colours.
    const t = isTerminal ? undefined : LINEAR[p.dark ? 'dark' : 'light']
    const detailsLabel = p.details ? 'Compact' : 'Details'
    // A quiet switch: no fill, dim text that turns full strength under the pointer.
    const detailsButton = <Button key="details" plain dimColor label={detailsLabel} onPress={flip} />
    const { Link } = $.ui.resolve(e)
    // Every link in the accent: a bare Link takes the surface's own colour, which drew grey in Details.
    const link = (href: string, label: string) =>
      t ? <Link href={href}><Text color={t.accent}>{label}</Text></Link> : <Link href={href} label={label} />
    // Only the ledger items due now (`bouncer-ledger due`), as what the user must do; open items that are not due are in
    // their card's row 2. Each row: the key as a link (the PR, else the Linear issue) and its next step.
    const dueButton = due.length > 0 && (
      <Button key="ledger" plain onPress={() => toggle('ledgerOpen')}><Text color="error">{`${due.length} to act`}</Text></Button>
    )
    const dueRows = dueLines.map(line => {
      const it = ledgerItem(line)
      if (!it) return <Text key={`due:${line}`} wrap="truncate">{line}</Text>
      const pr = /^https:\/\/github\.com\/\S+\/pull\/(\d+)$/.exec(it.key)
      const state = pr ? p.prs?.[it.key]?.state?.toLowerCase() : undefined
      const label = pr ? `#${pr[1]}${state && state !== 'open' ? ` ${state}` : ''}` : LINEAR_KEY.test(it.key) ? it.key : it.record
      const href = pr ? it.key : linear && LINEAR_KEY.test(label) ? `${linear}/issue/${label}` : undefined
      return (
        <Box key={`due:${line}`} flexDirection="row" alignItems="center" gap="sm">
          <Box flexShrink={0}>{href ? link(href, label) : <Text color={t?.ink}>{label}</Text>}</Box>
          <Box flexGrow={1} flexShrink={1} minWidth={0}><Text color={t?.muted} wrap="truncate-end">{it.next}</Text></Box>
          <Button key={`due:ask:${it.key}`} plain dimColor onPress={() => ask(`${it.record}: due ${it.kind}${it.key === it.record ? '' : ` ${it.key}`}: ${it.next}`)}>Ask Bouncer</Button>
        </Box>
      )
    })
    // The clock only when a card shows a time.
    const now = Object.values(p.sessions ?? {}).some(x => x.at) ? await $.clock.now() : 0
    // A Bartender as Rounds row pieces: the title (dot and key, the key a link to its Linear issue), the status code as a
    // chip, the PR (`#17860 +1`, glyph in the PR state colour). The title is not a Button: a desktop Button adds its own
    // inset, so the rows would not align.
    const isLinked = (c: Column) => !!c.ticket && !!linear && LINEAR_KEY.test(c.ticket)
    const titleOf = (c: Column) => isLinked(c)
      ? <Box flexDirection="row"><Text>{`${c.dot} `}</Text>{link(`${linear}/issue/${c.ticket}`, c.ticket)}</Box>
      : <Text weight="medium" color={t?.ink} wrap="truncate-end">{c.value}</Text>
    const chipOf = (c: Column) => (
      <Box key={`chip:${c.key}`} flexShrink={0} paddingX="xs" {...(t ? { backgroundColor: t.hairline } : {})}>
        <Text size="footnote" color={t?.muted}>{c.label}</Text>
      </Box>
    )
    const prOf = (c: Column) => {
      const id = c.ids.length === 1 ? c.ids[0]! : undefined
      const s = id ? p.sessions?.[id] : undefined
      const [glyph, glyphColor] = prMark(s?.pr?.state)
      // PR links only from full URLs in its report or its ticket's ledger lines; never from the folder's remote.
      const urls = prUrls([id ? p.reportTexts?.[id] ?? '' : '', ...ticketLedger(p.ledgerLines ?? [], c.ticket)])
      const n = s?.pr?.number ?? Number(/\d+$/.exec(urls[0] ?? '')?.[0] ?? 0)
      const href = n ? prUrl(n, urls) : undefined
      const others = urls.filter(u => u !== href).length
      return {
        cells: n ? `⑂ #${n}${others ? ` +${others}` : ''}`.length + 1 : 0,
        time: s?.at ? ago(s.at, now) : '',
        el: n > 0 && (
          <Box key={`pr:${c.key}`} flexDirection="row" flexShrink={0}>
            <Text color={glyphColor}>{`${glyph} `}</Text>
            {href ? link(href, `#${n}`) : <Text color={t?.muted}>{`#${n}`}</Text>}
            {others > 0 && <Text color={t?.muted}>{` +${others}`}</Text>}
          </Box>
        ),
      }
    }

    // Details lists every open PR of the ticket (its open pr ledger items, and the session's own PR), each a link in the
    // PR state colour with its base (`#17860 → dev`), on a row of its own under row 1. Compact keeps `#17860 +1`.
    const prsOf = (c: Column) => {
      const id = c.ids.length === 1 ? c.ids[0]! : undefined
      const s = id ? p.sessions?.[id] : undefined
      const urls = openPrUrls(p.ledgerLines ?? [], c.ticket)
      const own = s?.pr?.number
      const ownHref = own ? prUrl(own, [id ? p.reportTexts?.[id] ?? '' : '', ...ticketLedger(p.ledgerLines ?? [], c.ticket)]) : undefined
      const list = [
        ...(own && !(ownHref && urls.includes(ownHref)) ? [{ n: own, href: ownHref, state: s?.pr?.state }] : []),
        ...urls.map(u => ({ n: Number(/\d+$/.exec(u)?.[0] ?? 0), href: u as string | undefined, state: u === ownHref ? s?.pr?.state : undefined })),
      ]
      return list.map(x => ({ ...x, state: (x.href && p.prs?.[x.href]?.state) || x.state, base: x.href ? p.prs?.[x.href]?.base : undefined }))
    }
    const prRow = (c: Column) => {
      const prs = prsOf(c)
      return prs.length > 0 && (
        <Box key={`prs:${c.key}`} flexDirection="row" flexWrap="wrap" gap="md">
          {prs.map(x => {
            const [glyph, color] = prMark(x.state)
            return (
              <Box key={`pr:${c.key}:${x.n}`} flexDirection="row" flexShrink={0}>
                <Text color={color}>{`${glyph} `}</Text>
                {x.href ? link(x.href, `#${x.n}`) : <Text color={t?.muted}>{`#${x.n}`}</Text>}
                {/* The base only while open: a merged PR's glyph says enough. */}
                {x.base && (!x.state || /^open$/i.test(x.state)) && <Text color={t?.muted}>{` → ${x.base}`}</Text>}
              </Box>
            )
          })}
        </Box>
      )
    }

    if (!p.details) {
      // Compact: one row, as ponytail's compact band. Each Bartender is one pill (dot and key, status code, PR; the code is
      // plain text, so pills do not nest); on the right what waits on the user, the due count and the switch. It wraps only when narrow.
      const n = p.waiting
      const mine = (
        <Box flexDirection="row" alignItems="center" flexWrap="wrap" gap={isTerminal ? 2 : 'sm'} width={width}>
          {all.length === 0 && strip}
          {all.map(c => (
            <Box key={`row:${c.key}`} flexDirection="row" alignItems="center" gap={isTerminal ? 1 : 'sm'} {...(t
              ? { borderStyle: 'round' as const, borderColor: t.hairline, backgroundColor: t.surface, paddingX: 'sm' as const, paddingY: 0 }
              : {})}>
              <Box key={`title:${c.key}`} flexShrink={isLinked(c) ? 0 : 1} minWidth={0}>{titleOf(c)}</Box>
              {c.label && <Box key={`chip:${c.key}`} flexShrink={0}><Text color={t?.muted}>{c.label}</Text></Box>}
              {prOf(c).el}
            </Box>
          ))}
          <Box flexGrow={1} />
          {n > 0 && (waits?.b
            ? <Button key="waits" plain onPress={() => open(waits.b!.id, waits.name)}><Text color="error">{`${n} waits on you`}</Text></Button>
            : <Text key="waits" color="error">{`${n} waits on you`}</Text>)}
          {dueButton}
          {detailsButton}
        </Box>
      )
      if (dueLines.length > 0) return <Box flexDirection="column" gap={isTerminal ? 0 : 'xs'}>{mine}{dueRows}{below}</Box>
      return below ? <Box flexDirection="column">{mine}{below}</Box> : mine
    }

    // Details. Terminal: ponytail's columns split by `│`. Elsewhere Linear's look: one card a Bartender
    // (surface, hairline border, round corners, padding), a hairline under the header, nothing below ink-subtle.
    // The terminal shows 4 columns and counts the rest (`+N`); off the terminal every card shows, in one row.
    const shown = isTerminal ? all.slice(0, 4) : all
    const more = all.length - shown.length
    // The terminal draws a rule under the header; elsewhere the cards' borders do that work.
    const rule = isTerminal && <Text dimColor wrap="truncate-end">{'─'.repeat(e.props.bodyColumns)}</Text>
    const bar = (i: number) => <Box key={`bar:${i}`} flexDirection="column">{['a', 'b', 'c'].map(k => <Text key={k} dimColor>│</Text>)}</Box>
    const colWidth = width === undefined ? undefined : Math.max(10, Math.floor(width / Math.max(1, shown.length)) - 3)
    // One card a Bartender, as a Rounds session row in two rows. Row 1: title, chip, PR, the time, `⋯` (the menu).
    // Row 2: the next step or the last result. Width 0 and grow 1 give equal cards (no flexBasis prop).
    // shortcut: no prop gives a card's drawn width, so what fits is guessed from the band's cells (one character a cell);
    // when row 1 is too long the time goes first, then the chip. Measure the card once the engine gives its width.
    const room = Math.floor((e.props.bodyColumns ?? 120) / Math.max(1, shown.length)) - 3
    const card = (c: Column) => {
      const { time } = prOf(c)
      // Row 1 does not hold the PR in Details: the PRs have a row of their own.
      const prCells = 0
      const showChip = !!c.label && c.value.length + c.label.length + 3 + prCells <= room
      // The time also needs room for `⋯` and the gaps (4 cells), so it shows only when row 1 is short.
      const showTime = !!time && c.value.length + (showChip ? c.label.length + 3 : 0) + prCells + time.length + 5 <= room
      const line = sub(c)
      return (
        <Box key={`col:${c.key}`} flexDirection="column" minWidth={0} {...(t
          ? { flexGrow: 1, flexShrink: 1, width: 0, minWidth: 0, gap: 'sm' as const, borderStyle: 'round', borderColor: t.hairline, backgroundColor: t.surface, paddingX: 'md' as const, paddingY: 'md' as const }
          : colWidth === undefined ? { flexGrow: 1 } : { width: colWidth })}>
          <Box flexDirection="row" alignItems="center" gap="sm">
            {/* A Link wraps instead of truncating: a linked key keeps its width. */}
            <Box key={`title:${c.key}`} flexGrow={1} flexShrink={isLinked(c) || !isTerminal ? 0 : 1} minWidth={0}>{titleOf(c)}</Box>
            {showChip && chipOf(c)}
            {showTime && <Text size="footnote" color={t?.muted}>{time}</Text>}
            <Button key={c.key} plain dimColor label="⋯" onPress={() => update($, pool, q => ({ ...q, menu: q.menu === c.key ? undefined : c.key }))} />
          </Box>
          {prRow(c)}
          {line && <Box key={`line:${c.key}`}><Text size="footnote" color={t?.muted} wrap="wrap" maxLines={2}>{line}</Text></Box>}
          {/* The menu is a row of its own under the next step: secondary buttons on one row; the card grows to fit.
              The terminal keeps plain ones. */}
          {p.menu === c.key && (
            <Box key={`menu:${c.key}`} flexDirection="row" gap="sm" flexWrap="nowrap">
              {/* A desktop Button keeps its label's width (no width prop), so each cell draws the button: equal (width 0, grow 1, as the cards),
                  a plain Button centred in it, in a Box that never shrinks, so the label never truncates. The keyed cell is the hover scope, so the
                  whole cell lights; only the label takes the click (a Box has no onPress, a Button holds only text). Stop and Reset ask first. */}
              {menuCells(c).map(o => (
                <Box key={`cell:${c.key}:${o.value}`} flexDirection="row" width={0} flexGrow={1} alignItems="center" justifyContent="center"
                  {...(t ? { backgroundColor: t.hairline, borderStyle: 'round', borderColor: o.red ? 'error' : t.hairline, paddingX: 0 as const, paddingY: 'xs' as const, hover: { backgroundColor: t.hover } } : {})}>
                  <Box flexShrink={0}>
                    <Button key={`${c.key}:${o.value}`} plain onPress={o.press} {...(t ? { hover: { backgroundColor: t.hover } } : {})}>
                      {o.red ? <Text color="error">{o.label}</Text> : o.label}
                    </Button>
                  </Box>
                </Box>
              ))}
            </Box>
          )}
        </Box>
      )
    }
    const mine = (
      <Box flexDirection="column" width={width} gap={isTerminal ? 0 : 'sm'} paddingY={isTerminal ? 0 : 'xs'}>
        <Box flexDirection="row" alignItems="center" gap={isTerminal ? 1 : 'sm'}>
          {strip}
          <Text bold weight="semibold" color={t?.ink}>Bouncer</Text>
          <Text color={t?.muted}>{ownRepo}</Text>
          <Box flexGrow={1} />
          {p.queue > 0 && <Button key="queue" plain onPress={() => toggle('queueOpen')}><Text color={t?.muted}>{`Queue ${p.queue}`}</Text></Button>}
          {dueButton}
          {detailsButton}
        </Box>
        {rule}
        {dueRows.length > 0 && <Box key="due" flexDirection="column" gap={isTerminal ? 0 : 'xs'}>{dueRows}</Box>}
        {waits && (
          <Box backgroundColor="diffRemovedDimmed" paddingX={isTerminal ? 'xs' : 'lg'} paddingY={isTerminal ? 0 : 'sm'} {...(t ? { borderStyle: 'round', borderColor: t.hairline } : {})}>
            {waits.b
              ? <Button key={`open:${waits.b.id}`} plain onPress={() => open(waits.b!.id, waits.name)}>
                  <Text wrap="truncate" color={t?.ink}>{`🔴 ${waits.name}: ${waits.question}`}</Text>
                </Button>
              : <Text wrap="truncate" color={t?.ink}>{`🔴 ${waits.name}: ${waits.question}`}</Text>}
          </Box>
        )}
        {shown.length > 0 && (
          <Box flexDirection="row" gap={isTerminal ? 2 : 'md'} flexWrap="nowrap">
            {shown.flatMap((c, i) => [...(isTerminal && i > 0 ? [bar(i)] : []), card(c)])}
            {more > 0 && <Text key="more" color={t?.muted}>{`+${more}`}</Text>}
          </Box>
        )}
        {lines.map((line, i) => {
          const ticket = line.split('|')[0]?.trim() ?? ''
          return (
            <Box flexDirection="row" alignItems="center" gap={1}>
              <Box flexShrink={1} minWidth={0}><Text wrap="truncate">{queueSummary(line)}</Text></Box>
              {i === 0 && <Button key="queue:pop" plain onPress={() => ask('queue: pop')}>Pop</Button>}
              <Button key={`queue:remove:${ticket}`} plain onPress={() => ask(`queue: remove ${ticket}`)}>Remove</Button>
            </Box>
          )
        })}
      </Box>
    )
    return below ? <Box flexDirection="column">{mine}{below}</Box> : mine
  })
}
