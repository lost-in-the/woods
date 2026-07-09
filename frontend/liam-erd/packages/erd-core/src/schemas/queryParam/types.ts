import type { InferOutput } from 'valibot'
import type { queryParamSchema } from './schemas'

export type QueryParam = InferOutput<typeof queryParamSchema>
