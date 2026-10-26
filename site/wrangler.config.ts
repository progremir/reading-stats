import { defineWranglerConfig } from "wrangler/experimental-config";

// cf builds this static site with Wrangler; the files are the landing page in docs/.
export default defineWranglerConfig({
  assetsDirectory: "../docs",
});
