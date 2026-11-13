# The Open Library MCP server (https://github.com/8enSmith/mcp-open-library),
# built from the checkout you just read. book/mcp.md walks through it:
#
#   git clone --branch v1.2.6 https://github.com/8enSmith/mcp-open-library
#   cd mcp-open-library
#   podman build -f <workshop>/pikuri-mcp/containers/mcp-open-library.Containerfile \
#                -t mcp-open-library:1.2.6 .
#
# Why not upstream's Dockerfile: it re-clones the repo's `main` inside the
# build, so the image would hold whatever is on main that day rather than the
# source you read; it pipes two installers from curl into a shell; and it
# swallows build failures (`|| true`). This one copies your checkout in,
# installs the exact tree in package-lock.json, and runs no package's install
# scripts.

# Stage 1: compile the TypeScript with the full (dev) dependency tree.
FROM docker.io/library/node:22-bookworm-slim AS build
WORKDIR /src
COPY package.json package-lock.json tsconfig.json ./
RUN npm ci --ignore-scripts
COPY src ./src
RUN npx tsc

# Stage 2: the runtime dependencies only, and the compiled server.
FROM docker.io/library/node:22-bookworm-slim
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --omit=dev --ignore-scripts && npm cache clean --force
COPY --from=build /src/build ./build
USER node
ENTRYPOINT ["node", "/app/build/index.js"]
