<script>
  import {
    SvelteFlow,
    Controls,
    MiniMap,
    Background,
  } from '@xyflow/svelte';
  import { getLayoutedElements } from '../lib/layout.js';
  import ModelNode from './ModelNode.svelte';
  import CompactNode from './CompactNode.svelte';

  let { nodes, edges, loading, onNodeSelect, onCanvasClick } = $props();

  let layoutedNodes = $state.raw([]);
  let layoutedEdges = $state.raw([]);

  const nodeTypes = { model: ModelNode, compact: CompactNode };

  const layout = $derived.by(() => {
    if (!nodes || nodes.length === 0) return { nodes: [], edges: [] };
    return getLayoutedElements(nodes, edges, 'TB');
  });

  $effect(() => {
    layoutedNodes = layout.nodes;
    layoutedEdges = layout.edges;
  });

  function handleNodeClick({ node }) {
    onNodeSelect?.(node);
  }

  function handlePaneClick() {
    onCanvasClick?.();
  }
</script>

<div class="flow-container">
  {#if loading}
    <div class="loading-overlay">Loading clusters...</div>
  {:else}
    <SvelteFlow
      bind:nodes={layoutedNodes}
      bind:edges={layoutedEdges}
      {nodeTypes}
      onnodeclick={handleNodeClick}
      onpaneclick={handlePaneClick}
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
