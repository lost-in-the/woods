import { mount } from 'svelte';
import App from './App.svelte';
import './app.css';
import '@xyflow/svelte/dist/style.css';

const target = document.getElementById('app');
while (target.firstChild) target.removeChild(target.firstChild);
mount(App, { target });
