import { expect, test } from 'claude-code/testing'

const BAND = { plugin: 'bouncer', component: 'AbovePrompt', props: { hasSurvey: false, bodyColumns: 120 } } as const

// This session's id, and writes of the Bouncer owner file.
const base = (on: any) => {
  on('session.id', () => ({ value: 'me' }))
  on('fs.write', () => ({ value: undefined }))
}

const engine = (on: any) => {
  on('tool.call', () => ({ result: {} }))
  on('turn.complete', (_: unknown, e: { answer: string }) => ({ text: e.answer }))
  base(on)
  on('process.hookEnv', () => ({ value: { CLAUDE_PLUGIN_DATA: '/data' } }))
  on('fs.read', (_: unknown, e: { path?: string }) => {
    if (e.path === '/data/queue.md') return { value: 'A-1 | r | Code | x\nA-2 | r | Spike | y\n' }
    if (e.path === '/data/questions.md') return { value: 'MIDI-1616 | local_a | Post the draft yourself? Default: yes\n' }
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

// The text a chip draws: its menu's first option.
const chip = (el: any) => el?.props.options[0].label

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
    const ui = await $.ui.mount({ ...BAND, surface } as any)
    expect((await ui.find({ type: 'Text', text: /waiting/ }))?.text).toBe('!1 waiting')
    expect(chip(await ui.find({ key: 'act:a' }))).toBe('🍸 Dev MIDI-1')
    expect(chip(await ui.find({ key: 'act:b' }))).toBe('🍸 CR MIDI-2')
    expect((await ui.findAll({ type: 'Text', text: /^!$/ }))).toHaveLength(1)
    expect((await ui.findAll({ type: 'Select' })).map(s => s.key)).toEqual(['act:a', 'act:b'])
    expect((await ui.find({ key: 'queue' }))?.text).toBe('queue 2')
    await ui.unmount()
  }
})

test('a ticket key opens in the Linear workspace of the option from its chip menu', { options: { linear_workspace_url: 'https://linear.app/acme/' } }, async ($, on) => {
  engine(on)
  const runs: string[][] = []
  on('process.run', (_: unknown, e: any) => { runs.push(e.argv); return { value: { exitCode: 0, stdout: '', stderr: '', isStdoutTruncated: false, isStderrTruncated: false } } })
  await title($, 'a', '[Dev] 🍸 MIDI-1 aspire')
  await title($, 'b', '[Dev] 🍸 12 web')
  const ui = await $.ui.mount({ ...BAND, surface: 'desktop' } as any)
  expect((await ui.find({ key: 'act:b' }))?.props.options.map((o: any) => o.value)).not.toContain('linear')
  await ui.select({ key: 'act:a', value: 'linear' })
  expect(runs).toEqual([['/usr/bin/open', 'https://linear.app/acme/issue/MIDI-1']])
  await ui.unmount()
})

test('the chip menu has no Linear item while the option is unset', async ($, on) => {
  engine(on)
  await title($, 'a', '[Dev] 🍸 MIDI-1 aspire')
  const ui = await $.ui.mount({ ...BAND, surface: 'desktop' } as any)
  const menu = (await ui.find({ key: 'act:a' }))?.props.options.map((o: any) => o.label)
  expect(menu).toEqual(['🍸 Dev MIDI-1', 'Status', 'Stop', 'Reset'])
  await ui.unmount()
})

test('the Bartender menu asks the Bouncer, never the Bartender', async ($, on) => {
  engine(on)
  const { prompts } = record(on)
  await title($, 'a', '[Dev] 🍸 MIDI-1616 aspire')
  await title($, 'c', '[Idle] 🍸 web')
  const ui = await $.ui.mount({ ...BAND, surface: 'desktop' } as any)
  for (const value of ['status', 'stop', 'reset']) { await ui.select({ key: 'act:a', value: `${value} a` }); await endTurn($) }
  await ui.select({ key: 'act:a', value: 'chip' })
  await ui.select({ key: 'idle:🍸:web', value: 'stop c' })
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
  const ui = await $.ui.mount({ ...BAND, surface: 'desktop' } as any)
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

  const ui = await $.ui.mount({ ...BAND, surface: 'desktop' } as any)
  expect((await ui.findAll({ type: 'Select' })).map(chip)).toEqual(['🍸 Dev MIDI-1616', '🔧 Dev bouncer-types', '🧹 1 idle · aspire'])
  await ui.unmount()
})

