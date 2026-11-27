import { expect, test } from 'claude-code/testing'

import { EMPTY, dot, parseBartender, ticketLedger, questionsBySession, renamed, reportLine, sessionRows, synced } from './pool'

const BAND = { plugin: 'bouncer', component: 'AbovePrompt', props: { hasSurvey: false, bodyColumns: 120 } } as const
const PANE = { plugin: 'bouncer', component: 'Pane', requestId: 'bouncer', props: { bodyColumns: 120 } } as const

// This session's id, and writes of the Bouncer owner file.
const base = (on: any, store: Record<string, unknown> = {}) => {
  // The 5-second confirm timer never fires in a test (a refused clock.after never runs its fn).
  on('clock.after', () => { throw new Error('no timer') })
  on('session.id', () => ({ value: 'me' }))
  on('session.cwd', () => ({ value: '/w/rounds' }))
  on('fs.write', () => ({ value: undefined }))
  on('store.get', (_: unknown, e: any) => ({ value: store[e.key] }))
  on('store.set', (_: unknown, e: any) => { store[e.key] = e.value; return { value: undefined } })
}

// Mount the band in Details (the columns); Compact is the default.
const details = async (ui: any) => {
  if ((await ui.find({ key: 'details' }))?.text === 'Details') await ui.press({ key: 'details' })
  return ui
}

const engine = (on: any, store?: Record<string, unknown>) => {
  on('tool.call', () => ({ result: {} }))
  on('turn.complete', (_: unknown, e: { answer: string }) => ({ text: e.answer }))
  base(on, store)
  on('process.hookEnv', () => ({ value: { CLAUDE_PLUGIN_DATA: '/data' } }))
  on('fs.read', (_: unknown, e: { path?: string }) => {
    if (e.path === '/data/rounds/queue.md') return { value: 'A-1 | r | Code | x\nA-2 | r | Spike | y\n' }
    if (e.path === '/data/rounds/questions.md') return { value: 'MIDI-1616 | local_a | Post the draft yourself? Default: yes\n' }
    throw new Error('missing')
  })
}

// What the band asks the Bouncer, and the notifications and toasts it raises.
const record = (on: any) => {
  const prompts: string[] = []
  const notes: string[] = []
  const toasts: string[] = []
  on('prompt.submit', (_: unknown, e: { text: string }) => { prompts.push(e.text); return { text: e.text } })
  on('ui.notify', (_: unknown, e: { text: string }) => { notes.push(e.text); return { value: { isSent: true, channel: 'test' } } })
  on('ui.toast', (_: unknown, e: { text: string }) => { toasts.push(e.text); return { value: undefined } })
  return { prompts, notes, toasts }
}

// The Bouncer's turn that a band prompt started ends.
const endTurn = ($: any) => $.turn.complete({ answer: '', durationMs: 1, isAborted: false, reason: 'answer' })

// The text a column's value draws.
const chip = (el: any) => el?.text
// A pick in a column's actions: the value opens them, the action closes them.
// Stop and Reset ask first: the second press of the same key sends.
const act = async (ui: any, key: string, value: string) => {
  await ui.press({ key })
  await ui.press({ key: `${key}:${value}` })
  if (!value.startsWith('status')) await ui.press({ key: `${key}:${value}` })
}
// The labels of a column's actions.
const actions = async (ui: any, key: string) => {
  await ui.press({ key })
  const labels = (await ui.findAll({ type: 'Button' })).filter((b: any) => b.key?.startsWith(`${key}:`)).map((b: any) => b.text)
  await ui.press({ key })
  return labels
}

// A Link's drawn text: its label, else its Text child's (the desktop's accent-coloured link).
const linkText = (l: any) => l.props.label ?? (l.children as any[]).find(c => c?.type === 'Text')?.children?.join('')

// True when a Link sits inside a Button: the Button would take the click, and the link would not open.
const linkInButton = async (ui: any) => {
  const has = (n: any): boolean => n && typeof n === 'object' && (n.type === 'Link' || (n.children ?? []).some(has))
  return (await ui.findAll({ type: 'Button' })).some((b: any) => (b.children ?? []).some(has))
}

const title = ($: any, session_id: string, t: string) =>
  $.tool.call({ tool: 'mcp__ccd_session_mgmt__set_session_title', session_id, title: t } as any)

test('no band outside a Bouncer session', async ($, on) => {
  engine(on)
  on('ui.render', ($, e) => { const { Text } = $.ui.resolve(e); return <Text>engine</Text> })
  await title($, 's1', '[Dev][MIDI-9] normal work')
  const ui = await $.ui.mount({ ...BAND, surface: 'desktop' } as any)
  expect(await ui.find({ type: 'Text', text: /Bouncer/ })).toBe(undefined)
  await ui.unmount()
})

test('the band shows Bartenders, the question count and the queue', async ($, on) => {
  engine(on)
  record(on)
  await title($, 'a', '[Dev] 🍸 MIDI-1 aspire')
  await title($, 'b', '![CR] 🍸 MIDI-2 web')
  await title($, 'c', '[Idle] 🍸 aspire')
  await title($, 'self', '!1 🚪 Bouncer')
  await $.tool.call({ tool: 'Bash', command: 'scripts/bouncer-queue list' } as any)
  await $.tool.call({ tool: 'mcp__ccd_session_mgmt__archive_session', session_id: 'c' } as any)

  for (const surface of ['terminal', 'desktop'] as const) {
    const ui = await $.ui.mount({ ...PANE, surface } as any)
    expect((await ui.find({ type: 'Text', text: /^[🔴🟡🟢⚪]( [🔴🟡🟢⚪])*$/u }))?.text).toBe('🔴 🟡')
    expect(chip(await ui.find({ key: 'title:' + 'act:a' }))).toBe('🟡 MIDI-1')
    expect(chip(await ui.find({ key: 'title:' + 'act:b' }))).toBe('🔴 MIDI-2')
    expect((await ui.find({ key: 'queue' }))?.text).toBe('Queue 2')
    await ui.unmount()
  }
})

test('the menu has only Status, Stop and Reset (the key is the Linear link), on one row under the next step', { options: { linear_workspace_url: 'https://linear.app/acme/' } }, async ($, on) => {
  engine(on)
  await title($, 'a', '[Dev] 🍸 MIDI-1 aspire')
  const ui = await $.ui.mount({ ...PANE, surface: 'desktop' } as any)
  expect(await actions(ui, 'act:a')).toEqual(['Status', 'Stop', 'Reset'])
  await ui.press({ key: 'act:a' })
  expect((await ui.find({ key: 'menu:act:a' }))?.props?.flexWrap).toBe('nowrap')
  // Three equal cells, each a plain Button centred.
  const cells = (await ui.find({ key: 'menu:act:a' }))?.children ?? []
  expect(cells.map((x: any) => [x.props?.width, x.props?.flexGrow, x.props?.justifyContent])).toEqual(Array(3).fill([0, 1, 'center']))
  // The whole cell lights under the pointer, not only the label.
  expect(cells.map((x: any) => [x.props?.key?.startsWith("cell:"), !!x.hover?.backgroundColor])).toEqual(Array(3).fill([true, true]))
  await ui.unmount()
})

test('one click on Stop or Reset sends nothing; it asks to confirm, and Cancel ends the ask', async ($, on) => {
  engine(on)
  const { prompts } = record(on)
  await title($, 'a', '[Dev] 🍸 MIDI-1616 aspire')
  const ui = await $.ui.mount({ ...PANE, surface: 'desktop' } as any)
  const labels = async () => (await ui.findAll({ type: 'Button' })).filter((b: any) => b.key?.startsWith('act:a:')).map((b: any) => b.text)
  await ui.press({ key: 'act:a' })
  for (const v of ['stop', 'reset']) {
    await ui.press({ key: `act:a:${v} a` })
    expect(prompts).toEqual([])
    // Title Case, as every button label.
    expect(await labels()).toEqual([`Confirm ${v[0]!.toUpperCase()}${v.slice(1)}?`, 'Cancel'])
    await ui.press({ key: 'act:a:cancel' })
    expect(prompts).toEqual([])
    expect(await labels()).toEqual(['Status', 'Stop', 'Reset'])
  }
  await ui.unmount()
})

test('the Bartender menu asks the Bouncer, never the Bartender', async ($, on) => {
  engine(on)
  const { prompts } = record(on)
  await title($, 'a', '[Dev] 🍸 MIDI-1616 aspire')
  await title($, 'c', '[Idle] 🍸 web')
  const ui = await $.ui.mount({ ...PANE, surface: 'desktop' } as any)
  for (const value of ['status', 'stop', 'reset']) { await act(ui, 'act:a', `${value} a`); await endTurn($) }
  await act(ui, 'idle', 'stop c')
  expect(prompts).toEqual(['MIDI-1616: status', 'MIDI-1616: stop', 'MIDI-1616: reset', 'c: stop'])
  await ui.unmount()
})

