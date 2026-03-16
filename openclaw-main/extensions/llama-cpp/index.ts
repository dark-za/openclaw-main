import {
  buildLlamaCppProvider,
  configureOpenAICompatibleSelfHostedProviderNonInteractive,
  discoverOpenAICompatibleSelfHostedProvider,
  emptyPluginConfigSchema,
  promptAndConfigureOpenAICompatibleSelfHostedProviderAuth,
  type OpenClawPluginApi,
  type ProviderAuthMethodNonInteractiveContext,
} from "openclaw/plugin-sdk/core";

const PROVIDER_ID = "llama-cpp";
const DEFAULT_BASE_URL = "http://127.0.0.1:8765/v1";

const llamaCppPlugin = {
  id: "llama-cpp",
  name: "llama-cpp-python Provider",
  description: "Bundled llama-cpp-python native local inference provider plugin",
  configSchema: emptyPluginConfigSchema(),
  register(api: OpenClawPluginApi) {
    api.registerProvider({
      id: PROVIDER_ID,
      label: "llama-cpp-python",
      docsPath: "/providers/llama-cpp",
      envVars: ["LLAMA_CPP_API_KEY"],
      auth: [
        {
          id: "custom",
          label: "llama-cpp-python",
          hint: "Native local inference — no API key required",
          kind: "custom",
          run: async (ctx) =>
            promptAndConfigureOpenAICompatibleSelfHostedProviderAuth({
              cfg: ctx.config,
              prompter: ctx.prompter,
              providerId: PROVIDER_ID,
              providerLabel: "llama-cpp-python",
              defaultBaseUrl: DEFAULT_BASE_URL,
              defaultApiKeyEnvVar: "LLAMA_CPP_API_KEY",
              modelPlaceholder: "Llama-3.2-3B-Instruct-Q4_K_M",
              input: ["text", "image"],
            }),
          runNonInteractive: async (ctx: ProviderAuthMethodNonInteractiveContext) =>
            configureOpenAICompatibleSelfHostedProviderNonInteractive({
              ctx,
              providerId: PROVIDER_ID,
              providerLabel: "llama-cpp-python",
              defaultBaseUrl: DEFAULT_BASE_URL,
              defaultApiKeyEnvVar: "LLAMA_CPP_API_KEY",
              modelPlaceholder: "Llama-3.2-3B-Instruct-Q4_K_M",
              input: ["text", "image"],
            }),
        },
      ],
      discovery: {
        order: "late",
        run: async (ctx) =>
          discoverOpenAICompatibleSelfHostedProvider({
            ctx,
            providerId: PROVIDER_ID,
            buildProvider: buildLlamaCppProvider,
          }),
      },
      wizard: {
        onboarding: {
          choiceId: "llama-cpp",
          choiceLabel: "llama-cpp-python (local)",
          choiceHint: "Native GGUF inference — no cloud, no API key",
          groupId: "llama-cpp",
          groupLabel: "llama-cpp-python",
          groupHint: "Run GGUF models locally with GPU acceleration",
          methodId: "custom",
        },
        modelPicker: {
          label: "llama-cpp-python (local)",
          hint: "Enter llama-cpp-python server URL + model ID",
          methodId: "custom",
        },
      },
    });
  },
};

export default llamaCppPlugin;
