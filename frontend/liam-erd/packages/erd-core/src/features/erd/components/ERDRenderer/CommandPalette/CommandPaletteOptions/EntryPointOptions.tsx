'use client'

import { Command } from 'cmdk'
import { type FC } from 'react'
import { useJourneyMode } from '@/features/journey'
import { useSchemaOrThrow } from '@/stores'
import { useCommandPaletteOrThrow } from '../CommandPaletteProvider'
import styles from './CommandPaletteOptions.module.css'

export const EntryPointOptions: FC = () => {
  const schema = useSchemaOrThrow()
  const entryPoints = schema.current.entryPoints ?? []
  const { enterJourney } = useJourneyMode()
  const { setOpen } = useCommandPaletteOrThrow()

  if (entryPoints.length === 0) return null

  return (
    <Command.Group heading="Entry Points">
      {entryPoints.map((entry) => (
        <Command.Item
          key={`entry-${entry.identifier}-${entry.path}`}
          value={`${entry.verb} ${entry.path} ${entry.identifier} ${entry.action}`}
          onSelect={() => {
            enterJourney({
              identifier: entry.identifier,
              verb: entry.verb,
              path: entry.path,
              action: entry.action,
            })
            setOpen(false)
          }}
        >
          <span className={styles.item}>
            <span className={styles.itemText}>
              {entry.verb} {entry.path} → {entry.identifier}#{entry.action}
            </span>
          </span>
        </Command.Item>
      ))}
    </Command.Group>
  )
}
