import { expect, test } from 'claude-code/testing'

import { EMPTY, dot, parseBartender, questionsBySession, renamed, reportLine, sessionRows } from './pool'

const BAND = { plugin: 'bouncer', component: 'AbovePrompt', props: { hasSurvey: false, bodyColumns: 120 } } as const

// This session's id, and writes of the Bouncer owner file.
const base = (on: any, store: Record<string, unknown> = {}) => {
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
const act = async (ui: any, key: string, value: string) => { await ui.press({ key }); await ui.press({ key: `${key}:${value}` }) }
// The labels of a column's actions.
const actions = async (ui: any, key: string) => {
  await ui.press({ key })
  const labels = (await ui.findAll({ type: 'Button' })).filter((b: any) => b.key?.startsWith(`${key}:`)).map((b: any) => b.text)
  await ui.press({ key })
  return labels
}

const title = ($: any, session_id: string, t: string) =>
  $.tool.call({ tool: 'mcp__ccd_session_mgmt__set_session_title', session_id, title: t } as any)

test('no band outside a Bouncer session', async ($, on) => {
  engine(on)
  on('ui.render', ($, e) => { const { Text } = $.ui.resolve(e); return <Text>engine</Text> })
  await title($, 's1', '[Dev][MIDI-9] normal work')
  const ui = await details(await $.ui.mount({ ...BAND, surface: 'desktop' } as any))
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
    const ui = await details(await $.ui.mount({ ...BAND, surface } as any))
    expect((await ui.find({ type: 'Text', text: /^[🔴🟡🟢⚪]+$/u }))?.text).toBe('🔴🟡')
    expect(chip(await ui.find({ key: 'act:a' }))).toBe('🟡 MIDI-1')
    expect(chip(await ui.find({ key: 'act:b' }))).toBe('🔴 MIDI-2')
    expect((await ui.find({ key: 'queue' }))?.text).toBe('Queue 2')
    await ui.unmount()
  }
})

test('a ticket key opens in the Linear workspace of the option from its column menu', { options: { linear_workspace_url: 'https://linear.app/acme/' } }, async ($, on) => {
  engine(on)
  const runs: string[][] = []
  on('process.run', (_: unknown, e: any) => { runs.push(e.argv); return { value: { exitCode: 0, stdout: '', stderr: '', isStdoutTruncated: false, isStderrTruncated: false } } })
  await title($, 'a', '[Dev] 🍸 MIDI-1 aspire')
  await title($, 'b', '[Dev] 🍸 12 web')
  const ui = await details(await $.ui.mount({ ...BAND, surface: 'desktop' } as any))
  expect(await actions(ui, 'act:b')).toEqual(['Status', 'Stop', 'Reset'])
  await act(ui, 'act:a', 'linear')
  expect(runs).toEqual([['/usr/bin/open', 'https://linear.app/acme/issue/MIDI-1']])
  await ui.unmount()
})

test('the column menu has no Linear item while the option is unset', async ($, on) => {
  engine(on)
  await title($, 'a', '[Dev] 🍸 MIDI-1 aspire')
  const ui = await details(await $.ui.mount({ ...BAND, surface: 'desktop' } as any))
  expect(await actions(ui, 'act:a')).toEqual(['Status', 'Stop', 'Reset'])
  await ui.unmount()
})

