<script>
  import GraphView from './components/GraphView.svelte';
  import ClusterView from './components/ClusterView.svelte';
  import NodeDetail from './components/NodeDetail.svelte';
  import Sidebar from './components/Sidebar.svelte';
  import { fetchJSON } from './lib/api.js';

  let activeTab = $state('graph');
  let activeNodeId = $state(null);
  let visibleNodeIds = $state(new Set());
  let filterText = $state('');
  let collapsedTypes = $state(new Set());

  let allNodes = $state.raw([]);
  let allEdges = $state.raw([]);
  let clusterNodes = $state.raw([]);
  let clusterEdges = $state.raw([]);
  let clusters = $state.raw([]);
  let loading = $state(true);
  let focusNodeId = $state(null);

  // Bidirectional adjacency set for the active node
  const adjacencySet = $derived.by(() => {
    if (!activeNodeId) return new Set();
    const currentEdges = activeTab === 'clusters' ? clusterEdges : allEdges;
    const neighbors = new Set();
    for (const e of currentEdges) {
      if (e.source === activeNodeId) neighbors.add(e.target);
      if (e.target === activeNodeId) neighbors.add(e.source);
    }
    return neighbors;
  });

  // Nodes filtered by visibility, with highlight flags
  const visibleNodes = $derived.by(() => {
    const sourceNodes = activeTab === 'clusters' ? clusterNodes : allNodes;
    return sourceNodes
      .filter((n) => visibleNodeIds.has(n.id))
      .map((n) => {
        if (!activeNodeId) {
          return { ...n, data: { ...n.data, isActive: undefined, isHighlighted: undefined } };
        }
        const isActive = n.id === activeNodeId;
        const isHighlighted = adjacencySet.has(n.id);
        return {
          ...n,
          data: { ...n.data, isActive, isHighlighted },
        };
      });
  });

  // Edges filtered to visible endpoints, with highlight styling
  const visibleEdges = $derived.by(() => {
    const sourceEdges = activeTab === 'clusters' ? clusterEdges : allEdges;
    return sourceEdges
      .filter((e) => visibleNodeIds.has(e.source) && visibleNodeIds.has(e.target))
      .map((e) => {
        if (!activeNodeId) return e;
        const connected =
          e.source === activeNodeId || e.target === activeNodeId;
        return {
          ...e,
          style: connected
            ? 'stroke: #22c55e; stroke-width: 2px'
            : 'opacity: 0.3',
          zIndex: connected ? 10 : 0,
        };
      });
  });

  // Full node object for the detail panel
  const selectedNode = $derived.by(() => {
    if (!activeNodeId) return null;
    const sourceNodes = activeTab === 'clusters' ? clusterNodes : allNodes;
    return sourceNodes.find((n) => n.id === activeNodeId) || null;
  });

  function initCollapsedTypes(nodes) {
    const types = [...new Set(nodes.map((n) => n.data?.unitType || 'default'))];
    const TYPE_SORT_ORDER = [
      'model', 'controller', 'job', 'service', 'mailer', 'concern',
    ];
    types.sort((a, b) => {
      const ai = TYPE_SORT_ORDER.indexOf(a);
      const bi = TYPE_SORT_ORDER.indexOf(b);
      if (ai !== -1 && bi !== -1) return ai - bi;
      if (ai !== -1) return -1;
      if (bi !== -1) return 1;
      return a.localeCompare(b);
    });
    // Collapse all except the first type
    const collapsed = new Set(types.slice(1));
    collapsedTypes = collapsed;
  }

  async function loadGraphData() {
    loading = true;
    try {
      const data = await fetchJSON('graph');
      const rawNodes = (data.nodes || []).map((n) => ({
        ...n,
        type: n.data?.unitType === 'model' ? 'model' : 'compact',
        position: n.position || { x: 0, y: 0 },
      }));
      const rawEdges = (data.edges || []).map((e) => ({
        ...e,
        style: e.data?.isCycle
          ? 'stroke: #ef4444; stroke-width: 2px'
          : undefined,
        animated: e.data?.isCycle || e.animated || false,
      }));
      allNodes = rawNodes;
      allEdges = rawEdges;
      visibleNodeIds = new Set(rawNodes.map((n) => n.id));
      initCollapsedTypes(rawNodes);
    } catch (e) {
      console.error('Failed to load graph data:', e);
    }
    loading = false;
  }

  async function loadClusterData() {
    loading = true;
    try {
      const data = await fetchJSON('clusters');
      const rawNodes = (data.nodes || []).map((n) => ({
        ...n,
        type: n.data?.unitType === 'model' ? 'model' : 'compact',
        position: n.position || { x: 0, y: 0 },
      }));
      const rawEdges = (data.edges || []).map((e) => ({
        ...e,
        animated: e.data?.relationship === 'boundary' || e.animated || false,
        style:
          e.data?.relationship === 'boundary'
            ? 'stroke: #22d3ee; stroke-dasharray: 5 5'
            : undefined,
      }));
      clusterNodes = rawNodes;
      clusterEdges = rawEdges;
      clusters = data.clusters || [];
      visibleNodeIds = new Set(rawNodes.map((n) => n.id));
      initCollapsedTypes(rawNodes);
    } catch (e) {
      console.error('Failed to load cluster data:', e);
    }
    loading = false;
  }

  function switchTab(tab) {
    if (activeTab === tab) return;
    activeTab = tab;
    activeNodeId = null;
    filterText = '';
    if (tab === 'graph' && allNodes.length === 0) {
      loadGraphData();
    } else if (tab === 'clusters' && clusterNodes.length === 0) {
      loadClusterData();
    } else {
      // Re-init visibleNodeIds for the new tab's data
      const sourceNodes = tab === 'clusters' ? clusterNodes : allNodes;
      visibleNodeIds = new Set(sourceNodes.map((n) => n.id));
    }
  }

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
    activeNodeId = id;
    // Bump focusNodeId to trigger pan — use a fresh object to re-trigger even for the same id
    focusNodeId = id;
  }

  function handleToggleVisibility(id) {
    const next = new Set(visibleNodeIds);
    if (next.has(id)) {
      next.delete(id);
      // If we're hiding the active node, deselect it
      if (activeNodeId === id) activeNodeId = null;
    } else {
      next.add(id);
    }
    visibleNodeIds = next;
  }

  function handleFocusUnit(id) {
    // Show only the selected node + its direct neighbors
    const neighbors = new Set([id]);
    const sourceEdges = activeTab === 'clusters' ? clusterEdges : allEdges;
    for (const e of sourceEdges) {
      if (e.source === id) neighbors.add(e.target);
      if (e.target === id) neighbors.add(e.source);
    }
    visibleNodeIds = neighbors;
    activeNodeId = id;
  }

  function handleToggleCollapse(type) {
    const next = new Set(collapsedTypes);
    if (next.has(type)) {
      next.delete(type);
    } else {
      next.add(type);
    }
    collapsedTypes = next;
  }

  function handleShowAll() {
    const sourceNodes = activeTab === 'clusters' ? clusterNodes : allNodes;
    visibleNodeIds = new Set(sourceNodes.map((n) => n.id));
  }

  function handleHideAll() {
    visibleNodeIds = new Set();
    activeNodeId = null;
  }

  const sidebarNodes = $derived(
    activeTab === 'clusters' ? clusterNodes : allNodes
  );

  // Initial load
  loadGraphData();
