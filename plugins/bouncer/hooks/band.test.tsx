import { expect, test } from 'claude-code/testing'

const BAND = { plugin: 'bouncer', component: 'AbovePrompt', props: { hasSurvey: false, bodyColumns: 120 } } as const

const engine = (on: any) => {
  on('tool.call', () => ({ result: {} }))
  on('turn.complete', (_: unknown, e: { answer: string }) => ({ text: e.answer }))
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
    expect((await ui.find({ type: 'Text', text: /waiting/ }))?.text).toBe('! 1 waiting on you')
    expect((await ui.find({ type: 'Text', text: /Dev/ }))?.text).toBe('[Dev]')
    expect((await ui.find({ type: 'Text', text: /CR/ }))?.text).toBe('![CR]')
    expect(await ui.find({ type: 'Text', text: /Idle/ })).toBe(undefined)
    expect((await ui.find({ key: 'queue' }))?.text).toBe('queue 2')
    await ui.unmount()
  }
})

test('a ticket key links to the Linear workspace of the option', { options: { linear_workspace_url: 'https://linear.app/acme/' } }, async ($, on) => {
  engine(on)
  await title($, 'a', '[Dev] 🍸 MIDI-1 aspire')
  await title($, 'b', '[Dev] 🍸 12 web')
  const ui = await $.ui.mount({ ...BAND, surface: 'desktop' } as any)
  const links = await ui.findAll({ type: 'Link' })
  expect(links.map(l => l.props.href)).toEqual(['https://linear.app/acme/issue/MIDI-1'])
  expect((await ui.find({ type: 'Text', text: /^12$/ }))?.text).toBe('12')
  await ui.unmount()
})

test('a ticket key is plain text while the option is unset', async ($, on) => {
  engine(on)
  await title($, 'a', '[Dev] 🍸 MIDI-1 aspire')
  const ui = await $.ui.mount({ ...BAND, surface: 'desktop' } as any)
  expect(await ui.find({ type: 'Link' })).toBe(undefined)
  expect((await ui.find({ type: 'Text', text: /MIDI-1/ }))?.text).toBe('MIDI-1')
  await ui.unmount()
})

