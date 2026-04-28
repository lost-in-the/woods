import type { InferOutput } from 'valibot'
import type { showModeSchema } from './schemas'

export type ShowMode = InferOutput<typeof showModeSchema>
