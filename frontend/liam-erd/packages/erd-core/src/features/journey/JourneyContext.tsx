import { createContext, useMemo, useState, type ReactNode } from 'react'
import type { EdgeVia, WalkableSchema, WalkResult } from './walker'
import { walk } from './walker'

export type EntryPoint = {
  identifier: string
  verb: 'GET' | 'SYNTHETIC'
  path: string
  action: string
}

export type JourneyContextValue = {
  entryPoint: EntryPoint | null
  maxDepth: number
  enabledEdgeTypes: Set<EdgeVia>
  result: WalkResult | null
  enterJourney: (entry: EntryPoint) => void
  exitJourney: () => void
  setDepth: (depth: number) => void
  toggleEdgeType: (via: EdgeVia) => void
}

export const JourneyContext = createContext<JourneyContextValue | null>(null)

const DEFAULT_EDGE_TYPES: Set<EdgeVia> = new Set<EdgeVia>([
  'link_to',
  'redirect_to',
  'form_action',
])

export function JourneyProvider({
  schema,
  children,
}: {
  schema: WalkableSchema
  children: ReactNode
}) {
  const [entryPoint, setEntryPoint] = useState<EntryPoint | null>(null)
  const [maxDepth, setMaxDepth] = useState(10)
  const [enabledEdgeTypes, setEnabledEdgeTypes] =
    useState<Set<EdgeVia>>(DEFAULT_EDGE_TYPES)

  const result = useMemo<WalkResult | null>(() => {
    if (!entryPoint) return null
    return walk(schema, entryPoint.identifier, {
      maxDepth,
      edgeTypes: enabledEdgeTypes,
    })
  }, [schema, entryPoint, maxDepth, enabledEdgeTypes])

  const value: JourneyContextValue = {
    entryPoint,
    maxDepth,
    enabledEdgeTypes,
    result,
    enterJourney: setEntryPoint,
    exitJourney: () => setEntryPoint(null),
    setDepth: setMaxDepth,
    toggleEdgeType: (via) =>
      setEnabledEdgeTypes((prev) => {
        const next = new Set(prev)
        if (next.has(via)) next.delete(via)
        else next.add(via)
        return next
      }),
  }

  return (
    <JourneyContext.Provider value={value}>{children}</JourneyContext.Provider>
  )
}
