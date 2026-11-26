import { atom, read, update } from 'claude-code'
import type { EngineInterface, Register } from 'claude-code'

import { EMPTY, archived, parseBartender, queueLines, questionsBySession, renamed, synced } from './pool'
import type { Report } from './pool'

const pool = atom({ plugin: 'bouncer', key: 'pool' } as const, EMPTY)

// A Linear-shaped key (ABC-123) links to the tracker; a GitHub issue number does not.
const LINEAR_KEY = /^[A-Z][A-Z0-9]*-\d+$/

// The queue, the open questions and the ledger in the plugin's data folder, the one bouncer-data prints (CLAUDE_PLUGIN_DATA).
const dataFile = async ($: EngineInterface, name: string) => {
  const data = (await $.process.hookEnv()).CLAUDE_PLUGIN_DATA
  return String(data ? await $.fs.read(`${data}/${name}`).catch(() => '') : '')
}
// Open ledger items live in the ticket records; bouncer-ledger list prints one line each.
const ledgerCount = async ($: EngineInterface, records: string) => {
  const env = await $.process.hookEnv()
  if (!env.CLAUDE_PLUGIN_ROOT) return undefined
  const ran = await $.process.run([`${env.CLAUDE_PLUGIN_ROOT}/skills/bouncer/scripts/bouncer-ledger`, 'list'],
    { env: records ? { ...env, BOUNCER_RECORDS: records } : env }).catch(() => undefined)
  return ran?.exitCode === 0 ? queueLines(ran.stdout).length : undefined
}
const refreshData = async ($: EngineInterface, records = '') => {
  const lines = queueLines(await dataFile($, 'queue.md'))
  const questions = questionsBySession(await dataFile($, 'questions.md'))
  const ledger = await ledgerCount($, records)
  await update($, pool, p => ({ ...p, queue: lines.length, queueLines: lines, questions, ledger: ledger ?? p.ledger }))
}

// Make the titles match the open questions and, given a report, its status code; set_session_title is the Bouncer's own call.
const syncTitles = async ($: EngineInterface, report?: Report) => {
  for (const [session_id, title] of synced(await read($, pool), await dataFile($, 'questions.md'), report)) {
    const ran = await $.tool.call({ tool: 'mcp__ccd_session_mgmt__set_session_title', session_id, title } as any).catch(() => undefined)
    if (ran && ran.deny === undefined && ran.isError !== true) await update($, pool, p => renamed(p, session_id, title))
  }
}

// A Bartender's turn-end note reaches the Bouncer as a delivery or a prompt: parse it with bouncer-report, then set titles.
const onNote = async ($: EngineInterface, text: string) => {
  if (!(await read($, pool)).isOn || !/^\s*STATUS:/m.test(text) || !/^\s*TICKET:/m.test(text)) return
  const env = await $.process.hookEnv()
  if (!env.CLAUDE_PLUGIN_ROOT) return
  const ran = await $.process.run([`${env.CLAUDE_PLUGIN_ROOT}/skills/bouncer/scripts/bouncer-report`], { stdin: text, env })
    .catch(() => undefined)
  if (!ran || ran.exitCode !== 0) return
  try { await syncTitles($, JSON.parse(ran.stdout) as Report) } catch { /* not a report */ }
}

export const register: Register = (on, options) => {
  const linear = String(options.linear_workspace_url ?? '').replace(/\/+$/, '')
  const records = String(options.records_dir ?? '').trim()

  on('tool.call', async ($, e, next) => {
    const ran = await next(e)
    if (ran.deny !== undefined || ran.isError === true) return ran

    const tool = String(e.tool)
    if (tool === 'Skill' && /(^|:)bouncer$/.test(String((e as { skill?: unknown }).skill ?? ''))) {
      await update($, pool, p => ({ ...p, isOn: true }))
      await refreshData($, records)
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
    } else if (tool === 'Bash' && /bouncer-(queue|questions|ledger)/.test(String((e as { command?: unknown }).command))) {
      await refreshData($, records)
      if (/bouncer-questions/.test(String((e as { command?: unknown }).command))) await syncTitles($)
    }
    return ran
  })

  on('session.receive', async ($, e, next) => {
    if (!e.agentId) await onNote($, e.text).catch(() => undefined)
    return next(e)
  })
  on('prompt.submit', async ($, e, next) => {
    await onNote($, e.text).catch(() => undefined)
    return next(e)
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
    // `open claude://…` does not switch the app (tried 2026-11-26), so show the Bartender in split view.
    // The window tool takes only sessions the Bouncer started; when the call fails, the Bouncer opens it.
    const open = async (id: string, name: string) => {
      const ran = await $.tool.call({ tool: 'mcp__ccd_window__open_session_in', session_id: id, target: 'split' } as any)
        .catch(() => undefined)
      if (!ran || ran.deny !== undefined || ran.isError === true) await ask(`${name}: open`)
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
              <Text>{b.emoji}</Text>
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
            ? <Button key="queue" onPress={async () => { await update($, pool, q => ({ ...q, queueOpen: !q.queueOpen })); await refreshData($, records) }}>
                {`queue ${p.queue}`}
              </Button>
            : <Text dimColor>queue 0</Text>}
          {(p.ledger ?? 0) > 0 && <Text key="ledger">{`ledger ${p.ledger}`}</Text>}
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