test('the Bartender menu asks the Bouncer, never the Bartender', async ($, on) => {
  engine(on)
  const { prompts } = record(on)
  await title($, 'a', '[Dev] 🍸 MIDI-1616 aspire')
  await title($, 'c', '[Idle] 🍸 web')
  const ui = await $.ui.mount({ ...BAND, surface: 'desktop' } as any)
  for (const value of ['status', 'stop', 'reset']) { await ui.select({ key: 'act:a', value }); await endTurn($) }
  await ui.select({ key: 'act:c', value: 'stop' })
  expect(prompts).toEqual(['MIDI-1616: status', 'MIDI-1616: stop', 'MIDI-1616: reset', 'web: stop'])
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
  expect(await ui.find({ type: 'Text', text: /A-1 \|/ })).toBe(undefined)

  await ui.press({ key: 'queue' })
  expect((await ui.find({ type: 'Text', text: /A-2 \|/ }))?.text).toBe('A-2 | r | Spike | y')
  expect(await ui.findAll({ key: 'queue:pop' })).toHaveLength(1)
  await ui.press({ key: 'queue:pop' })
  await endTurn($)
  await ui.press({ key: 'queue:remove:A-2' })
  expect(prompts).toEqual(['queue: pop', 'queue: remove A-2'])

  await ui.press({ key: 'queue' })
  expect(await ui.find({ type: 'Text', text: /A-1 \|/ })).toBe(undefined)
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

  const ui = await $.ui.mount({ ...BAND, surface: 'desktop' } as any)
  expect((await ui.find({ type: 'Text', text: /MIDI-1616/ }))?.text).toBe('MIDI-1616')
  expect(await ui.find({ type: 'Text', text: /MIDI-7/ })).toBe(undefined)
  expect(await ui.find({ type: 'Text', text: /Fix the band/ })).toBe(undefined)
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

test('a Bartender that waits shows its question and opens its conversation', async ($, on) => {
  const opened: unknown[] = []
  on('tool.call', { tool: 'mcp__ccd_window__open_session_in' }, (_: unknown, e: any) => {
    opened.push([e.session_id, e.target])
    if (e.session_id === 'local_c') return { deny: 'not a session this session started' }
    if (e.session_id === 'local_d' && e.target === 'focus') return { result: 'Refused: the cursor is in a text field or terminal.' }
    return { result: 'Shown.' }
  })
  engine(on)
  const { prompts, toasts } = record(on)
  await title($, 'local_a', '![Wont] 🍸 MIDI-1616 aspire')
  await title($, 'local_b', '[Dev] 🍸 MIDI-2 web')
  await title($, 'local_c', '![Dev] 🍸 MIDI-3 web')
  await title($, 'local_d', '![Dev] 🍸 MIDI-4 web')
  await $.tool.call({ tool: 'Bash', command: 'scripts/bouncer-questions add "MIDI-1616 | local_a | x"' } as any)

  const ui = await $.ui.mount({ ...BAND, surface: 'desktop' } as any)
  expect((await ui.find({ type: 'Text', text: /MIDI-1616:/ }))?.text).toBe('! MIDI-1616: Post the draft yourself? Default: yes')
  expect((await ui.find({ type: 'Text', text: /MIDI-3:/ }))?.text).toBe('! MIDI-3: waits on you')
  expect(await ui.find({ type: 'Text', text: /MIDI-2:/ })).toBe(undefined)
  expect((await ui.findAll({ type: 'Button' })).map(b => b.key).filter(k => k?.startsWith('open:'))).toEqual(['open:local_a', 'open:local_c', 'open:local_d'])

  // Open goes to the Bartender; a refused focus falls back to split view, and a refused split to the Bouncer.
  await ui.press({ key: 'open:local_a' })
  await ui.press({ key: 'open:local_d' })
  await ui.press({ key: 'open:local_c' })
  expect(opened).toEqual([['local_a', 'focus'], ['local_d', 'focus'], ['local_d', 'split'], ['local_c', 'focus'], ['local_c', 'split']])
  expect(toasts).toEqual(['The cursor is in a text field, so MIDI-4 opens in split view'])
  expect(prompts).toEqual(['MIDI-3: open'])
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
  await ui.select({ key: 'act:local_a', value: 'stop' })
  await ui.press({ key: 'queue' })
  await ui.press({ key: 'queue:pop' })
  await ui.press({ key: 'open:local_a' })
  await ui.press({ key: 'open:local_b' })
  expect(opened).toEqual(['local_a', 'local_b', 'local_b'])
  expect(prompts).toEqual([])
  expect(toasts).toEqual(Array(3).fill('Answer the waiting question first'))

  await title($, 'self', '🚪 Bouncer')
  await ui.select({ key: 'act:local_a', value: 'stop' })
  expect(prompts).toEqual(['MIDI-1: stop'])
  await ui.unmount()
})

test('the band sends one prompt at a time, and none while the Bouncer works', async ($, on) => {
  engine(on)
  const { prompts, toasts } = record(on)
  await title($, 'self', '🚪 Bouncer')
  await title($, 'local_a', '[Dev] 🍸 MIDI-1 aspire')

  const busy = await $.ui.mount({ ...BAND, surface: 'desktop', props: { ...BAND.props, isWorking: true } } as any)
  await busy.select({ key: 'act:local_a', value: 'status' })
  await busy.unmount()
  expect(prompts).toEqual([])

  const ui = await $.ui.mount({ ...BAND, surface: 'desktop', props: { ...BAND.props, isWorking: false } } as any)
  await ui.select({ key: 'act:local_a', value: 'status' })
  await ui.select({ key: 'act:local_a', value: 'stop' })
  expect(prompts).toEqual(['MIDI-1: status'])
  expect(toasts).toEqual(Array(2).fill('Wait for the Bouncer to finish its turn'))

  await $.turn.complete({ answer: '', durationMs: 1, isAborted: false, reason: 'answer', agentId: 'sub' } as any)
  await ui.select({ key: 'act:local_a', value: 'stop' })
  expect(prompts).toEqual(['MIDI-1: status'])
  await endTurn($)
  await ui.select({ key: 'act:local_a', value: 'stop' })
  expect(prompts).toEqual(['MIDI-1: status', 'MIDI-1: stop'])
  await ui.unmount()
})
