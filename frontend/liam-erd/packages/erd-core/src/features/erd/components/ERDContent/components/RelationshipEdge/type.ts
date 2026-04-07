import type { Cardinality } from '@liam-hq/schema'
import type { Edge } from '@xyflow/react'

type Data = {
  isHighlighted: boolean
  isHoverHighlighted: boolean
  cardinality: Cardinality
}

export type RelationshipEdgeType = Edge<Data, 'relationship'>
