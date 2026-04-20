<script>
  import { COLORS } from '../lib/theme.js';

  let { direction, expanded = false, onExpand, onCollapse, onExpandAll } = $props();

  const symbol = $derived(
    expanded
      ? (direction === 'right' ? '\u00AB' : '\u00BB') // collapse: flip direction
      : (direction === 'right' ? '\u00BB' : '\u00AB') // expand: point in direction
  );

  function handleClick(e) {
    if (expanded) {
      onCollapse?.();
    } else if (e.altKey) {
      onExpandAll?.();
    } else {
      onExpand?.();
    }
  }
</script>

<button
  class="expand-btn"
  class:expanded
  class:left={direction === 'left'}
  class:right={direction === 'right'}
  title={expanded ? 'Collapse' : (direction === 'right' ? 'Expand children (Alt+click: expand all)' : 'Expand parents (Alt+click: expand all)')}
  onclick={handleClick}
>
  {symbol}
</button>

<style>
  .expand-btn {
    width: 20px;
    height: 20px;
    display: flex;
    align-items: center;
    justify-content: center;
    border: 1px solid #334155;
    border-radius: 4px;
    background: #0f172a;
    color: #475569;
    font-size: 14px;
    cursor: pointer;
    padding: 0;
    line-height: 1;
    transition: border-color 0.15s, color 0.15s;
    flex-shrink: 0;
  }

  .expand-btn:hover {
    border-color: #475569;
    color: #e2e8f0;
  }

  .expand-btn.expanded {
    border-color: #22c55e;
    color: #22c55e;
  }

  .expand-btn.expanded:hover {
    border-color: #16a34a;
    color: #16a34a;
  }
</style>
