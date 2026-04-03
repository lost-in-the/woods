<script>
  import { Handle, Position } from '@xyflow/svelte';
  import { getTypeColor } from '../lib/theme.js';

  let { data, sourcePosition, targetPosition } = $props();

  const colors = $derived(getTypeColor(data?.unitType));
  const label = $derived(data?.label || '');
  const truncated = $derived(
    label.length > 24 ? label.slice(0, 22) + '...' : label
  );
  const columns = $derived(data?.columns || []);

  const highlightClass = $derived.by(() => {
    if (data?.isActive === undefined) return '';
    if (data?.isActive) return 'node-active';
    if (data?.isHighlighted) return 'node-highlighted';
    return 'node-dimmed';
  });

  function columnIcon(col) {
    if (col.primaryKey) return '\u{1F511}';
    if (col.foreignKey) return '\u{1F517}';
    if (col.required) return '\u25C6';
    return '\u25C7';
  }
</script>

<div
  class="model-node {highlightClass}"
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

  {#each columns as col, i}
    <div class="column-row" class:first={i === 0}>
      <span class="col-icon">{columnIcon(col)}</span>
      <span class="col-name">{col.name}</span>
      <span class="col-type">{col.type || ''}</span>
    </div>
  {/each}

  <Handle type="source" position={sourcePosition || Position.Bottom} />
</div>

<style>
  .model-node {
    border: 2px solid;
    border-radius: 8px;
    min-width: 140px;
    max-width: 220px;
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

  .column-row {
    display: flex;
    align-items: center;
    gap: 4px;
    padding: 2px 10px;
    font-size: 10px;
    border-top: 1px solid var(--border-subtle);
  }

  .column-row.first {
    border-top: 1px solid var(--border-subtle);
  }

  .col-icon {
    width: 14px;
    text-align: center;
    flex-shrink: 0;
    font-size: 10px;
  }

  .col-name {
    flex: 1;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }

  .col-type {
    opacity: 0.6;
    flex-shrink: 0;
    font-size: 9px;
  }
</style>
