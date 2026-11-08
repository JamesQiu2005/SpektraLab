import { resolve } from 'node:path';
import { defineConfig } from 'vitest/config';

export default defineConfig({
  resolve: { alias: { '@shared': resolve(__dirname, 'src/shared') } },
  test: {
    include: ['src/**/*.test.ts', 'src/**/*.test.tsx', 'mock-host/**/*.test.ts'],
    environment: 'node',
  },
});
