<script>
  import {
    SvelteFlow,
    Controls,
    MiniMap,
    Background,
  } from '@xyflow/svelte';
  import ModelNode from './ModelNode.svelte';
  import CompactNode from './CompactNode.svelte';
  import FocusNode from './FocusNode.svelte';
  import { layoutColumns } from '../lib/column-layout.js';
  import { assignColumns } from '../lib/graph-state.js';

  let {
    allNodes,
    allEdges,
    visibleNodeIds,
    centerNodeId,
    expandedBranches,
    loading,
    focusNodeId,
    onNodeSelect,
    onCanvasClick,
  } = $props();

  const nodeTypes = { model: ModelNode, compact: CompactNode };

  // Filter to visible nodes and edges
  const visibleNodes = $derived.by(() => {
    return allNodes.filter((n) => visibleNodeIds.has(n.id)).map((n) => ({
      ...n,
      type: n.data?.unitType === 'model' ? 'model' : 'compact',
      data: {
        ...n.data,
        isCenter: n.id === centerNodeId,
      },
    }));
  });

  const visibleEdges = $derived.by(() => {
    return allEdges
      .filter((e) => visibleNodeIds.has(e.source) && visibleNodeIds.has(e.target))
      .map((e) => ({
        ...e,
        style: e.data?.isCycle
          ? 'stroke: #ef4444; stroke-width: 2px'
          : 'stroke: #475569; stroke-width: 1.5px',
        animated: e.data?.isCycle || false,
      }));
  });

  // Compute column assignments and layout
  const columnMap = $derived(
    assignColumns(centerNodeId, visibleNodeIds, allEdges, expandedBranches)
  );

  let layoutedNodes = $state.raw([]);
  let layoutedEdges = $state.raw([]);

  $effect(() => {
    if (visibleNodes.length === 0) {
      layoutedNodes = [];
      layoutedEdges = [];
      return;
    }
    layoutedNodes = layoutColumns(visibleNodes, columnMap, centerNodeId);
    layoutedEdges = visibleEdges;
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
    <div class="loading-overlay">Loading graph...</div>
  {:else if allNodes.length === 0}
    <div class="loading-overlay">
      No extraction data available. Run <code>rake woods:extract</code> first.
    </div>
  {:else}
    <SvelteFlow
      bind:nodes={layoutedNodes}
      bind:edges={layoutedEdges}
      {nodeTypes}
      onnodeclick={handleNodeClick}
      onpaneclick={handlePaneClick}
      defaultViewport={{ x: 50, y: 50, zoom: 0.85 }}
      minZoom={0.1}
      maxZoom={2}
    >
      <Controls />
      <MiniMap />
      <Background />
      <FocusNode nodeId={focusNodeId} />
    </SvelteFlow>
  {/if}
</div>

<style>
  .flow-container {
    flex: 1;
    position: relative;
  }

  .loading-overlay {
    display: flex;
    align-items: center;
    justify-content: center;
    height: 100%;
    color: #64748b;
    font-size: 14px;
  }

  .loading-overlay code {
    background: #1e293b;
    padding: 2px 6px;
    border-radius: 4px;
    font-size: 13px;
  }
</style>