test('a notification only when the waiting count goes up', async ($, on) => {
  engine(on)
  const { notes } = record(on)
  await title($, 'self', '!1 🚪 Bouncer')
  await title($, 'self', '!3 🚪 Bouncer')
  await title($, 'self', '!2 🚪 Bouncer')
  await title($, 'self', '🚪 Bouncer')
  await title($, 'self', '!2 🚪 Bouncer')
  expect(notes).toEqual(['1 waiting on you', '3 waiting on you', '2 waiting on you'])
})

test('the queue opens to its lines, with Pop and Remove sent to the Bouncer', async ($, on) => {
  engine(on)
  const { prompts } = record(on)
  await title($, 'self', '🚪 Bouncer')
  await $.tool.call({ tool: 'Bash', command: 'scripts/bouncer-queue list' } as any)
  const ui = await $.ui.mount({ ...PANE, surface: 'desktop' } as any)
  expect(await ui.find({ type: 'Text', text: /A-1/ })).toBe(undefined)

  await ui.press({ key: 'queue' })
  expect((await ui.find({ type: 'Text', text: /A-2/ }))?.text).toBe('A-2 · r · Spike')
  expect(await ui.findAll({ key: 'queue:pop' })).toHaveLength(1)
  await ui.press({ key: 'queue:pop' })
  await endTurn($)
  await ui.press({ key: 'queue:remove:A-2' })
  expect(prompts).toEqual(['queue: pop', 'queue: remove A-2'])

  await ui.press({ key: 'queue' })
  expect(await ui.find({ type: 'Text', text: /A-1/ })).toBe(undefined)
  await ui.unmount()
})

test('a Bartender shows in the band when the Bouncer starts it', async ($, on) => {
  on('tool.call', { tool: 'mcp__ccd_session__start_session' }, (_: unknown, e: any) => ({
    result: `Started session "${e.title}" (session_id: local_${e.title.length}, name: x)`,
  }))
  engine(on)
  const start = (t: string, initiation = 'user_asked') =>
    $.tool.call({ tool: 'mcp__ccd_session__start_session', title: t, initiation, prompt: 'p' } as any)
  await title($, 'self', '🚪 Bouncer')
  await start('[Dev] 🍸 MIDI-1616 aspire')
  await start('Fix the band')
  await start('[Todo] 🍸 MIDI-7 web', 'offer')
  await start('[Dev] 🔧 bouncer-types rounds')
  await start('[Idle] 🧹 aspire')

  const ui = await $.ui.mount({ ...PANE, surface: 'desktop' } as any)
  const shown = (await cols(ui)).map((c: any) => c[1])
  expect(shown).toEqual(['🟡 MIDI-1616', '🟡 bouncer-types', '🟢 1 idle'])
  await ui.unmount()
})

test('a start_session call with a non-Bartender title leaves the pool unchanged', async ($, on) => {
  on('tool.call', { tool: 'mcp__ccd_session__start_session' }, () => ({
    result: 'Started session "Fix the band" (session_id: local_abc, name: x)',
  }))
  engine(on)
  await title($, 'self', '🚪 Bouncer')
  await $.tool.call({ tool: 'mcp__ccd_session__start_session', title: 'Fix the band', initiation: 'user_asked' } as any)

  const ui = await $.ui.mount({ ...PANE, surface: 'desktop' } as any)
  expect((await ui.find({ type: 'Text', text: /Bartenders/ }))?.text).toBe('no Bartenders yet')
  await ui.unmount()
})

test('only the head question shows; it opens its Bartender, or asks the Bouncer to', async ($, on) => {
  const opened: unknown[] = []
  on('tool.call', { tool: 'mcp__ccd_window__open_session_in' }, (_: unknown, e: any) => {
    opened.push([e.session_id, e.target])
    if (e.session_id === 'local_a') return { deny: 'not a session this session started' }
    return { result: 'Opened in split view.' }
  })
  engine(on)
  const { prompts } = record(on)
  await title($, 'local_a', '![Wont] 🍸 MIDI-1616 aspire')
  await title($, 'local_b', '[Dev] 🍸 MIDI-2 web')
  await $.tool.call({ tool: 'Bash', command: 'scripts/bouncer-questions add "MIDI-1616 | local_a | x"' } as any)
  // Set after the questions sync, which would clear a `!` that has no line in questions.md.
  await title($, 'local_c', '![Dev] 🍸 MIDI-3 web')
  // The sync set the Bouncer to !1; at 0 the band may send its fallback prompt.
  await title($, 'self', '🚪 Bouncer')

  const ui = await $.ui.mount({ ...PANE, surface: 'desktop' } as any)
  expect((await ui.find({ type: 'Text', text: /MIDI-1616:/ }))?.text).toBe('🔴 MIDI-1616: Post the draft yourself? Default: yes')
  // Questions block in order: MIDI-3 waits (its `!` shows) but its line stays hidden until the head is answered.
  expect(await ui.find({ type: 'Text', text: /MIDI-3:/ })).toBe(undefined)
  expect(chip(await ui.find({ key: 'title:' + 'act:local_c' }))).toBe('🔴 MIDI-3')
  expect((await ui.findAll({ type: 'Button' })).map((b: any) => b.key).filter((k: any) => k?.startsWith('open:'))).toEqual(['open:local_a'])

  // The plugin opens the Bartender in split view itself; when the app refuses, it asks the Bouncer.
  await ui.press({ key: 'open:local_a' })
  expect(opened).toEqual([['local_a', 'split']])
  expect(prompts).toEqual(['MIDI-1616: open'])
  await ui.unmount()
})

test('while a question waits, the band sends no prompt but Open still works', async ($, on) => {
  const opened: unknown[] = []
  on('tool.call', { tool: 'mcp__ccd_window__open_session_in' }, (_: unknown, e: any) => {
    opened.push(e.session_id)
    return e.session_id === 'local_a' ? { result: 'Opened in split view.' } : { deny: 'not started here' }
  })
  engine(on)
  const { prompts, toasts } = record(on)
  await title($, 'self', '!1 🚪 Bouncer')
  await title($, 'local_a', '![Dev] 🍸 MIDI-1 aspire')
  await title($, 'local_b', '![Dev] 🍸 MIDI-2 web')
  await $.tool.call({ tool: 'Bash', command: 'scripts/bouncer-queue list' } as any)

  const ui = await $.ui.mount({ ...PANE, surface: 'desktop' } as any)
  await act(ui, 'act:local_a', 'stop local_a')
  await ui.press({ key: 'queue' })
  await ui.press({ key: 'queue:pop' })
  await ui.press({ key: 'open:local_a' })
  expect(opened).toEqual(['local_a'])
  expect(prompts).toEqual([])
  expect(toasts).toEqual(Array(2).fill('Answer the waiting question first'))

  await title($, 'self', '🚪 Bouncer')
  await act(ui, 'act:local_a', 'stop local_a')
  expect(prompts).toEqual(['MIDI-1: stop'])
  await ui.unmount()
})

test('the band sends one prompt at a time, and none while the Bouncer works', async ($, on) => {
  engine(on)
  const { prompts, toasts } = record(on)
  await title($, 'self', '🚪 Bouncer')
  await title($, 'local_a', '[Dev] 🍸 MIDI-1 aspire')

  const busy = await $.ui.mount({ ...PANE, surface: 'desktop', props: { ...PANE.props, isWorking: true } } as any)
  await act(busy, 'act:local_a', 'status local_a')
  await busy.unmount()
  expect(prompts).toEqual([])

  const ui = await $.ui.mount({ ...PANE, surface: 'desktop', props: { ...PANE.props, isWorking: false } } as any)
  await act(ui, 'act:local_a', 'status local_a')
  await act(ui, 'act:local_a', 'stop local_a')
  expect(prompts).toEqual(['MIDI-1: status'])
  expect(toasts).toEqual(Array(2).fill('Wait for the Bouncer to finish its turn'))

  await $.turn.complete({ answer: '', durationMs: 1, isAborted: false, reason: 'answer', agentId: 'sub' } as any)
  await act(ui, 'act:local_a', 'stop local_a')
  expect(prompts).toEqual(['MIDI-1: status'])
  await endTurn($)
  await act(ui, 'act:local_a', 'stop local_a')
  expect(prompts).toEqual(['MIDI-1: status', 'MIDI-1: stop'])
  await ui.unmount()
})

