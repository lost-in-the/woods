import type { InferOutput } from 'valibot'
import type { versionSchema } from './schemas'

export type Version = InferOutput<typeof versionSchema>
