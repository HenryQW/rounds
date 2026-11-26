import { atom, read, update } from 'claude-code'
import type { EngineInterface, Register } from 'claude-code'

import { EMPTY, archived, chips, dots, ledgerSummary, parseBartender, queueLines, queueSummary, questionsBySession, renamed, synced } from './pool'
import type { Chip, Report } from './pool'

const pool = atom({ plugin: 'bouncer', key: 'pool' } as const, EMPTY)
const ACTIONS = [['status', 'Status'], ['stop', 'Stop'], ['reset', 'Reset']] as const

// A Linear-shaped key (ABC-123) links to the tracker; a GitHub issue number does not.
const LINEAR_KEY = /^[A-Z][A-Z0-9]*-\d+$/

// The queue, the open questions and the ledger in the plugin's data folder, the one bouncer-data prints (CLAUDE_PLUGIN_DATA).
// One Bouncer a repo: its repo is the folder name of its folder (the main checkout), and its queue, questions and
// owner file live in <data>/<repo>/ (bouncer-data --repo). Another repo's Bouncer has its own.
const repoOf = async ($: EngineInterface) => (await $.session.cwd()).split('/').pop() ?? ''
const repoDir = async ($: EngineInterface) => {
  const data = (await $.process.hookEnv()).CLAUDE_PLUGIN_DATA
  return data ? `${data}/${await repoOf($)}` : undefined
}
const dataFile = async ($: EngineInterface, name: string) => {
  const dir = await repoDir($)
  return String(dir ? await $.fs.read(`${dir}/${name}`).catch(() => '') : '')
}
// Open ledger items live in the ticket records; bouncer-ledger list prints one line each.
const ledgerList = async ($: EngineInterface, records: string) => {
  const env = await $.process.hookEnv()
  if (!env.CLAUDE_PLUGIN_ROOT) return undefined
  const ran = await $.process.run([`${env.CLAUDE_PLUGIN_ROOT}/skills/bouncer/scripts/bouncer-ledger`, 'list'],
    { env: records ? { ...env, BOUNCER_RECORDS: records } : env }).catch(() => undefined)
  return ran?.exitCode === 0 ? queueLines(ran.stdout) : undefined
}
// One Bouncer a repo: `bouncer` in <data>/<repo>/ holds the engine session id of that repo's Bouncer.
// A session claims it when it is free; another one takes it over only on the user's Take Over.
const writeOwner = async ($: EngineInterface, id: string) => {
  const dir = await repoDir($)
  if (dir) await $.fs.write(`${dir}/bouncer`, id).catch(() => undefined)
}
const isOtherBouncer = async ($: EngineInterface) => {
  const me = await $.session.id()
  const owner = (await dataFile($, 'bouncer')).trim()
  if (!owner) await writeOwner($, me)
  return owner !== '' && owner !== me
}
const refreshData = async ($: EngineInterface, records = '') => {
  const isOther = await isOtherBouncer($)
  await update($, pool, p => (p.isOther === isOther ? p : { ...p, isOther }))
  const lines = queueLines(await dataFile($, 'queue.md'))
  const questions = questionsBySession(await dataFile($, 'questions.md'))
  const ledger = await ledgerList($, records)
  await update($, pool, p => ({
    ...p, queue: lines.length, queueLines: lines, questions,
    ledger: ledger?.length ?? p.ledger, ledgerLines: ledger ?? p.ledgerLines,
  }))
}

