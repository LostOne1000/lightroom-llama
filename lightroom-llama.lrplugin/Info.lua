return {
    VERSION = {
        major = 1,
        minor = 0,
        revision = 0
    },
    LrPluginName = "Lightroom Llama",
    LrPluginDescription = "Generate titles, captions, and organized keywords for photos using Ollama models directly from Lightroom Classic.",
    LrToolkitIdentifier = "com.thejoltjoker.lightroom.llama",
    LrPluginInfoUrl = "https://github.com/LostOne1000/lightroom-llama",
    LrPluginInfoUrlProvider = "https://github.com/LostOne1000",
    LrSdkVersion = 10.0,
    LrSdkMinimumVersion = 5.0,
    LrLibraryMenuItems = {{
        title = "Lightroom Llama...",
        file = "LrLlama.lua",
        enabledWhen = "photosSelected"
    }, {
        title = "Batch Process with Llama...",
        file = "BatchLrLlama.lua",
        enabledWhen = "photosSelected"
    }, {
        title = "Reset Metadata...",
        file = "ResetMetadata.lua",
        enabledWhen = "photosSelected"
    }},
    LrExportMenuItems = {{
        title = "Lightroom Llama...",
        file = "LrLlama.lua",
        enabledWhen = "photosSelected"
    }, {
        title = "Batch Process with Llama...",
        file = "BatchLrLlama.lua",
        enabledWhen = "photosSelected"
    }, {
        title = "Reset Metadata...",
        file = "ResetMetadata.lua",
        enabledWhen = "photosSelected"
    }}
}
