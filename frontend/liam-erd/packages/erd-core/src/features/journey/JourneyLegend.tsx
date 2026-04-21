import { useJourneyMode } from './useJourneyMode'
import styles from './journey.module.css'

export function JourneyLegend() {
  const { entryPoint } = useJourneyMode()
  if (!entryPoint) return null

  return (
    <div className={styles.legend} role="note" aria-label="Edge type legend">
      <div style={{ marginBottom: 4, fontWeight: 600, color: '#ddd' }}>
        Edge types
      </div>
      <div className={styles.legendRow}>
        <span
          style={{ display: 'inline-block', width: 24, borderTop: '2px solid #4a8acf' }}
        />
        link_to
      </div>
      <div className={styles.legendRow}>
        <span
          style={{ display: 'inline-block', width: 24, borderTop: '2px dashed #cf8a4a' }}
        />
        redirect_to
      </div>
      <div className={styles.legendRow}>
        <span
          style={{ display: 'inline-block', width: 24, borderTop: '3px solid #8a4acf' }}
        />
        form_action
      </div>
    </div>
  )
}
