import type { WoodsNodeType } from '@liam-hq/schema'
import { Handle, Position } from '@xyflow/react'
import type { FC } from 'react'
import styles from './WoodsNode.module.css'
import { woodsNodeColors } from './woodsNodeColors'

type Props = {
  name: string
  type: WoodsNodeType
  meta: Record<string, unknown>
}

const formatLabel = (type: WoodsNodeType): string => {
  return type.charAt(0).toUpperCase() + type.slice(1)
}

const formatMeta = (type: WoodsNodeType, meta: Record<string, unknown>): string | null => {
  if (type === 'controller' && typeof meta['action_count'] === 'number') {
    return `${meta['action_count']} actions`
  }
  if (type === 'job' && typeof meta['queue'] === 'string') {
    return meta['queue']
  }
  if (type === 'service' && meta['callable'] === true) {
    return 'callable'
  }
  return null
}

export const WoodsNodeHeader: FC<Props> = ({ name, type, meta }) => {
  const colors = woodsNodeColors[type]
  const metaText = formatMeta(type, meta)

  return (
    <div
      className={styles.header}
      style={{ backgroundColor: colors.header }}
    >
      <span className={styles.typeLabel}>{formatLabel(type)}</span>
      <span className={styles.name}>{name}</span>
      {metaText && <span className={styles.meta}>{metaText}</span>}
      <Handle
        id={`${name}-target`}
        type="target"
        position={Position.Left}
        className={styles.handle}
      />
      <Handle
        id={`${name}-source`}
        type="source"
        position={Position.Right}
        className={styles.handle}
      />
    </div>
  )
}
