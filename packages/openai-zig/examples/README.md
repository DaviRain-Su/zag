# openai-zig examples

Build (Zig 0.16 Juicy Main):

```sh
zig build examples -Dexamples=true
# optional filter
zig build examples -Dexamples=true -Dexamples_filter=chat_completion,models_list
# run one
zig build run-chat_completion -Dexamples=true
```

Auth: set `OPENAI_API_KEY` / `DEEPSEEK_API_KEY` or `config/config.toml`.
