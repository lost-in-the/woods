/**
 * Graph state management for the bidirectional column explorer.
 *
 * Operates on raw graph data (nodes hash, edges adjacency list, reverse adjacency list)
 * and produces the set of visible node IDs based on center + expansions.
 */

/**
 * Get the forward dependencies of a node, grouped by relationship type.
 * @param {string} nodeId
 * @param {Array} allNodes - Svelte Flow node objects (with data.columns, etc.)
 * @param {Array} allEdges - Svelte Flow edge objects
 * @returns {Object} { 'has_many': ['Order', 'Product', ...], 'has_one': [...], ... }
 */
export function getGroupedDependencies(nodeId, allNodes, allEdges) {
  const groups = {};
  const nodeMap = new Map(allNodes.map((n) => [n.id, n]));
  const centerNode = nodeMap.get(nodeId);

  for (const edge of allEdges) {
    if (edge.source !== nodeId) continue;
    const targetNode = nodeMap.get(edge.target);
    if (!targetNode) continue;

    // Determine relationship type from edge data or association metadata
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
  const nodeMap = new Map(allNodes.map((n) => [n.id, n]));

  for (const edge of allEdges) {
    if (edge.target !== nodeId) continue;
    const sourceNode = nodeMap.get(edge.source);
    if (!sourceNode) continue;

    const via = edge.data?.via || 'dependency';
    if (!groups[via]) groups[via] = [];
    groups[via].push(edge.source);
  }

  return groups;
}

/**
 * Compute the set of visible node IDs based on center node and expanded branches.
 * @param {string} centerNodeId
 * @param {Map<string, Set<string>>} expandedBranches - nodeId => Set('left'|'right')
 * @param {Array} allNodes
 * @param {Array} allEdges
 * @param {Set<string>} hiddenNodeIds - explicitly hidden nodes
 * @returns {Set<string>}
 */
export function computeVisibleNodes(centerNodeId, expandedBranches, allNodes, allEdges, hiddenNodeIds) {
  if (!centerNodeId) return new Set();

  const visible = new Set([centerNodeId]);

  // Depth 1: direct neighbors of center
  for (const edge of allEdges) {
    if (edge.source === centerNodeId) visible.add(edge.target);
    if (edge.target === centerNodeId) visible.add(edge.source);
  }

  // Expanded branches: for each expanded node, add its neighbors in the expanded direction
  for (const [nodeId, directions] of expandedBranches) {
    if (!visible.has(nodeId)) continue; // only expand visible nodes

    if (directions.has('right')) {
      for (const edge of allEdges) {
        if (edge.source === nodeId) visible.add(edge.target);
      }
    }
    if (directions.has('left')) {
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

      if (direction === 'right') {
        for (const edge of allEdges) {
          if (edge.source === nodeId && !visited.has(edge.target)) {
            visited.add(edge.target);
            neighbors.push(edge.target);
          }
        }
      } else {
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
 * Center = 0, left neighbors = -1, right neighbors = +1, etc.
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

    // Right (forward dependencies)
    for (const edge of allEdges) {
      if (edge.source === id && visibleNodeIds.has(edge.target) && !visited.has(edge.target)) {
        visited.add(edge.target);
        const nextCol = col + 1;
        columns.set(edge.target, nextCol);
        queue.push({ id: edge.target, col: nextCol });
      }
    }

    // Left (reverse dependencies / dependents)
    for (const edge of allEdges) {
      if (edge.target === id && visibleNodeIds.has(edge.source) && !visited.has(edge.source)) {
        visited.add(edge.source);
        const nextCol = col - 1;
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
  if (direction === 'right') {
    return allEdges.some((e) => e.source === nodeId && !visibleNodeIds.has(e.target));
  }
  return allEdges.some((e) => e.target === nodeId && !visibleNodeIds.has(e.source));
}
