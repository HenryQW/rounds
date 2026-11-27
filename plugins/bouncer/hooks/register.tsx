import { atom, read, update } from 'claude-code'
import type { EngineInterface, Register } from 'claude-code'

import { EMPTY, ago, archived, columns, dots, ledgerItem, parseBartender, ledgerNext, openPrUrls, prInfo, ownPr, prMark, prUrl, prUrls, ticketLedger, queueLines, queueSummary, questionItem, questionsBySession, renamed, reportLine, sessionRows, synced } from './pool'
import type { Column, Report } from './pool'

const pool = atom({ plugin: 'bouncer', key: 'pool' } as const, EMPTY)
// shortcut: an undecided item's key to the requestId of the Bouncer's last Decide reply that named it, drawn since the
// module loaded; a reload forgets it until the reply draws again. Keep it in state once a render may write it.
const asks = new Map<string, string>()
const PANE = 'bouncer'
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
  const script = `${env.CLAUDE_PLUGIN_ROOT}/skills/bouncer/scripts/bouncer-ledger`
  // `due` runs each item's check (gh calls): a login shell finds gh where the app's PATH may not, as the PR queries do.
  const argv = cmd === 'list' ? [script, 'list', '--all'] : ['/bin/bash', '-lc', 'exec "$0" due', script]
  const ran = await $.process.run(argv, { env: records ? { ...env, BOUNCER_RECORDS: records } : env }).catch(() => undefined)
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
  const questionsText = await dataFile($, 'questions.md')
  const questions = questionsBySession(questionsText)
  const ledger = await ledgerList($, records)
  await update($, pool, p => ({
    ...p, queue: lines.length, queueLines: lines, questions, questionLines: queueLines(questionsText),
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

// The band above the prompt; off the terminal Details opens in the Bouncer pane, which this same code draws.
// shortcut: e and next are untyped here, as one function draws the AbovePrompt and the Pane.
const draw = async ($: EngineInterface, e: any, next: any, inPane: boolean, records: string, linear: string) => {
  const p = await read($, pool)
  if (!inPane && (e.props.hasSurvey || !p.isOn)) return next(e)
  // Other mods share this slot (ponytail's band): draw theirs below ours.
  const below = inPane ? undefined : await next(e).catch(() => undefined)

  const { Box, Text, Button } = $.ui.resolve(e)
  const width = e.surface === 'terminal' && !inPane ? e.props.bodyColumns : undefined
  const bartenders = Object.entries(p.bartenders).flatMap(([id, t]) => {
    const b = parseBartender(t)
    return b ? [{ id, ...b }] : []
  })
  // Only the Bouncer talks to Bartenders: the band asks it with a plain prompt. Prompts are sequential:
  // none while a question waits on the user, while the Bouncer works, or before the last one's turn ended.
  // The pane's props do not say whether a turn runs; the pool keeps it from prompt.submit to turn.complete.
  const isWorking = e.props?.isWorking ?? !!p.working
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
  const all = columns(p.bartenders, p.reports, p.running)
  // The band is one line; Details (and `+N`, `N to act`) opens the Bouncer pane, or brings it to the front: focus
  // raises a pane that is open already (the surface refuses it over text in the composer).
  const openPane = async () => {
    const opened: { isPlaced: boolean, reason?: string } = await $.ui.open({ id: PANE, title: 'Bouncer', focus: true })
      .catch((err: unknown) => ({ isPlaced: false, reason: String(err) }))
    if (!opened.isPlaced) $.ui.toast(`The Bouncer pane waits to show${opened.reason ? `: ${opened.reason}` : ''}`)
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
      { value: o.value, label: `Confirm ${o.label}?`, red: o.value.startsWith('reset'), press: () => pick(c, o.value) },
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
  // One menu row a session: the idle column's three actions a session would not fit one row.
  const rowsOf = <T,>(cells: T[]) => Array.from({ length: Math.ceil(cells.length / 3) }, (_, r) => cells.slice(r * 3, r * 3 + 3))
  const pick = async (c: Column, v: string) => {
    await update($, pool, q => ({ ...q, menu: undefined, confirm: undefined }))
    const [a, id] = v.split(' ')
    if (a && id) await ask(`${c.ticket || id}: ${a}`)
  }
  const toggle = async (k: 'queueOpen') => {
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
  // A column's ledger lines; its session's repo (the folder of its main checkout) picks among records of the same name.
  const ledgerOf = (c: Column) => {
    const cwd = c.ids.length === 1 ? p.sessions?.[c.ids[0]!]?.cwd : undefined
    return ticketLedger(p.ledgerLines ?? [], c.ticket, cwd?.split('/.claude/worktrees/')[0]?.split('/').pop())
  }
  const sub = (c: Column) => {
    const id = c.ids.length === 1 ? c.ids[0]! : undefined
    // A pr item whose PR is merged or closed is stale (the ledger closes it later), so it is never the next step.
    const live = ledgerOf(c).filter(l => {
      const url = /: - \[open\] pr \| (\S+) \|/.exec(l)?.[1]
      const state = url ? p.prs?.[url]?.state : undefined
      return !state || /^open$/i.test(state)
    })
    // Else the last RESULT; the session title has a line of its own, so it is never the next step.
    return id ? ledgerNext(live) ?? p.notes?.[id] ?? '' : ''
  }
  const isTerminal = e.surface === 'terminal'
  // Linear's look off the terminal; the terminal keeps its own colours.
  const t = isTerminal ? undefined : LINEAR[p.dark ? 'dark' : 'light']
  // A quiet button: no fill, dim text that turns full strength under the pointer.
  const detailsButton = <Button key="details" plain dimColor label="Open Pane" onPress={openPane} />
  const { Link } = $.ui.resolve(e)
  // Every link in the accent: a bare Link takes the surface's own colour, which drew grey in Details.
  const link = (href: string, label: string) =>
    t ? <Link href={href}><Text color={t.accent}>{label}</Text></Link> : <Link href={href} label={label} />
  // Only the ledger items due now (`bouncer-ledger due`), as what the user must do; open items that are not due are in
  // their card's row 2. In the band a count that opens the pane; there each row is the key as a link (the PR, else the
  // Linear issue), its next step and Ask Bouncer.
  const dueButton = due.length > 0 && (
    <Button key="ledger" plain onPress={openPane}><Text color="error">{`${due.length} to act`}</Text></Button>
  )
  const dueRows = due.map(line => {
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
  const undecided = (p.questionLines ?? []).map(questionItem).filter(q => q.id && q.question)
  const now = Object.values(p.sessions ?? {}).some(x => x.at) || undecided.some(q => q.at) ? await $.clock.now() : 0
  // A Bartender as Rounds row pieces: the title (dot and key, the key a link to its Linear issue), the status code as a
  // chip, the PR (`#17860 +1`, glyph in the PR state colour). The title is not a Button: a desktop Button adds its own
  // inset, so the rows would not align.
  const isLinked = (c: Column) => !!c.ticket && !!linear && LINEAR_KEY.test(c.ticket)
  // On a card (go), the dot, and the name when it is not a Linear key, open that Bartender's session; the key stays
  // the Linear link. A group of idle Bartenders has no one session to open.
  const titleOf = (c: Column, go = false) => {
    const id = go && c.ids.length === 1 ? c.ids[0]! : undefined
    const name = <Text weight="medium" color={t?.ink} wrap="truncate-end">{c.value}</Text>
    const press = id ? () => open(id, c.ticket || c.value) : undefined
    return isLinked(c)
      ? <Box flexDirection="row">{press ? <Button key={`go:${id}`} plain onPress={press}>{`${c.dot} `}</Button> : <Text>{`${c.dot} `}</Text>}{link(`${linear}/issue/${c.ticket}`, c.ticket)}</Box>
      : press ? <Button key={`go:${id}`} plain onPress={press}>{name}</Button> : name
  }
  // A Bartender's session title without its marks: `Fix it` of `🍸 [MIDI-1] [QA] Fix it`, `web` of `🔧 [Idle] web`.
  const sessionTitle = (id: string) => {
    const b = parseBartender(p.bartenders[id] ?? '')
    return b?.name || b?.repo || (p.bartenders[id] ?? '')
  }
  // The band pill's dot and key (or name) as one button that opens the Bartender's session; none for the idle group.
  const jumpOf = (c: Column) => c.ids.length === 1
    ? <Button key={`go:${c.ids[0]}`} plain label={c.value} onPress={() => open(c.ids[0]!, c.ticket || c.value)} />
    : undefined
  const chipOf = (c: Column) => (
    <Box key={`chip:${c.key}`} flexShrink={0} paddingX="xs" {...(t ? { backgroundColor: t.hairline } : {})}>
      <Text size="footnote" color={t?.muted}>{c.label}</Text>
    </Box>
  )
  const prOf = (c: Column) => {
    const id = c.ids.length === 1 ? c.ids[0]! : undefined
    const s = id ? p.sessions?.[id] : undefined
    // PR links only from full URLs in its report or its ticket's ledger lines; never from the folder's remote.
    const report = id ? p.reportTexts?.[id] ?? '' : ''
    const ledger = ledgerOf(c)
    const urls = prUrls([report, ...ledger])
    // With no PR of its own, the report's or an open ledger item's PR; a done item's only when nothing is open.
    const current = prUrls([report, ...ledger.filter(l => /: - \[open\] pr \| /.test(l))])[0] ?? urls[0]
    const own = ownPr(s?.pr, [report, ...ledger])
    const n = own?.number ?? Number(/\d+$/.exec(current ?? '')?.[0] ?? 0)
    const href = n ? prUrl(n, urls) : undefined
    // The state gh read for the URL first, as the pane does; the session's own PR state else.
    const [glyph, glyphColor] = prMark((href && p.prs?.[href]?.state) || own?.state)
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

  // The pane lists every open PR of the ticket (its open pr ledger items, and the session's own PR), each a link in the
  // PR state colour with its base (`#17860 → dev`), on a row of its own under row 1. The band keeps `#17860 +1`.
  const prsOf = (c: Column) => {
    const id = c.ids.length === 1 ? c.ids[0]! : undefined
    const s = id ? p.sessions?.[id] : undefined
    const urls = openPrUrls(ledgerOf(c), c.ticket)
    const texts = [id ? p.reportTexts?.[id] ?? '' : '', ...ledgerOf(c)]
    const own = ownPr(s?.pr, texts)?.number
    const ownHref = own ? prUrl(own, texts) : undefined
    const list = [
      ...(own && !(ownHref && urls.includes(ownHref)) ? [{ n: own, href: ownHref, state: s?.pr?.state }] : []),
      ...urls.map(u => ({ n: Number(/\d+$/.exec(u)?.[0] ?? 0), href: u as string | undefined, state: u === ownHref ? s?.pr?.state : undefined })),
    ]
    return list.map(x => ({ ...x, state: (x.href && p.prs?.[x.href]?.state) || x.state, base: x.href ? p.prs?.[x.href]?.base : undefined }))
  }
  if (!inPane) {
    // The band is exactly one line: the Bartender pills that fit, `+N` for the rest, what waits on the user, the due
    // count and Details at the far right. shortcut: no prop gives a pill's drawn width, so the fit is guessed in cells
    // (a character a cell on the terminal, 0.8 of one on the desktop app's proportional font; the dot 2, the gap and
    // the pill's frame 3; measured on the desktop app, 2026-11-27); the pills' Box clips what the guess lets through.
    // Measure once the engine gives widths.
    const n = p.waiting
    const w = (chars: number) => (isTerminal ? chars : Math.ceil(chars * 0.8))
    const right = w((n > 0 ? `${n} waits on you`.length + 2 : 0) + (due.length > 0 ? `${due.length} to act`.length + 2 : 0) + 'Open Pane'.length + 2)
    const budget = (e.props?.bodyColumns ?? 120) - right - 5
    const fitOf = (withPr: boolean) => {
      const cells = (c: Column) => 2 + w(c.value.length + (c.label ? c.label.length + 1 : 0) + (withPr ? prOf(c).cells : 0)) + 3
      let fit = 0
      for (let used = 0; fit < all.length && (used += cells(all[fit]!)) <= budget; fit++);
      return fit
    }
    // The jump never goes: when the pills do not all fit, they drop their PR links first (the pane keeps them).
    const withPr = fitOf(true) >= all.length || fitOf(false) <= fitOf(true)
    const shown = all.slice(0, Math.max(fitOf(withPr), Math.min(1, all.length)))
    const more = all.length - shown.length
    const mine = (
      <Box flexDirection="row" alignItems="center" flexWrap="nowrap" gap={isTerminal ? 2 : 'sm'} width={width}>
        <Box flexDirection="row" alignItems="center" flexWrap="nowrap" gap={isTerminal ? 2 : 'sm'} flexShrink={1} minWidth={0} overflow="hidden">
          {all.length === 0 && strip}
          {shown.map(c => (
            <Box key={`row:${c.key}`} flexDirection="row" alignItems="center" flexShrink={0} gap={isTerminal ? 1 : 'sm'} {...(t
              ? { borderStyle: 'round' as const, borderColor: t.hairline, backgroundColor: t.surface, paddingX: 'sm' as const, paddingY: 0 }
              : {})}>
              {/* The dot and key (or name) open the Bartender's session; the Linear link is in the pane. */}
              <Box key={`title:${c.key}`} flexShrink={0}>{jumpOf(c) ?? titleOf(c)}</Box>
              {c.label && <Box key={`chip:${c.key}`} flexShrink={0}><Text color={t?.muted}>{c.label}</Text></Box>}
              {withPr && prOf(c).el}
            </Box>
          ))}
        </Box>
        {more > 0 && <Button key="more" plain dimColor onPress={openPane}>{`+${more}`}</Button>}
        <Box flexGrow={1} />
        {n > 0 && (waits?.b
          ? <Button key="waits" plain onPress={() => open(waits.b!.id, waits.name)}><Text color="error">{`${n} waits on you`}</Text></Button>
          : <Text key="waits" color="error">{`${n} waits on you`}</Text>)}
        {dueButton}
        {detailsButton}
      </Box>
    )
    return below ? <Box flexDirection="column">{mine}{below}</Box> : mine
  }

  // The Bouncer pane, in Linear's look off the terminal (surface cards, hairline borders, ink, muted and subtle text):
  // the header, what waits on the user, the due list, the queue, then one card a Bartender, two a row.
  // A card in three rows, as a Rounds session row: the title (the dot and name open the session, the key is the Linear
  // link), the chip, the time and `⋯`; the open PRs; the next step or the last result. Width 0 and grow 1 give equal
  // cards (no flexBasis prop).
  const section = (label: string) => <Box key={`section:${label}`}><Text size="footnote" weight="medium" color={t?.subtle} dimColor={!t}>{label}</Text></Box>
  const frame = t
    ? { borderStyle: 'round' as const, borderColor: t.hairline, backgroundColor: t.surface, paddingX: 'md' as const, paddingY: 'md' as const }
    : { borderStyle: 'round' as const, paddingX: 1 as const }
  const card = (c: Column) => {
    const { time } = prOf(c)
    const id = c.ids.length === 1 ? c.ids[0]! : undefined
    const line = sub(c)
    const prs = prsOf(c)
    // Row 1 is the session title: the dot and title are one button that opens the session (the idle group's title is its count).
    const title = id ? sessionTitle(id) : c.value.replace(/^\S+ /, '')
    return (
      <Box key={`col:${c.key}`} flexDirection="column" flexGrow={1} flexShrink={1} width={0} minWidth={0} gap={isTerminal ? 0 : 'xs'} {...frame}>
        <Box flexDirection="row" alignItems="center" gap="sm">
          <Box key={`title:${c.key}`} flexGrow={1} flexShrink={1} minWidth={0}>
            {id
              ? <Button key={`jump:${id}`} plain onPress={() => open(id, c.ticket || c.value)}>{`${c.dot} `}<Text weight="medium" color={t?.ink} wrap="wrap" maxLines={2}>{title}</Text></Button>
              : <Box paddingLeft={isTerminal ? 0 : 'xs'}><Text weight="medium" color={t?.ink} wrap="truncate-end">{c.value}</Text></Box>}
          </Box>
          <Button key={c.key} plain dimColor label="⋯" onPress={() => update($, pool, q => ({ ...q, menu: q.menu === c.key ? undefined : c.key }))} />
        </Box>
        {/* Row 2: the key (the Linear link), the status chip and the time since its last activity. Row 3: each PR with its base. */}
        {id && (
          <Box key={`meta:${c.key}`} flexDirection="row" alignItems="center" flexWrap="wrap" gap="sm" paddingLeft={isTerminal ? 0 : 'xs'}>
            {c.ticket ? (isLinked(c) ? link(`${linear}/issue/${c.ticket}`, c.ticket) : <Text size="footnote" color={t?.muted}>{c.ticket}</Text>) : null}
            {c.label && chipOf(c)}
            <Box flexGrow={1} />
            {time && <Text size="footnote" color={t?.subtle}>{time}</Text>}
          </Box>
        )}
        {prs.length > 0 && (
          <Box key={`prs:${c.key}`} flexDirection="row" flexWrap="wrap" gap="md" paddingLeft={isTerminal ? 0 : 'xs'}>
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
        )}
        {line && <Box key={`line:${c.key}`} paddingLeft={isTerminal ? 0 : 'xs'}><Text size="footnote" color={t?.muted} wrap="wrap" maxLines={2}>{line}</Text></Box>}
        {/* The menu is a row of its own under the next step: secondary buttons on one row; the card grows to fit.
            The terminal keeps plain ones. */}
        {p.menu === c.key && rowsOf(menuCells(c)).map((cells, r) => (
          <Box key={`menu:${c.key}${r ? `:${r}` : ''}`} flexDirection="row" gap="sm" flexWrap="nowrap">
            {/* A desktop Button keeps its label's width (no width prop), so each cell draws the button: equal (width 0, grow 1, as the cards),
                a plain Button centred in it, in a Box that never shrinks, so the label never truncates. The keyed cell is the hover scope, so the
                whole cell lights; only the label takes the click (a Box has no onPress, a Button holds only text). Stop and Reset ask first. */}
            {cells.map(o => (
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
        ))}
      </Box>
    )
  }
  return (
    <Box flexDirection="column" gap={isTerminal ? 1 : 'md'} paddingY={isTerminal ? 0 : 'xs'}>
      <Box flexDirection="row" alignItems="center" gap={isTerminal ? 1 : 'sm'}>
        {/* Each card shows its own dot, so the pane header has no dot strip. */}
        {all.length === 0 && strip}
        <Text bold weight="semibold" color={t?.ink}>Bouncer</Text>
        <Text color={t?.muted}>{ownRepo}</Text>
        <Box flexGrow={1} />
        {p.queue > 0 && <Button key="queue" plain onPress={() => toggle('queueOpen')}><Text color={t?.muted}>{`Queue ${p.queue}`}</Text></Button>}
      </Box>
      {/* Every undecided item, oldest first: a Bartender's opens its session; the Bouncer's own scrolls this transcript to
          the reply that asked it (the last one that named its key), else says why not. */}
      {undecided.length > 0 && (
        <Box key="undecided" flexDirection="column" gap={isTerminal ? 0 : 'sm'}>
          <Box key="undecided:title"><Text size="footnote" weight="medium" color="error">{`Undecided ${undecided.length}`}</Text></Box>
          <Box flexDirection="column" gap={isTerminal ? 0 : 'xs'} backgroundColor="diffRemovedDimmed" paddingX={isTerminal ? 'xs' : 'md'} paddingY={isTerminal ? 0 : 'sm'} {...(t ? { borderStyle: 'round', borderColor: t.hairline } : {})}>
            {undecided.map(q => {
              const b = bartenders.find(x => x.id === q.id)
              const go = q.id === 'self'
                ? async () => {
                    const at = asks.get(q.ticket)
                    const ran = at ? await $.ui.scroll({ to: { requestId: at }, block: 'start' }).catch((err: unknown) => ({ deny: String(err) })) : { deny: 'no reply named it yet' }
                    if (ran.deny !== undefined) $.ui.toast(`${q.ticket}: ${ran.deny}`)
                  }
                : () => open(q.id, b ? b.ticket || b.repo : q.ticket)
              return (
                <Box key={`undecided:${q.ticket}`} flexDirection="row" alignItems="center" gap="sm" {...(t ? { hover: { backgroundColor: t.hover } } : {})}>
                  <Box flexGrow={1} flexShrink={1} minWidth={0}>
                    <Button key={`ask:${q.ticket}`} plain onPress={go}><Text wrap="truncate-end" color={t?.ink}>{`🔴 ${q.ticket}: ${q.question}`}</Text></Button>
                  </Box>
                  {q.at && now > 0 && <Text size="footnote" color={t?.subtle}>{ago(q.at, now)}</Text>}
                </Box>
              )
            })}
          </Box>
        </Box>
      )}
      {waits && undecided.length === 0 && (
        <Box backgroundColor="diffRemovedDimmed" paddingX={isTerminal ? 'xs' : 'md'} paddingY={isTerminal ? 0 : 'sm'} {...(t ? { borderStyle: 'round', borderColor: t.hairline } : {})}>
          {waits.b
            ? <Button key={`open:${waits.b.id}`} plain onPress={() => open(waits.b!.id, waits.name)}>
                <Text wrap="truncate" color={t?.ink}>{`🔴 ${waits.name}: ${waits.question}`}</Text>
              </Button>
            : <Text wrap="truncate" color={t?.ink}>{`🔴 ${waits.name}: ${waits.question}`}</Text>}
        </Box>
      )}
      {lines.length > 0 && (
        <Box key="queue:list" flexDirection="column" gap={isTerminal ? 0 : 'xs'}>
          {lines.map((line, i) => {
            const ticket = line.split('|')[0]?.trim() ?? ''
            return (
              <Box flexDirection="row" alignItems="center" gap={1}>
                <Box flexShrink={1} minWidth={0}><Text wrap="truncate" color={t?.ink}>{queueSummary(line)}</Text></Box>
                {i === 0 && <Button key="queue:pop" plain onPress={() => ask('queue: pop')}>Pop</Button>}
                <Button key={`queue:remove:${ticket}`} plain onPress={() => ask(`queue: remove ${ticket}`)}>Remove</Button>
              </Box>
            )
          })}
        </Box>
      )}
      {dueRows.length > 0 && (
        <Box key="due" flexDirection="column" gap={isTerminal ? 0 : 'sm'}>
          <Box key="due:title"><Text size="footnote" weight="medium" color="error">{`${due.length} to act`}</Text></Box>
          <Box flexDirection="column" gap={isTerminal ? 0 : 'sm'} {...frame}>{dueRows}</Box>
        </Box>
      )}
      {all.length > 0 && (
        <Box key="cards" flexDirection="column" gap={isTerminal ? 0 : 'sm'}>
          {section(`Bartenders ${all.length}`)}
          {Array.from({ length: Math.ceil(all.length / 2) }, (_, r) => (
            // Stretch: the cards of a row share one height, whatever rows each card shows.
            <Box key={`cards:${r}`} flexDirection="row" alignItems="stretch" gap={isTerminal ? 1 : 'md'}>
              {all.slice(r * 2, r * 2 + 2).map(card)}
              {/* The last card of an odd count keeps a half width: a spacer with the card's frame. */}
              {all.length > 1 && r * 2 + 1 >= all.length && <Box key="pad" flexGrow={1} flexShrink={1} width={0} minWidth={0} {...frame} borderStyle={undefined} backgroundColor={undefined} />}
            </Box>
          ))}
        </Box>
      )}
    </Box>
  )
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
    await update($, pool, p => (p.working ? p : { ...p, working: true }))
    if ((await read($, pool)).isOn) await refreshSessions($).catch(() => undefined)
    return next(e)
  })

  // The queue, questions and ledger change outside the Bouncer's own calls (a Bartender, a shell, the last session):
  // read them again when the session starts and after each of the Bouncer's turns.
  on('session.start', async ($, e, next) => {
    await update($, pool, p => (p.working ? { ...p, working: false } : p))
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
      await update($, pool, p => (p.pending || p.working ? { ...p, pending: false, working: false } : p))
      await refreshLook($).catch(() => undefined)
      if ((await read($, pool)).isOn) {
        await refreshData($, records).catch(() => undefined)
        await refreshDue($, records).catch(() => undefined)
      }
    }
    return next(e)
  })

  on('ui.render', { component: 'AbovePrompt' }, ($, e, next) => draw($, e, next, false, records, linear))
  // The Bouncer's Decide reply that names an undecided item's key is where the pane scrolls on a click; the last one wins.
  // A render may not write state, so the map is the module's own.
  on('ui.render', { component: 'AssistantMessage' }, async ($, e, next) => {
    const p = await read($, pool)
    if (p.isOn && /Decide/.test(e.props.text))
      for (const q of (p.questionLines ?? []).map(questionItem)) if (q.id === 'self' && e.props.text.includes(q.ticket)) asks.set(q.ticket, e.requestId)
    return next(e)
  })
  on('ui.render', { component: 'Pane', requestId: PANE }, async ($, e, next) => {
    const { Text } = $.ui.resolve(e)
    return (await read($, pool)).isOn ? draw($, e, next, true, records, linear) : <Text>This session is not the Bouncer.</Text>
  })
}
