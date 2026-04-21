import { useContext } from 'react'
import { JourneyContext, type JourneyContextValue } from './JourneyContext'

export function useJourneyMode(): JourneyContextValue {
  const ctx = useContext(JourneyContext)
  if (!ctx) {
    throw new Error('useJourneyMode must be used within a JourneyProvider')
  }
  return ctx
}
