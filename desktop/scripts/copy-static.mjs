// Copies renderer HTML/CSS next to the compiled renderer scripts. Cross-platform (no shell cp).
import { cpSync, writeFileSync } from 'node:fs';
cpSync('src/renderer/static', 'dist/ui/renderer', { recursive: true });
// Renderer/worker code is ESM; this also makes fake-browser contract imports explicit in Node.
writeFileSync('dist/ui/package.json', JSON.stringify({ type: 'module' }) + '\n');
