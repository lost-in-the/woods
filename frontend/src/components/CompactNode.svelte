<script>
  import { Handle, Position } from '@xyflow/svelte';
  import { getTypeColor } from '../lib/theme.js';

  let { data, sourcePosition, targetPosition } = $props();

  const colors = $derived(getTypeColor(data?.unitType));
  const label = $derived(data?.label || '');
  const truncated = $derived(
    label.length > 24 ? label.slice(0, 22) + '...' : label
  );
  const attributes = $derived(
    (data?.attributes || []).join(', ')
  );

  const highlightClass = $derived.by(() => {
    if (data?.isActive === undefined) return '';
    if (data?.isActive) return 'node-active';
    if (data?.isHighlighted) return 'node-highlighted';
    return 'node-dimmed';
  });
</script>

<div
  class="compact-node {highlightClass}"
  style="background:{colors.bg}; border-color:{colors.border}; color:{colors.text};"
>
  <Handle type="target" position={targetPosition || Position.Top} />

  <div class="node-header">
    <span class="type-dot" style="background:{colors.border};"></span>
    <span class="node-name">{truncated}</span>
    {#if data?.isHub}
      <span class="badge hub">HUB</span>
    {/if}
    {#if data?.isBridge}
      <span class="badge bridge">BRG</span>
    {/if}
  </div>

  {#if attributes}
    <div class="attr-row">{attributes}</div>
  {/if}

  <Handle type="source" position={sourcePosition || Position.Bottom} />
</div>

<style>
  .compact-node {
    border: 2px solid;
    border-radius: 8px;
    min-width: 120px;
    max-width: 200px;
    font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif;
    position: relative;
    transition: opacity 0.15s, box-shadow 0.15s;
  }

  .node-header {
    display: flex;
    align-items: center;
    gap: 6px;
    padding: 6px 10px;
  }

  .type-dot {
    width: 8px;
    height: 8px;
    border-radius: 2px;
    flex-shrink: 0;
  }

  .node-name {
    font-size: 11px;
    font-weight: 600;
    line-height: 1.3;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
    flex: 1;
  }

  .badge {
    font-size: 8px;
    font-weight: 600;
    padding: 1px 4px;
    border-radius: 3px;
    flex-shrink: 0;
  }

  .badge.hub {
    background: #dc2626;
    color: #fff;
  }

  .badge.bridge {
    background: #f59e0b;
    color: #000;
  }

  .attr-row {
    padding: 2px 10px 6px;
    font-size: 10px;
    opacity: 0.7;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
    border-top: 1px solid var(--border-subtle);
  }
</style>
