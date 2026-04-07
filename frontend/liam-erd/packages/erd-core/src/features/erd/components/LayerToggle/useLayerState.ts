import { useCallback, useState } from 'react'

export type NodeLayer = 'controllers' | 'jobs' | 'services' | 'mailers'
export type EdgeCategory = 'data' | 'dependency'

export interface LayerState {
  nodeLayers: Record<NodeLayer, boolean>
  edgeCategories: Record<EdgeCategory, boolean>
  toggleNodeLayer: (layer: NodeLayer) => void
  toggleEdgeCategory: (category: EdgeCategory) => void
  focusedNode: string | null
  setFocusedNode: (nodeId: string | null) => void
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

export function useLayerState(): LayerState {
  const [nodeLayers, setNodeLayers] =
    useState<Record<NodeLayer, boolean>>(DEFAULT_NODE_LAYERS)
  const [edgeCategories, setEdgeCategories] = useState<
    Record<EdgeCategory, boolean>
  >(DEFAULT_EDGE_CATEGORIES)
  const [focusedNode, setFocusedNode] = useState<string | null>(null)

  const toggleNodeLayer = useCallback((layer: NodeLayer) => {
    setNodeLayers((prev) => ({ ...prev, [layer]: !prev[layer] }))
  }, [])

  const toggleEdgeCategory = useCallback((category: EdgeCategory) => {
    setEdgeCategories((prev) => ({ ...prev, [category]: !prev[category] }))
  }, [])

  return {
    nodeLayers,
    edgeCategories,
    toggleNodeLayer,
    toggleEdgeCategory,
    focusedNode,
    setFocusedNode,
  }
}
