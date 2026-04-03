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

  let { onNodeSelect } = $props();

  let nodes = $state.raw([]);
  let edges = $state.raw([]);
  let loading = $state(true);
  let error = $state(null);

  const nodeTypes = { woods: WoodsNode };

  async function load() {
    loading = true;
    error = null;
    try {
      const data = await fetchJSON('graph');
      const rawNodes = (data.nodes || []).map((n) => ({
        ...n,
        type: 'woods',
        position: n.position || { x: 0, y: 0 },
      }));
      const rawEdges = (data.edges || []).map((e) => ({
        ...e,
        style: e.data?.isCycle
          ? 'stroke: #ef4444; stroke-width: 2px'
          : undefined,
        animated: e.data?.isCycle || e.animated || false,
      }));

      const laid = getLayoutedElements(rawNodes, rawEdges, 'TB');
      nodes = laid.nodes;
      edges = laid.edges;
    } catch (e) {
      error = e.message;
    }
    loading = false;
  }

  function handleNodeClick(_event, node) {
    onNodeSelect?.(node);
  }

  load();
</script>

<div class="flow-container">
  {#if loading}
    <div class="loading-overlay">Loading graph...</div>
  {:else if error}
    <div class="error-overlay">
      <div>Error loading graph</div>
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
