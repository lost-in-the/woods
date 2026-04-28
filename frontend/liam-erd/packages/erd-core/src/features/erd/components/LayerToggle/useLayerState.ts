import { useCallback, useState } from 'react'

export type NodeLayer = 'controllers' | 'jobs' | 'services' | 'mailers'
export type EdgeCategory = 'data' | 'dependency'

export interface LayerState {
  nodeLayers: Record<NodeLayer, boolean>
  edgeCategories: Record<EdgeCategory, boolean>
  toggleNodeLayer: (layer: NodeLayer) => void
  toggleEdgeCategory: (category: EdgeCategory) => void
  focusedNodes: Set<string>
  setFocusedNodes: (nodes: Set<string>) => void
  toggleFocusedNode: (nodeId: string) => void
}

const DEFAULT_NODE_LAYERS: Record<NodeLayer, boolean> = {
  controllers: false,
  jobs: false,
  services: false,
  mailers: false,
}

const DEFAULT_EDGE_CATEGORIES: Record<EdgeCategory, boolean> = {
  data: true,
  dependency: true,
}

export function useLayerState(initialFocusedNodes?: Set<string>): LayerState {
  const [nodeLayers, setNodeLayers] =
    useState<Record<NodeLayer, boolean>>(DEFAULT_NODE_LAYERS)
  const [edgeCategories, setEdgeCategories] = useState<
    Record<EdgeCategory, boolean>
  >(DEFAULT_EDGE_CATEGORIES)
  const [focusedNodes, setFocusedNodes] = useState<Set<string>>(
    initialFocusedNodes ?? new Set(),
  )

  const toggleNodeLayer = useCallback((layer: NodeLayer) => {
    setNodeLayers((prev) => ({ ...prev, [layer]: !prev[layer] }))
  }, [])

  const toggleEdgeCategory = useCallback((category: EdgeCategory) => {
    setEdgeCategories((prev) => ({ ...prev, [category]: !prev[category] }))
  }, [])

  const toggleFocusedNode = useCallback((nodeId: string) => {
    setFocusedNodes((prev) => {
      const next = new Set(prev)
      if (next.has(nodeId)) {
        next.delete(nodeId)
      } else {
        next.add(nodeId)
      }
      return next
    })
  }, [])

  return {
    nodeLayers,
    edgeCategories,
    toggleNodeLayer,
    toggleEdgeCategory,
    focusedNodes,
    setFocusedNodes,
    toggleFocusedNode,
  }
}
