import { err, ok, type Result } from 'neverthrow'
import * as v from 'valibot'

export function fromValibotSafeParse<
  TSchema extends v.BaseSchema<unknown, unknown, v.BaseIssue<unknown>>,
>(schema: TSchema, data: unknown): Result<v.InferOutput<TSchema>, Error> {
  const result = v.safeParse(schema, data)

  if (result.success) {
    return ok(result.output)
  }

  const errorMessage = result.issues.map((issue) => issue.message).join(', ')
  return err(new Error(errorMessage))
}
