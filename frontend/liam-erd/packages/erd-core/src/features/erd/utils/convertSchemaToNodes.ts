import type { Cardinality, Schema } from '@liam-hq/schema'
import { constraintsToRelationships } from '@liam-hq/schema'
import type { Edge, Node } from '@xyflow/react'
import {
  NON_RELATED_TABLE_GROUP_NODE_ID,
  zIndex,
} from '@/features/erd/constants'
import { columnHandleId } from '@/features/erd/utils'
import type { ShowMode } from '@/schemas/showMode'
import type { NodeLayer } from '../components/LayerToggle'

type Params = {
  schema: Schema
  showMode: ShowMode
  nodeLayers?: Record<NodeLayer, boolean>
}

export const convertSchemaToNodes = ({
  schema,
  showMode,
  nodeLayers,
}: Params): {
  nodes: Node[]
  edges: Edge[]
} => {
  const tables = Object.values(schema.tables)
  const relationships = Object.values(constraintsToRelationships(schema.tables))

  const tablesWithRelationships = new Set<string>()
  const sourceColumns = new Map<string, string>()
  const tableColumnCardinalities = new Map<
    string,
    Record<string, Cardinality>
  >()
  for (const relationship of relationships) {
    tablesWithRelationships.add(relationship.primaryTableName)
    tablesWithRelationships.add(relationship.foreignTableName)
    sourceColumns.set(
      relationship.primaryTableName,
      relationship.primaryColumnName,
    )
    tableColumnCardinalities.set(relationship.foreignTableName, {
      ...tableColumnCardinalities.get(relationship.foreignTableName),
      [relationship.foreignColumnName]: relationship.cardinality,
    })
  }

  // Create table nodes and check if any need NON_RELATED_TABLE_GROUP_NODE_ID as parent
  let hasNonRelatedTables = false
  const tableNodes = tables.map((table) => {
    const isNonRelatedTable = !tablesWithRelationships.has(table.name)

    if (isNonRelatedTable) {
      hasNonRelatedTables = true
    }

    return {
      id: table.name,
      type: 'table',
      data: {
        table,
        sourceColumnName: sourceColumns.get(table.name),
        targetColumnCardinalities: tableColumnCardinalities.get(table.name),
      },
      position: { x: 0, y: 0 },
      ariaLabel: `${table.name} table`,
      zIndex: zIndex.nodeDefault,
      ...(isNonRelatedTable
        ? { parentId: NON_RELATED_TABLE_GROUP_NODE_ID }
        : {}),
    }
  })

  // Only include NON_RELATED_TABLE_GROUP_NODE_ID if there are tables that need it
  const nodes: Node[] = [
    ...(hasNonRelatedTables
      ? [
          {
            id: NON_RELATED_TABLE_GROUP_NODE_ID,
            type: 'nonRelatedTableGroup',
            data: {},
            position: { x: 0, y: 0 },
          },
        ]
      : []),
    ...tableNodes,
  ]

  const edges: Edge[] = relationships.map((rel) => ({
    id: rel.name,
    type: 'relationship',
    source: rel.primaryTableName,
    target: rel.foreignTableName,
    sourceHandle:
      showMode === 'TABLE_NAME'
        ? null
        : columnHandleId(rel.primaryTableName, rel.primaryColumnName),
    targetHandle:
      showMode === 'TABLE_NAME'
        ? null
        : columnHandleId(rel.foreignTableName, rel.foreignColumnName),
    data: {
      relationship: rel,
      cardinality: rel.cardinality,
    },
  }))

  // Convert Woods nodes to React Flow nodes
  if (schema.nodes) {
    // Map woods node type to layer key
    const WOODS_TYPE_TO_LAYER: Record<string, NodeLayer> = {
      controller: 'controllers',
      job: 'jobs',
      service: 'services',
      mailer: 'mailers',
    }

    for (const [id, woodsNode] of Object.entries(schema.nodes)) {
      // Skip nodes whose layer is disabled (lazy creation)
      if (nodeLayers) {
        const layerKey = WOODS_TYPE_TO_LAYER[woodsNode.type]
        if (layerKey && !nodeLayers[layerKey]) continue
      }

      nodes.push({
        id: `woods-${id}`,
        type: 'woodsNode',
        position: { x: 0, y: 0 },
        data: {
          name: woodsNode.name,
          type: woodsNode.type,
          members: woodsNode.members,
          meta: woodsNode.meta,
        },
        zIndex: zIndex.nodeDefault,
      })
    }

    // Convert dependencies to React Flow edges (skip disabled layers)
    for (const [id, woodsNode] of Object.entries(schema.nodes)) {
      if (nodeLayers) {
        const layerKey = WOODS_TYPE_TO_LAYER[woodsNode.type]
        if (layerKey && !nodeLayers[layerKey]) continue
      }
      for (const dep of woodsNode.dependencies) {
        // Table targets use table name directly (matches table node IDs)
        // Non-table targets use woods- prefix
        const targetId =
          dep.target_type === 'table' ? dep.target : `woods-${dep.target}`
        edges.push({
          id: `dep-${id}-${dep.target}-${dep.via}`,
          source: `woods-${id}`,
          target: targetId,
          type: 'relationship',
          data: {
            via: dep.via,
            sourceNodeType: woodsNode.type,
          },
        })
      }
    }
  }

  // Identify disconnected woods nodes (no edges at all)
  const connectedNodeIds = new Set<string>()
  for (const edge of edges) {
    connectedNodeIds.add(edge.source)
    connectedNodeIds.add(edge.target)
  }

  const WOODS_DISCONNECTED_GROUP_ID = 'woods-disconnected-group'
  let hasDisconnectedWoods = false

  for (const node of nodes) {
    if (node.type === 'woodsNode' && !connectedNodeIds.has(node.id)) {
      node.parentId = WOODS_DISCONNECTED_GROUP_ID
      hasDisconnectedWoods = true
    }
  }

  if (hasDisconnectedWoods) {
    // Insert group node BEFORE its children — convertNodesToElkNodes requires
    // parent nodes to appear first in the array (it builds a nodeMap linearly).
    const groupNodeIndex = nodes.findIndex(
      (n) => n.parentId === WOODS_DISCONNECTED_GROUP_ID,
    )
    nodes.splice(groupNodeIndex, 0, {
      id: WOODS_DISCONNECTED_GROUP_ID,
      type: 'nonRelatedTableGroup',
      data: {},
      position: { x: 0, y: 0 },
    })
  }

  return { nodes, edges }
}
