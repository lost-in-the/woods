import {
  Button,
  Check,
  ChevronDown,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuLabel,
  DropdownMenuPortal,
  DropdownMenuRoot,
  DropdownMenuSeparator,
  DropdownMenuTrigger,
} from '@liam-hq/ui'
import type { FC } from 'react'
import type { EdgeCategory, NodeLayer } from './useLayerState'
import styles from './LayerToggleDropdown.module.css'

const NODE_LAYER_OPTIONS: {
  value: NodeLayer
  label: string
  color: string
}[] = [
  { value: 'controllers', label: 'Controllers', color: '#60a5fa' },
  { value: 'jobs', label: 'Jobs', color: '#fbbf24' },
  { value: 'services', label: 'Services', color: '#c084fc' },
  { value: 'mailers', label: 'Mailers', color: '#f472b6' },
]

const EDGE_CATEGORY_OPTIONS: { value: EdgeCategory; label: string }[] = [
  { value: 'data', label: 'Data' },
  { value: 'dependency', label: 'Dependency' },
]

type Props = {
  nodeLayers: Record<NodeLayer, boolean>
  edgeCategories: Record<EdgeCategory, boolean>
  onToggleNodeLayer: (layer: NodeLayer) => void
  onToggleEdgeCategory: (category: EdgeCategory) => void
}

export const LayerToggleDropdown: FC<Props> = ({
  nodeLayers,
  edgeCategories,
  onToggleNodeLayer,
  onToggleEdgeCategory,
}) => {
  const activeNodeCount = Object.values(nodeLayers).filter(Boolean).length

  const buttonLabel =
    activeNodeCount > 0 ? `${activeNodeCount} active` : 'Layers'

  return (
    <div className={styles.wrapper}>
      <span className={styles.label}>layers</span>
      <DropdownMenuRoot>
        <DropdownMenuTrigger asChild>
          <Button
            size="sm"
            variant="ghost-secondary"
            rightIcon={<ChevronDown />}
            aria-label="Layer toggles"
          >
            {buttonLabel}
          </Button>
        </DropdownMenuTrigger>
        <DropdownMenuPortal>
          <DropdownMenuContent
            className={styles.content}
            align="start"
            side="top"
            sideOffset={12}
          >
            <DropdownMenuLabel>
              <span className={styles.sectionLabel}>Node Types</span>
            </DropdownMenuLabel>
            {NODE_LAYER_OPTIONS.map(({ value, label, color }) => (
              <DropdownMenuItem
                key={value}
                size="sm"
                onSelect={(e) => {
                  e.preventDefault()
                  onToggleNodeLayer(value)
                }}
              >
                <span className={styles.itemContent}>
                  <span
                    className={styles.colorDot}
                    style={{ backgroundColor: color }}
                  />
                  <span className={styles.itemLabel}>{label}</span>
                  {nodeLayers[value] && (
                    <span className={styles.checkIcon}>
                      <Check width={12} height={12} />
                    </span>
                  )}
                </span>
              </DropdownMenuItem>
            ))}
            <DropdownMenuSeparator />
            <DropdownMenuLabel>
              <span className={styles.sectionLabel}>Edges</span>
            </DropdownMenuLabel>
            {EDGE_CATEGORY_OPTIONS.map(({ value, label }) => (
              <DropdownMenuItem
                key={value}
                size="sm"
                onSelect={(e) => {
                  e.preventDefault()
                  onToggleEdgeCategory(value)
                }}
              >
                <span className={styles.itemContent}>
                  <span className={styles.itemLabel}>{label}</span>
                  {edgeCategories[value] && (
                    <span className={styles.checkIcon}>
                      <Check width={12} height={12} />
                    </span>
                  )}
                </span>
              </DropdownMenuItem>
            ))}
          </DropdownMenuContent>
        </DropdownMenuPortal>
      </DropdownMenuRoot>
    </div>
  )
}