test('a turn-end note sets the status code, and the CTA follows questions.md', async ($, on) => {
  const renames: string[] = []
  let questions = ''
  on('tool.call', (_: unknown, e: any) => {
    if (String(e.tool).endsWith('set_session_title')) renames.push(`${e.session_id}=${e.title}`)
    return { result: {} }
  })
  base(on)
  on('process.hookEnv', () => ({ value: { CLAUDE_PLUGIN_DATA: '/data', CLAUDE_PLUGIN_ROOT: '/plugin' } }))
  on('fs.read', (_: unknown, e: { path?: string }) => {
    if (e.path === '/data/rounds/questions.md') return { value: questions }
    throw new Error('missing')
  })
  on('session.receive', (_: unknown, e: any) => ({ text: e.text }))
  const runs: string[] = []
  on('process.run', (_: unknown, e: any) => {
    runs.push(e.argv[0])
    const isReport = /STATUS: NEEDS_INPUT/.test(e.init?.stdin ?? '')
    return { value: isReport
      ? { exitCode: 0, stdout: '{"status":"NEEDS_INPUT","ticket":"MIDI-1","linear":"CR"}', stderr: '', isStdoutTruncated: false, isStderrTruncated: false }
      : { exitCode: 2, stdout: '', stderr: 'bad', isStdoutTruncated: false, isStderrTruncated: false } }
  })
  await title($, 'self', '🚪 Bouncer')
  await title($, 'local_a', '[Dev] 🍸 MIDI-1 aspire')
  await title($, 'local_b', '[Dev] 🔧 band web')
  renames.length = 0

  await $.session.receive({ origin: { kind: 'task-notification' }, text: 'note\nSTATUS: NEEDS_INPUT\nTICKET: MIDI-1' } as any)
  expect(runs).toEqual(['/plugin/skills/bouncer/scripts/bouncer-report'])
  expect(renames).toEqual(['local_a=[CR] 🍸 MIDI-1 aspire'])

  await $.session.receive({ origin: { kind: 'task-notification' }, text: 'no report here' } as any)
  expect(runs.length).toBe(1)

  questions = 'MIDI-1 | local_a | Ship it? Default: yes\n'
  renames.length = 0
  await $.tool.call({ tool: 'Bash', command: 'scripts/bouncer-questions add "MIDI-1 | local_a | Ship it?"' } as any)
  expect(renames).toEqual(['local_a=![CR] 🍸 MIDI-1 aspire', 'self=!1 🚪 Bouncer rounds'])

  questions = ''
  renames.length = 0
  await $.tool.call({ tool: 'Bash', command: 'scripts/bouncer-questions done MIDI-1' } as any)
  expect(renames).toEqual(['local_a=[CR] 🍸 MIDI-1 aspire', 'self=🚪 Bouncer rounds'])
})

const LEDGER = '/r/K-1.md: - [open] pr | u | trigger: merged | check:  | next: merge it | 2026-11-26\n'
  + '/r/K-2.md: - [open] verify | K | trigger: t | check: c | next: check prod | 2026-11-26\n'

const DUE = '/r/MIDI-1.md: - [open] pr | https://github.com/acme/backend/pull/17 | trigger: merged | check:  | next: delete the branch | 2026-11-26\n'
  + '/r/MIDI-2.md: - [open] held-message | 17-freeze | trigger: t | check: c | next: post the QA reply | 2026-11-26\n'

test('the band shows only the due ledger items as a count to act on, each a link and its next step', { options: { records_dir: '~/.tickets', linear_workspace_url: 'https://linear.app/acme' } }, async ($, on) => {
  on('tool.call', () => ({ result: {} }))
  on('turn.complete', (_: unknown, e: { answer: string }) => ({ text: e.answer }))
  base(on)
  on('process.hookEnv', () => ({ value: { CLAUDE_PLUGIN_DATA: '/data', CLAUDE_PLUGIN_ROOT: '/plugin' } }))
  on('fs.read', () => { throw new Error('missing') })
  const { prompts } = record(on)
  const runs: unknown[] = []
  let due = ''
  on('process.run', (_: unknown, e: any) => {
    runs.push([e.argv.join(' '), e.init?.env?.BOUNCER_RECORDS])
    // `due` runs in a login shell (gh on PATH): `/bin/bash -lc 'exec "$0" due' <script>`.
    const stdout = e.argv[2] === 'exec "$0" due' ? due : LEDGER + DUE
    return { value: { exitCode: 0, stdout, stderr: '', isStdoutTruncated: false, isStderrTruncated: false } }
  })
  await $.tool.call({ tool: 'Skill', skill: 'bouncer' } as any)
  // Open items that are not due show nowhere in the header.
  let ui = await $.ui.mount({ ...BAND, surface: 'desktop' } as any)
  expect(await ui.find({ key: 'ledger' })).toBe(undefined)
  await ui.unmount()
  // A tool call reads the list only; `due` runs its checks once a turn.
  runs.length = 0
  due = DUE
  await $.tool.call({ tool: 'Bash', command: 'scripts/bouncer-ledger done K-1 u' } as any)
  expect(runs).toEqual([['/plugin/skills/bouncer/scripts/bouncer-ledger list --all', '~/.tickets']])
  await endTurn($)
  expect(runs).toContainEqual(['/bin/bash -lc exec "$0" due /plugin/skills/bouncer/scripts/bouncer-ledger', '~/.tickets'])
  ui = await $.ui.mount({ ...BAND, surface: 'desktop' } as any)
  expect((await ui.find({ key: 'ledger' }))?.text).toBe('2 to act')
  // The band stays one line: the list is in the pane.
  expect(await ui.find({ type: 'Text', text: /post the QA reply/ })).toBe(undefined)
  await ui.unmount()
  ui = await $.ui.mount({ ...PANE, surface: 'desktop' } as any)
  expect((await ui.find({ key: 'due:title' }))?.text).toBe('2 to act')
  const links = (await ui.findAll({ type: 'Link' })).map((l: any) => [linkText(l), l.props.href])
  expect(links).toEqual(expect.arrayContaining([['#17', 'https://github.com/acme/backend/pull/17'], ['MIDI-2', 'https://linear.app/acme/issue/MIDI-2']]))
  expect((await ui.find({ type: 'Text', text: /post the QA reply/ }))?.text).toBe('post the QA reply')
  expect(await ui.find({ type: 'Text', text: /check prod|K-2/ })).toBe(undefined)
  // In the pane the list sits under the header, above the cards.
  expect((await ui.find({ key: 'due' }))?.text).toMatch(/post the QA reply/)
  // Each row can go to the Bouncer.
  await ui.press({ key: 'due:ask:17-freeze' })
  // The prompt names the item (kind, key unless it is the ticket) and its next step.
  expect(prompts).toEqual(['MIDI-2: due held-message 17-freeze: post the QA reply'])
  await ui.unmount()
})

test('off the terminal Details opens the Bouncer pane, two cards a row, and the band stays one row', async ($, on) => {
  engine(on)
  const opened: unknown[] = []
  on('ui.open', (_: unknown, e: any) => { opened.push([e.id, e.focus]); return { value: { isPlaced: true } } })
  for (const k of ['a', 'b', 'c', 'd', 'e']) await title($, k, `🍸 [MIDI-${k.charCodeAt(0)}] [Dev] Ticket ${k}`)
  const band = await $.ui.mount({ ...BAND, surface: 'desktop' } as any)
  await band.press({ key: 'details' })
  // focus raises the pane when it is open already.
  expect(opened).toEqual([['bouncer', true]])
  expect((await band.find({ key: 'details' }))?.text).toBe('Open Pane')
  expect((await band.findAll({ type: 'Box' })).some((b: any) => b.props?.key?.startsWith('col:'))).toBe(false)
  await band.unmount()
  const pane = await $.ui.mount({ ...PANE, surface: 'desktop' } as any)
  const rows = ['cards:0', 'cards:1', 'cards:2']
  expect(await Promise.all(rows.map(async k => ((await pane.find({ key: k }))?.children ?? []).filter((c: any) => c.props?.key?.startsWith('col:')).length))).toEqual([2, 2, 1])
  await pane.unmount()
})

