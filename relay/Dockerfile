# 中转的容器镜像（契约 §2 / §12：只转发与记账，不存会话内容）。
#
# ## 构建上下文必须是**仓库根**
#
# `relay/src/*.ts` 里有 `import ... from '../../protocol/relay-control.mjs'`
# （`core.ts:7` / `http-face.ts:2` / `server.ts:9` / `tickets.ts:3`）——
# 中转发帧与配对候选的解析**复用仓库根的那一份协议模块**，不复制第二份。
# 所以镜像里的相对层级要与仓库一致（`/app/relay/src` + `/app/protocol`），
# 构建命令是（在仓库根）：
#
#   docker build -f relay/Dockerfile -t dsh-mobile-relay:local .
#
# `relay/docker-compose.yml` 已经把 context 指成 `..`，直接 compose 即可。
#
# ## 为什么是 node:24-alpine 且**没有构建步骤**
#
# 中转直接跑 TypeScript（`node src/main.ts`，靠 Node 的类型剥离），
# `relay/package.json` 的 engines 是 `>=22.6`，而 Node 23 起类型剥离默认开启 ——
# 24 正好。加一层 tsc 只会多一个与现状相反的产物目录。
#
# ## 镜像里**不放配置**
#
# `relay.config.json` 存的是本机签发的令牌**摘要**（不是明文，但它是这台机器的
# 凭据表，换机器就得重签）。它走挂载（见 docker-compose.yml），镜像只带代码与依赖。
FROM node:24-alpine

WORKDIR /app

# 运行时依赖只有 `ws` 一个（relay/package.json 的 dependencies）。
# 用 pnpm 锁文件装，版本与开发机一致；devDependencies（typescript / @types）不进镜像。
COPY relay/package.json relay/pnpm-lock.yaml ./relay/
RUN cd relay \
  && corepack enable \
  && pnpm install --prod --frozen-lockfile \
  && pnpm store prune

# 中转复用的协议模块（**一份，不复制**）+ 中转自己的源码。
COPY protocol/relay-control.mjs ./protocol/relay-control.mjs
COPY relay/src ./relay/src
COPY relay/tsconfig.json ./relay/

WORKDIR /app/relay
ENV NODE_ENV=production
EXPOSE 8787

# 健康检查**不依赖 curl/wget**（alpine 基础镜像里没有）：直接 TCP 连一下端口。
# 端口来自配置，所以容器里用 `RELAY_PORT` 告诉健康检查（compose 里设成同一个值）。
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
  CMD node -e "require('node:net').connect(Number(process.env.RELAY_PORT ?? 8787),'127.0.0.1').on('connect',()=>process.exit(0)).on('error',()=>process.exit(1))"

# 配置路径固定成 `/config/relay.config.json`：编排与文档都按这个挂。
CMD ["node", "src/main.ts", "--config", "/config/relay.config.json"]
