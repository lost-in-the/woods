import { mount } from 'svelte';
import App from './App.svelte';
import './app.css';
import '@xyflow/svelte/dist/style.css';

mount(App, { target: document.getElementById('app') });
