# MquickjsEx

Execute JavaScript inside your Elixir process using [mquickjs](https://github.com/bellard/mquickjs).

> **Work in Progress** - This library is under active development.

## Inspiration

- [tv-labs/lua](https://github.com/tv-labs/lua) - Elixir wrapper around luerl for executing Lua inside Elixir process
- [pythonx](https://github.com/livebook-dev/pythonx) - Python execution inside Elixir process

## Installation

```elixir
def deps do
  [
    {:mquickjs_ex, "~> 0.1.0"}
  ]
end
```

## License

MIT

### Third-Party Code

This library includes vendored code from [mquickjs](https://github.com/bellard/mquickjs) (Micro QuickJS Javascript Engine) by Fabrice Bellard and Charlie Gordon, licensed under the MIT License. See `c_src/vendor/LICENSE` for details.
