<script>
  import ColumnLayout from './components/ColumnLayout.svelte';
  import NodeDetail from './components/NodeDetail.svelte';
  import Sidebar from './components/Sidebar.svelte';
  import ShowModeSelector from './components/ShowModeSelector.svelte';
  import { fetchNeighbors, fetchFullGraph, fetchSubgraph } from './lib/api.js';
  import { computeVisibleNodes, expandRecursive } from './lib/graph-state.js';

  let allNodes = $state.raw([]);
  let allEdges = $state.raw([]);
  let loading = $state(true);
  let centerNodeId = $state(null);
  let expandedBranches = $state(new Map());
  let hiddenNodeIds = $state(new Set());
  let recentNodes = $state([]);
  let activeNodeId = $state(null);
  let focusNodeId = $state(null);
  let fullGraphLoaded = $state(false);

  const SHOW_MODE_KEY = 'woods-flow-show-mode';
  let showMode = $state(localStorage.getItem(SHOW_MODE_KEY) || 'all_fields');

  function handleShowModeChange(mode) {
    showMode = mode;
    localStorage.setItem(SHOW_MODE_KEY, mode);
  }

  function getCenterFromUrl() {
    const params = new URLSearchParams(window.location.search);
    return params.get('center') || null;
  }

  // Read a query-scoped request (?nodes=A,B,C&depth=N&via=belongs_to,render) from
  // the URL. When present, the app renders just that scoped subgraph — the
  // rendered form of an agent's query — instead of the full dependency graph.
  function getQueryFromUrl() {
    const params = new URLSearchParams(window.location.search);
    const asList = (key) =>
      (params.get(key) || '').split(',').map((s) => s.trim()).filter(Boolean);
    return {
      nodes: asList('nodes'),
      depth: parseInt(params.get('depth') || '0', 10) || 0,
      via: asList('via'),
    };
  }

  function mapNodes(data) {
    return (data.nodes || []).map((n) => ({
      ...n,
      type: n.data?.unitType === 'model' ? 'model' : 'compact',
      position: n.position || { x: 0, y: 0 },
    }));
  }

  function mapEdges(data) {
    return (data.edges || []).map((e) => ({
      ...e,
      animated: e.data?.isCycle || false,
    }));
  }

  // Pick a center node: a preferred id if it's present, else highest PageRank.
  function pickCenter(nodes, preferred) {
    if (preferred && nodes.some((n) => n.id === preferred)) return preferred;
    if (nodes.length === 0) return null;
    return [...nodes].sort((a, b) => (b.data?.pagerank || 0) - (a.data?.pagerank || 0))[0].id;
  }

  function updateUrl(centerId) {
    const url = new URL(window.location.href);
    if (centerId) {
      url.searchParams.set('center', centerId);
    } else {
      url.searchParams.delete('center');
    }
    history.replaceState({}, '', url);
  }

  // Compute visible nodes from state
  const visibleNodeIds = $derived(
    computeVisibleNodes(centerNodeId, expandedBranches, allNodes, allEdges, hiddenNodeIds)
  );

  // Active node for detail panel
  const selectedNode = $derived.by(() => {
    if (!activeNodeId) return null;
    return allNodes.find((n) => n.id === activeNodeId) || null;
  });

  /**
   * Load the full dependency graph.
   */
  async function loadFullGraph() {
    loading = true;
    try {
      const data = await fetchFullGraph();
      allNodes = mapNodes(data);
      allEdges = mapEdges(data);
      fullGraphLoaded = true;

      // Auto-select highest pagerank node if no center, or restore from URL
      if (!centerNodeId && allNodes.length > 0) {
        setCenterNode(pickCenter(allNodes, getCenterFromUrl()));
      }
    } catch (e) {
      console.error('Failed to load graph:', e);
    }
    loading = false;
  }

  // Load a query-scoped subgraph: only the requested nodes (+ optional depth
  // hops / relationship filter) are present, so exploration is bounded to the
  // agent's query result.
  async function loadSubgraph({ nodes, depth, via }) {
    loading = true;
    try {
      const data = await fetchSubgraph(nodes, { depth, via });
      allNodes = mapNodes(data);
      allEdges = mapEdges(data);

      if (data.dropped?.length > 0) {
        console.warn('Subgraph: unknown nodes dropped:', data.dropped.join(', '));
      }

      if (allNodes.length > 0) {
        const preferred = getCenterFromUrl() || (data.requested || nodes)[0];
        setCenterNode(pickCenter(allNodes, preferred));
      }
    } catch (e) {
      console.error('Failed to load subgraph:', e);
    }
    loading = false;
  }

  /**
   * Set the center node and add to recent history.
   */
  function setCenterNode(id) {
    centerNodeId = id;
    activeNodeId = id;
    expandedBranches = new Map();
    focusNodeId = { id, t: Date.now() };
    updateUrl(id);

    recentNodes = [id, ...recentNodes.filter((r) => r !== id)].slice(0, 10);
  }

  // --- Event handlers ---

  function handleNodeSelect(node) {
    activeNodeId = node?.id || null;
  }

  function handleCanvasClick() {
    activeNodeId = null;
  }

  function handleCloseDetail() {
    activeNodeId = null;
  }

  function handleSelectUnit(id) {
    // Re-center on this node
    setCenterNode(id);
  }

  function handleToggleVisibility(id) {
    const next = new Set(hiddenNodeIds);
    if (next.has(id)) {
      next.delete(id);
    } else {
      next.add(id);
      if (activeNodeId === id) activeNodeId = null;
    }
    hiddenNodeIds = next;
  }

  function handleClearAll() {
    // Reset to just the center node
    expandedBranches = new Map();
    hiddenNodeIds = new Set();
  }

  function handleExpand(nodeId, direction) {
    const next = new Map(expandedBranches);
    if (!next.has(nodeId)) next.set(nodeId, new Set());
    next.get(nodeId).add(direction);
    expandedBranches = next;
  }

  function handleCollapse(nodeId, direction) {
    const next = new Map(expandedBranches);
    if (next.has(nodeId)) {
      next.get(nodeId).delete(direction);
      if (next.get(nodeId).size === 0) next.delete(nodeId);
    }
    expandedBranches = next;
  }

  function handleExpandAll(nodeId, direction) {
    const newBranches = expandRecursive(nodeId, direction, allEdges);
    const next = new Map(expandedBranches);
    for (const [id, dirs] of newBranches) {
      if (!next.has(id)) next.set(id, new Set());
      for (const d of dirs) next.get(id).add(d);
    }
    expandedBranches = next;
  }

  // Initial load: a query-scoped subgraph when ?nodes= is present, else the full graph.
  const initialQuery = getQueryFromUrl();
  if (initialQuery.nodes.length > 0) {
    loadSubgraph(initialQuery);
  } else {
    loadFullGraph();
  }
