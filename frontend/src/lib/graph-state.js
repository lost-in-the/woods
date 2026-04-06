/**
 * Graph state management for the bidirectional column explorer.
 *
 * Edge convention: source → target means "source depends on target".
 * So forward edges (source = nodeId) point to dependencies (LEFT columns),
 * and reverse edges (target = nodeId) point to dependents (RIGHT columns).
 *
 * Visual layout:
 *   ← Dependencies (parents)  |  Center  |  Dependents (children) →
 *   things center depends on  |          |  things that depend on center
 */

const MAX_INITIAL_NEIGHBORS = 20;

/**
 * Get the forward dependencies of a node, grouped by relationship type.
 * @param {string} nodeId
 * @param {Array} allNodes - Svelte Flow node objects (with data.columns, etc.)
 * @param {Array} allEdges - Svelte Flow edge objects
 * @returns {Object} { 'has_many': ['Order', 'Product', ...], 'has_one': [...], ... }
 */
export function getGroupedDependencies(nodeId, allNodes, allEdges) {
  const groups = {};

  for (const edge of allEdges) {
    if (edge.source !== nodeId) continue;

    const via = edge.data?.via || 'dependency';
    if (!groups[via]) groups[via] = [];
    groups[via].push(edge.target);
  }

  return groups;
}

/**
 * Get the reverse dependencies of a node (things that depend on it), grouped by type.
 * @param {string} nodeId
 * @param {Array} allNodes
 * @param {Array} allEdges
 * @returns {Object} { 'belongs_to': ['Plan', 'Country'], ... }
 */
export function getGroupedDependents(nodeId, allNodes, allEdges) {
  const groups = {};

  for (const edge of allEdges) {
    if (edge.target !== nodeId) continue;

    const via = edge.data?.via || 'dependency';
    if (!groups[via]) groups[via] = [];
    groups[via].push(edge.source);
  }

  return groups;
}

/**
 * Pick the top N neighbors by PageRank from a list of node IDs.
 * @param {Array<string>} neighborIds
 * @param {Map<string, Object>} nodeMap - id => node
 * @param {number} max
 * @returns {Array<string>}
 */
function topByPageRank(neighborIds, nodeMap, max) {
  return neighborIds
    .map((id) => ({ id, rank: nodeMap.get(id)?.data?.pagerank || 0 }))
    .sort((a, b) => b.rank - a.rank)
    .slice(0, max)
    .map((x) => x.id);
}

/**
 * Compute the set of visible node IDs based on center node and expanded branches.
 *
 * Initial view: center + top N neighbors per direction (by PageRank).
 * Expanded branches add more nodes beyond the initial set.
 *
 * @param {string} centerNodeId
 * @param {Map<string, Set<string>>} expandedBranches - nodeId => Set('left'|'right')
 * @param {Array} allNodes
 * @param {Array} allEdges
 * @param {Set<string>} hiddenNodeIds - explicitly hidden nodes
 * @returns {Set<string>}
 */
export function computeVisibleNodes(centerNodeId, expandedBranches, allNodes, allEdges, hiddenNodeIds) {
  if (!centerNodeId) return new Set();

  const nodeMap = new Map(allNodes.map((n) => [n.id, n]));
  const visible = new Set([centerNodeId]);

  // Depth 1: direct neighbors of center, limited to top N per direction
  // Left = dependencies (things center depends on): edge.source === center
  const leftNeighbors = [];
  // Right = dependents (things that depend on center): edge.target === center
  const rightNeighbors = [];

  for (const edge of allEdges) {
    if (edge.source === centerNodeId) leftNeighbors.push(edge.target);
    if (edge.target === centerNodeId) rightNeighbors.push(edge.source);
  }

  for (const id of topByPageRank(leftNeighbors, nodeMap, MAX_INITIAL_NEIGHBORS)) {
    visible.add(id);
  }
  for (const id of topByPageRank(rightNeighbors, nodeMap, MAX_INITIAL_NEIGHBORS)) {
    visible.add(id);
  }

  // Expanded branches: for each expanded node, add its neighbors in the expanded direction
  // "left" expansion = show more dependencies (forward edges from this node)
  // "right" expansion = show more dependents (reverse edges to this node)
  for (const [nodeId, directions] of expandedBranches) {
    if (!visible.has(nodeId)) continue;

    if (directions.has('left')) {
      for (const edge of allEdges) {
        if (edge.source === nodeId) visible.add(edge.target);
      }
    }
    if (directions.has('right')) {
      for (const edge of allEdges) {
        if (edge.target === nodeId) visible.add(edge.source);
      }
    }
  }

  // Remove explicitly hidden nodes
  for (const id of hiddenNodeIds) {
    if (id !== centerNodeId) visible.delete(id);
  }

  return visible;
}

