import { useCallback, useContext } from 'react'
import { UserEditingContext } from '@/stores/userEditing/context'
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

  const userEditing = useContext(UserEditingContext)
  const { setEntryPoint, setSnapshot } = ctx

  const enterJourney = useCallback(
    (entry: EntryPoint) => {
      if (userEditing) {
        const snap: ExploreSnapshot = {
          showMode: userEditing.showMode,
          hiddenNodeIds: userEditing.hiddenNodeIds,
          activeTableName: userEditing.activeTableName,
          viewport: null, // filled in Task 7
        }
        setSnapshot(snap)
      }
      setEntryPoint(entry)
    },
    [userEditing, setSnapshot, setEntryPoint],
  )

  return { ...ctx, enterJourney }
}
