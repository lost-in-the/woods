const basePath =
  document.querySelector('meta[name="woods-base-path"]')?.content || '';

/**
 * Data inlined into a self-contained export (no server). When present,
 * fetch helpers return it directly instead of calling the HTTP API.
 * @returns {?{graph: Object, sources: Object}}
 */
function inlined() {
  return typeof window !== 'undefined' ? window.__WOODS_SUBGRAPH__ || null : null;
}

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
  const data = inlined();
  if (data?.graph) return data.graph;
  return fetchJSON('graph');
}

/**
 * Fetch a subgraph scoped to an explicit set of node identifiers — the
 * rendered form of an agent's query result (dependents, a flow, a search).
 * @param {Array<string>} nodeIds - Identifiers to render
 * @param {Object} [opts]
 * @param {number} [opts.depth=0] - Extra BFS hops pulled in around the set
 * @param {Array<string>} [opts.via] - Relationship filter (e.g. ['belongs_to'])
 * @returns {Promise<{nodes: Array, edges: Array, requested: Array, dropped: Array}>}
 */
export async function fetchSubgraph(nodeIds, { depth = 0, via = [] } = {}) {
  const data = inlined();
  if (data?.graph) return data.graph;
  const params = new URLSearchParams({ nodes: nodeIds.join(','), depth: String(depth) });
  if (via.length > 0) params.set('via', via.join(','));
  return fetchJSON(`subgraph?${params}`);
}

/**
 * Fetch a unit's source code and file links for the detail pane.
 * @param {string} identifier
 * @returns {Promise<{identifier: string, filePath: string, sourceCode: string, blobUrl: ?string}>}
 */
export async function fetchUnitSource(identifier) {
  const data = inlined();
  if (data?.sources) return data.sources[identifier] || { identifier, sourceCode: null };
  return fetchJSON(`unit/${encodeURIComponent(identifier)}/source`);
}
