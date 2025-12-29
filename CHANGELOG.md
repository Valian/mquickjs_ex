# Changelog

## UNRELEASED

- Initial release of MquickjsEx
- Embed MQuickJS JavaScript engine directly in Elixir processes via NIFs
- Bidirectional function calls between Elixir and JavaScript using trampoline pattern
- Automatic type conversion between Elixir and JavaScript types (nil, booleans, numbers, strings, lists, maps, functions)
- `MquickjsEx.API` behaviour for defining reusable function modules with `defjs` macro
- Support for nested scopes in API modules (e.g., `utils.math.add`)
- Variadic function support via `@variadic true` attribute
- Private storage for associating Elixir data with contexts without JavaScript exposure
- Configurable memory limits (default 64KB, minimum 10KB)
- Sandboxed execution with no file system or network access
