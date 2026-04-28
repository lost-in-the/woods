import { describe, expect, it } from 'vitest'
import { walk, type WalkableSchema } from './walker'

const schema: WalkableSchema = {
  nodes: {
    CheckoutController: {
      dependencies: [
        { target: 'Cart', via: 'link_to' },
        { target: 'ConfirmController', via: 'redirect_to' },
      ],
    },
    ConfirmController: {
      dependencies: [{ target: 'OrderCreator', via: 'form_action' }],
    },
    Cart: { dependencies: [] },
    OrderCreator: {
      dependencies: [{ target: 'CheckoutController', via: 'redirect_to' }],
    },
  },
}

describe('walk', () => {
  it('returns only the entry node when maxDepth is 0', () => {
    const result = walk(schema, 'CheckoutController', { maxDepth: 0 })
    expect([...result.nodes.keys()]).toEqual(['CheckoutController'])
    expect(result.truncated).toBe(true)
  })

  it('performs BFS to leaves', () => {
    const result = walk(schema, 'CheckoutController', { maxDepth: 10 })
    expect(result.nodes.get('CheckoutController')?.depth).toBe(0)
    expect(result.nodes.get('Cart')?.depth).toBe(1)
    expect(result.nodes.get('ConfirmController')?.depth).toBe(1)
    expect(result.nodes.get('OrderCreator')?.depth).toBe(2)
    expect(result.truncated).toBe(false)
  })

  it('detects cycles as back-edges without re-traversing', () => {
    const result = walk(schema, 'CheckoutController', { maxDepth: 10 })
    const backEdge = result.edges.find(
      (e) => e.from === 'OrderCreator' && e.to === 'CheckoutController',
    )
    expect(backEdge?.isBackEdge).toBe(true)
    expect(result.cycles).toContainEqual(['OrderCreator', 'CheckoutController'])
    expect(result.nodes.get('CheckoutController')?.depth).toBe(0)
  })

  it('filters edges by edgeTypes', () => {
    const result = walk(schema, 'CheckoutController', {
      maxDepth: 10,
      edgeTypes: new Set(['link_to']),
    })
    expect([...result.nodes.keys()].sort()).toEqual(['Cart', 'CheckoutController'])
  })

  it('stops expanding at maxDepth and flags truncated', () => {
    const result = walk(schema, 'CheckoutController', { maxDepth: 1 })
    expect(result.nodes.has('OrderCreator')).toBe(false)
    expect(result.truncated).toBe(true)
  })

  it('returns empty result for unknown entry', () => {
    const result = walk(schema, 'DoesNotExist', { maxDepth: 10 })
    expect(result.nodes.size).toBe(0)
    expect(result.edges).toEqual([])
  })
})
