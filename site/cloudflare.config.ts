import { defineConfig } from "cf/config";

// The landing page in ../docs, served as static assets at readstreak.progremir.dev. Deploy from this folder with `npx cf deploy`.
export default defineConfig({
  worker: {
    name: "readstreak",
    compatibilityDate: "2026-10-19",
    domains: ["readstreak.progremir.dev"],
    assets: {
      notFoundHandling: "404-page",
    },
    observability: {
      enabled: true,
    },
  },
});
