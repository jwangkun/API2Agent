# API2Agent

本地 OpenAI 兼容网关，将 DeepSeek 及其他兼容 OpenAI 的模型转换为标准 API，供 Codex、OpenCode、PI、Claude Code 等 AI 编程代理客户端调用。

## 致谢

本项目基于 [Composer API](https://github.com/standardagents/composer-api) by [Standard Agents](https://github.com/standardagents) 进行二次开发。感谢原作者提供的优秀基础架构和 UI 设计。

## 这是什么

AI 编程代理客户端（Codex、OpenCode）需要 OpenAI 兼容的 API 接口。API2Agent 作为一个本地 macOS 应用，提供了一个轻量级网关，可以：

- 将 DeepSeek API 转换为 OpenAI 兼容格式
- 将其他兼容 OpenAI 的模型统一接入
- 支持 Chat Completions 和 Responses API
- 本地运行，无需依赖外部托管服务

## 支持的端点

- `POST /v1/chat/completions`
- `POST /v1/responses`
- `GET /v1/models`

## 使用方法

安装 macOS 应用后，启动本地 API 服务。默认基础 URL：

```txt
http://127.0.0.1:8787/v1
```

将任何 OpenAI 兼容客户端指向本地基础 URL，使用任意 Bearer token 进行认证。

```ts
import OpenAI from "openai";

const client = new OpenAI({
  apiKey: "local",
  baseURL: "http://127.0.0.1:8787/v1"
});

const completion = await client.chat.completions.create({
  model: "composer-2.5",
  messages: [{ role: "user", content: "写一个 TypeScript 防抖函数。" }]
});
```

```bash
curl http://127.0.0.1:8787/v1/chat/completions \
  -H "Authorization: Bearer local" \
  -H "Content-Type: application/json" \
  -d '{"model":"composer-2.5","messages":[{"role":"user","content":"Hello"}]}'
```

## 支持的模型

### DeepSeek 模型
- DeepSeek V4 Flash
- DeepSeek V4 Pro
- DeepSeek Chat (legacy)
- DeepSeek Reasoner (legacy)

### Cursor Composer 模型
- Composer 2.5
- Composer 2.5 Fast
- Composer 2.5 SDK Harness

### 其他兼容模型
- GPT-5.x 系列
- Gemini 系列
- Grok 系列
- Kimi 系列

## 本地开发

```bash
npm install
npm run db:migrate:local
npm run dev
```

创建本地 `.dev.vars` 文件：

```bash
ENCRYPTION_KEY="替换为长随机密钥"
DEEPSEEK_API_BASE="https://api.deepseek.com"
DEEPSEEK_API_KEY="你的 DeepSeek API 密钥"
```

## Cloudflare 部署

Worker 使用 Cloudflare Vite 和 D1。

远程迁移和部署需要有效的 `CLOUDFLARE_API_TOKEN`。

```bash
npm run build
npm run test
npm run typecheck
npm run db:migrate:remote
npm run deploy
```

## macOS 构建

```bash
# 构建 macOS 应用
export https_proxy=http://127.0.0.1:7890 http_proxy=http://127.0.0.1:7890 all_proxy=socks5://127.0.0.1:7890
bash macos/api2agent/Scripts/package-app.sh --development
```

## 兼容性说明

本项目支持：
- 文本和图片输入
- 非流式和流式输出
- JSON 输出提示约束
- 常见 SDK 响应格式

不支持的功能：
- `n` 大于 `1`
- `logprobs` 和 `top_logprobs`
- 音频输出
- OpenAI function/tool calls on the Responses API
- 后台 Responses API 任务

## 许可证

MIT License - 详见 [LICENSE](LICENSE)

本项目基于 [Composer API](https://github.com/standardagents/composer-api) (MIT License) 进行二次开发。

## 相关资源

- [原项目: Composer API](https://github.com/standardagents/composer-api)
- OpenAI Chat Completions 参考: https://developers.openai.com/api/docs/api-reference/chat
- OpenAI Responses 参考: https://developers.openai.com/api/docs/api-reference/responses
- DeepSeek API 文档: https://platform.deepseek.com/api-docs
