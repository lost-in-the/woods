import type {
  Cardinality,
  Table,
  WoodsNodeMember,
  WoodsNodeType as WoodsNodeTypeEnum,
} from '@liam-hq/schema'
import type { Node } from '@xyflow/react'
import type { ShowMode } from '@/schemas/showMode/types'

export type TableNodeData = {
  table: Table
  isActiveHighlighted: boolean
  isHighlighted: boolean
  isTooltipVisible: boolean
  sourceColumnName: string | undefined
  targetColumnCardinalities?:
    | Record<string, Cardinality | undefined>
    | undefined
  showMode?: ShowMode | undefined
}

export type TableNodeType = Node<TableNodeData, 'table'>

export type WoodsNodeData = {
  name: string
  type: WoodsNodeTypeEnum
  members: WoodsNodeMember[]
  meta: Record<string, unknown>
  isHighlighted?: boolean
  isActiveHighlighted?: boolean
}

export type WoodsNodeType = Node<WoodsNodeData, 'woodsNode'>

export type DisplayArea = 'main' | 'relatedTables'
