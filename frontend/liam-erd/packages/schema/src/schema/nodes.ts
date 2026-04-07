import * as v from 'valibot'

// --- Node member (simplified row — name only, no type/null badges) ---
export const woodsNodeMemberSchema = v.object({
  name: v.string(),
})
export type WoodsNodeMember = v.InferOutput<typeof woodsNodeMemberSchema>

// --- Node dependency (edge to another node or table) ---
export const woodsNodeDependencySchema = v.object({
  target: v.string(),
  target_type: v.string(),
  via: v.string(),
})
export type WoodsNodeDependency = v.InferOutput<typeof woodsNodeDependencySchema>

// --- Node type enum ---
export const woodsNodeTypeSchema = v.picklist([
  'controller',
  'job',
  'service',
  'mailer',
])
export type WoodsNodeType = v.InferOutput<typeof woodsNodeTypeSchema>

// --- A single Woods node ---
export const woodsNodeSchema = v.object({
  name: v.string(),
  type: woodsNodeTypeSchema,
  members: v.array(woodsNodeMemberSchema),
  meta: v.record(v.string(), v.unknown()),
  dependencies: v.array(woodsNodeDependencySchema),
})
export type WoodsNode = v.InferOutput<typeof woodsNodeSchema>

// --- Record of nodes keyed by identifier ---
export const woodsNodesSchema = v.record(v.string(), woodsNodeSchema)
export type WoodsNodes = v.InferOutput<typeof woodsNodesSchema>
