import { Scan, X } from '@liam-hq/ui'
import type { FC } from 'react'
import styles from './FocusBanner.module.css'

type Props = {
  focusedNodes: Set<string>
  onRemoveNode: (nodeId: string) => void
  onExitFocus: () => void
}

export const FocusBanner: FC<Props> = ({
  focusedNodes,
  onRemoveNode,
  onExitFocus,
}) => {
  const nodeList = Array.from(focusedNodes)

  return (
    <div className={styles.banner}>
      <Scan width={14} height={14} />
      <span className={styles.label}>
        Showing nodes connected to
      </span>
      <div className={styles.chips}>
        {nodeList.map((nodeId) => {
          const displayName = nodeId.replace(/^woods-/, '')
          return (
            <span key={nodeId} className={styles.chip}>
              {displayName}
              <button
                type="button"
                className={styles.chipRemove}
                onClick={() => onRemoveNode(nodeId)}
                aria-label={`Remove ${displayName} from focus`}
              >
                <X width={10} height={10} />
              </button>
            </span>
          )
        })}
      </div>
      <button
        type="button"
        className={styles.exitButton}
        onClick={onExitFocus}
        aria-label="Exit focus mode"
      >
        Exit focus
      </button>
    </div>
  )
}