test('a card title opens its Bartender session in split view', async ($, on) => {
  const opened: unknown[] = []
  on('tool.call', { tool: 'mcp__ccd_window__open_session_in' }, (_: unknown, e: any) => {
    opened.push([e.session_id, e.target])
    return { result: 'Opened in split view.' }
  })
  engine(on)
  const { prompts } = record(on)
  await title($, 'local_a', '[Dev] 🍸 MIDI-1 aspire')
  await title($, 'local_b', '🍸 [Prep] S96 prep')
  const pane = await $.ui.mount({ ...PANE, surface: 'desktop' } as any)
  await pane.press({ key: 'go:local_a' })
  await pane.press({ key: 'go:local_b' })
  // The session title line is on every card, for a ticket and a non-ticket Bartender, and opens the session too.
  expect((await pane.find({ key: 'jump:local_a' }))?.text).toBe('aspire')
  expect((await pane.find({ key: 'jump:local_b' }))?.text).toBe('S96 prep')
  await pane.press({ key: 'jump:local_a' })
  await pane.press({ key: 'jump:local_b' })
  // The band pill's key opens the session.
  const band = await $.ui.mount({ ...BAND, surface: 'desktop' } as any)
  await band.press({ key: 'go:local_a' })
  await band.unmount()
  expect(opened).toEqual([['local_a', 'split'], ['local_b', 'split'], ['local_a', 'split'], ['local_b', 'split'], ['local_a', 'split']])
  expect(prompts).toEqual([])
  await pane.unmount()
})

test('a pane open that the engine rejects says so in a toast, never silently', async ($, on) => {
  engine(on)
  const { toasts } = record(on)
  // No ui.open handler: the open rejects, as it does for a pane another plugin holds.
  await title($, 'a', '🍸 [MIDI-1] [Dev] Ticket a')
  const ui = await $.ui.mount({ ...BAND, surface: 'desktop' } as any)
  await ui.press({ key: 'details' })
  expect(toasts).toHaveLength(1)
  expect(toasts[0]).toMatch(/^The Bouncer pane waits to show: .+/)
  await ui.unmount()
})

test('a pane that does not show says so; the band stays one line', async ($, on) => {
  engine(on)
  const { toasts } = record(on)
  on('ui.open', () => ({ value: { isPlaced: false, reason: 'no surface attached' } }))
  await title($, 'a', '🍸 [MIDI-1] [Dev] Ticket a')
  const ui = await $.ui.mount({ ...BAND, surface: 'desktop' } as any)
  await ui.press({ key: 'details' })
  expect(toasts).toEqual(['The Bouncer pane waits to show: no surface attached'])
  expect((await ui.findAll({ type: 'Box' })).some((b: any) => b.props?.key?.startsWith('col:'))).toBe(false)
  await ui.unmount()
})

test('off the terminal every Bartender has a card with its session title, which is never its next step', async ($, on) => {
  engine(on)
  for (const k of ['a', 'b', 'c', 'd', 'e']) await title($, k, `🍸 [MIDI-${k.charCodeAt(0)}] [Dev] Ticket ${k}`)
  const ui = await $.ui.mount({ ...PANE, surface: 'desktop' } as any)
  expect((await ui.findAll({ type: 'Box' })).filter((b: any) => b.props?.key?.startsWith('col:')).length).toBe(5)
  expect(await ui.find({ key: 'more' })).toBe(undefined)
  expect((await ui.findAll({ type: 'Text', text: 'Ticket e' })).length).toBe(1)
  await ui.unmount()
})

test('all idle Bartenders share one column, whose actions name each session', async ($, on) => {
  engine(on)
  const { prompts } = record(on)
  await title($, 'local_aaaaaaaa1', '[Idle] 🍸 aspire')
  await title($, 'local_bbbbbbbb2', '[Idle] 🍸 aspire')
  await title($, 'local_c', '[Idle] 🔧 web')
  const ui = await $.ui.mount({ ...PANE, surface: 'desktop' } as any)
  expect(chip(await ui.find({ key: 'title:' + 'idle' }))).toBe('🟢 3 idle')
  expect((await ui.findAll({ type: 'Button' })).filter((b: any) => b.key?.startsWith('act:'))).toEqual([])
  const labels = await actions(ui, 'idle')
  expect(labels).toContain('Reset aaaaaaaa')
  expect(labels).toContain('Reset bbbbbbbb')
  // One menu row a session, so nine buttons never squeeze into one row of a half-width card.
  const cellsIn = async (k: string) => ((await ui.find({ key: k }))?.children ?? []).filter((c: any) => c.props?.key?.startsWith('cell:')).length
  await ui.press({ key: 'idle' })
  expect(await Promise.all(['menu:idle', 'menu:idle:1', 'menu:idle:2'].map(cellsIn))).toEqual([3, 3, 3])
  await ui.press({ key: 'idle' })
  await act(ui, 'idle', 'reset local_bbbbbbbb2')
  expect(prompts).toEqual(['local_bbbbbbbb2: reset'])
  await ui.unmount()
})

test('nothing waits: no waiting text, no queue or ledger count, one row', async ($, on) => {
  on('tool.call', () => ({ result: {} }))
  base(on)
  on('process.hookEnv', () => ({ value: { CLAUDE_PLUGIN_DATA: '/data' } }))
  on('fs.read', () => { throw new Error('missing') })
  await title($, 'self', '🚪 Bouncer')
  await title($, 'a', '[Dev] 🍸 MIDI-1 aspire')
  const ui = await $.ui.mount({ ...PANE, surface: 'desktop' } as any)
  expect(await ui.find({ type: 'Text', text: /wait|🔴|│/ })).toBe(undefined)
  expect(await ui.find({ key: 'queue' })).toBe(undefined)
  expect(await ui.find({ key: 'ledger' })).toBe(undefined)
  await ui.unmount()
})

test('a queue emptied elsewhere leaves the band after the next turn or session start', async ($, on) => {
  let queue = 'A-1 | r | Code | x\n'
  on('tool.call', () => ({ result: {} }))
  on('turn.complete', (_: unknown, e: { answer: string }) => ({ text: e.answer }))
  on('session.start', (_: unknown, e: { cwd: string }) => ({ cwd: e.cwd }))
  base(on)
  on('process.hookEnv', () => ({ value: { CLAUDE_PLUGIN_DATA: '/data' } }))
  on('fs.read', (_: unknown, e: { path?: string }) => {
    if (e.path === '/data/rounds/queue.md') return { value: queue }
    throw new Error('missing')
  })
  await title($, 'self', '🚪 Bouncer')
  await $.tool.call({ tool: 'Bash', command: 'scripts/bouncer-queue list' } as any)
  const ui = await $.ui.mount({ ...PANE, surface: 'desktop' } as any)
  expect((await ui.find({ key: 'queue' }))?.text).toBe('Queue 1')
  queue = ''
  await endTurn($)
  expect(await ui.find({ key: 'queue' })).toBe(undefined)
  queue = 'A-1 | r | Code | x\nA-2 | r | Code | y\n'
  await $.session.start({ cwd: '/w', surface: 'desktop', isInteractive: true } as any)
  expect((await ui.find({ key: 'queue' }))?.text).toBe('Queue 2')
  await ui.unmount()
})

test('one Bouncer a repo: a second session of the same repo shows Take Over, and only that takes the Bouncer', async ($, on) => {
  let owner = 'other'
  const writes: string[] = []
  on('tool.call', () => ({ result: {} }))
  on('session.end', (_: unknown, e: any) => ({ sessionId: e.sessionId }))
  on('session.id', () => ({ value: 'me' }))
  on('session.cwd', () => ({ value: '/w/rounds' }))
  on('fs.write', (_: unknown, e: any) => { writes.push(e.text ?? e.content ?? e.data); owner = String(writes.at(-1)); return { value: undefined } })
  on('process.hookEnv', () => ({ value: { CLAUDE_PLUGIN_DATA: '/data' } }))
  on('fs.read', (_: unknown, e: { path?: string }) => {
    if (e.path === '/data/rounds/bouncer') return { value: owner }
    throw new Error('missing')
  })
  await $.tool.call({ tool: 'Skill', skill: 'bouncer:bouncer' } as any)
  await title($, 'a', '[Dev] 🍸 MIDI-1 aspire')
  const ui = await $.ui.mount({ ...PANE, surface: 'desktop' } as any)
  expect((await ui.find({ type: 'Text', text: /another session/ }))?.text).toBe('another session is the Bouncer of rounds')
  expect(await ui.find({ key: 'act:a' })).toBe(undefined)
  expect(writes).toEqual([])

  await ui.press({ key: 'takeover' })
  expect(writes).toEqual(['me'])
  expect(await ui.find({ type: 'Text', text: /another session/ })).toBe(undefined)
  await details(ui)
  expect(chip(await ui.find({ key: 'title:' + 'act:a' }))).toBe('🟡 MIDI-1')
  await ui.unmount()

  // Its session ends: the Bouncer is free for the next one.
  await $.session.end({ reason: 'other', sessionId: 'me' } as any)
  expect(writes).toEqual(['me', ''])
})

