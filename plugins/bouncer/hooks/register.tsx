import { atom, read, update } from 'claude-code'
import type { EngineInterface, Register } from 'claude-code'

import { EMPTY, archived, parseBartender, queueLength, renamed } from './pool'

const pool = atom({ plugin: 'bouncer', key: 'pool' } as const, EMPTY)

// The plugin's data folder, the one bouncer-data prints (CLAUDE_PLUGIN_DATA).
const refreshQueue = async ($: EngineInterface) => {
  const data = (await $.process.hookEnv()).CLAUDE_PLUGIN_DATA
  const text = data ? await $.fs.read(`${data}/queue.md`).catch(() => '') : ''
  await update($, pool, p => ({ ...p, queue: queueLength(String(text)) }))
}

export const register: Register = on => {
  on('tool.call', async ($, e, next) => {
    const ran = await next(e)
    if (ran.deny !== undefined || ran.isError === true) return ran

    const tool = String(e.tool)
    if (tool === 'Skill' && /(^|:)bouncer$/.test(String((e as { skill?: unknown }).skill ?? ''))) {
      await update($, pool, p => ({ ...p, isOn: true }))
      await refreshQueue($)
    } else if (tool.endsWith('__set_session_title')) {
      const { session_id, title } = e as { session_id?: unknown; title?: unknown }
      await update($, pool, p => renamed(p, String(session_id), String(title)))
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

    const { Box, Text } = $.ui.resolve(e)
    const width = e.surface === 'terminal' ? e.props.bodyColumns : undefined
    const bartenders = Object.values(p.bartenders).flatMap(t => parseBartender(t) ?? [])

    const mine = (
      <Box flexDirection="row" alignItems="center" gap={2} width={width} flexWrap="wrap">
        <Text bold>Bouncer</Text>
        {p.waiting > 0 ? <Text color="warning">! {p.waiting} waiting on you</Text> : <Text dimColor>nothing waits on you</Text>}
        {bartenders.length === 0 && <Text dimColor>no Bartenders yet</Text>}
        {bartenders.map(b => (
          <Text color={b.cta ? 'warning' : undefined} dimColor={b.status === 'Idle'}>
            {b.cta ? '!' : ''}[{b.status}]{b.ticket ? ` ${b.ticket}` : ''} {b.repo}
          </Text>
        ))}
        <Text dimColor>queue {p.queue}</Text>
      </Box>
    )
    return below ? <Box flexDirection="column">{mine}{below}</Box> : mine
  })
}
