import { Command } from 'cmdk'
import { type FC, useEffect, useRef } from 'react'
import { woodsNodeColors } from '@/features/erd/components/ERDContent/components/WoodsNode'
import { useSchemaOrThrow } from '@/stores'
import { getSuggestionText } from '../utils'
import styles from './CommandPaletteOptions.module.css'

type Props = {
  onSelectNode: (nodeId: string) => void
  onToggleNode: (nodeId: string) => void
}

const WOODS_GROUPS: {
  type: string
  label: string
}[] = [
  { type: 'controller', label: 'Controllers' },
  { type: 'job', label: 'Jobs' },
  { type: 'service', label: 'Services' },
  { type: 'mailer', label: 'Mailers' },
]

export const WoodsNodeOptions: FC<Props> = ({ onSelectNode, onToggleNode }) => {
  const schema = useSchemaOrThrow()
  const nodes = schema.current.nodes

  // Track meta/ctrl key state for Cmd+Enter multi-select
  const metaKeyRef = useRef(false)

  useEffect(() => {
    const down = (e: KeyboardEvent) => {
      metaKeyRef.current = e.metaKey || e.ctrlKey
    }
    const up = (e: KeyboardEvent) => {
      metaKeyRef.current = e.metaKey || e.ctrlKey
    }
    document.addEventListener('keydown', down)
    document.addEventListener('keyup', up)
    return () => {
      document.removeEventListener('keydown', down)
      document.removeEventListener('keyup', up)
    }
  }, [])

  if (!nodes) return null

  const nodeEntries = Object.entries(nodes)
  if (nodeEntries.length === 0) return null

  return (
    <>
      {WOODS_GROUPS.map(({ type, label }) => {
        const groupNodes = nodeEntries.filter(([, n]) => n.type === type)
        if (groupNodes.length === 0) return null

        const colors = woodsNodeColors[type as keyof typeof woodsNodeColors]

        return (
          <Command.Group key={type} heading={label}>
            {groupNodes.map(([id, node]) => (
              <Command.Item
                key={id}
                value={getSuggestionText({ type: 'woods', name: id })}
                onSelect={() => {
                  const nodeId = `woods-${id}`
                  if (metaKeyRef.current) {
                    onToggleNode(nodeId)
                  } else {
                    onSelectNode(nodeId)
                  }
                }}
              >
                <a className={styles.item}>
                  <span
                    style={{
                      width: 8,
                      height: 8,
                      borderRadius: '50%',
                      backgroundColor: colors?.border ?? 'var(--overlay-40)',
                      flexShrink: 0,
                      marginRight: 'var(--spacing-2)',
                    }}
                  />
                  <span className={styles.itemText}>{node.name}</span>
                </a>
              </Command.Item>
            ))}
          </Command.Group>
        )
      })}
    </>
  )
}
