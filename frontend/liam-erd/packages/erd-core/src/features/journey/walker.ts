export type EdgeVia = 'link_to' | 'redirect_to' | 'form_action'

export type WalkableDependency = { target: string; via: string }
export type WalkableNode = { dependencies: WalkableDependency[] }
export type WalkableSchema = { nodes: Record<string, WalkableNode> }

export type WalkOptions = {
  maxDepth?: number
  edgeTypes?: ReadonlySet<string>
}

export type WalkEdge = {
  from: string
  to: string
  via: EdgeVia
  isBackEdge: boolean
}

export type WalkResult = {
  nodes: Map<string, { depth: number }>
  edges: WalkEdge[]
  cycles: Array<[string, string]>
  truncated: boolean
}

const DEFAULT_EDGE_TYPES: ReadonlySet<string> = new Set<string>([
  'link_to',
  'redirect_to',
  'form_action',
])

const DEFAULT_MAX_DEPTH = 10

export function walk(
  schema: WalkableSchema,
  entryId: string,
  opts: WalkOptions = {},
): WalkResult {
  const maxDepth = opts.maxDepth ?? DEFAULT_MAX_DEPTH
  const edgeTypes = opts.edgeTypes ?? DEFAULT_EDGE_TYPES

  const nodes = new Map<string, { depth: number }>()
  const edges: WalkEdge[] = []
  const cycles: Array<[string, string]> = []

  if (!schema.nodes[entryId]) {
    return { nodes, edges, cycles, truncated: false }
  }

  nodes.set(entryId, { depth: 0 })
  const queue: string[] = [entryId]
  let truncated = false

  while (queue.length > 0) {
    const current = queue.shift() as string
    const currentDepth = nodes.get(current)?.depth ?? 0

    const node = schema.nodes[current]
    if (!node) continue

    for (const dep of node.dependencies) {
      if (!isEdgeVia(dep.via) || !edgeTypes.has(dep.via)) continue

      const alreadyVisited = nodes.has(dep.target)

      if (alreadyVisited) {
        edges.push({ from: current, to: dep.target, via: dep.via, isBackEdge: true })
        cycles.push([current, dep.target])
        continue
      }

      if (currentDepth >= maxDepth) {
        truncated = true
        continue
      }

      nodes.set(dep.target, { depth: currentDepth + 1 })
      edges.push({ from: current, to: dep.target, via: dep.via, isBackEdge: false })
      queue.push(dep.target)
    }
  }

  return { nodes, edges, cycles, truncated }
}

function isEdgeVia(value: string): value is EdgeVia {
  return value === 'link_to' || value === 'redirect_to' || value === 'form_action'
}