</script>

<div class="app-layout">
  <div class="header">
    <h1>Woods <span>Visualize</span></h1>
    <div class="header-controls">
      <ShowModeSelector mode={showMode} onModeChange={handleShowModeChange} />
    </div>
  </div>

  <div class="content">
    <div class="sidebar">
      <Sidebar
        {allNodes}
        {centerNodeId}
        {visibleNodeIds}
        {hiddenNodeIds}
        {recentNodes}
        onSelectUnit={handleSelectUnit}
        onToggleVisibility={handleToggleVisibility}
        onClearAll={handleClearAll}
      />
    </div>

    <div class="main-content">
      <ColumnLayout
        {allNodes}
        {allEdges}
        {visibleNodeIds}
        {centerNodeId}
        {expandedBranches}
        {loading}
        {focusNodeId}
        {showMode}
        onNodeSelect={handleNodeSelect}
        onCanvasClick={handleCanvasClick}
      />
      <NodeDetail node={selectedNode} onClose={handleCloseDetail} />
    </div>
  </div>
</div>

<style>
  .app-layout {
    display: flex;
    flex-direction: column;
    height: 100vh;
    background: #0f172a;
    color: #e2e8f0;
  }

  .header {
    display: flex;
    align-items: center;
    justify-content: space-between;
    padding: 8px 16px;
    border-bottom: 1px solid #334155;
    background: #0f172a;
  }

  .header-controls {
    display: flex;
    align-items: center;
    gap: 8px;
  }

  .header h1 {
    font-size: 14px;
    font-weight: 600;
    margin: 0;
    color: #94a3b8;
  }

  .header h1 span {
    color: #22c55e;
  }

  .content {
    display: flex;
    flex: 1;
    min-height: 0;
    overflow: hidden;
  }

  .sidebar {
    width: 240px;
    flex-shrink: 0;
    background: #1e293b;
    border-right: 1px solid #475569;
    overflow-y: auto;
  }

  .main-content {
    flex: 1;
    position: relative;
    display: flex;
    min-width: 0;
  }
</style>
