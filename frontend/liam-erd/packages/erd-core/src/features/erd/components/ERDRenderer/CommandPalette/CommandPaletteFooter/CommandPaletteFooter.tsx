import type { FC } from 'react'
import styles from './CommandPaletteFooter.module.css'

export const CommandPaletteFooter: FC = () => {
  return (
    <div className={styles.footer}>
      <span className={styles.hint}>
        <kbd className={styles.key}>Enter</kbd>
        <span>Focus</span>
      </span>
      <span className={styles.hint}>
        <kbd className={styles.key}>&#8984;Enter</kbd>
        <span>Add to focus</span>
      </span>
      <span className={styles.hint}>
        <kbd className={styles.key}>Esc</kbd>
        <span>Close</span>
      </span>
    </div>
  )
}