test('a start_session call with a non-Bartender title leaves the pool unchanged', async ($, on) => {
  on('tool.call', { tool: 'mcp__ccd_session__start_session' }, () => ({
    result: 'Started session "Fix the band" (session_id: local_abc, name: x)',
  }))
  engine(on)
  await title($, 'self', '🚪 Bouncer')
  await $.tool.call({ tool: 'mcp__ccd_session__start_session', title: 'Fix the band', initiation: 'user_asked' } as any)

  const ui = await $.ui.mount({ ...BAND, surface: 'desktop' } as any)
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

  const ui = await $.ui.mount({ ...BAND, surface: 'desktop' } as any)
  expect((await ui.find({ type: 'Text', text: /MIDI-1616:/ }))?.text).toBe('! MIDI-1616: Post the draft yourself? Default: yes')
  // Questions block in order: MIDI-3 waits (its `!` shows) but its line stays hidden until the head is answered.
  expect(await ui.find({ type: 'Text', text: /MIDI-3:/ })).toBe(undefined)
  expect(chip(await ui.find({ key: 'act:local_c' }))).toBe('🍸 Dev MIDI-3')
  expect((await ui.findAll({ type: 'Button' })).map(b => b.key).filter(k => k?.startsWith('open:'))).toEqual(['open:local_a'])

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

  const ui = await $.ui.mount({ ...BAND, surface: 'desktop' } as any)
  await ui.select({ key: 'act:local_a', value: 'stop local_a' })
  await ui.press({ key: 'queue' })
  await ui.press({ key: 'queue:pop' })
  await ui.press({ key: 'open:local_a' })
  expect(opened).toEqual(['local_a'])
  expect(prompts).toEqual([])
  expect(toasts).toEqual(Array(2).fill('Answer the waiting question first'))

  await title($, 'self', '🚪 Bouncer')
  await ui.select({ key: 'act:local_a', value: 'stop local_a' })
  expect(prompts).toEqual(['MIDI-1: stop'])
  await ui.unmount()
})

test('the band sends one prompt at a time, and none while the Bouncer works', async ($, on) => {
  engine(on)
  const { prompts, toasts } = record(on)
  await title($, 'self', '🚪 Bouncer')
  await title($, 'local_a', '[Dev] 🍸 MIDI-1 aspire')

  const busy = await $.ui.mount({ ...BAND, surface: 'desktop', props: { ...BAND.props, isWorking: true } } as any)
  await busy.select({ key: 'act:local_a', value: 'status local_a' })
  await busy.unmount()
  expect(prompts).toEqual([])

  const ui = await $.ui.mount({ ...BAND, surface: 'desktop', props: { ...BAND.props, isWorking: false } } as any)
  await ui.select({ key: 'act:local_a', value: 'status local_a' })
  await ui.select({ key: 'act:local_a', value: 'stop local_a' })
  expect(prompts).toEqual(['MIDI-1: status'])
  expect(toasts).toEqual(Array(2).fill('Wait for the Bouncer to finish its turn'))

  await $.turn.complete({ answer: '', durationMs: 1, isAborted: false, reason: 'answer', agentId: 'sub' } as any)
  await ui.select({ key: 'act:local_a', value: 'stop local_a' })
  expect(prompts).toEqual(['MIDI-1: status'])
  await endTurn($)
  await ui.select({ key: 'act:local_a', value: 'stop local_a' })
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
    if (e.path === '/data/questions.md') return { value: questions }
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
  expect(renames).toEqual(['local_a=![CR] 🍸 MIDI-1 aspire', 'self=!1 🚪 Bouncer'])

  questions = ''
  renames.length = 0
  await $.tool.call({ tool: 'Bash', command: 'scripts/bouncer-questions done MIDI-1' } as any)
  expect(renames).toEqual(['local_a=[CR] 🍸 MIDI-1 aspire', 'self=🚪 Bouncer'])
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
  const ui = await $.ui.mount({ ...BAND, surface: 'desktop' } as any)
  expect((await ui.find({ key: 'ledger' }))?.text).toBe('ledger 2')
  expect(await ui.find({ type: 'Text', text: /K-1/ })).toBe(undefined)
  await ui.press({ key: 'ledger' })
  expect((await ui.findAll({ type: 'Text', text: /^K-/ })).map(t => t.text)).toEqual(['K-1 · pr · merge it', 'K-2 · verify · check prod'])
  await ui.unmount()
})