test('dots: red needs the user, yellow works, white holds a ticket with no turn running, green only when idle and free', () => {
  const d = (title: string, report?: string) => dot(parseBartender(title)!, report)
  expect(d('![Dev] 🍸 A-1 r')).toBe('🔴')
  expect(d('![Idle] 🍸 r')).toBe('🔴')
  expect(d('[Dev] 🍸 A-1 r', 'NEEDS_INPUT')).toBe('🔴')
  expect(d('[Dev] 🍸 A-1 r', 'BLOCKED')).toBe('🔴')
  expect(d('[CR] 🍸 A-1 r')).toBe('🟡')
  expect(d('[Dev] 🍸 A-1 r', 'DONE')).toBe('🟡')
  expect(d('[Dev] 🍸 A-1 r', 'WORKING')).toBe('🟡')
  expect(d('[Idle] 🍸 r')).toBe('🟢')
  expect(d('[Idle] 🍸 r', 'BLOCKED')).toBe('🟢')
  const s = (title: string, report: string | undefined, isRunning: boolean) => dot(parseBartender(title)!, report, isRunning)
  // Not free while the ticket is still its own, whatever waits: an open PR (CR), a gate (QA, Staging), a DONE turn.
  expect(s('[CR] 🍸 A-1 r', undefined, false)).toBe('⚪')
  expect(s('[QA] 🍸 A-1 r', undefined, false)).toBe('⚪')
  expect(s('🍸 [A-1] [Staging] Fix it', 'WORKING', false)).toBe('⚪')
  expect(s('[Dev] 🍸 A-1 r', 'DONE', false)).toBe('⚪')
  expect(s('🔧 [band] [Dev] Band layout', undefined, false)).toBe('⚪')
  // A question that waits on the user stays red.
  expect(s('[Dev] 🍸 A-1 r', 'NEEDS_INPUT', false)).toBe('🔴')
  // Free: the Bouncer set it Idle.
  expect(s('🍸 [Idle] r', undefined, false)).toBe('🟢')
  expect(s('[Dev] 🍸 A-1 r', undefined, true)).toBe('🟡')
  expect(s('[Dev] 🍸 A-1 r', 'BLOCKED', false)).toBe('🔴')
  expect(s('![Dev] 🍸 A-1 r', undefined, false)).toBe('🔴')
})

test('linked sessions parse from list_sessions JSON, bare or in text blocks', () => {
  const rows = '[{"sessionId":"local_a","title":"[QA] 🍸 A-1 r","isRunning":false,"prNumber":12,"prState":"OPEN"},{"sessionId":"local_b","title":"x","isRunning":true}]'
  const want = [{ id: 'local_a', title: '[QA] 🍸 A-1 r', isRunning: false, pr: { number: 12, state: 'open' } }, { id: 'local_b', title: 'x', isRunning: true }]
  expect(sessionRows(rows)).toEqual(want)
  expect(sessionRows(JSON.stringify([{ type: 'text', text: rows }]))).toEqual(want)
  expect(sessionRows(JSON.stringify({ content: [{ type: 'text', text: rows }] }))).toEqual(want)
  expect(sessionRows('{}')).toBe(undefined)
  expect(sessionRows('not json')).toBe(undefined)
})

test('the band fills from the linked sessions: titles, white when no turn runs, no filler in row 2', async ($, on) => {
  on('tool.call', { tool: 'mcp__ccd_session_mgmt__list_sessions' }, () => ({ result: JSON.stringify([
    { sessionId: 'local_a', title: '[QA] 🍸 MIDI-1 rounds', isRunning: false, prNumber: 12, prState: 'OPEN' },
    { sessionId: 'local_b', title: '[Dev] 🔧 band rounds', isRunning: true },
    { sessionId: 'local_c', title: 'Not a Bartender', isRunning: false },
  ]) }))
  engine(on, { details: true })
  on('session.start', (_: unknown, e: { cwd: string }) => ({ cwd: e.cwd }))
  await title($, 'self', '🚪 Bouncer')
  await title($, 'local_old', '[Dev] 🍸 MIDI-9 rounds')
  await $.session.start({ cwd: '/w', surface: 'desktop', isInteractive: true } as any)
  const ui = await $.ui.mount({ ...PANE, surface: 'desktop' } as any)
  expect((await ui.find({ type: 'Text', text: /^[🔴🟡🟢⚪]( [🔴🟡🟢⚪])*$/u }))?.text).toBe('🟡 ⚪')
  expect(await cols(ui)).toEqual([['Dev', '🟡 band', undefined], ['QA', '⚪ MIDI-1', undefined]])
  await ui.unmount()
})

test('a turn-end report sets its Bartender dot, and the strip is sorted red first', async ($, on) => {
  base(on)
  on('tool.call', () => ({ result: {} }))
  on('process.hookEnv', () => ({ value: { CLAUDE_PLUGIN_DATA: '/data', CLAUDE_PLUGIN_ROOT: '/plugin' } }))
  on('fs.read', () => { throw new Error('missing') })
  on('session.receive', (_: unknown, e: any) => ({ text: e.text }))
  on('process.run', () => ({ value: { exitCode: 0, stdout: '{"status":"BLOCKED","ticket":"A-2","linear":"Dev"}', stderr: '', isStdoutTruncated: false, isStderrTruncated: false } }))
  await title($, 'self', '🚪 Bouncer')
  await title($, 'a', '[Idle] 🍸 aspire')
  await title($, 'b', '[Dev] 🍸 A-1 aspire')
  await title($, 'c', '[Dev] 🍸 A-2 aspire')
  await title($, 'd', '[CR] 🍸 A-3 aspire')
  await $.session.receive({ origin: { kind: 'task-notification' }, text: 'STATUS: BLOCKED\nTICKET: A-2' } as any)
  const ui = await $.ui.mount({ ...PANE, surface: 'desktop' } as any)
  expect((await ui.find({ type: 'Text', text: /^[🔴🟡🟢⚪]( [🔴🟡🟢⚪])*$/u }))?.text).toBe('🔴 🟡 🟡 🟢')
  expect(chip(await ui.find({ key: 'title:' + 'act:c' }))).toBe('🔴 A-2')
  await ui.unmount()
})

test('the band is one line: a pill a Bartender (dot and key, chip), the waiting count and Details', async ($, on) => {
  const store: Record<string, unknown> = {}
  engine(on, store)
  await title($, 'self', '!1 🚪 Bouncer')
  await title($, 'a', '[Dev] 🍸 MIDI-1 aspire')
  await title($, 'c', '[CR] 🍸 MIDI-3 aspire')
  await title($, 'b', '[Idle] 🍸 aspire')
  await $.tool.call({ tool: 'Bash', command: 'scripts/bouncer-queue list' } as any)
  const ui = await $.ui.mount({ ...BAND, surface: 'desktop' } as any)
  expect(await ui.find({ key: 'dots' })).toBe(undefined)
  expect((await ui.find({ type: 'Text', text: /waits on you/ }))?.text).toBe('1 waits on you')
  expect(chip(await ui.find({ key: 'title:act:a' }))).toBe('🟡 MIDI-1')
  expect(chip(await ui.find({ key: 'chip:act:c' }))).toBe('CR')
  expect(chip(await ui.find({ key: 'title:idle' }))).toBe('🟢 1 idle')
  expect(await ui.find({ key: 'queue' })).toBe(undefined)
  expect(await ui.find({ type: 'Text', text: /Post the draft/ })).toBe(undefined)
  expect(await ui.find({ key: 'act:a' })).toBe(undefined)
  expect(await ui.find({ key: 'idle' })).toBe(undefined)
  expect((await ui.find({ key: 'details' }))?.text).toBe('Open Pane')
  // Details has no other state: the band stays this one line.
  await ui.press({ key: 'details' })
  expect((await ui.find({ key: 'details' }))?.text).toBe('Open Pane')
  expect(await ui.find({ key: 'act:a' })).toBe(undefined)

  await title($, 'self', '🚪 Bouncer')
  expect(await ui.find({ type: 'Text', text: /waits on you/ })).toBe(undefined)
  await ui.unmount()
})

test('a Bouncer of another repo does not block this one, and a repo title turns the band on', async ($, on) => {
  on('tool.call', () => ({ result: {} }))
  on('session.id', () => ({ value: 'me' }))
  on('session.cwd', () => ({ value: '/w/rounds' }))
  on('store.get', () => ({ value: true }))
  const writes: string[] = []
  on('fs.write', (_: unknown, e: any) => { writes.push(e.path); return { value: undefined } })
  on('process.hookEnv', () => ({ value: { CLAUDE_PLUGIN_DATA: '/data' } }))
  const reads: string[] = []
  on('fs.read', (_: unknown, e: { path?: string }) => {
    reads.push(String(e.path))
    if (e.path === '/data/web/bouncer') return { value: 'other' }
    if (e.path === '/data/rounds/queue.md') return { value: 'R-1 | rounds | Code | x\n' }
    if (e.path === '/data/web/queue.md') return { value: 'W-1 | web | Code | x\n' }
    throw new Error('missing')
  })
  await title($, 'self', '!1 🚪 Bouncer rounds')
  await $.tool.call({ tool: 'Bash', command: 'scripts/bouncer-queue list' } as any)
  const ui = await $.ui.mount({ ...PANE, surface: 'desktop' } as any)
  expect(await ui.find({ type: 'Text', text: /another session/ })).toBe(undefined)
  expect((await ui.find({ key: 'queue' }))?.text).toBe('Queue 1')
  expect(reads.filter(r => r.startsWith('/data/web/'))).toEqual([])
  expect(writes).toEqual(['/data/rounds/bouncer'])
  await ui.unmount()
})

