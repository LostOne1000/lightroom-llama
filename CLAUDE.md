# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with this repository.

## Project Overview

**Lightroom Llama** is an [Adobe Lightroom Classic](https://www.adobe.com/products/photoshop-lightroom/classic.html) plugin written in **Lua** that generates photo metadata (title, caption, keywords) via a local [Ollama](https://ollama.ai/) instance. Photos are never uploaded — all AI inference runs locally on the user's machine.

## Technology

- **Language:** Lua (Lightroom SDK 10.0, minimum SDK 5.0)
- **Plugin format:** `.lrplugin` directory bundle
- **AI backend:** Ollama running on `localhost:11434`, currently using the `gemma4:latest` model (configured as a global variable in `LrLlama.lua:19`)
- **API endpoint:** `http://localhost:11434/api/generate` — Ollama's generate API with multimodal image support

## Source Files

| File | Purpose |
|------|---------|
| `lightroom-llama.lrplugin/Info.lua` | Plugin manifest: version, name, toolkit identifier, menu registration (Library + Export menus, enabled only when photos are selected) |
| `lightroom-llama.lrplugin/LrLlama.lua` | Main plugin logic: thumbnail export, Ollama API calls, dialog UI, metadata writing |
| `lightroom-llama.lrplugin/JSON.lua` | Third-party JSON encoder/decoder (Jeffrey Friedl's pure-Lua JSON library) |

## Architecture

### Data Flow

1. User selects a photo in Lightroom and invokes the plugin via **Library** or **Export** menu.
2. `exportThumbnail()` requests a 512×512 JPEG thumbnail from Lightroom and writes it to the system temp directory.
3. The thumbnail is Base64-encoded via `LrStringUtils.encodeBase64`.
4. `sendDataToApi()` POSTs the encoded image + prompt to Ollama's `/api/generate` endpoint with `format: "json"`.
5. Ollama returns a JSON response containing `title`, `caption`, and `keywords` fields.
6. The dialog displays the generated metadata in editable fields. On save, metadata is written back via `setRawMetadata` and keywords are added as children of an `llm` parent keyword.

### Key Lightroom SDK APIs Used

- **LrHttp** — HTTP POST to Ollama API
- **LrTasks** — async task execution (API calls run on background threads)
- **LrView** / **LrBinding** — dialog UI construction and data binding
- **LrDialogs** — modal dialogs and user messages
- **LrFileUtils** / **LrPathUtils** / **LrStringUtils** — file I/O, paths, Base64 encoding
- **LrLogger** — logging to `~/Documents/LrClassicLogs/LrLlama.log`
- **LrApplication** — catalog access, photo metadata read/write

### Keywords System

Generated keywords are nested under a parent keyword named `llm`. The `addKeywordsWithParent()` function creates/retrieves this parent, then adds each generated keyword as a child. `getLlmKeywordsFromPhoto()` reads back existing llm keywords to pre-populate the dialog.

## Development Notes

- There is **no build system** — the `.lrplugin` directory is loaded directly by Lightroom. Changes are picked up by restarting Lightroom or reloading the plugin via File > Plug-in Manager.
- Logs are written to `~/Documents/LrClassicLogs/LrLlama.log`. Tail with: `tail -f ~/Documents/LrClassicLogs/LrLlama.log`
- The model name is hardcoded at `LrLlama.lua:19`. Change it to switch models.
- `request.txt` in the repo root contains a reference `curl` command for testing the Ollama API manually.
- To test the plugin, install it in Lightroom Classic via File > Plug-in Manager > Add, then navigate to the `.lrplugin` folder.