test('idle Bartenders of one type and repo share one chip, whose menu names each session', async ($, on) => {
  engine(on)
  const { prompts } = record(on)
  await title($, 'local_aaaaaaaa1', '[Idle] 🍸 aspire')
  await title($, 'local_bbbbbbbb2', '[Idle] 🍸 aspire')
  await title($, 'local_c', '[Idle] 🔧 aspire')
  const ui = await $.ui.mount({ ...BAND, surface: 'desktop' } as any)
  expect((await ui.findAll({ type: 'Select' })).map(chip)).toEqual(['🍸 2 idle · aspire', '🔧 1 idle · aspire'])
  const menu = (await ui.find({ key: 'idle:🍸:aspire' }))?.props.options.map((o: any) => o.label)
  expect(menu).toContain('Reset aaaaaaaa')
  expect(menu).toContain('Reset bbbbbbbb')
  await ui.select({ key: 'idle:🍸:aspire', value: 'reset local_bbbbbbbb2' })
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
  const ui = await $.ui.mount({ ...BAND, surface: 'desktop' } as any)
  expect(await ui.find({ type: 'Text', text: /wait/ })).toBe(undefined)
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
    if (e.path === '/data/queue.md') return { value: queue }
    throw new Error('missing')
  })
  await title($, 'self', '🚪 Bouncer')
  await $.tool.call({ tool: 'Bash', command: 'scripts/bouncer-queue list' } as any)
  const ui = await $.ui.mount({ ...BAND, surface: 'desktop' } as any)
  expect((await ui.find({ key: 'queue' }))?.text).toBe('queue 1')
  queue = ''
  await endTurn($)
  expect(await ui.find({ key: 'queue' })).toBe(undefined)
  queue = 'A-1 | r | Code | x\nA-2 | r | Code | y\n'
  await $.session.start({ cwd: '/w', surface: 'desktop', isInteractive: true } as any)
  expect((await ui.find({ key: 'queue' }))?.text).toBe('queue 2')
  await ui.unmount()
})

test('one Bouncer: a second session shows Take Over, and only that takes the Bouncer', async ($, on) => {
  let owner = 'other'
  const writes: string[] = []
  on('tool.call', () => ({ result: {} }))
  on('session.end', (_: unknown, e: any) => ({ sessionId: e.sessionId }))
  on('session.id', () => ({ value: 'me' }))
  on('fs.write', (_: unknown, e: any) => { writes.push(e.text ?? e.content ?? e.data); owner = String(writes.at(-1)); return { value: undefined } })
  on('process.hookEnv', () => ({ value: { CLAUDE_PLUGIN_DATA: '/data' } }))
  on('fs.read', (_: unknown, e: { path?: string }) => {
    if (e.path === '/data/bouncer') return { value: owner }
    throw new Error('missing')
  })
  await $.tool.call({ tool: 'Skill', skill: 'bouncer:bouncer' } as any)
  await title($, 'a', '[Dev] 🍸 MIDI-1 aspire')
  const ui = await $.ui.mount({ ...BAND, surface: 'desktop' } as any)
  expect((await ui.find({ type: 'Text', text: /another session/ }))?.text).toBe('another session is the Bouncer')
  expect(await ui.find({ type: 'Select' })).toBe(undefined)
  expect(writes).toEqual([])

  await ui.press({ key: 'takeover' })
  expect(writes).toEqual(['me'])
  expect(await ui.find({ type: 'Text', text: /another session/ })).toBe(undefined)
  expect(chip(await ui.find({ key: 'act:a' }))).toBe('🍸 Dev MIDI-1')
  await ui.unmount()

  // Its session ends: the Bouncer is free for the next one.
  await $.session.end({ reason: 'other', sessionId: 'me' } as any)
  expect(writes).toEqual(['me', ''])
})