test('two Bouncer questions keep the oldest as the head', () => {
  const q = questionsBySession('A-1 | self | Approve A?\nC-1 | self | Approve C?\nB-1 | local_b | Why?\n')
  expect(Object.entries(q)).toEqual([['self', 'Approve A?'], ['local_b', 'Why?']])
})

test('a Bartender loses its last report when it goes idle or takes another ticket', () => {
  const p = { ...EMPTY, bartenders: { s: '[Dev] 🍸 A-1 rounds' }, reports: { s: 'BLOCKED' } }
  expect(renamed(p, 's', '[Review] 🍸 A-1 rounds').reports).toEqual({ s: 'BLOCKED' })
  expect(renamed(p, 's', '[Dev] 🍸 B-2 rounds').reports).toEqual({})
  expect(renamed(p, 's', '[Idle] 🍸 rounds').reports).toEqual({})
  const n = { ...p, notes: { s: 'PR 31 open' } }
  expect(renamed(n, 's', '[Review] 🍸 A-1 rounds').notes).toEqual({ s: 'PR 31 open' })
  expect(renamed(n, 's', '[Idle] 🍸 rounds').notes).toEqual({})
})

test('a report line is the wait reason while the Bartender waits on the user, else the result', () => {
  const r = (status: string) => reportLine({ status, ticket: 'A-1', linear: null, result: 'PR 31 green', question: 'Merge it?' })
  expect(r('NEEDS_INPUT')).toBe('Merge it?')
  expect(r('BLOCKED')).toBe('Merge it?')
  expect(r('DONE')).toBe('PR 31 green')
  expect(reportLine({ status: 'BLOCKED', ticket: 'A-1', linear: null, result: 'waits on CI', question: null })).toBe('waits on CI')
  expect(reportLine({ status: 'WORKING', ticket: 'A-1', linear: null })).toBe('')
})

// Each card as [status chip, title, row 2], in band order.
const cols = async (ui: any) => {
  const out = []
  for (const b of (await ui.findAll({ type: 'Button' })).filter((b: any) => /^(act:|idle$)/.test(b.key ?? ''))) {
    const part = async (k: string) => (await ui.find({ key: `${k}:${b.key}` }))?.text
    out.push([await part('chip'), await part('title'), await part('line')])
  }
  return out
}

test('the pane has a card an active Bartender and one for the idle ones; the band shows what fits, then +N', async ($, on) => {
  engine(on)
  const opened: unknown[] = []
  on('ui.open', (_: unknown, e: any) => { opened.push(e.id); return { value: { isPlaced: true } } })
  on('session.start', (_: unknown, e: { cwd: string }) => ({ cwd: e.cwd }))
  await $.session.start({ cwd: '/w', surface: 'terminal', isInteractive: true } as any)
  await title($, 'self', '🚪 Bouncer')
  await title($, 'a', '[QA] 🍸 MIDI-1 rounds')
  const pane = await $.ui.mount({ ...PANE, surface: 'terminal' } as any)
  expect(await cols(pane)).toEqual([['QA', '🟡 MIDI-1', undefined]])
  expect((await pane.find({ type: 'Text', text: /^Bouncer$/ }))?.text).toBe('Bouncer')
  expect((await pane.find({ type: 'Text', text: /^rounds$/ }))?.text).toBe('rounds')

  await title($, 'b', '[Dev] 🔧 band rounds')
  await title($, 'c', '[Idle] 🍸 rounds')
  await title($, 'd', '[Idle] 🧹 rounds')
  await title($, 'e', '![Dev] 🍸 MIDI-5 rounds')
  await title($, 'f', '[CR] 🍸 MIDI-6 rounds')
  expect((await cols(pane)).map((c: any) => c[1])).toEqual(['🔴 MIDI-5', '🟡 MIDI-1', '🟡 band', '🟡 MIDI-6', '🟢 2 idle'])
  expect((await pane.find({ key: 'section:Bartenders 5' }))?.text).toBe('Bartenders 5')
  await pane.unmount()

  // 62 cells hold two pills next to the waiting count and Details; the rest is +N, which opens the pane.
  const band = await $.ui.mount({ ...BAND, surface: 'terminal', props: { ...BAND.props, bodyColumns: 62 } } as any)
  expect((await band.findAll({ type: 'Box' })).filter((b: any) => b.props?.key?.startsWith('row:')).length).toBe(2)
  expect((await band.find({ key: 'more' }))?.text).toBe('+3')
  await band.press({ key: 'more' })
  expect(opened).toEqual(['bouncer'])
  await band.unmount()
})

test('Details: the ask row shows only while a question waits; a report fills the sub-line, which stays while the menu is open', async ($, on) => {
  let questions = ''
  on('tool.call', () => ({ result: {} }))
  base(on, { details: true })
  on('session.start', (_: unknown, e: { cwd: string }) => ({ cwd: e.cwd }))
  on('process.hookEnv', () => ({ value: { CLAUDE_PLUGIN_DATA: '/data', CLAUDE_PLUGIN_ROOT: '/plugin' } }))
  on('fs.read', (_: unknown, e: { path?: string }) => {
    if (e.path === '/data/rounds/questions.md') return { value: questions }
    throw new Error('missing')
  })
  on('session.receive', (_: unknown, e: any) => ({ text: e.text }))
  on('process.run', () => ({ value: { exitCode: 0, stdout: '{"status":"DONE","ticket":"MIDI-1","linear":null,"result":"PR 31 open, CI green","question":null}', stderr: '', isStdoutTruncated: false, isStderrTruncated: false } }))
  await $.session.start({ cwd: '/w', surface: 'desktop', isInteractive: true } as any)
  await title($, 'self', '🚪 Bouncer')
  await title($, 'local_a', '[Dev] 🍸 MIDI-1 rounds')
  const ui = await $.ui.mount({ ...PANE, surface: 'desktop' } as any)
  expect(await ui.find({ type: 'Text', text: /^🔴 / })).toBe(undefined)

  await $.session.receive({ origin: { kind: 'task-notification' }, text: 'STATUS: DONE\nTICKET: MIDI-1' } as any)
  expect(await cols(ui)).toEqual([['Dev', '⚪ MIDI-1', 'PR 31 open, CI green']])

  await ui.press({ key: 'act:local_a' })
  expect((await ui.find({ type: 'Text', text: /PR 31/ }))?.text).toBe('PR 31 open, CI green')
  expect((await ui.findAll({ type: 'Button' })).filter((b: any) => b.key?.startsWith('act:local_a:')).map((b: any) => b.text)).toEqual(['Status', 'Stop', 'Reset'])
  await ui.press({ key: 'act:local_a' })
  expect((await ui.find({ type: 'Text', text: /PR 31/ }))?.text).toBe('PR 31 open, CI green')

  questions = 'MIDI-1 | local_a | Merge it? Default: yes\n'
  await $.tool.call({ tool: 'Bash', command: 'scripts/bouncer-questions add "MIDI-1 | local_a | Merge it?"' } as any)
  expect((await ui.find({ type: 'Text', text: /^🔴 / }))?.text).toBe('🔴 MIDI-1: Merge it? Default: yes')
  expect(await ui.find({ key: 'open:local_a' })).not.toBe(undefined)
  await ui.unmount()
})