/**
 * Recursively expand all descendants from a node (for alt+click).
 * @param {string} startNodeId
 * @param {'left'|'right'} direction
 * @param {Array} allEdges
 * @param {number} maxDepth
 * @returns {Map<string, Set<string>>} new branches to add
 */
export function expandRecursive(startNodeId, direction, allEdges, maxDepth = 5) {
  const newBranches = new Map();
  const visited = new Set([startNodeId]);
  let frontier = [startNodeId];

  for (let d = 0; d < maxDepth; d++) {
    const nextFrontier = [];
    for (const nodeId of frontier) {
      const neighbors = [];

      if (direction === 'left') {
        // Left = dependencies: forward edges from this node
        for (const edge of allEdges) {
          if (edge.source === nodeId && !visited.has(edge.target)) {
            visited.add(edge.target);
            neighbors.push(edge.target);
          }
        }
      } else {
        // Right = dependents: reverse edges to this node
        for (const edge of allEdges) {
          if (edge.target === nodeId && !visited.has(edge.source)) {
            visited.add(edge.source);
            neighbors.push(edge.source);
          }
        }
      }

      if (neighbors.length > 0) {
        if (!newBranches.has(nodeId)) newBranches.set(nodeId, new Set());
        newBranches.get(nodeId).add(direction);
        nextFrontier.push(...neighbors);
      }
    }
    frontier = nextFrontier;
    if (frontier.length === 0) break;
  }

  return newBranches;
}

/**
 * Determine which column (depth level) each visible node belongs to.
 *
 * Center = 0.
 * Dependencies (forward edges, things center depends on) = negative columns (LEFT).
 * Dependents (reverse edges, things that depend on center) = positive columns (RIGHT).
 *
 * @param {string} centerNodeId
 * @param {Set<string>} visibleNodeIds
 * @param {Array} allEdges
 * @param {Map<string, Set<string>>} expandedBranches
 * @returns {Map<string, number>} nodeId => column index
 */
export function assignColumns(centerNodeId, visibleNodeIds, allEdges, expandedBranches) {
  const columns = new Map();
  columns.set(centerNodeId, 0);

  const visited = new Set([centerNodeId]);
  const queue = [{ id: centerNodeId, col: 0 }];

  while (queue.length > 0) {
    const { id, col } = queue.shift();

    // Forward edges (source = id): dependencies go LEFT (negative columns)
    for (const edge of allEdges) {
      if (edge.source === id && visibleNodeIds.has(edge.target) && !visited.has(edge.target)) {
        visited.add(edge.target);
        const nextCol = col - 1;
        columns.set(edge.target, nextCol);
        queue.push({ id: edge.target, col: nextCol });
      }
    }

    // Reverse edges (target = id): dependents go RIGHT (positive columns)
    for (const edge of allEdges) {
      if (edge.target === id && visibleNodeIds.has(edge.source) && !visited.has(edge.source)) {
        visited.add(edge.source);
        const nextCol = col + 1;
        columns.set(edge.source, nextCol);
        queue.push({ id: edge.source, col: nextCol });
      }
    }
  }

  return columns;
}

/**
 * Check if a node has further dependencies in a given direction.
 * Used to decide whether to show the expand button.
 * @param {string} nodeId
 * @param {'left'|'right'} direction
 * @param {Array} allEdges
 * @param {Set<string>} visibleNodeIds - nodes already visible
 * @returns {boolean}
 */
export function hasMoreInDirection(nodeId, direction, allEdges, visibleNodeIds) {
  if (direction === 'left') {
    // Left = more dependencies (forward edges from this node not yet visible)
    return allEdges.some((e) => e.source === nodeId && !visibleNodeIds.has(e.target));
  }
  // Right = more dependents (reverse edges to this node not yet visible)
  return allEdges.some((e) => e.target === nodeId && !visibleNodeIds.has(e.source));
}
