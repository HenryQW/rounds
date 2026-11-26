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