test("Details off the terminal takes Linear's tokens for the system appearance: dark, or the light inverse", async ($, on) => {
  let style = 'Dark\n'
  on('process.run', (_: unknown, e: any) => ({ value: e.argv[0] === '/usr/bin/defaults'
    ? { exitCode: style ? 0 : 1, stdout: style, stderr: '', isStdoutTruncated: false, isStderrTruncated: false }
    : { exitCode: 1, stdout: '', stderr: '', isStdoutTruncated: false, isStderrTruncated: false } }))
  engine(on, { details: true })
  on('session.start', (_: unknown, e: { cwd: string }) => ({ cwd: e.cwd }))
  await title($, 'self', '🚪 Bouncer')
  await title($, 'a', '[Dev] 🍸 MIDI-1 rounds')
  await $.session.start({ cwd: '/w', surface: 'desktop', isInteractive: true } as any)
  // Off the terminal Details is the Bouncer pane.
  const ui = await $.ui.mount({ ...PANE, surface: 'desktop' } as any)
  const color = async (text: RegExp) => (await ui.find({ type: 'Text', text }))?.props?.color
  expect(await color(/^Bouncer$/)).toBe('#f7f8f8')
  expect(await color(/^Dev$/)).toBe('#d0d6e0')
  const cards = (await ui.findAll({ type: 'Box' })).filter((b: any) => b.props?.borderStyle === 'round' && b.props?.backgroundColor === '#0f1011')
  // One card, sized for equal widths (width 0, grow 1); the pane has no Compact switch.
  expect(cards.map((b: any) => [b.props.width, b.props.flexGrow])).toEqual([[0, 1]])
  expect(await ui.find({ key: 'details' })).toBe(undefined)
  style = ''
  await endTurn($)
  expect(await color(/^Bouncer$/)).toBe('#000000')
  expect(await ui.find({ type: 'Text', text: /│/ })).toBe(undefined)
  await ui.unmount()
})

test('with no PR of its own, the band pill takes the open ledger PR, not an older done one', async ($, on) => {
  on('tool.call', { tool: 'mcp__ccd_session_mgmt__list_sessions' }, () => ({ result: JSON.stringify([
    { sessionId: 'local_a', title: '[CR] 🍸 MIDI-1 rounds', isRunning: false, cwd: '/w' },
  ]) }))
  const out = (stdout: string) => ({ value: { exitCode: 0, stdout, stderr: '', isStdoutTruncated: false, isStderrTruncated: false } })
  on('process.run', (_: unknown, e: any) => {
    const cmd = String(e.argv[0])
    if (cmd.endsWith('bouncer-ledger')) return out('/r/MIDI-1.md: - [done] pr | https://github.com/acme/backend/pull/3 | trigger: merged | check:  | next: merge | 2026-11-25\n'
      + '/r/MIDI-1.md: - [open] pr | https://github.com/acme/backend/pull/4 | trigger: merged | check:  | next: review #4 | 2026-11-26\n')
    if (cmd === '/bin/bash') return out('{"state":"OPEN","baseRefName":"dev"}')
    return { value: { exitCode: 1, stdout: '', stderr: '', isStdoutTruncated: false, isStderrTruncated: false } }
  })
  on('tool.call', () => ({ result: {} }))
  on('turn.complete', (_: unknown, e: { answer: string }) => ({ text: e.answer }))
  base(on, { details: true })
  on('fs.read', () => { throw new Error('missing') })
  on('process.hookEnv', () => ({ value: { CLAUDE_PLUGIN_DATA: '/data', CLAUDE_PLUGIN_ROOT: '/plugin' } }))
  on('session.start', (_: unknown, e: { cwd: string }) => ({ cwd: e.cwd }))
  await title($, 'self', '🚪 Bouncer')
  await $.session.start({ cwd: '/w', surface: 'desktop', isInteractive: true } as any)
  await endTurn($)
  const band = await $.ui.mount({ ...BAND, surface: 'desktop' } as any)
  expect((await band.find({ key: 'pr:act:local_a' }))?.text).toContain('#4 +1')
  await band.unmount()
})

