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

export function filterByFocus(
  nodes: Node[],
  edges: Edge[],
  focusedNode: string | null,
): { nodes: Node[]; edges: Edge[] } {
  if (!focusedNode) return { nodes, edges }

  const connectedIds = new Set<string>([focusedNode])
  for (const edge of edges) {
    if (edge.source === focusedNode) connectedIds.add(edge.target)
    if (edge.target === focusedNode) connectedIds.add(edge.source)
  }

  return {
    nodes: nodes.filter((node) => connectedIds.has(node.id)),
    edges: edges.filter(
      (edge) => connectedIds.has(edge.source) && connectedIds.has(edge.target),
    ),
  }
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
