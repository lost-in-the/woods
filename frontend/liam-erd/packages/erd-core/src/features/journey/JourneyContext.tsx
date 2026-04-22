import { createContext, useCallback, useMemo, useState, type ReactNode } from 'react'
import type { ShowMode } from '@/schemas'
import type { WalkableSchema, WalkResult } from './walker'
import { walk } from './walker'

export type EntryPoint = {
  identifier: string
  verb: 'GET' | 'SYNTHETIC'
  path: string
  action: string
}

export type ExploreSnapshot = {
  showMode: ShowMode
  hiddenNodeIds: string[]
  activeTableName: string | null
  viewport: { x: number; y: number; zoom: number } | null
}

export type JourneyContextValue = {
  entryPoint: EntryPoint | null
  maxDepth: number
  result: WalkResult | null
  snapshot: ExploreSnapshot | null
  enterJourney: (entry: EntryPoint) => void
  exitJourney: () => void
  setDepth: (depth: number) => void
  setEntryPoint: (entry: EntryPoint | null) => void
  setSnapshot: (snapshot: ExploreSnapshot | null) => void
  setSnapshotViewport: (vp: { x: number; y: number; zoom: number }) => void
}

export const JourneyContext = createContext<JourneyContextValue | null>(null)

export function JourneyProvider({
  schema,
  children,
}: {
  schema: WalkableSchema
  children: ReactNode
}) {
  const [entryPoint, setEntryPoint] = useState<EntryPoint | null>(null)
  const [maxDepth, setMaxDepth] = useState(10)
  const [snapshot, setSnapshot] = useState<ExploreSnapshot | null>(null)

  const setSnapshotViewport = useCallback(
    (vp: { x: number; y: number; zoom: number }) => {
      setSnapshot((prev) => (prev ? { ...prev, viewport: vp } : prev))
    },
    [],
  )

  const result = useMemo<WalkResult | null>(() => {
    if (!entryPoint) return null
    return walk(schema, entryPoint.identifier, { maxDepth })
  }, [schema, entryPoint, maxDepth])

  const value: JourneyContextValue = {
    entryPoint,
    maxDepth,
    result,
    snapshot,
    enterJourney: setEntryPoint,
    exitJourney: () => setEntryPoint(null),
    setDepth: setMaxDepth,
    setEntryPoint,
    setSnapshot,
    setSnapshotViewport,
  }

  return (
    <JourneyContext.Provider value={value}>{children}</JourneyContext.Provider>
  )
}