// Make the titles match the open questions and, given a report, its status code; set_session_title is the Bouncer's own call.
const syncTitles = async ($: EngineInterface, report?: Report) => {
  for (const [session_id, title] of synced(await read($, pool), await dataFile($, 'questions.md'), report, await repoOf($))) {
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
  let report: Report
  try { report = JSON.parse(ran.stdout) as Report } catch { return /* not a report */ }
  // Keep the STATUS for the band's dot, on the session whose title has the report's ticket.
  const id = Object.entries((await read($, pool)).bartenders).find(([, t]) => report.ticket && parseBartender(t)?.ticket === report.ticket)?.[0]
  if (id) await update($, pool, p => ({ ...p, reports: { ...p.reports, [id]: report.status } }))
  await syncTitles($, report)
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

  // The queue, questions and ledger change outside the Bouncer's own calls (a Bartender, a shell, the last session):
  // read them again when the session starts and after each of the Bouncer's turns.
  on('session.start', async ($, e, next) => {
    const details = (await $.store.get('details').catch(() => undefined)) === true
    await update($, pool, p => (p.details === details ? p : { ...p, details }))
    if ((await read($, pool)).isOn) await refreshData($, records).catch(() => undefined)
    return next(e)
  })
  // The Bouncer's session ends (or a /clear gives it a new id): free the Bouncer for the next session.
  on('session.end', async ($, e, next) => {
    if ((await read($, pool)).isOn && (await dataFile($, 'bouncer')).trim() === e.sessionId) await writeOwner($, '')
    return next(e)
  })
  // A band prompt's turn ended (main's, not a subagent's): the band may send the next one.
  on('turn.complete', async ($, e, next) => {
    if (!e.agentId) {
      await update($, pool, p => (p.pending ? { ...p, pending: false } : p))
      if ((await read($, pool)).isOn) await refreshData($, records).catch(() => undefined)
    }
    return next(e)
  })

  on('ui.render', { component: 'AbovePrompt' }, async ($, e, next) => {
    const p = await read($, pool)
    if (e.props.hasSurvey || !p.isOn) return next(e)
    // Other mods share this slot (ponytail's band): draw theirs below ours.
    const below = await next(e).catch(() => undefined)

    const { Box, Text, Button } = $.ui.resolve(e)
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
    const ownRepo = await repoOf($)
    if (p.isOther) {
      const take = async () => { await writeOwner($, await $.session.id()); await refreshData($, records) }
      const row = (
        <Box flexDirection="row" alignItems="center" gap={2} flexWrap="wrap" width={width}>
          <Text bold>Bouncer</Text>
          <Text dimColor>{`another session is the Bouncer of ${ownRepo}`}</Text>
          <Button key="takeover" dimColor onPress={take}>Take Over</Button>
        </Box>
      )
      return below ? <Box flexDirection="column">{row}{below}</Box> : row
    }
    // Questions block in order: the band shows only the oldest (the head of questions.md); the next shows once it is answered.
    const [headId, headQuestion] = Object.entries(p.questions ?? {})[0] ?? []
    const headB = bartenders.find(b => b.id === headId)
    const ctaB = bartenders.find(b => b.cta)
    const waits = headQuestion !== undefined
      ? { b: headB, name: headB ? headB.ticket || headB.repo : headId === 'self' ? 'Bouncer' : headId ?? '', question: headQuestion }
      : ctaB && { b: ctaB, name: ctaB.ticket || ctaB.repo, question: 'waits on you' }
    const lines = p.queueOpen ? p.queueLines ?? [] : []
    const ledgerLines = p.ledgerOpen ? p.ledgerLines ?? [] : []
    const all = chips(p.bartenders, p.reports, ownRepo)
    const opened = p.details ? all.find(c => c.key === p.menu) : undefined
    // Compact (the default) shows the dots, the ask pill and the counts; Details adds the chips. Kept across sessions.
    const flip = async () => {
      const details = !(await read($, pool)).details
      await update($, pool, q => ({ ...q, details }))
      await $.store.set('details', details).catch(() => undefined)
    }
    // A chip opens its action row. Each action names one session (a ticket key, else its session id),
    // so an action on the grouped idle chip is never ambiguous.
    const actions = (c: Chip) => [
      ...c.ids.flatMap(id => ACTIONS.map(([a, label]) =>
        ({ value: `${a} ${id}`, label: c.ids.length > 1 ? `${label} ${id.replace(/^local_/, '').slice(0, 8)}` : label }))),
      ...(linear && LINEAR_KEY.test(c.ticket) ? [{ value: 'linear', label: 'Open in Linear' }] : []),
    ]
    const pick = async (c: Chip, v: string) => {
      await update($, pool, q => ({ ...q, menu: undefined }))
      if (v === 'linear') return void await $.process.run(['/usr/bin/open', `${linear}/issue/${c.ticket}`]).catch(() => undefined)
      const [a, id] = v.split(' ')
      if (a && id) await ask(`${c.ticket || id}: ${a}`)
    }
    const toggle = async (k: 'queueOpen' | 'ledgerOpen') => {
      await update($, pool, q => ({ ...q, [k]: !q[k] }))
      await refreshData($, records)
    }
    // `open claude://…` does not switch the app (tried 2026-11-26), so show the Bartender in split view.
    // The window tool takes only sessions the Bouncer started; when the call fails, the Bouncer opens it.
    const open = async (id: string, name: string) => {
      const ran = await $.tool.call({ tool: 'mcp__ccd_window__open_session_in', session_id: id, target: 'split' } as any)
        .catch(() => undefined)
      if (!ran || ran.deny !== undefined || ran.isError === true) await ask(`${name}: open`)
    }

    // One row: dot strip, the head question, chips, then the counts on the right. Steps: `lg` between chips, `xs` inside.
    const mine = (
      <Box flexDirection="column" width={width}>
        <Box flexDirection="row" alignItems="center" columnGap="lg" rowGap="xs" flexWrap="wrap">
          {bartenders.length === 0
            ? <Text dimColor>no Bartenders yet</Text>
            : <Text key="dots">{dots(p.bartenders, p.reports).join('')}</Text>}
          {waits && (
            <Box backgroundColor="diffRemovedDimmed" paddingX="xs" flexShrink={1} minWidth={0}>
              {waits.b
                ? <Button key={`open:${waits.b.id}`} plain onPress={() => open(waits.b!.id, waits.name)}>
                    <Text wrap="truncate">{`🔴 ${waits.name}: ${waits.question} →`}</Text>
                  </Button>
                : <Text wrap="truncate">{`🔴 ${waits.name}: ${waits.question}`}</Text>}
            </Box>
          )}
          {p.details && waits && <Text dimColor>│</Text>}
          {p.details && all.map(c => (
            <Button key={c.key} plain dimColor={c.key === 'idle'} onPress={() => update($, pool, q => ({ ...q, menu: q.menu === c.key ? undefined : c.key }))}>
              <Text bold={c.key !== 'idle'}>{c.head}</Text>
              {c.tail && <Text dimColor>{` ${c.tail}`}</Text>}
            </Button>
          ))}
          <Box flexGrow={1} />
          {p.queue > 0 && <Button key="queue" plain dimColor onPress={() => toggle('queueOpen')}>{`📥 ${p.queue} queued`}</Button>}
          {(p.ledger ?? 0) > 0 && <Button key="ledger" plain dimColor onPress={() => toggle('ledgerOpen')}>{`⏰ ${p.ledger} open`}</Button>}
          {bartenders.length > 0 && <Button key="details" plain dimColor label={p.details ? 'Compact' : 'Details'} onPress={flip} />}
        </Box>
        {opened && (
          <Box flexDirection="row" alignItems="center" gap="xs" flexWrap="wrap">
            <Text dimColor>{opened.head}</Text>
            {actions(opened).map(o => <Button key={`${opened.key}:${o.value}`} plain dimColor onPress={() => pick(opened, o.value)}>{o.label}</Button>)}
          </Box>
        )}
        {lines.map((line, i) => {
          const ticket = line.split('|')[0]?.trim() ?? ''
          return (
            <Box flexDirection="row" alignItems="center" gap={1}>
              <Box flexShrink={1} minWidth={0}><Text dimColor wrap="truncate">{queueSummary(line)}</Text></Box>
              {i === 0 && <Button key="queue:pop" plain dimColor onPress={() => ask('queue: pop')}>Pop</Button>}
              <Button key={`queue:remove:${ticket}`} plain dimColor onPress={() => ask(`queue: remove ${ticket}`)}>Remove</Button>
            </Box>
          )
        })}
        {ledgerLines.map(line => <Text dimColor wrap="truncate">{ledgerSummary(line)}</Text>)}
      </Box>
    )
    return below ? <Box flexDirection="column">{mine}{below}</Box> : mine
  })
}
