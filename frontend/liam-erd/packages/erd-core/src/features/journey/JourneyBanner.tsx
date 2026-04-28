import { useJourneyMode } from './useJourneyMode'
import styles from './journey.module.css'

export function JourneyBanner() {
  const { entryPoint, maxDepth, result, exitJourney, setDepth } =
    useJourneyMode()

  if (!entryPoint || !result) return null

  const label =
    entryPoint.verb === 'GET'
      ? `${entryPoint.verb} ${entryPoint.path} → ${entryPoint.identifier}#${entryPoint.action}`
      : `Journey from ${entryPoint.identifier}`

  return (
    <div className={styles.banner} role="region" aria-label="Journey mode banner">
      <div>
        <span className={styles.badge}>JOURNEY</span>
        <span>{label}</span>
        <span className={styles.meta}>
          reaches {result.nodes.size} nodes · depth {maxDepth}
          {result.truncated && ' (truncated)'}
        </span>
      </div>
      <div className={styles.controls}>
        <label>
          Depth:
          <select
            value={maxDepth}
            onChange={(e) => setDepth(Number(e.target.value))}
            aria-label="Walk depth"
          >
            {Array.from({ length: 10 }, (_, i) => i + 1).map((n) => (
              <option key={n} value={n}>
                {n}
              </option>
            ))}
          </select>
        </label>
        <button
          type="button"
          className={styles.exitButton}
          onClick={exitJourney}
        >
          Exit journey
        </button>
      </div>
    </div>
  )
}
