# API2Agent

API2Agent is a local OpenAI compatible gateway that converts DeepSeek and other compatible models to standard API for AI coding agent clients like Cursor Composer, Codex, OpenCode, VS Code, Cline, Kilo Code, Continue, Aider, and Roo.

Download the latest DMG:

```txt
https://github.com/jwangkun/API2Agent/releases
```

After installing, open the app, add your API keys, and start the local gateway.

## Local Endpoints

Default base URL:

```txt
http://127.0.0.1:8787/v1
```

Endpoints:

- `GET /v1/models`
- `POST /v1/chat/completions`
- `POST /v1/responses`

## Supported Models

API2Agent supports:

- DeepSeek models (V4 Flash, V4 Pro, Chat, Reasoner)
- Cursor Composer models (2.5, 2.5 Fast, 2.5 SDK)
- Other OpenAI-compatible models (GPT-5.x, Gemini, Grok, Kimi)

## OpenCode

Use the app's OpenCode installer from **Agent Setup**. It writes a local OpenAI-compatible provider that points at your local server.

The model ids are:

- `composer-2.5`
- `composer-2.5-fast`

## Codex

Use the app's Codex installer from **Agent Setup**, or configure a custom OpenAI-compatible provider manually:

```toml
[model_providers.api2agent]
name = "API2Agent"
base_url = "http://127.0.0.1:8787/v1"
wire_api = "chat"

[profiles.api2agent]
model = "composer-2.5"
model_provider = "api2agent"
```

## How It Works

API2Agent runs as a local macOS app that starts a localhost /v1 server. It converts DeepSeek API and other OpenAI-compatible models to standard OpenAI API format that works with Cursor Composer, Codex, OpenCode, and any other AI coding agent client.

Your API keys stay on your machine, agent tools run against your real project folders, and all requests are processed locally without external dependencies.
