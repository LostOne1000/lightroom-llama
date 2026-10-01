# AGENTS.md

This file is the repository-wide source of truth for AI coding assistants, including ChatGPT/Codex, OpenCode, and Claude. Follow it for all work in this repository.

## Project overview

Lightroom Llama is an Adobe Lightroom Classic plugin written in Lua. It generates photo titles, captions, and keywords through an Ollama server. The runtime plugin is the `lightroom-llama.lrplugin/` directory; Lightroom loads that directory directly.

The plugin supports single-photo generation, batch generation, and selective reset of generated metadata. Ollama defaults to `localhost:11434`, but users can configure another `host:port`.

## Repository layout

| Path | Responsibility |
| --- | --- |
| `lightroom-llama.lrplugin/Info.lua` | Manifest, version, SDK requirements, and Library/Export menu registration |
| `lightroom-llama.lrplugin/LrLlama.lua` | Single-photo entry point and dependency wiring |
| `lightroom-llama.lrplugin/BatchLrLlama.lua` | Batch-processing entry point and progress flow |
| `lightroom-llama.lrplugin/ResetMetadata.lua` | Selective title, caption, and generated-keyword reset |
| `lightroom-llama.lrplugin/LlamaDialog.lua` | Single-photo Lightroom dialog adapter |
| `lightroom-llama.lrplugin/SinglePhotoController.lua` | Testable single-photo workflow and state transitions |
| `lightroom-llama.lrplugin/Common.lua` | Compatibility/delegation layer used by the entry points |
| `lightroom-llama.lrplugin/OllamaClient.lua` | Server validation, model discovery, and generation orchestration |
| `lightroom-llama.lrplugin/ThumbnailService.lua` | Thumbnail export and Base64 encoding |
| `lightroom-llama.lrplugin/PromptBuilder.lua` | Prompt text and Ollama request payload construction |
| `lightroom-llama.lrplugin/ResponseValidator.lua` | Ollama envelope parsing and metadata schema validation |
| `lightroom-llama.lrplugin/MetadataService.lua` | Lightroom metadata and `llm` keyword hierarchy operations |
| `lightroom-llama.lrplugin/JSON.lua` | Vendored third-party JSON implementation |
| `tests/helpers/mock_sdk.lua` | Lightroom SDK test doubles |
| `tests/spec/` | Busted unit and entry-point specs |
| `.github/workflows/` | Tests, site deployment, and tagged-release packaging |

Treat `JSON.lua` as vendored code. Do not reformat or modify it unless the task specifically requires a JSON-library change.

## Architecture and invariants

- Keep entry points thin. Put reusable behavior in focused modules and inject dependencies through constructors such as `new(deps)` when practical.
- Preserve `Common.lua` as the compatibility layer until a task explicitly completes its migration and updates every caller and relevant test.
- Lightroom modules are loaded with `loadfile(LrPathUtils.child(_PLUGIN.path, "..."))`; do not assume normal Lua package paths or replace this pattern casually.
- Network work and long-running operations must not block Lightroom's UI. Respect existing `LrTasks.startAsyncTask` boundaries.
- All catalog mutations must occur inside `catalog:withWriteAccessDo(...)`.
- Generated keywords belong beneath the top-level `llm` keyword. Resetting metadata removes keyword associations from photos, not shared keyword definitions from the catalog.
- Ollama model discovery uses `GET /api/tags`; generation uses `POST /api/generate`.
- Generated metadata must remain a JSON object with a string `title`, string `caption`, and an array of non-empty string `keywords`. Keep validation failures explicit and user-readable.
- Do not introduce uploads or external image services without an explicit requirement. A configured Ollama host is the only intended image-processing destination.
- Keep single-photo, batch, and reset behavior consistent where they share metadata, prompt, server, or model-selection logic.

## Lua and Lightroom conventions

- Target Lua 5.1.5 and Lightroom SDK 10.0 while preserving the manifest's minimum SDK 5.0 compatibility.
- Do not use syntax or standard-library features introduced after Lua 5.1.
- Obtain Lightroom APIs through `import`; tests replace these imports with the mock SDK.
- Prefer modules that return a table. For SDK-heavy code, preserve or add dependency injection so logic remains testable without Lightroom.
- Public functions use LuaLS documentation comments: a prose summary followed by `---@param` and `---@return` annotations.
- Use `--` comments to explain constraints and intent, not to narrate obvious code.
- Follow the existing section-divider style in files that use it.
- Preserve meaningful error handling and logging. Runtime logs are written to `~/Documents/LrClassicLogs/LrLlama.log`.
- Avoid unrelated refactors, formatting churn, and generated artifacts.

## Development workflow

Before changing code:

1. Read the relevant production module, its callers, and the matching specs.
2. Check whether the behavior is shared by single-photo, batch, and reset flows.
3. Prefer the smallest cohesive change that preserves existing public contracts.

Prerequisites are Lua 5.1.5, LuaRocks, and Busted 2.3.0-1.

Run the complete test suite:

```bash
make test
```

Run one spec while iterating:

```bash
./tests/run_tests.sh tests/spec/<name>_spec.lua
```

Tests run against `tests/helpers/mock_sdk.lua`; Lightroom is not required. Add or update focused specs for every behavior change, and extend the shared SDK mocks only when the production behavior genuinely needs another SDK surface.

Build and verify a release archive:

```bash
make package VERSION=<version>
```

This runs the full test suite, recreates `dist/`, builds `dist/lightroom-llama-v<version>.zip`, and verifies the archive. Use `make clean` to remove generated test and release artifacts.

## Change-specific verification

- For manifest or menu changes, update `Info.lua` specs and confirm all three commands remain available from both Library and Export menus when photos are selected.
- For Ollama client changes, cover host normalization, model-list fallbacks, request construction, transport errors, and malformed responses.
- For prompt or response changes, test exact payload/schema behavior without requiring a live model.
- For metadata changes, test write-access boundaries, idempotent keyword creation, and safe handling of missing or malformed keyword data.
- For UI or entry-point changes, run automated specs and describe any Lightroom manual smoke test that still needs to be performed.
- When architecture, commands, prerequisites, or user-visible behavior changes, update `README.md` and this file in the same change.

## Licensing and attribution

- Preserve upstream copyright, license, and attribution notices.
- Keep the README's upstream attribution and independent-fork statement.
- Document bundled third-party code and its verified license terms in `THIRD_PARTY_NOTICES.md`.
- Include `LICENSE` and `THIRD_PARTY_NOTICES.md` in every release bundle.
- When adding or replacing a bundled dependency, verify redistribution terms and update the notices in the same change.
- Add copyright notices for new contributions without replacing existing authors' notices.

## Completion standard

A change is complete when relevant focused tests and `make test` pass, generated files are excluded, documentation matches the implementation, and the final summary states what changed, what was tested, and any Lightroom-only verification that remains.
