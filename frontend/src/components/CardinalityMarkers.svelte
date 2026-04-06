<script>
  import { onMount, tick } from 'svelte';

  let el;

  const NS = 'http://www.w3.org/2000/svg';

  function createLine(x1, y1, x2, y2, stroke, strokeWidth) {
    const line = document.createElementNS(NS, 'line');
    line.setAttribute('x1', x1);
    line.setAttribute('y1', y1);
    line.setAttribute('x2', x2);
    line.setAttribute('y2', y2);
    line.setAttribute('stroke', stroke);
    line.setAttribute('stroke-width', strokeWidth);
    return line;
  }

  function createMarker(id, viewBox, refX, refY, width, height, children) {
    const marker = document.createElementNS(NS, 'marker');
    marker.setAttribute('id', id);
    marker.setAttribute('viewBox', viewBox);
    marker.setAttribute('refX', refX);
    marker.setAttribute('refY', refY);
    marker.setAttribute('markerWidth', width);
    marker.setAttribute('markerHeight', height);
    marker.setAttribute('orient', 'auto-start-reverse');
    for (const child of children) marker.appendChild(child);
    return marker;
  }

  function injectDefs() {
    if (!el) return false;
    const flowContainer = el.closest('.svelte-flow');
    if (!flowContainer) return false;

    // SvelteFlow renders edges in this SVG — markers must live here
    const edgeSvg = flowContainer.querySelector('svg.svelte-flow__edges');
    if (!edgeSvg) return false;
    if (edgeSvg.querySelector('#marker-bar')) return true; // already injected

    const color = '#94a3b8';
    const defs = document.createElementNS(NS, 'defs');
    defs.setAttribute('id', 'cardinality-markers');

    // Bar marker (one side of relationship)
    defs.appendChild(
      createMarker('marker-bar', '0 0 10 14', '5', '7', '10', '14', [
        createLine('5', '0', '5', '14', color, '2'),
      ])
    );

    // Crow's foot marker (many side of relationship)
    defs.appendChild(
      createMarker('marker-crow-foot', '0 0 16 14', '1', '7', '16', '14', [
        createLine('14', '0', '1', '7', color, '1.5'),
        createLine('14', '14', '1', '7', color, '1.5'),
        createLine('14', '0', '14', '14', color, '1.5'),
      ])
    );

    edgeSvg.prepend(defs);
    return true;
  }

  // Try injection after mount, with retries for SvelteFlow's async rendering
  onMount(async () => {
    await tick();
    if (injectDefs()) return;

    // SvelteFlow SVG may not exist yet — retry a few times
    let attempts = 0;
    const interval = setInterval(() => {
      attempts++;
      if (injectDefs() || attempts > 20) {
        clearInterval(interval);
      }
    }, 100);

    return () => clearInterval(interval);
  });
</script>

<span bind:this={el} style="display:none"></span>