</script>

<div class="header">
  <h1>Woods <span>Visualize</span></h1>
  <div class="tabs">
    <button
      class="tab"
      class:active={activeTab === 'graph'}
      onclick={() => switchTab('graph')}
    >
      Dependencies
    </button>
    <button
      class="tab"
      class:active={activeTab === 'clusters'}
      onclick={() => switchTab('clusters')}
    >
      Clusters
    </button>
  </div>
</div>

<Sidebar
  allNodes={sidebarNodes}
  {activeNodeId}
  {visibleNodeIds}
  bind:filterText
  {collapsedTypes}
  onSelectUnit={handleSelectUnit}
  onToggleVisibility={handleToggleVisibility}
  onFocusUnit={handleFocusUnit}
  onToggleCollapse={handleToggleCollapse}
  onShowAll={handleShowAll}
  onHideAll={handleHideAll}
/>

<div class="main-content">
  {#if activeTab === 'graph'}
    <GraphView
      nodes={visibleNodes}
      edges={visibleEdges}
      {loading}
      {focusNodeId}
      onNodeSelect={handleNodeSelect}
      onCanvasClick={handleCanvasClick}
    />
  {:else if activeTab === 'clusters'}
    <ClusterView
      nodes={visibleNodes}
      edges={visibleEdges}
      {loading}
      {focusNodeId}
      onNodeSelect={handleNodeSelect}
      onCanvasClick={handleCanvasClick}
    />
  {/if}

  <NodeDetail node={selectedNode} onClose={handleCloseDetail} />
</div>

<div class="stats-bar">
  <div class="stat">
    Visible: <span class="stat-value">{visibleNodeIds.size}</span> / {sidebarNodes.length}
  </div>
  {#if activeTab === 'clusters' && clusters.length > 0}
    <div class="stat">
      Clusters: <span class="stat-value">{clusters.length}</span>
    </div>
  {/if}
</div>

<style>
  .main-content {
    position: relative;
    overflow: hidden;
    display: flex;
    flex-direction: column;
  }
</style>
