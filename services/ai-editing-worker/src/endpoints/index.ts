import { Hono } from 'hono';
import type { Bindings } from '../env';
import edit from './edit';
import traces from './traces';

const endpoints = new Hono<{ Bindings: Bindings }>();

endpoints.route('/edit', edit);
endpoints.route('/traces', traces);
// Compose healthcheck probe (see docker/docker-compose.yml ai_editing_worker).
endpoints.get('/health', (c) => c.text('ok'));

export default endpoints;
