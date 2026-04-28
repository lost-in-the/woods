import type { Edge, Node } from '@xyflow/react'
import type { EdgeCategory } from './useLayerState'

export function filterByFocus(
  nodes: Node[],
  edges: Edge[],
  focusedNodes: Set<string>,
): { nodes: Node[]; edges: Edge[] } {
  if (focusedNodes.size === 0) return { nodes, edges }

  // Compute union of one-hop neighborhoods for all focused nodes
  const visibleIds = new Set<string>(focusedNodes)
  for (const edge of edges) {
    if (focusedNodes.has(edge.source)) visibleIds.add(edge.target)
    if (focusedNodes.has(edge.target)) visibleIds.add(edge.source)
  }

  return {
    nodes: nodes.filter((node) => visibleIds.has(node.id)),
    edges: edges.filter(
      (edge) => visibleIds.has(edge.source) && visibleIds.has(edge.target),
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
    if (edge.data?.['via']) {
      return edgeCategories.dependency
    }
    return edgeCategories.data
  })
}
