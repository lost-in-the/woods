/**
 * Woods Svelte Flow Visualization
 *
 * Standalone JavaScript application that renders interactive graph visualizations
 * of Woods extraction data. Fetches data from the middleware API endpoints and
 * renders using a canvas-based flow renderer.
 *
 * This is a pre-built bundle that ships with the Woods gem.
 * No Node.js or build step required for users.
 */
(function () {
  'use strict';

  // ─── State ─────────────────────────────────────────────────────────
  const state = {
    activeTab: 'graph',
    nodes: [],
    edges: [],
    clusters: [],
    flowIndex: {},
    selectedFlow: null,
    selectedNode: null,
    loading: false,
    error: null,
    pan: { x: 0, y: 0 },
    zoom: 1,
    dragging: null,
    panning: false,
    panStart: { x: 0, y: 0 },
  };

  const basePath = document.querySelector('meta[name="woods-base-path"]')?.content || '';

  // ─── API ───────────────────────────────────────────────────────────
  async function fetchJSON(endpoint) {
    const res = await fetch(`${basePath}/api/${endpoint}`);
    if (!res.ok) throw new Error(`API error: ${res.status} ${res.statusText}`);
    return res.json();
  }

  async function loadGraph() {
    state.loading = true;
    state.error = null;
    render();
    try {
      const data = await fetchJSON('graph');
      state.nodes = data.nodes || [];
      state.edges = data.edges || [];
      autofitView();
    } catch (e) {
      state.error = e.message;
    }
    state.loading = false;
    render();
  }

  async function loadClusters() {
    state.loading = true;
    state.error = null;
    render();
    try {
      const data = await fetchJSON('clusters');
      state.nodes = data.nodes || [];
      state.edges = data.edges || [];
      state.clusters = data.clusters || [];
      autofitView();
    } catch (e) {
      state.error = e.message;
    }
    state.loading = false;
    render();
  }

  async function loadFlowIndex() {
    state.loading = true;
    state.error = null;
    render();
    try {
      state.flowIndex = await fetchJSON('flows');
      const keys = Object.keys(state.flowIndex);
      if (keys.length > 0) {
        await loadFlow(keys[0]);
      } else {
        state.nodes = [];
        state.edges = [];
        state.loading = false;
        render();
      }
    } catch (e) {
      state.error = e.message;
      state.loading = false;
      render();
    }
  }

  async function loadFlow(entryPoint) {
    const safeKey = entryPoint.replace(/::/g, '__').replace(/#/g, '_');
    state.selectedFlow = entryPoint;
    state.loading = true;
    render();
    try {
      const data = await fetchJSON(`flows/${safeKey}`);
      state.nodes = data.nodes || [];
      state.edges = data.edges || [];
      autofitView();
    } catch (e) {
      state.error = e.message;
    }
    state.loading = false;
    render();
  }

  // ─── Layout Helpers ────────────────────────────────────────────────
  function autofitView() {
    if (state.nodes.length === 0) return;
    const xs = state.nodes.map(n => n.position.x);
    const ys = state.nodes.map(n => n.position.y);
    const minX = Math.min(...xs);
    const maxX = Math.max(...xs) + 200;
    const minY = Math.min(...ys);
    const maxY = Math.max(...ys) + 60;
    const container = document.querySelector('.flow-container');
    if (!container) return;
    const w = container.clientWidth;
    const h = container.clientHeight;
    const scaleX = w / (maxX - minX + 100);
    const scaleY = h / (maxY - minY + 100);
    state.zoom = Math.min(scaleX, scaleY, 1.5);
    state.pan.x = -minX * state.zoom + 50;
    state.pan.y = -minY * state.zoom + 50;
  }

  // ─── Canvas Renderer ──────────────────────────────────────────────
  function renderCanvas() {
    const container = document.querySelector('.flow-container');
    if (!container) return;

    let canvas = container.querySelector('canvas');
    if (!canvas) {
      canvas = document.createElement('canvas');
      canvas.style.width = '100%';
      canvas.style.height = '100%';
      container.appendChild(canvas);
      setupCanvasEvents(canvas);
    }

    const dpr = window.devicePixelRatio || 1;
    canvas.width = container.clientWidth * dpr;
    canvas.height = container.clientHeight * dpr;

    const ctx = canvas.getContext('2d');
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    ctx.clearRect(0, 0, canvas.width, canvas.height);

    ctx.save();
    ctx.translate(state.pan.x, state.pan.y);
    ctx.scale(state.zoom, state.zoom);

    drawEdges(ctx);
    drawNodes(ctx);

    ctx.restore();
  }

  const TYPE_COLORS = {
    model: { bg: '#1e3a5f', border: '#3b82f6', text: '#93c5fd' },
    controller: { bg: '#3b1f3b', border: '#a855f7', text: '#d8b4fe' },
    service: { bg: '#1a3b2a', border: '#22c55e', text: '#86efac' },
    job: { bg: '#3b2e1a', border: '#f59e0b', text: '#fcd34d' },
    mailer: { bg: '#3b1a2e', border: '#ec4899', text: '#f9a8d4' },
    concern: { bg: '#2a2a3b', border: '#6366f1', text: '#a5b4fc' },
    component: { bg: '#1a3b3b', border: '#14b8a6', text: '#5eead4' },
    graphql: { bg: '#3b1a3b', border: '#e11d48', text: '#fda4af' },
    flow_step: { bg: '#1e293b', border: '#0ea5e9', text: '#7dd3fc' },
    framework: { bg: '#27272a', border: '#71717a', text: '#a1a1aa' },
    default: { bg: '#1e293b', border: '#475569', text: '#94a3b8' },
  };

  function getNodeColor(node) {
    return TYPE_COLORS[node.type] || TYPE_COLORS.default;
  }

  function getNodeWidth(node) {
    const label = node.data?.label || node.id;
    return Math.max(120, Math.min(label.length * 7 + 24, 240));
  }

  function drawNodes(ctx) {
    for (const node of state.nodes) {
      const x = node.position.x;
      const y = node.position.y;
      const w = getNodeWidth(node);
      const h = 44;
      const colors = getNodeColor(node);
      const isSelected = state.selectedNode === node.id;

      // Background
      ctx.fillStyle = colors.bg;
      ctx.strokeStyle = isSelected ? '#f8fafc' : colors.border;
      ctx.lineWidth = isSelected ? 3 : 2;
      roundRect(ctx, x, y, w, h, 8);
      ctx.fill();
      ctx.stroke();

      // Label
      ctx.fillStyle = colors.text;
      ctx.font = '600 11px -apple-system, sans-serif';
      const label = node.data?.label || node.id;
      const truncated = label.length > 28 ? label.slice(0, 26) + '...' : label;
      ctx.fillText(truncated, x + 8, y + 18);

      // Type
      ctx.fillStyle = colors.text;
      ctx.globalAlpha = 0.6;
      ctx.font = '10px -apple-system, sans-serif';
      ctx.fillText((node.data?.unitType || node.type || '').toUpperCase(), x + 8, y + 34);
      ctx.globalAlpha = 1;

      // Badges
      let badgeX = x + w - 8;
      if (node.data?.isHub) {
        badgeX -= 26;
        ctx.fillStyle = '#dc2626';
        roundRect(ctx, badgeX, y + 4, 24, 14, 3);
        ctx.fill();
        ctx.fillStyle = '#fff';
        ctx.font = '600 8px sans-serif';
        ctx.fillText('HUB', badgeX + 3, y + 14);
      }
      if (node.data?.isBridge) {
        badgeX -= 26;
        ctx.fillStyle = '#f59e0b';
        roundRect(ctx, badgeX, y + 4, 24, 14, 3);
        ctx.fill();
        ctx.fillStyle = '#000';
        ctx.font = '600 8px sans-serif';
        ctx.fillText('BRG', badgeX + 3, y + 14);
      }
    }
  }

  function drawEdges(ctx) {
    const nodeMap = {};
    for (const n of state.nodes) {
      nodeMap[n.id] = n;
    }

    for (const edge of state.edges) {
      const src = nodeMap[edge.source];
      const tgt = nodeMap[edge.target];
      if (!src || !tgt) continue;

      const srcW = getNodeWidth(src);
      const x1 = src.position.x + srcW;
      const y1 = src.position.y + 22;
      const x2 = tgt.position.x;
      const y2 = tgt.position.y + 22;

      ctx.beginPath();
      ctx.strokeStyle = edge.data?.isCycle ? '#ef4444' : (edge.animated ? '#22d3ee' : '#334155');
      ctx.lineWidth = edge.data?.isCycle ? 2 : 1;

      if (edge.type === 'smoothstep') {
        const midX = (x1 + x2) / 2;
        ctx.moveTo(x1, y1);
        ctx.bezierCurveTo(midX, y1, midX, y2, x2, y2);
      } else {
        ctx.moveTo(x1, y1);
        ctx.lineTo(x2, y2);
      }
      ctx.stroke();

      // Arrow
      const angle = Math.atan2(y2 - y1, x2 - x1);
      ctx.beginPath();
      ctx.moveTo(x2, y2);
      ctx.lineTo(x2 - 8 * Math.cos(angle - 0.4), y2 - 8 * Math.sin(angle - 0.4));
      ctx.lineTo(x2 - 8 * Math.cos(angle + 0.4), y2 - 8 * Math.sin(angle + 0.4));
      ctx.closePath();
      ctx.fillStyle = edge.data?.isCycle ? '#ef4444' : '#334155';
      ctx.fill();
    }
  }

  function roundRect(ctx, x, y, w, h, r) {
    ctx.beginPath();
    ctx.moveTo(x + r, y);
    ctx.lineTo(x + w - r, y);
    ctx.quadraticCurveTo(x + w, y, x + w, y + r);
    ctx.lineTo(x + w, y + h - r);
    ctx.quadraticCurveTo(x + w, y + h, x + w - r, y + h);
    ctx.lineTo(x + r, y + h);
    ctx.quadraticCurveTo(x, y + h, x, y + h - r);
    ctx.lineTo(x, y + r);
    ctx.quadraticCurveTo(x, y, x + r, y);
    ctx.closePath();
  }

  // ─── Canvas Events ─────────────────────────────────────────────────
  function setupCanvasEvents(canvas) {
    canvas.addEventListener('wheel', (e) => {
      e.preventDefault();
      const delta = e.deltaY > 0 ? 0.9 : 1.1;
      const newZoom = Math.min(Math.max(state.zoom * delta, 0.1), 5);
      const rect = canvas.getBoundingClientRect();
      const mx = e.clientX - rect.left;
      const my = e.clientY - rect.top;
      state.pan.x = mx - (mx - state.pan.x) * (newZoom / state.zoom);
      state.pan.y = my - (my - state.pan.y) * (newZoom / state.zoom);
      state.zoom = newZoom;
      renderCanvas();
    });

    canvas.addEventListener('mousedown', (e) => {
      const { x: wx, y: wy } = screenToWorld(e, canvas);
      const hit = hitTestNode(wx, wy);
      if (hit) {
        state.selectedNode = hit.id;
        renderSidebar();
        renderCanvas();
      } else {
        state.panning = true;
        state.panStart = { x: e.clientX - state.pan.x, y: e.clientY - state.pan.y };
      }
    });

    canvas.addEventListener('mousemove', (e) => {
      if (state.panning) {
        state.pan.x = e.clientX - state.panStart.x;
        state.pan.y = e.clientY - state.panStart.y;
        renderCanvas();
      }
    });

    canvas.addEventListener('mouseup', () => {
      state.panning = false;
    });

    canvas.addEventListener('mouseleave', () => {
      state.panning = false;
    });
  }

  function screenToWorld(e, canvas) {
    const rect = canvas.getBoundingClientRect();
    return {
      x: (e.clientX - rect.left - state.pan.x) / state.zoom,
      y: (e.clientY - rect.top - state.pan.y) / state.zoom,
    };
  }

  function hitTestNode(wx, wy) {
    for (let i = state.nodes.length - 1; i >= 0; i--) {
      const n = state.nodes[i];
      const nw = getNodeWidth(n);
      if (wx >= n.position.x && wx <= n.position.x + nw &&
          wy >= n.position.y && wy <= n.position.y + 44) {
        return n;
      }
    }
    return null;
  }

  // ─── DOM Renderer ──────────────────────────────────────────────────
  function render() {
    const app = document.getElementById('app');
    if (!app) return;

    app.innerHTML = `
      <div class="header">
        <h1>Woods <span>Visualize</span></h1>
        <div class="tabs">
          <button class="tab ${state.activeTab === 'graph' ? 'active' : ''}" data-tab="graph">Dependencies</button>
          <button class="tab ${state.activeTab === 'flows' ? 'active' : ''}" data-tab="flows">Flows</button>
          <button class="tab ${state.activeTab === 'clusters' ? 'active' : ''}" data-tab="clusters">Clusters</button>
        </div>
      </div>
      ${state.activeTab === 'flows' ? renderFlowSelector() : ''}
      <div class="flow-container">
        ${state.loading ? '<div class="loading"><div class="spinner"></div>Loading...</div>' : ''}
        ${state.error ? `<div class="error"><div>Error loading data</div><div class="error-detail">${state.error}</div></div>` : ''}
      </div>
      <div class="sidebar ${state.selectedNode ? 'open' : ''}" id="sidebar"></div>
      <div class="stats-bar">
        <div class="stat">Nodes: <span class="stat-value">${state.nodes.length}</span></div>
        <div class="stat">Edges: <span class="stat-value">${state.edges.length}</span></div>
        ${state.clusters.length ? `<div class="stat">Clusters: <span class="stat-value">${state.clusters.length}</span></div>` : ''}
      </div>
    `;

    // Bind tab clicks
    app.querySelectorAll('.tab').forEach(btn => {
      btn.addEventListener('click', () => switchTab(btn.dataset.tab));
    });

    // Bind flow selector
    const flowSelect = app.querySelector('#flow-select');
    if (flowSelect) {
      flowSelect.addEventListener('change', () => loadFlow(flowSelect.value));
    }

    if (!state.loading && !state.error && state.nodes.length > 0) {
      requestAnimationFrame(renderCanvas);
    }

    renderSidebar();
  }

  function renderFlowSelector() {
    const keys = Object.keys(state.flowIndex);
    if (keys.length === 0) return '';
    const options = keys.map(k =>
      `<option value="${k}" ${k === state.selectedFlow ? 'selected' : ''}>${k}</option>`
    ).join('');
    return `<div class="flow-selector"><select id="flow-select">${options}</select></div>`;
  }

  function renderSidebar() {
    const sidebar = document.getElementById('sidebar');
    if (!sidebar) return;

    if (!state.selectedNode) {
      sidebar.classList.remove('open');
      return;
    }

    const node = state.nodes.find(n => n.id === state.selectedNode);
    if (!node) return;

    sidebar.classList.add('open');
    const d = node.data || {};
    const rows = [
      ['Type', d.unitType || node.type],
      ['File', d.filePath || '-'],
      ['Namespace', d.namespace || '-'],
      ['PageRank', d.pagerank ? d.pagerank.toFixed(6) : '-'],
    ];

    if (d.isHub) rows.push(['Role', 'Hub']);
    if (d.isBridge) rows.push(['Role', 'Bridge']);
    if (d.isOrphan) rows.push(['Role', 'Orphan']);

    if (d.operations) {
      rows.push(['Operations', d.operationCount || d.operations.length]);
    }

    sidebar.innerHTML = `
      <button class="close-btn" id="close-sidebar">&times;</button>
      <h3>${node.id}</h3>
      ${rows.map(([l, v]) => `<div class="detail-row"><span class="detail-label">${l}</span><span class="detail-value">${v}</span></div>`).join('')}
    `;

    document.getElementById('close-sidebar')?.addEventListener('click', () => {
      state.selectedNode = null;
      renderSidebar();
      renderCanvas();
    });
  }

  function switchTab(tab) {
    if (state.activeTab === tab) return;
    state.activeTab = tab;
    state.selectedNode = null;
    state.nodes = [];
    state.edges = [];
    state.clusters = [];

    if (tab === 'graph') loadGraph();
    else if (tab === 'clusters') loadClusters();
    else if (tab === 'flows') loadFlowIndex();
  }

  // ─── Resize Handler ────────────────────────────────────────────────
  window.addEventListener('resize', () => {
    if (!state.loading && state.nodes.length > 0) renderCanvas();
  });

  // ─── Init ──────────────────────────────────────────────────────────
  document.addEventListener('DOMContentLoaded', () => {
    loadGraph();
  });
})();
