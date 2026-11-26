import { atom, read, update } from 'claude-code'
import type { EngineInterface, Register } from 'claude-code'

import { EMPTY, archived, parseBartender, queueLines, renamed } from './pool'

const pool = atom({ plugin: 'bouncer', key: 'pool' } as const, EMPTY)

// A Linear-shaped key (ABC-123) links to the tracker; a GitHub issue number does not.
const LINEAR_KEY = /^[A-Z][A-Z0-9]*-\d+$/

// The plugin's data folder, the one bouncer-data prints (CLAUDE_PLUGIN_DATA).
const refreshQueue = async ($: EngineInterface) => {
  const data = (await $.process.hookEnv()).CLAUDE_PLUGIN_DATA
  const text = data ? await $.fs.read(`${data}/queue.md`).catch(() => '') : ''
  const lines = queueLines(String(text))
  await update($, pool, p => ({ ...p, queue: lines.length, queueLines: lines }))
}

export const register: Register = (on, options) => {
  const linear = String(options.linear_workspace_url ?? '').replace(/\/+$/, '')

  on('tool.call', async ($, e, next) => {
    const ran = await next(e)
    if (ran.deny !== undefined || ran.isError === true) return ran

    const tool = String(e.tool)
    if (tool === 'Skill' && /(^|:)bouncer$/.test(String((e as { skill?: unknown }).skill ?? ''))) {
      await update($, pool, p => ({ ...p, isOn: true }))
      await refreshQueue($)
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
    } else if (tool === 'Bash' && String((e as { command?: unknown }).command).includes('bouncer-queue')) {
      await refreshQueue($)
    }
    return ran
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
    // Only the Bouncer talks to Bartenders: the band asks it with a plain prompt.
    const ask = (text: string) => void $.prompt.submit({ text })
    const lines = p.queueOpen ? p.queueLines ?? [] : []

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
            ? <Button key="queue" onPress={async () => { await update($, pool, q => ({ ...q, queueOpen: !q.queueOpen })); await refreshQueue($) }}>
                {`queue ${p.queue}`}
              </Button>
            : <Text dimColor>queue 0</Text>}
        </Box>
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
