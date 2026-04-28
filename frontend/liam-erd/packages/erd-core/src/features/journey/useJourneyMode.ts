import { useCallback, useContext } from 'react'
import { useUserEditingOrThrow } from '@/stores/userEditing/hooks'
import {
  JourneyContext,
  type EntryPoint,
  type ExploreSnapshot,
  type JourneyContextValue,
} from './JourneyContext'

export function useJourneyMode(): JourneyContextValue {
  const ctx = useContext(JourneyContext)
  if (!ctx) {
    throw new Error('useJourneyMode must be used within a JourneyProvider')
  }

  const userEditing = useUserEditingOrThrow()
  const { setEntryPoint, setSnapshot } = ctx

  const enterJourney = useCallback(
    (entry: EntryPoint) => {
      const snap: ExploreSnapshot = {
        showMode: userEditing.showMode,
        hiddenNodeIds: userEditing.hiddenNodeIds,
        activeTableName: userEditing.activeTableName,
        viewport: null, // filled in Task 7
      }
      setSnapshot(snap)
      userEditing.setActiveTableName(null)
      setEntryPoint(entry)
    },
    [userEditing, setSnapshot, setEntryPoint],
  )

  const { snapshot } = ctx

  const exitJourney = useCallback(() => {
    if (snapshot) {
      userEditing.setShowMode(snapshot.showMode)
      userEditing.setHiddenNodeIds(snapshot.hiddenNodeIds)
      userEditing.setActiveTableName(snapshot.activeTableName)
      // viewport restore happens in Task 7
    }
    setEntryPoint(null)
    setSnapshot(null)
  }, [snapshot, userEditing, setEntryPoint, setSnapshot])

  return { ...ctx, enterJourney, exitJourney }
}