test('the Bartender menu asks the Bouncer, never the Bartender', async ($, on) => {
  engine(on)
  const { prompts } = record(on)
  await title($, 'a', '[Dev] 🍸 MIDI-1616 aspire')
  await title($, 'c', '[Idle] 🍸 web')
  const ui = await details(await $.ui.mount({ ...BAND, surface: 'desktop' } as any))
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
  const ui = await details(await $.ui.mount({ ...BAND, surface: 'desktop' } as any))
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

  const ui = await details(await $.ui.mount({ ...BAND, surface: 'desktop' } as any))
  const shown = (await ui.findAll({ type: 'Button' })).filter((b: any) => /^(act:|idle$)/.test(b.key ?? '')).map(chip)
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

  const ui = await details(await $.ui.mount({ ...BAND, surface: 'desktop' } as any))
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

  const ui = await details(await $.ui.mount({ ...BAND, surface: 'desktop' } as any))
  expect((await ui.find({ type: 'Text', text: /MIDI-1616:/ }))?.text).toBe('🔴 MIDI-1616: Post the draft yourself? Default: yes')
  // Questions block in order: MIDI-3 waits (its `!` shows) but its line stays hidden until the head is answered.
  expect(await ui.find({ type: 'Text', text: /MIDI-3:/ })).toBe(undefined)
  expect(chip(await ui.find({ key: 'act:local_c' }))).toBe('🔴 MIDI-3')
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

  const ui = await details(await $.ui.mount({ ...BAND, surface: 'desktop' } as any))
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

  const busy = await details(await $.ui.mount({ ...BAND, surface: 'desktop', props: { ...BAND.props, isWorking: true } } as any))
  await act(busy, 'act:local_a', 'status local_a')
  await busy.unmount()
  expect(prompts).toEqual([])

  const ui = await details(await $.ui.mount({ ...BAND, surface: 'desktop', props: { ...BAND.props, isWorking: false } } as any))
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

test('the band shows the open ledger count', { options: { records_dir: '~/.tickets' } }, async ($, on) => {
  on('tool.call', () => ({ result: {} }))
  base(on)
  on('process.hookEnv', () => ({ value: { CLAUDE_PLUGIN_DATA: '/data', CLAUDE_PLUGIN_ROOT: '/plugin' } }))
  on('fs.read', () => { throw new Error('missing') })
  const envs: unknown[] = []
  on('process.run', (_: unknown, e: any) => {
    envs.push([e.argv.join(' '), e.init?.env?.BOUNCER_RECORDS])
    return { value: { exitCode: 0, stdout: LEDGER, stderr: '', isStdoutTruncated: false, isStderrTruncated: false } }
  })
  await title($, 'self', '🚪 Bouncer')
  await $.tool.call({ tool: 'Bash', command: 'scripts/bouncer-ledger done K-1 u' } as any)
  expect(envs).toEqual([['/plugin/skills/bouncer/scripts/bouncer-ledger list', '~/.tickets']])
  const ui = await details(await $.ui.mount({ ...BAND, surface: 'desktop' } as any))
  expect((await ui.find({ key: 'ledger' }))?.text).toBe('Due 2')
  expect(await ui.find({ type: 'Text', text: /K-1/ })).toBe(undefined)
  await ui.press({ key: 'ledger' })
  expect((await ui.findAll({ type: 'Text', text: /^K-/ })).map((t: any) => t.text)).toEqual(['K-1 · pr · merge it', 'K-2 · verify · check prod'])
  await ui.unmount()
})

test('all idle Bartenders share one column, whose actions name each session', async ($, on) => {
  engine(on)
  const { prompts } = record(on)
  await title($, 'local_aaaaaaaa1', '[Idle] 🍸 aspire')
  await title($, 'local_bbbbbbbb2', '[Idle] 🍸 aspire')
  await title($, 'local_c', '[Idle] 🔧 web')
  const ui = await details(await $.ui.mount({ ...BAND, surface: 'desktop' } as any))
  expect(chip(await ui.find({ key: 'idle' }))).toBe('🟢 3 idle')
  expect((await ui.findAll({ type: 'Button' })).filter((b: any) => b.key?.startsWith('act:'))).toEqual([])
  const labels = await actions(ui, 'idle')
  expect(labels).toContain('Reset aaaaaaaa')
  expect(labels).toContain('Reset bbbbbbbb')
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
  const ui = await details(await $.ui.mount({ ...BAND, surface: 'desktop' } as any))
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
  const ui = await details(await $.ui.mount({ ...BAND, surface: 'desktop' } as any))
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
  const ui = await details(await $.ui.mount({ ...BAND, surface: 'desktop' } as any))
  expect((await ui.find({ type: 'Text', text: /another session/ }))?.text).toBe('another session is the Bouncer of rounds')
  expect(await ui.find({ key: 'act:a' })).toBe(undefined)
  expect(writes).toEqual([])

  await ui.press({ key: 'takeover' })
  expect(writes).toEqual(['me'])
  expect(await ui.find({ type: 'Text', text: /another session/ })).toBe(undefined)
  await details(ui)
  expect(chip(await ui.find({ key: 'act:a' }))).toBe('🟡 MIDI-1')
  await ui.unmount()

  // Its session ends: the Bouncer is free for the next one.
  await $.session.end({ reason: 'other', sessionId: 'me' } as any)
  expect(writes).toEqual(['me', ''])
})

test('dots: red needs the user, yellow works or waits on others, green is idle', () => {
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
  expect(s('[InQA] 🍸 A-1 r', undefined, false)).toBe('🟢')
  expect(s('[Dev] 🍸 A-1 r', 'DONE', false)).toBe('🟢')
  expect(s('[Dev] 🍸 A-1 r', undefined, true)).toBe('🟡')
  expect(s('[Dev] 🍸 A-1 r', 'BLOCKED', false)).toBe('🔴')
  expect(s('![Dev] 🍸 A-1 r', undefined, false)).toBe('🔴')
})

test('linked sessions parse from list_sessions JSON, bare or in text blocks', () => {
  const rows = '[{"sessionId":"local_a","title":"[InQA] 🍸 A-1 r","isRunning":false,"prNumber":12,"prState":"OPEN"},{"sessionId":"local_b","title":"x","isRunning":true}]'
  const want = [{ id: 'local_a', title: '[InQA] 🍸 A-1 r', isRunning: false, pr: 'PR 12 open' }, { id: 'local_b', title: 'x', isRunning: true }]
  expect(sessionRows(rows)).toEqual(want)
  expect(sessionRows(JSON.stringify([{ type: 'text', text: rows }]))).toEqual(want)
  expect(sessionRows(JSON.stringify({ content: [{ type: 'text', text: rows }] }))).toEqual(want)
  expect(sessionRows('{}')).toBe(undefined)
  expect(sessionRows('not json')).toBe(undefined)
})

test('the band fills from the linked sessions: titles, green when no turn runs, the PR as the sub-line', async ($, on) => {
  on('tool.call', { tool: 'mcp__ccd_session_mgmt__list_sessions' }, () => ({ result: JSON.stringify([
    { sessionId: 'local_a', title: '[InQA] 🍸 MIDI-1 rounds', isRunning: false, prNumber: 12, prState: 'OPEN' },
    { sessionId: 'local_b', title: '[Dev] 🔧 band rounds', isRunning: true },
    { sessionId: 'local_c', title: 'Not a Bartender', isRunning: false },
  ]) }))
  engine(on, { details: true })
  on('session.start', (_: unknown, e: { cwd: string }) => ({ cwd: e.cwd }))
  await title($, 'self', '🚪 Bouncer')
  await title($, 'local_old', '[Dev] 🍸 MIDI-9 rounds')
  await $.session.start({ cwd: '/w', surface: 'desktop', isInteractive: true } as any)
  const ui = await $.ui.mount({ ...BAND, surface: 'desktop' } as any)
  expect((await ui.find({ type: 'Text', text: /^[🔴🟡🟢]+$/u }))?.text).toBe('🟡🟢')
  expect(await cols(ui)).toEqual([['skill · Dev', '🟡 band', 'working'], ['ticket · InQA', '🟢 MIDI-1', 'PR 12 open']])
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
  const ui = await details(await $.ui.mount({ ...BAND, surface: 'desktop' } as any))
  expect((await ui.find({ type: 'Text', text: /^[🔴🟡🟢⚪]+$/u }))?.text).toBe('🔴🟡🟡🟢')
  expect(chip(await ui.find({ key: 'act:c' }))).toBe('🔴 A-2')
  await ui.unmount()
})

test('Compact is one line: dots, the waiting count, the active keys and Details; Details is kept in the store', async ($, on) => {
  const store: Record<string, unknown> = {}
  engine(on, store)
  await title($, 'self', '!1 🚪 Bouncer')
  await title($, 'a', '[Dev] 🍸 MIDI-1 aspire')
  await title($, 'c', '[CR] 🍸 MIDI-3 aspire')
  await title($, 'b', '[Idle] 🍸 aspire')
  await $.tool.call({ tool: 'Bash', command: 'scripts/bouncer-queue list' } as any)
  const ui = await $.ui.mount({ ...BAND, surface: 'desktop' } as any)
  expect((await ui.find({ type: 'Text', text: /^[🔴🟡🟢]+$/u }))?.text).toBe('🟡🟡🟢')
  expect((await ui.find({ type: 'Text', text: /waits on you/ }))?.text).toBe('1 waits on you')
  expect((await ui.find({ type: 'Text', text: /^MIDI-/ }))?.text).toBe('MIDI-1 MIDI-3')
  expect(await ui.find({ key: 'queue' })).toBe(undefined)
  expect(await ui.find({ type: 'Text', text: /Post the draft/ })).toBe(undefined)
  expect(await ui.find({ key: 'act:a' })).toBe(undefined)
  expect(await ui.find({ key: 'idle' })).toBe(undefined)
  expect((await ui.find({ key: 'details' }))?.text).toBe('Details')

  await ui.press({ key: 'details' })
  expect(chip(await ui.find({ key: 'act:a' }))).toBe('🟡 MIDI-1')
  expect((await ui.find({ key: 'details' }))?.text).toBe('Compact')
  expect(store.details).toBe(true)
  await ui.press({ key: 'details' })
  expect(await ui.find({ key: 'act:a' })).toBe(undefined)
  expect(store.details).toBe(false)

  await title($, 'self', '🚪 Bouncer')
  expect(await ui.find({ type: 'Text', text: /waits on you/ })).toBe(undefined)
  await ui.unmount()
})

test('a new session starts in the stored mode', async ($, on) => {
  engine(on, { details: true })
  on('session.start', (_: unknown, e: { cwd: string }) => ({ cwd: e.cwd }))
  await title($, 'self', '🚪 Bouncer')
  await title($, 'a', '[Dev] 🍸 MIDI-1 aspire')
  await $.session.start({ cwd: '/w', surface: 'desktop', isInteractive: true } as any)
  const ui = await $.ui.mount({ ...BAND, surface: 'desktop' } as any)
  expect(chip(await ui.find({ key: 'act:a' }))).toBe('🟡 MIDI-1')
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
  const ui = await details(await $.ui.mount({ ...BAND, surface: 'desktop' } as any))
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

// Each column as [label, value, sub-line], in band order.
const cols = async (ui: any) => {
  const texts = (await ui.findAll({ type: 'Text' })).map((t: any) => t.text)
  return (await ui.findAll({ type: 'Button' })).filter((b: any) => /^(act:|idle$)/.test(b.key ?? '')).map((b: any) => {
    const i = texts.indexOf(b.text)
    return [texts[i - 1], b.text, texts[i + 1]]
  })
}

test('Details: one column an active Bartender, idle ones in one column, at most 4 then +N', async ($, on) => {
  engine(on, { details: true })
  on('session.start', (_: unknown, e: { cwd: string }) => ({ cwd: e.cwd }))
  await $.session.start({ cwd: '/w', surface: 'terminal', isInteractive: true } as any)
  await title($, 'self', '🚪 Bouncer')
  await title($, 'a', '[QA] 🍸 MIDI-1 rounds')
  const ui = await $.ui.mount({ ...BAND, surface: 'terminal' } as any)
  expect(await cols(ui)).toEqual([['ticket · QA', '🟡 MIDI-1', '']])
  expect(await ui.find({ type: 'Text', text: /^│$/ })).toBe(undefined)
  expect((await ui.find({ type: 'Text', text: /^Bouncer$/ }))?.text).toBe('Bouncer')
  expect((await ui.find({ type: 'Text', text: /^rounds$/ }))?.text).toBe('rounds')

  await title($, 'b', '[Dev] 🔧 band rounds')
  await title($, 'c', '[Idle] 🍸 rounds')
  await title($, 'd', '[Idle] 🧹 rounds')
  expect(await cols(ui)).toEqual([['ticket · QA', '🟡 MIDI-1', ''], ['skill · Dev', '🟡 band', ''], ['idle', '🟢 2 idle', 'free for work']])
  // Two vertical hairlines of three lines each.
  expect((await ui.findAll({ type: 'Text', text: /^│$/ })).length).toBe(6)
  expect(await ui.find({ type: 'Text', text: /^\+\d/ })).toBe(undefined)

  await title($, 'e', '![Dev] 🍸 MIDI-5 rounds')
  await title($, 'f', '[CR] 🍸 MIDI-6 rounds')
  expect((await cols(ui)).map((c: any) => c[1])).toEqual(['🔴 MIDI-5', '🟡 MIDI-1', '🟡 band', '🟡 MIDI-6'])
  expect((await ui.find({ type: 'Text', text: /^\+\d/ }))?.text).toBe('+1')
  await ui.unmount()
})

test('Details: the ask row shows only while a question waits; a report fills the sub-line; a menu takes its place', async ($, on) => {
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
  const ui = await $.ui.mount({ ...BAND, surface: 'desktop' } as any)
  expect(await ui.find({ type: 'Text', text: /^🔴 / })).toBe(undefined)

  await $.session.receive({ origin: { kind: 'task-notification' }, text: 'STATUS: DONE\nTICKET: MIDI-1' } as any)
  expect(await cols(ui)).toEqual([['ticket · Dev', '🟡 MIDI-1', 'PR 31 open, CI green']])

  await ui.press({ key: 'act:local_a' })
  expect(await ui.find({ type: 'Text', text: /PR 31/ })).toBe(undefined)
  expect((await ui.findAll({ type: 'Button' })).filter((b: any) => b.key?.startsWith('act:local_a:')).map((b: any) => b.text)).toEqual(['Status', 'Stop', 'Reset'])
  await ui.press({ key: 'act:local_a' })
  expect((await ui.find({ type: 'Text', text: /PR 31/ }))?.text).toBe('PR 31 open, CI green')

  questions = 'MIDI-1 | local_a | Merge it? Default: yes\n'
  await $.tool.call({ tool: 'Bash', command: 'scripts/bouncer-questions add "MIDI-1 | local_a | Merge it?"' } as any)
  expect((await ui.find({ type: 'Text', text: /^🔴 / }))?.text).toBe('🔴 MIDI-1: Merge it? Default: yes')
  expect(await ui.find({ key: 'open:local_a' })).not.toBe(undefined)
  await ui.unmount()
})
