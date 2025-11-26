import {resolve} from 'path';
import {defineConfig} from 'vite';
import dts from 'vite-plugin-dts';
// https://vitejs.dev/guide/build.html#library-mode

export default defineConfig({
    build: {
        lib: {
            entry: resolve(__dirname, 'src/index.ts'),
            name: 'muckwebinterface-websocket',
            fileName: 'muckwebinterface-websocket',
        },
        copyPublicDir: false,
        emptyOutDir: true,
        rollupOptions: {
            // Dependencies that shouldn't be bundled
            external: ['axios'],
            output: {
                // For UMD - expected globals
                globals: {
                    axios: 'axios',
                },
                // Flag that we're using the default export and then some extra ones
                exports: 'named'
            }
        }
    },
    plugins: [dts()],
    test: {
        include: [resolve(__dirname, 'test/*.ts')]
    },
    server: {
        port: 5175,
        watch: {
            usePolling: true
        }
    }
});