import { expect, test } from 'claude-code/testing'

const BAND = { plugin: 'bouncer', component: 'AbovePrompt', props: { hasSurvey: false, bodyColumns: 120 } } as const

const engine = (on: any) => {
  on('tool.call', () => ({ result: {} }))
  on('process.hookEnv', () => ({ value: { CLAUDE_PLUGIN_DATA: '/data' } }))
  on('fs.read', (_: unknown, e: { path?: string }) => {
    if (e.path === '/data/queue.md') return { value: 'A-1 | r | Code | x\nA-2 | r | Spike | y\n' }
    throw new Error('missing')
  })
}

// What the band asks the Bouncer, and the notifications it raises.
const record = (on: any) => {
  const prompts: string[] = []
  const notes: string[] = []
  on('prompt.submit', (_: unknown, e: { text: string }) => { prompts.push(e.text); return { text: e.text } })
  on('ui.notify', (_: unknown, e: { text: string }) => { notes.push(e.text); return { value: { isSent: true, channel: 'test' } } })
  return { prompts, notes }
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
  await title($, 'a', '[Dev] MIDI-1 - Bartender - aspire')
  await title($, 'b', '![CR] MIDI-2 - Bartender - web')
  await title($, 'c', '[Idle] Bartender - aspire')
  await title($, 'self', '!1 Bouncer')
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
  await title($, 'a', '[Dev] MIDI-1 - Bartender - aspire')
  await title($, 'b', '[Dev] 12 - Bartender - web')
  const ui = await $.ui.mount({ ...BAND, surface: 'desktop' } as any)
  const links = await ui.findAll({ type: 'Link' })
  expect(links.map(l => l.props.href)).toEqual(['https://linear.app/acme/issue/MIDI-1'])
  expect((await ui.find({ type: 'Text', text: /^12$/ }))?.text).toBe('12')
  await ui.unmount()
})

test('the Link uses the default workspace when the option is unset', async ($, on) => {
  engine(on)
  await title($, 'a', '[Dev] MIDI-1 - Bartender - aspire')
  const ui = await $.ui.mount({ ...BAND, surface: 'desktop' } as any)
  expect((await ui.find({ type: 'Link' }))?.props.href).toBe('https://linear.app/sleekflowplatform/issue/MIDI-1')
  await ui.unmount()
})

test('the Bartender menu asks the Bouncer, never the Bartender', async ($, on) => {
  engine(on)
  const { prompts } = record(on)
  await title($, 'a', '[Dev] MIDI-1616 - Bartender - aspire')
  await title($, 'c', '[Idle] Bartender - web')
  const ui = await $.ui.mount({ ...BAND, surface: 'desktop' } as any)
  for (const value of ['status', 'stop', 'reset']) await ui.select({ key: 'act:a', value })
  await ui.select({ key: 'act:c', value: 'stop' })
  expect(prompts).toEqual(['MIDI-1616: status', 'MIDI-1616: stop', 'MIDI-1616: reset', 'web: stop'])
  await ui.unmount()
})

test('a notification only when the waiting count goes up', async ($, on) => {
  engine(on)
  const { notes } = record(on)
  await title($, 'self', '!1 Bouncer')
  await title($, 'self', '!3 Bouncer')
  await title($, 'self', '!2 Bouncer')
  await title($, 'self', 'Bouncer')
  await title($, 'self', '!2 Bouncer')
  expect(notes).toEqual(['1 waiting on you', '3 waiting on you', '2 waiting on you'])
})

test('the queue opens to its lines, with Pop and Remove sent to the Bouncer', async ($, on) => {
  engine(on)
  const { prompts } = record(on)
  await title($, 'self', 'Bouncer')
  await $.tool.call({ tool: 'Bash', command: 'scripts/bouncer-queue list' } as any)
  const ui = await $.ui.mount({ ...BAND, surface: 'desktop' } as any)
  expect(await ui.find({ type: 'Text', text: /A-1 \|/ })).toBe(undefined)

  await ui.press({ key: 'queue' })
  expect((await ui.find({ type: 'Text', text: /A-2 \|/ }))?.text).toBe('A-2 | r | Spike | y')
  expect(await ui.findAll({ key: 'queue:pop' })).toHaveLength(1)
  await ui.press({ key: 'queue:pop' })
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
  await title($, 'self', 'Bouncer')
  await start('[Dev] MIDI-1616 - Bartender - aspire')
  await start('Fix the band')
  await start('[Todo] MIDI-7 - Bartender - web', 'offer')

  const ui = await $.ui.mount({ ...BAND, surface: 'desktop' } as any)
  expect((await ui.find({ type: 'Link' }))?.props.label).toBe('MIDI-1616')
  expect(await ui.findAll({ type: 'Link' })).toHaveLength(1)
  expect(await ui.find({ type: 'Text', text: /Fix the band/ })).toBe(undefined)
  await ui.unmount()
})

test('a start_session call with a non-Bartender title leaves the pool unchanged', async ($, on) => {
  on('tool.call', { tool: 'mcp__ccd_session__start_session' }, () => ({
    result: 'Started session "Fix the band" (session_id: local_abc, name: x)',
  }))
  engine(on)
  await title($, 'self', 'Bouncer')
  await $.tool.call({ tool: 'mcp__ccd_session__start_session', title: 'Fix the band', initiation: 'user_asked' } as any)

  const ui = await $.ui.mount({ ...BAND, surface: 'desktop' } as any)
  expect((await ui.find({ type: 'Text', text: /Bartenders/ }))?.text).toBe('no Bartenders yet')
  await ui.unmount()
})
