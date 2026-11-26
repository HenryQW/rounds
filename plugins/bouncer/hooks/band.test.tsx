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

test('no band outside a Bouncer session', async ($, on) => {
  engine(on)
  on('ui.render', ($, e) => { const { Text } = $.ui.resolve(e); return <Text>engine</Text> })
  await $.tool.call({ tool: 'mcp__ccd_session_mgmt__set_session_title', session_id: 's1', title: '[Dev][MIDI-9] normal work' } as any)
  const ui = await $.ui.mount({ ...BAND, surface: 'desktop' } as any)
  expect(await ui.find({ type: 'Text', text: /Bouncer/ })).toBe(undefined)
  await ui.unmount()
})

test('the band shows Bartenders, the question count and the queue', async ($, on) => {
  engine(on)
  const set = (session_id: string, title: string) =>
    $.tool.call({ tool: 'mcp__ccd_session_mgmt__set_session_title', session_id, title } as any)
  await set('a', '[Dev] MIDI-1 - Bartender - aspire')
  await set('b', '![CR] MIDI-2 - Bartender - web')
  await set('c', '[Idle] Bartender - aspire')
  await set('self', '!1 Bouncer')
  await $.tool.call({ tool: 'Bash', command: 'scripts/bouncer-queue list' } as any)
  await $.tool.call({ tool: 'mcp__ccd_session_mgmt__archive_session', session_id: 'c' } as any)

  for (const surface of ['terminal', 'desktop'] as const) {
    const ui = await $.ui.mount({ ...BAND, surface } as any)
    expect((await ui.find({ type: 'Text', text: /waiting/ }))?.text).toBe('! 1 waiting on you')
    expect((await ui.find({ type: 'Text', text: /MIDI-1/ }))?.text).toBe('[Dev] MIDI-1 aspire')
    expect((await ui.find({ type: 'Text', text: /MIDI-2/ }))?.text).toBe('![CR] MIDI-2 web')
    expect(await ui.find({ type: 'Text', text: /Idle/ })).toBe(undefined)
    expect((await ui.find({ type: 'Text', text: /queue/ }))?.text).toBe('queue 2')
    await ui.unmount()
  }
})

test('a Bartender shows in the band when the Bouncer starts it', async ($, on) => {
  on('tool.call', { tool: 'mcp__ccd_session__start_session' }, (_: unknown, e: { title: string }) => ({
    result: `Started session "${e.title}" (session_id: local_${e.title.length}, name: x)`,
  }))
  engine(on)
  const start = (title: string, initiation = 'user_asked') =>
    $.tool.call({ tool: 'mcp__ccd_session__start_session', title, initiation, prompt: 'p' } as any)
  await $.tool.call({ tool: 'mcp__ccd_session_mgmt__set_session_title', session_id: 'self', title: 'Bouncer' } as any)
  await start('[Dev] MIDI-1616 - Bartender - aspire')
  await start('Fix the band')
  await start('[Todo] MIDI-7 - Bartender - web', 'offer')

  const ui = await $.ui.mount({ ...BAND, surface: 'desktop' } as any)
  expect((await ui.find({ type: 'Text', text: /MIDI-1616/ }))?.text).toBe('[Dev] MIDI-1616 aspire')
  expect(await ui.find({ type: 'Text', text: /Fix the band|MIDI-7/ })).toBe(undefined)
  await ui.unmount()
})

test('a start_session call with a non-Bartender title leaves the pool unchanged', async ($, on) => {
  on('tool.call', { tool: 'mcp__ccd_session__start_session' }, () => ({
    result: 'Started session "Fix the band" (session_id: local_abc, name: x)',
  }))
  engine(on)
  await $.tool.call({ tool: 'mcp__ccd_session_mgmt__set_session_title', session_id: 'self', title: 'Bouncer' } as any)
  await $.tool.call({ tool: 'mcp__ccd_session__start_session', title: 'Fix the band', initiation: 'user_asked' } as any)

  const ui = await $.ui.mount({ ...BAND, surface: 'desktop' } as any)
  expect((await ui.find({ type: 'Text', text: /Bartenders/ }))?.text).toBe('no Bartenders yet')
  await ui.unmount()
})
