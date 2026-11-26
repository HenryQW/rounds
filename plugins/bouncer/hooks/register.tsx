import { atom, read, update } from 'claude-code'
import type { EngineInterface, Register } from 'claude-code'

import { EMPTY, archived, parseBartender, queueLines, questionsBySession, renamed } from './pool'

const pool = atom({ plugin: 'bouncer', key: 'pool' } as const, EMPTY)

// A Linear-shaped key (ABC-123) links to the tracker; a GitHub issue number does not.
const LINEAR_KEY = /^[A-Z][A-Z0-9]*-\d+$/

// The queue and the open questions in the plugin's data folder, the one bouncer-data prints (CLAUDE_PLUGIN_DATA).
const refreshData = async ($: EngineInterface) => {
  const data = (await $.process.hookEnv()).CLAUDE_PLUGIN_DATA
  const file = async (name: string) => String(data ? await $.fs.read(`${data}/${name}`).catch(() => '') : '')
  const lines = queueLines(await file('queue.md'))
  const questions = questionsBySession(await file('questions.md'))
  await update($, pool, p => ({ ...p, queue: lines.length, queueLines: lines, questions }))
}

export const register: Register = (on, options) => {
  const linear = String(options.linear_workspace_url ?? '').replace(/\/+$/, '')

  on('tool.call', async ($, e, next) => {
    const ran = await next(e)
    if (ran.deny !== undefined || ran.isError === true) return ran

    const tool = String(e.tool)
    if (tool === 'Skill' && /(^|:)bouncer$/.test(String((e as { skill?: unknown }).skill ?? ''))) {
      await update($, pool, p => ({ ...p, isOn: true }))
      await refreshData($)
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
    } else if (tool === 'Bash' && /bouncer-(queue|questions)/.test(String((e as { command?: unknown }).command))) {
      await refreshData($)
    }
    return ran
  })

  // A band prompt's turn ended (main's, not a subagent's): the band may send the next one.
  on('turn.complete', async ($, e, next) => {
    if (!e.agentId) await update($, pool, p => (p.pending ? { ...p, pending: false } : p))
    return next(e)
  })

  on('ui.render', { component: 'AbovePrompt' }, async ($, e, next) => {
    const p = await read($, pool)
    if (e.props.hasSurvey || !p.isOn) return next(e)
    // Other mods share this slot (ponytail's band): draw theirs below ours.
    const below = await next(e).catch(() => undefined)

    const { Box, Text, Link, Button, Select } = $.ui.resolve(e)
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
    const lines = p.queueOpen ? p.queueLines ?? [] : []
    // `open claude://…` does not switch the app (tried 2026-11-26), so the window tool shows the Bartender.
    // It takes only sessions the Bouncer started; when it fails, the Bouncer opens it.
    const show = (id: string, target: 'focus' | 'split') =>
      $.tool.call({ tool: 'mcp__ccd_window__open_session_in', session_id: id, target } as any).catch(() => undefined)
    const failed = (ran: Awaited<ReturnType<typeof show>>) => !ran || ran.deny !== undefined || ran.isError === true
    const open = async (id: string, name: string) => {
      const focus = await show(id, 'focus')
      const why = String(focus?.deny ?? focus?.text ?? JSON.stringify(focus?.result ?? ''))
      if (!failed(focus) && !/refus/i.test(why)) return
      // The app refuses focus while the cursor is in a text field or terminal: split view beside the Bouncer.
      if (/text field|terminal|cursor/i.test(why)) $.ui.toast(`The cursor is in a text field, so ${name} opens in split view`)
      if (failed(await show(id, 'split'))) await ask(`${name}: open`)
    }

    const mine = (
      <Box flexDirection="column" width={width}>
        <Box flexDirection="row" alignItems="center" gap={2} flexWrap="wrap">
          <Text bold>Bouncer</Text>
          {p.waiting > 0 ? <Text color="warning">! {p.waiting} waiting on you</Text> : <Text dimColor>nothing waits on you</Text>}
          {bartenders.length === 0 && <Text dimColor>no Bartenders yet</Text>}
          {bartenders.map(b => (
            <Box flexDirection="row" alignItems="center" gap={1}>
              <Text color={b.cta ? 'warning' : undefined} dimColor={b.status === 'Idle'}>
                {b.cta ? '!' : ''}[{b.status}]
              </Text>
              {b.ticket && (linear && LINEAR_KEY.test(b.ticket)
                ? <Link href={`${linear}/issue/${b.ticket}`} label={b.ticket} />
                : <Text>{b.ticket}</Text>)}
              <Text dimColor={b.status === 'Idle'}>{b.repo}</Text>
              <Select
                key={`act:${b.id}`}
                options={[{ value: 'status', label: 'Status' }, { value: 'stop', label: 'Stop' }, { value: 'reset', label: 'Reset' }]}
                onSelect={v => ask(`${b.ticket || b.repo}: ${v}`)}
              />
            </Box>
          ))}
          {p.queue > 0
            ? <Button key="queue" onPress={async () => { await update($, pool, q => ({ ...q, queueOpen: !q.queueOpen })); await refreshData($) }}>
                {`queue ${p.queue}`}
              </Button>
            : <Text dimColor>queue 0</Text>}
        </Box>
        {bartenders.filter(b => b.cta).map(b => (
          <Box flexDirection="row" alignItems="center" gap={1}>
            <Text color="warning">! {b.ticket || b.repo}: {p.questions?.[b.id] ?? 'waits on you'}</Text>
            <Button key={`open:${b.id}`} onPress={() => open(b.id, b.ticket || b.repo)}>Open</Button>
          </Box>
        ))}
        {lines.map((line, i) => {
          const ticket = line.split('|')[0]?.trim() ?? ''
          return (
            <Box flexDirection="row" alignItems="center" gap={1}>
              <Text dimColor>{line}</Text>
              {i === 0 && <Button key="queue:pop" onPress={() => ask('queue: pop')}>Pop</Button>}
              <Button key={`queue:remove:${ticket}`} onPress={() => ask(`queue: remove ${ticket}`)}>Remove</Button>
            </Box>
          )
        })}
      </Box>
    )
    return below ? <Box flexDirection="column">{mine}{below}</Box> : mine
  })
}
