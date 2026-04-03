<script>
  import {
    SvelteFlow,
    Controls,
    MiniMap,
    Background,
  } from '@xyflow/svelte';
  import { fetchJSON } from '../lib/api.js';
  import { getLayoutedElements } from '../lib/layout.js';
  import WoodsNode from './WoodsNode.svelte';

  let { onNodeSelect, onClusterData } = $props();

  let nodes = $state.raw([]);
  let edges = $state.raw([]);
  let loading = $state(true);
  let error = $state(null);

  const nodeTypes = { woods: WoodsNode };

  async function load() {
    loading = true;
    error = null;
    try {
      const data = await fetchJSON('clusters');
      const rawNodes = (data.nodes || []).map((n) => ({
        ...n,
        type: 'woods',
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

      const laid = getLayoutedElements(rawNodes, rawEdges, 'TB');
      nodes = laid.nodes;
      edges = laid.edges;
      onClusterData?.(data.clusters || []);
    } catch (e) {
      error = e.message;
    }
    loading = false;
  }

  function handleNodeClick({ node }) {
    onNodeSelect?.(node);
  }

  load();
</script>

<div class="flow-container">
  {#if loading}
    <div class="loading-overlay">Loading clusters...</div>
  {:else if error}
    <div class="error-overlay">
      <div>Error loading clusters</div>
      <div style="font-size:12px;color:#94a3b8">{error}</div>
    </div>
  {:else}
    <SvelteFlow
      bind:nodes
      bind:edges
      {nodeTypes}
      onnodeclick={handleNodeClick}
      fitView
      minZoom={0.05}
      maxZoom={2}
    >
      <Controls />
      <MiniMap />
      <Background />
    </SvelteFlow>
  {/if}
</div>