test('a card links its ticket to Linear and its PR to the URL that its ledger line or report names, never to its folder remote', { options: { linear_workspace_url: 'https://linear.app/acme' } }, async ($, on) => {
  on('tool.call', { tool: 'mcp__ccd_session_mgmt__list_sessions' }, () => ({ result: JSON.stringify([
    { sessionId: 'local_a', title: '[CR] 🍸 MIDI-1 rounds', isRunning: false, cwd: '/w/.claude/worktrees/midi-1', branch: 'henry/midi-1-fix', lastActivityAt: '2026-11-26T10:00:00Z', prNumber: 17, prState: 'MERGED' },
    { sessionId: 'local_b', title: '[Dev] 🔧 band rounds', isRunning: true, cwd: '/x/other', prNumber: 3, prState: 'OPEN' },
    { sessionId: 'local_c', title: '[Dev] 🍸 MIDI-2 rounds', isRunning: true, cwd: '/w', prNumber: 5, prState: 'OPEN' },
  ]) }))
  const out = (stdout: string) => ({ value: { exitCode: 0, stdout, stderr: '', isStdoutTruncated: false, isStderrTruncated: false } })
  on('process.run', (_: unknown, e: any) => {
    const cmd = String(e.argv[0])
    // The folder remote is another repo: the band must not use it.
    if (cmd === 'git') return out('git@github.com:acme/rounds.git\n')
    if (cmd.endsWith('bouncer-ledger')) return out('/r/MIDI-1.md: - [open] pr | https://github.com/acme/backend/pull/17 | trigger: merged | check:  | next: review, then merge #17 | 2026-11-26\n'
      + '/r/MIDI-1.md: - [open] pr | https://github.com/acme/backend/pull/18 | trigger: merged | check:  | next: merge #18 | 2026-11-26\n'
      + '/r/MIDI-9.md: - [open] pr | https://github.com/acme/web/pull/5 | trigger: merged | check:  | next: review | 2026-11-26\n'
      // A done item still names its PR's URL: band's #3 is found here even without a report.
      + '/r/rounds-bouncer-band.md: - [done] pr | https://github.com/acme/plugins/pull/3 | trigger: merged | check:  | next: merge | 2026-11-26\n')
    // gh, once a turn, for each open pr item: its state and base.
    if (cmd === '/bin/bash') return out(String(e.argv[3]).endsWith('/17') ? '{"state":"MERGED","baseRefName":"dev"}' : '{"state":"OPEN","baseRefName":"staging"}')
    if (cmd.endsWith('bouncer-report')) return out('{"status":"WORKING","ticket":"band","linear":null,"result":"PR up","question":null}')
    return { value: { exitCode: 1, stdout: '', stderr: '', isStdoutTruncated: false, isStderrTruncated: false } }
  })
  on('clock.now', () => ({ value: Date.parse('2026-11-26T10:14:30Z') }))
  // engine() without its hookEnv, which has no plugin root for bouncer-ledger and bouncer-report.
  on('tool.call', () => ({ result: {} }))
  on('turn.complete', (_: unknown, e: { answer: string }) => ({ text: e.answer }))
  base(on, { details: true })
  on('fs.read', () => { throw new Error('missing') })
  on('process.hookEnv', () => ({ value: { CLAUDE_PLUGIN_DATA: '/data', CLAUDE_PLUGIN_ROOT: '/plugin' } }))
  on('session.start', (_: unknown, e: { cwd: string }) => ({ cwd: e.cwd }))
  on('session.receive', (_: unknown, e: any) => ({ text: e.text }))
  await title($, 'self', '🚪 Bouncer')
  await $.session.start({ cwd: '/w', surface: 'desktop', isInteractive: true } as any)
  // A report whose EVIDENCE names the full PR URL.
  await $.session.receive({ origin: { kind: 'task-notification' }, text: 'STATUS: WORKING\nTICKET: band' } as any)
  const ui = await $.ui.mount({ ...PANE, surface: 'desktop' } as any)
  // The cards' links only: the due list above them links each due item's PR, MIDI-9's #5 included.
  const linksIn = (n: any): any[] => !n || typeof n !== 'object' ? [] : n.type === 'Link' ? [n] : (n.children ?? []).flatMap(linksIn)
  const links = linksIn(await ui.find({ key: 'cards' })).map((l: any) => [linkText(l), l.props.href])
  expect(links).toEqual(expect.arrayContaining([['MIDI-1', 'https://linear.app/acme/issue/MIDI-1'], ['#17', 'https://github.com/acme/backend/pull/17'], ['#3', 'https://github.com/acme/plugins/pull/3']]))
  expect(links.some(([, h]: any) => /acme\/rounds|pull\/5$/.test(h))).toBe(false)
  // No source names PR 5 for MIDI-2 (the ledger's #5 belongs to MIDI-9): plain text, no link.
  expect((await ui.find({ type: 'Text', text: /^#5$/ }))?.text).toBe('#5')
  expect((await ui.find({ type: 'Text', text: /^14m$/ }))?.text).toBe('14m')
  // Row 1 holds the status chip and the PR with the count of the ticket's other PRs; row 2 is the ledger's next step,
  // else the report line. No branch shows. The key shows once, as the title's link; the time is short and not mono.
  expect((await ui.find({ key: 'chip:act:local_a' }))?.text).toBe('CR')
  // Details lists each open PR of the ticket with its state colour, the base only while open, not `+1`.
  expect((await ui.find({ key: 'pr:act:local_a:17' }))?.text).toMatch(/^⤵ .*#17$/)
  expect((await ui.find({ key: 'pr:act:local_a:18' }))?.text).toMatch(/^⑂ .*#18 → staging$/)
  expect((await ui.find({ key: 'prs:act:local_a' }))?.text).not.toContain('+1')
  // #17 is merged, so its still-open ledger item is stale: the next step is the next open item.
  expect((await ui.find({ key: 'line:act:local_a' }))?.text).toBe('merge #18')
  expect((await ui.find({ key: 'line:act:local_b' }))?.text).toBe('PR up')
  expect(await ui.find({ type: 'Text', text: /⎇|henry\/midi-1-fix/ })).toBe(undefined)
  expect((await ui.findAll({ type: 'Text', text: /MIDI-1$/ })).map((x: any) => x.props.color)).toEqual(['#5e6ad2'])
  expect((await ui.find({ type: 'Text', text: /^14m$/ }))?.props?.mono).toBe(undefined)
  expect(await ui.find({ type: 'Text', text: /ticket|skill/ })).toBe(undefined)
  expect((await ui.find({ type: 'Text', text: /^⤵ $/ }))?.props?.color).toBe('merged')
  expect((await ui.find({ type: 'Text', text: /^⑂ $/ }))?.props?.color).toBe('success')
  expect(await linkInButton(ui)).toBe(false)
  // Each Details link draws in the accent, keys and PRs alike.
  const accent = (await ui.findAll({ type: 'Link' })).map((l: any) => (l.children as any[]).find(c => c?.type === 'Text')?.props?.color)
  expect(accent.length).toBeGreaterThanOrEqual(4)
  expect(new Set(accent)).toEqual(new Set(['#5e6ad2']))
  // The next step wraps to two lines.
  expect(((await ui.find({ key: 'line:act:local_a' }))?.children?.[0] as any)?.props).toMatchObject({ maxLines: 2 })
  await ui.unmount()
  // The band draws the PR links, none inside a Button, and keeps `+1`; its key opens the session (the Linear link is in the pane).
  const band = await $.ui.mount({ ...BAND, surface: 'desktop' } as any)
  expect((await band.find({ key: 'pr:act:local_a' }))?.text).toContain('+1')
  expect((await band.findAll({ type: 'Link' })).map((l: any) => linkText(l))).toEqual(expect.arrayContaining(['#17', '#3']))
  expect((await band.find({ key: 'go:local_a' }))?.text).toBe('⚪ MIDI-1')
  // A narrower band drops the PR links before any jump.
  const jumps = async (cols: number) => {
    const b = await $.ui.mount({ ...BAND, surface: 'desktop', props: { ...BAND.props, bodyColumns: cols } } as any)
    const r = [(await b.findAll({ type: 'Button' })).map((x: any) => x.key).filter((k: string) => k?.startsWith('go:')).length, (await b.findAll({ type: 'Link' })).length]
    await b.unmount()
    return r
  }
  expect(await jumps(75)).toEqual([3, 0])
  expect(await jumps(90)).toEqual([3, 2])
  expect(await linkInButton(band)).toBe(false)
  await band.unmount()
})

test('a Bartender title parses in the new format and the old one; a sync keeps the format', () => {
  expect(parseBartender('!🍸 [MIDI-3498] [QA] Broadcast channel switch skips low band…')).toMatchObject(
    { cta: true, status: 'QA', type: 'Ticket', ticket: 'MIDI-3498', name: 'Broadcast channel switch skips low band…', repo: '' })
  expect(parseBartender('🔧 [Idle] rounds')).toMatchObject({ cta: false, status: 'Idle', type: 'Skill', ticket: '', repo: 'rounds' })
  expect(parseBartender('🔧 [band] [Dev] Band layout')).toMatchObject({ status: 'Dev', ticket: 'band', name: 'Band layout' })
  expect(parseBartender('![Dev] 🍸 MIDI-1 rounds')).toMatchObject({ cta: true, status: 'Dev', ticket: 'MIDI-1', repo: 'rounds' })
  expect(parseBartender('🍸 MIDI-1 rounds')).toBe(undefined)
  const pool = { ...EMPTY, bartenders: { a: '🍸 [MIDI-1] [Dev] Fix it', b: '[Dev] 🍸 MIDI-2 rounds', c: '🧹 [Idle] rounds' } }
  const report = { status: 'DONE', ticket: 'MIDI-1', linear: 'QA', result: null, question: null }
  expect(synced(pool, 'MIDI-2 | b | Merge?\n', report)).toEqual([['a', '🍸 [MIDI-1] [QA] Fix it'], ['b', '![Dev] 🍸 MIDI-2 rounds'], ['self', '!1 🚪 Bouncer']])
})

test('a Bartender turn-end note turns its dot from yellow to white at once', async ($, on) => {
  on('tool.call', { tool: 'mcp__ccd_session_mgmt__list_sessions' }, () => ({ result: JSON.stringify([
    { sessionId: 'local_a', title: '🍸 [MIDI-1] [Dev] Fix it', isRunning: true, cwd: '/w' },
  ]) }))
  on('tool.call', () => ({ result: {} }))
  on('turn.complete', (_: unknown, e: { answer: string }) => ({ text: e.answer }))
  on('session.start', (_: unknown, e: { cwd: string }) => ({ cwd: e.cwd }))
  on('session.receive', (_: unknown, e: any) => ({ text: e.text }))
  base(on)
  on('fs.read', () => { throw new Error('missing') })
  on('process.hookEnv', () => ({ value: { CLAUDE_PLUGIN_DATA: '/data', CLAUDE_PLUGIN_ROOT: '/plugin' } }))
  on('process.run', (_: unknown, e: any) => ({ value: { exitCode: String(e.argv[0]).endsWith('bouncer-report') ? 0 : 1,
    stdout: '{"status":"DONE","ticket":"MIDI-1","linear":null,"result":"shipped","question":null}', stderr: '', isStdoutTruncated: false, isStderrTruncated: false } }))
  await $.tool.call({ tool: 'Skill', skill: 'bouncer' } as any)
  const ui = await $.ui.mount({ ...BAND, surface: 'desktop' } as any)
  expect(chip(await ui.find({ key: 'title:act:local_a' }))).toBe('🟡 MIDI-1')
  await $.session.receive({ origin: { kind: 'task-notification' }, text: 'STATUS: DONE\nTICKET: MIDI-1\nRESULT: shipped' } as any)
  expect(chip(await ui.find({ key: 'title:act:local_a' }))).toBe('⚪ MIDI-1')
  await ui.unmount()
})

test('a prompt into the Bouncer reads list_sessions again, so a Bartender that ended its turn leaves yellow', async ($, on) => {
  let isRunning = true
  on('tool.call', { tool: 'mcp__ccd_session_mgmt__list_sessions' }, () => ({ result: JSON.stringify([
    { sessionId: 'local_a', title: '🍸 [MIDI-1] [Dev] Fix it', isRunning, cwd: '/w' },
  ]) }))
  on('tool.call', () => ({ result: {} }))
  on('prompt.submit', (_: unknown, e: { text: string }) => ({ text: e.text }))
  base(on)
  on('fs.read', () => { throw new Error('missing') })
  on('process.hookEnv', () => ({ value: { CLAUDE_PLUGIN_DATA: '/data' } }))
  await $.tool.call({ tool: 'Skill', skill: 'bouncer' } as any)
  const ui = await $.ui.mount({ ...BAND, surface: 'desktop' } as any)
  expect(chip(await ui.find({ key: 'title:act:local_a' }))).toBe('🟡 MIDI-1')
  isRunning = false
  await $.prompt.submit({ text: '<side-sessions-event>local_a ended its turn</side-sessions-event>' } as any)
  expect(chip(await ui.find({ key: 'title:act:local_a' }))).toBe('⚪ MIDI-1')
  await ui.unmount()
})

test('a record named by its branch takes the session repo when two repos share the name', () => {
  const lines = ['/r/aaa-band.md: - [open] pr | https://github.com/x/aaa/pull/1 | next: a', '/r/rounds-band.md: - [open] pr | https://github.com/x/rounds/pull/2 | next: b', '/r/MIDI-1.md: - [open] x']
  expect(ticketLedger(lines, 'band', 'Rounds')).toEqual([lines[1]])
  // No repo, or no record of it: both stay.
  expect(ticketLedger(lines, 'band')).toEqual(lines.slice(0, 2))
  expect(ticketLedger(lines, 'band', 'other')).toEqual(lines.slice(0, 2))
  // One record of another repo stays: a folder may be another repo than its work.
  expect(ticketLedger(lines.slice(1), 'band', 'other')).toEqual([lines[1]])
  expect(ticketLedger(lines, 'MIDI-1', 'Rounds')).toEqual([lines[2]])
})
