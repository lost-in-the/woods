import type { Edge, Node } from '@xyflow/react'
import type { EdgeCategory, NodeLayer } from './useLayerState'

const WOODS_TYPE_TO_LAYER: Record<string, NodeLayer> = {
  controller: 'controllers',
  job: 'jobs',
  service: 'services',
  mailer: 'mailers',
}

export function filterNodesByLayers(
  nodes: Node[],
  nodeLayers: Record<NodeLayer, boolean>,
): Node[] {
  return nodes.filter((node) => {
    if (node.type !== 'woodsNode') return true
    const layerKey = WOODS_TYPE_TO_LAYER[node.data.type as string]
    if (!layerKey) return true
    return nodeLayers[layerKey]
  })
}

export function filterEdgesByLayers(
  edges: Edge[],
  edgeCategories: Record<EdgeCategory, boolean>,
  visibleNodeIds: Set<string>,
): Edge[] {
  return edges.filter((edge) => {
    if (!visibleNodeIds.has(edge.source) || !visibleNodeIds.has(edge.target)) {
      return false
    }
    if (edge.data?.via) {
      return edgeCategories.dependency
    }
    return edgeCategories.data
  })
}
