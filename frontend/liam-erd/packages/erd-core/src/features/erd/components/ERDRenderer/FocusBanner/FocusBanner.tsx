import { Scan, X } from '@liam-hq/ui'
import type { FC } from 'react'
import styles from './FocusBanner.module.css'

type Props = {
  focusedNode: string
  onExitFocus: () => void
}

export const FocusBanner: FC<Props> = ({ focusedNode, onExitFocus }) => {
  const displayName = focusedNode.replace(/^woods-/, '')

  return (
    <div className={styles.banner}>
      <Scan width={14} height={14} />
      <span className={styles.label}>
        Focused: <strong>{displayName}</strong>
      </span>
      <button
        type="button"
        className={styles.exitButton}
        onClick={onExitFocus}
        aria-label="Exit focus mode"
      >
        <X width={12} height={12} />
        <span>Exit</span>
      </button>
    </div>
  )
}
