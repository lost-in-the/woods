<script>
  import { Handle, Position } from '@xyflow/svelte';
  import { getTypeColor } from '../lib/theme.js';

  let { data, type, sourcePosition, targetPosition } = $props();

  const colors = $derived(getTypeColor(data?.unitType || type));
  const label = $derived(data?.label || '');
  const truncated = $derived(
    label.length > 28 ? label.slice(0, 26) + '...' : label
  );
</script>

<div
  class="woods-node"
  style="background:{colors.bg}; border-color:{colors.border}; color:{colors.text};"
>
  <Handle type="target" position={targetPosition || Position.Top} />

  <div class="node-label">{truncated}</div>
  <div class="node-type">{(data?.unitType || type || '').toUpperCase()}</div>

  <div class="badges">
    {#if data?.isHub}
      <span class="badge hub">HUB</span>
    {/if}
    {#if data?.isBridge}
      <span class="badge bridge">BRG</span>
    {/if}
  </div>

  <Handle type="source" position={sourcePosition || Position.Bottom} />
</div>

<style>
  .woods-node {
    padding: 8px 12px;
    border: 2px solid;
    border-radius: 8px;
    min-width: 120px;
    max-width: 200px;
    font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif;
    position: relative;
  }

  .node-label {
    font-size: 11px;
    font-weight: 600;
    line-height: 1.3;
    word-break: break-all;
  }

  .node-type {
    font-size: 10px;
    opacity: 0.6;
    margin-top: 2px;
  }

  .badges {
    position: absolute;
    top: 4px;
    right: 4px;
    display: flex;
    gap: 2px;
  }

  .badge {
    font-size: 8px;
    font-weight: 600;
    padding: 1px 4px;
    border-radius: 3px;
  }

  .badge.hub {
    background: #dc2626;
    color: #fff;
  }

  .badge.bridge {
    background: #f59e0b;
    color: #000;
  }
</style>
