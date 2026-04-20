const basePath =
  document.querySelector('meta[name="woods-base-path"]')?.content || '';

export async function fetchJSON(endpoint) {
  const res = await fetch(`${basePath}/api/${endpoint}`);
  if (!res.ok) throw new Error(`${res.status} ${res.statusText}`);
  return res.json();
}

/**
 * Fetch a node's neighborhood subgraph at a given depth.
 * @param {string} nodeId - The node identifier to center on
 * @param {number} [depth=1] - How many hops from the center
 * @returns {Promise<{nodes: Array, edges: Array, highest_pagerank: string}>}
 */
export async function fetchNeighbors(nodeId, depth = 1) {
  const params = new URLSearchParams({ node: nodeId, depth: String(depth) });
  return fetchJSON(`graph/neighbors?${params}`);
}

/**
 * Fetch the full dependency graph (for background caching).
 * @returns {Promise<{nodes: Array, edges: Array}>}
 */
export async function fetchFullGraph() {
  return fetchJSON('graph');
}
