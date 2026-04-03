<script>
  import GraphView from './components/GraphView.svelte';
  import FlowView from './components/FlowView.svelte';
  import ClusterView from './components/ClusterView.svelte';
  import NodeDetail from './components/NodeDetail.svelte';

  let activeTab = $state('graph');
  let selectedNode = $state(null);
  let clusters = $state([]);

  function switchTab(tab) {
    if (activeTab === tab) return;
    activeTab = tab;
    selectedNode = null;
    clusters = [];
  }

  function handleNodeSelect(node) {
    selectedNode = node;
  }

  function handleCloseDetail() {
    selectedNode = null;
  }

  function handleClusterData(data) {
    clusters = data;
  }
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
      class:active={activeTab === 'flows'}
      onclick={() => switchTab('flows')}
    >
      Flows
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

<div class="main-content">
  {#if activeTab === 'graph'}
    <GraphView onNodeSelect={handleNodeSelect} />
  {:else if activeTab === 'flows'}
    <FlowView onNodeSelect={handleNodeSelect} />
  {:else if activeTab === 'clusters'}
    <ClusterView
      onNodeSelect={handleNodeSelect}
      onClusterData={handleClusterData}
    />
  {/if}
</div>

<NodeDetail node={selectedNode} onClose={handleCloseDetail} />

<div class="stats-bar">
  {#if clusters.length > 0}
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
