import { describe, expect, it } from 'vitest'
import * as v from 'valibot'
import { schemaSchema } from './schema'

describe('schemaSchema', () => {
  const baseSchema = {
    tables: {},
    enums: {},
    extensions: {},
  }

  it('accepts a schema without entryPoints', () => {
    expect(() => v.parse(schemaSchema, baseSchema)).not.toThrow()
  })

  it('accepts a schema with an entryPoints array', () => {
    const parsed = v.parse(schemaSchema, {
      ...baseSchema,
      entryPoints: [
        { identifier: 'CheckoutController', verb: 'GET', path: '/checkout', action: 'new' },
      ],
    })
    const first = parsed.entryPoints?.[0]
    expect(first?.identifier).toBe('CheckoutController')
  })

  it('rejects non-GET entry points', () => {
    expect(() =>
      v.parse(schemaSchema, {
        ...baseSchema,
        entryPoints: [
          { identifier: 'X', verb: 'POST', path: '/x', action: 'create' },
        ],
      }),
    ).toThrow()
  })

  it('preserves entryPoints through safeParse with backend-shaped input', () => {
    const raw = {
      ...baseSchema,
      entryPoints: [
        { identifier: 'StaticPagesController', verb: 'GET', path: '/contact', action: 'contact' },
      ],
    }
    const result = v.safeParse(schemaSchema, raw)
    expect(result.success).toBe(true)
    if (result.success) {
      expect(result.output.entryPoints).toHaveLength(1)
      expect(result.output.entryPoints?.[0]?.identifier).toBe('StaticPagesController')
    }
  })
})
