<script>
  import {
    SvelteFlow,
    Controls,
    MiniMap,
    Background,
  } from '@xyflow/svelte';
  import { fetchJSON, safeKey } from '../lib/api.js';
  import WoodsNode from './WoodsNode.svelte';

  let { onNodeSelect } = $props();

  let nodes = $state.raw([]);
  let edges = $state.raw([]);
  let flowIndex = $state({});
  let selectedFlow = $state(null);
  let loading = $state(true);
  let error = $state(null);

  const nodeTypes = { woods: WoodsNode, flow_step: WoodsNode };

  async function loadIndex() {
    loading = true;
    error = null;
    try {
      flowIndex = await fetchJSON('flows');
      const keys = Object.keys(flowIndex);
      if (keys.length > 0) {
        await loadFlow(keys[0]);
      } else {
        nodes = [];
        edges = [];
        loading = false;
      }
    } catch (e) {
      error = e.message;
      loading = false;
    }
  }

  async function loadFlow(entryPoint) {
    selectedFlow = entryPoint;
    loading = true;
    error = null;
    try {
      const data = await fetchJSON(`flows/${safeKey(entryPoint)}`);
      nodes = (data.nodes || []).map((n) => ({
        ...n,
        type: 'woods',
        position: n.position || { x: 0, y: 0 },
        sourcePosition: 'bottom',
        targetPosition: 'top',
      }));
      edges = (data.edges || []).map((e) => ({
        ...e,
        type: e.type || 'smoothstep',
      }));
    } catch (e) {
      error = e.message;
    }
    loading = false;
  }

  function handleFlowChange(event) {
    loadFlow(event.target.value);
  }

  function handleNodeClick(_event, node) {
    onNodeSelect?.(node);
  }

  loadIndex();
</script>

{#if Object.keys(flowIndex).length > 0}
  <div class="flow-selector">
    <select onchange={handleFlowChange}>
      {#each Object.keys(flowIndex) as ep}
        <option value={ep} selected={ep === selectedFlow}>{ep}</option>
      {/each}
    </select>
  </div>
{/if}

<div class="flow-container">
  {#if loading}
    <div class="loading-overlay">Loading flow...</div>
  {:else if error}
    <div class="error-overlay">
      <div>Error loading flow</div>
      <div style="font-size:12px;color:#94a3b8">{error}</div>
    </div>
  {:else if nodes.length === 0}
    <div class="loading-overlay">No flows available. Enable precompute_flows in Woods config.</div>
  {:else}
    <SvelteFlow
      bind:nodes
      bind:edges
      {nodeTypes}
      onnodeclick={handleNodeClick}
      fitView
      minZoom={0.1}
      maxZoom={2}
    >
      <Controls />
      <Background />
    </SvelteFlow>
  {/if}
</div>
