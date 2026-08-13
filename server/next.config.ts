import type { NextConfig } from "next";

const nextConfig: NextConfig = {
  // Analysis requests carry a base64 screenshot; the default body limit is too small.
  experimental: {
    serverActions: { bodySizeLimit: "12mb" },
  },
};

export default nextConfig;
