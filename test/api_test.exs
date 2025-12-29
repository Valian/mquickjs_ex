defmodule MquickjsEx.APITest do
  use ExUnit.Case

  # Use 256KB for tests
  @default_memory 256 * 1024

  # ============================================================================
  # Test API Modules
  # ============================================================================

  defmodule BasicAPI do
    use MquickjsEx.API

    defjs(add(a, b), do: a + b)
    defjs(multiply(a, b), do: a * b)
    defjs(greet(name), do: "Hello, #{name}!")
  end

  defmodule ScopedAPI do
    use MquickjsEx.API, scope: "math"

    defjs(add(a, b), do: a + b)
    defjs(subtract(a, b), do: a - b)
  end

  defmodule NestedScopeAPI do
    use MquickjsEx.API, scope: "utils.math"

    defjs(divide(a, b), do: a / b)
  end

  defmodule ScopeAsListAPI do
    use MquickjsEx.API, scope: [:helpers, :string]

    defjs(upcase(s), do: String.upcase(s))
    defjs(downcase(s), do: String.downcase(s))
  end

  defmodule StateAccessAPI do
    use MquickjsEx.API

    defjs get_config(key), state do
      MquickjsEx.get!(state, key)
    end

    defjs set_config(key, value), state do
      new_state = MquickjsEx.set!(state, key, value)
      {nil, new_state}
    end

    defjs get_and_increment(key), state do
      value = MquickjsEx.get!(state, key)
      new_state = MquickjsEx.set!(state, key, value + 1)
      {value, new_state}
    end
  end

  defmodule VariadicAPI do
    use MquickjsEx.API

    @variadic true
    defjs(sum(args), do: Enum.sum(args))

    @variadic true
    defjs(join(args), do: Enum.join(args, " "))

    # Non-variadic function after variadic ones
    defjs(double(x), do: x * 2)
  end

  defmodule VariadicWithStateAPI do
    use MquickjsEx.API

    @variadic true
    defjs sum_and_store(args), state do
      total = Enum.sum(args)
      new_state = MquickjsEx.set!(state, [:last_sum], total)
      {total, new_state}
    end
  end

  defmodule GuardAPI do
    use MquickjsEx.API

    defjs(double(x) when is_number(x), do: x * 2)
    defjs(double(x) when is_binary(x), do: x <> x)
  end

  defmodule DestructuringAPI do
    use MquickjsEx.API

    defjs(first([head | _tail]), do: head)
    defjs(first([]), do: nil)

    defjs(get_name(%{"name" => name}), do: name)
    defjs(get_name(_), do: "unknown")
  end

  defmodule InstallAPI do
    use MquickjsEx.API, scope: "installed"

    defjs(get_version, do: 42)

    @impl MquickjsEx.API
    def install(ctx, _scope, _data) do
      MquickjsEx.set!(ctx, [:installed, :initialized], true)
    end
  end

  defmodule InstallWithCodeAPI do
    use MquickjsEx.API

    defjs(get_constant, do: "from elixir")

    @impl MquickjsEx.API
    def install(_ctx, _scope, _data) do
      "var GLOBAL_CONSTANT = 'from install';"
    end
  end

  defmodule RuntimeExceptionAPI do
    use MquickjsEx.API, scope: "safe"

    defjs divide(a, b) do
      if b == 0 do
        runtime_exception!("division by zero")
      else
        a / b
      end
    end
  end

  # ============================================================================
  # Basic API Tests
  # ============================================================================

  describe "basic API" do
    test "load and call simple functions" do
      {:ok, ctx} = MquickjsEx.new(memory: @default_memory)
      {:ok, ctx} = MquickjsEx.load_api(ctx, BasicAPI)

      {:ok, result} = MquickjsEx.eval(ctx, "add(1, 2)")
      assert result == 3

      {:ok, result} = MquickjsEx.eval(ctx, "multiply(3, 4)")
      assert result == 12

      {:ok, result} = MquickjsEx.eval(ctx, ~s|greet("World")|)
      assert result == "Hello, World!"
    end

    test "API functions tracked in context" do
      {:ok, ctx} = MquickjsEx.new(memory: @default_memory)
      {:ok, ctx} = MquickjsEx.load_api(ctx, BasicAPI)

      assert BasicAPI in ctx.loaded_apis
    end
  end

  # ============================================================================
  # Scoped API Tests
  # ============================================================================

  describe "scoped API" do
    test "single-level scope with string" do
      {:ok, ctx} = MquickjsEx.new(memory: @default_memory)
      {:ok, ctx} = MquickjsEx.load_api(ctx, ScopedAPI)

      {:ok, result} = MquickjsEx.eval(ctx, "math.add(10, 5)")
      assert result == 15

      {:ok, result} = MquickjsEx.eval(ctx, "math.subtract(10, 5)")
      assert result == 5
    end

    test "nested scope with string" do
      {:ok, ctx} = MquickjsEx.new(memory: @default_memory)
      {:ok, ctx} = MquickjsEx.load_api(ctx, NestedScopeAPI)

      {:ok, result} = MquickjsEx.eval(ctx, "utils.math.divide(10, 2)")
      assert result == 5.0
    end

    test "scope as list" do
      {:ok, ctx} = MquickjsEx.new(memory: @default_memory)
      {:ok, ctx} = MquickjsEx.load_api(ctx, ScopeAsListAPI)

      {:ok, result} = MquickjsEx.eval(ctx, ~s|helpers.string.upcase("hello")|)
      assert result == "HELLO"

      {:ok, result} = MquickjsEx.eval(ctx, ~s|helpers.string.downcase("WORLD")|)
      assert result == "world"
    end

    test "multiple scoped APIs can coexist" do
      {:ok, ctx} = MquickjsEx.new(memory: @default_memory)
      {:ok, ctx} = MquickjsEx.load_api(ctx, ScopedAPI)
      {:ok, ctx} = MquickjsEx.load_api(ctx, NestedScopeAPI)

      {:ok, result} = MquickjsEx.eval(ctx, "math.add(1, 2) + utils.math.divide(10, 2)")
      assert result == 8.0
    end
  end

  # ============================================================================
  # State Access Tests
  # ============================================================================

  describe "state access" do
    test "read state from defjs function" do
      {:ok, ctx} = MquickjsEx.new(memory: @default_memory)
      ctx = MquickjsEx.set!(ctx, :mykey, "myvalue")
      {:ok, ctx} = MquickjsEx.load_api(ctx, StateAccessAPI)

      {:ok, result} = MquickjsEx.eval(ctx, ~s|get_config("mykey")|)
      assert result == "myvalue"
    end

    test "write state from defjs function" do
      {:ok, ctx} = MquickjsEx.new(memory: @default_memory)
      {:ok, ctx} = MquickjsEx.load_api(ctx, StateAccessAPI)

      {:ok, _} = MquickjsEx.eval(ctx, ~s|set_config("counter", 42)|)
      # State changes are local to the callback, need to verify through another callback
      # that reads the state
    end

    test "read and modify state" do
      {:ok, ctx} = MquickjsEx.new(memory: @default_memory)
      ctx = MquickjsEx.set!(ctx, :counter, 0)
      {:ok, ctx} = MquickjsEx.load_api(ctx, StateAccessAPI)

      code = """
      var a = get_and_increment("counter");
      var b = get_and_increment("counter");
      var c = get_and_increment("counter");
      [a, b, c]
      """

      {:ok, result} = MquickjsEx.eval(ctx, code)
      assert result == [0, 1, 2]
    end
  end

  # ============================================================================
  # Variadic Function Tests
  # ============================================================================

  describe "variadic functions" do
    test "variadic function receives all arguments as list" do
      {:ok, ctx} = MquickjsEx.new(memory: @default_memory)
      {:ok, ctx} = MquickjsEx.load_api(ctx, VariadicAPI)

      {:ok, result} = MquickjsEx.eval(ctx, "sum(1, 2, 3, 4, 5)")
      assert result == 15

      {:ok, result} = MquickjsEx.eval(ctx, "sum(10)")
      assert result == 10

      {:ok, result} = MquickjsEx.eval(ctx, "sum()")
      assert result == 0
    end

    test "variadic string join" do
      {:ok, ctx} = MquickjsEx.new(memory: @default_memory)
      {:ok, ctx} = MquickjsEx.load_api(ctx, VariadicAPI)

      {:ok, result} = MquickjsEx.eval(ctx, ~s|join("Hello", "World", "!")|)
      assert result == "Hello World !"
    end

    test "non-variadic function after variadic" do
      {:ok, ctx} = MquickjsEx.new(memory: @default_memory)
      {:ok, ctx} = MquickjsEx.load_api(ctx, VariadicAPI)

      {:ok, result} = MquickjsEx.eval(ctx, "double(21)")
      assert result == 42
    end

    test "variadic with state" do
      {:ok, ctx} = MquickjsEx.new(memory: @default_memory)
      {:ok, ctx} = MquickjsEx.load_api(ctx, VariadicWithStateAPI)

      code = """
      var first = sum_and_store(1, 2, 3);
      var second = sum_and_store(10, 20);
      [first, second]
      """

      {:ok, result} = MquickjsEx.eval(ctx, code)
      assert result == [6, 30]
    end
  end

  # ============================================================================
  # Guard Tests
  # ============================================================================

  describe "guards" do
    test "function with guards dispatches correctly" do
      {:ok, ctx} = MquickjsEx.new(memory: @default_memory)
      {:ok, ctx} = MquickjsEx.load_api(ctx, GuardAPI)

      {:ok, result} = MquickjsEx.eval(ctx, "double(21)")
      assert result == 42

      {:ok, result} = MquickjsEx.eval(ctx, ~s|double("ab")|)
      assert result == "abab"
    end
  end

  # ============================================================================
  # Destructuring Tests
  # ============================================================================

  describe "argument destructuring" do
    test "list destructuring" do
      {:ok, ctx} = MquickjsEx.new(memory: @default_memory)
      {:ok, ctx} = MquickjsEx.load_api(ctx, DestructuringAPI)

      {:ok, result} = MquickjsEx.eval(ctx, "first([1, 2, 3])")
      assert result == 1

      {:ok, result} = MquickjsEx.eval(ctx, "first([])")
      assert result == nil
    end

    test "map destructuring" do
      {:ok, ctx} = MquickjsEx.new(memory: @default_memory)
      {:ok, ctx} = MquickjsEx.load_api(ctx, DestructuringAPI)

      {:ok, result} = MquickjsEx.eval(ctx, ~s|get_name({name: "Alice"})|)
      assert result == "Alice"

      {:ok, result} = MquickjsEx.eval(ctx, ~s|get_name({foo: "bar"})|)
      assert result == "unknown"
    end
  end

  # ============================================================================
  # Install Callback Tests
  # ============================================================================

  describe "install callback" do
    test "install modifies context" do
      {:ok, ctx} = MquickjsEx.new(memory: @default_memory)
      {:ok, ctx} = MquickjsEx.load_api(ctx, InstallAPI)

      {:ok, result} = MquickjsEx.eval(ctx, "installed.initialized")
      assert result == true

      {:ok, result} = MquickjsEx.eval(ctx, "installed.get_version()")
      assert result == 42
    end

    test "install returns JS code" do
      {:ok, ctx} = MquickjsEx.new(memory: @default_memory)
      {:ok, ctx} = MquickjsEx.load_api(ctx, InstallWithCodeAPI)

      {:ok, result} = MquickjsEx.eval(ctx, "GLOBAL_CONSTANT")
      assert result == "from install"

      {:ok, result} = MquickjsEx.eval(ctx, "get_constant()")
      assert result == "from elixir"
    end
  end

  # ============================================================================
  # Runtime Exception Tests
  # ============================================================================

  describe "runtime_exception!" do
    test "raises with scope and function context" do
      {:ok, ctx} = MquickjsEx.new(memory: @default_memory)
      {:ok, ctx} = MquickjsEx.load_api(ctx, RuntimeExceptionAPI)

      {:ok, result} = MquickjsEx.eval(ctx, "safe.divide(10, 2)")
      assert result == 5.0

      {:error, reason} = MquickjsEx.eval(ctx, "safe.divide(10, 0)")
      assert reason =~ "division by zero"
    end
  end

  # ============================================================================
  # Mixed Usage Tests
  # ============================================================================

  describe "mixed usage with set!" do
    test "API functions work alongside set! functions" do
      {:ok, ctx} = MquickjsEx.new(memory: @default_memory)
      {:ok, ctx} = MquickjsEx.load_api(ctx, BasicAPI)
      ctx = MquickjsEx.set!(ctx, :triple, fn [x] -> x * 3 end)

      {:ok, result} = MquickjsEx.eval(ctx, "add(1, 2) + triple(10)")
      assert result == 33
    end

    test "scoped API with global set! function" do
      {:ok, ctx} = MquickjsEx.new(memory: @default_memory)
      {:ok, ctx} = MquickjsEx.load_api(ctx, ScopedAPI)
      ctx = MquickjsEx.set!(ctx, :double, fn [x] -> x * 2 end)

      {:ok, result} = MquickjsEx.eval(ctx, "double(math.add(1, 2))")
      assert result == 6
    end
  end

  # ============================================================================
  # Scope Function Tests
  # ============================================================================

  describe "scope/0 callback" do
    test "returns correct scope for different definitions" do
      assert BasicAPI.scope() == []
      assert ScopedAPI.scope() == ["math"]
      assert NestedScopeAPI.scope() == ["utils", "math"]
      assert ScopeAsListAPI.scope() == ["helpers", "string"]
    end
  end

  # ============================================================================
  # Error Handling Tests
  # ============================================================================

  describe "load_api error handling" do
    test "load_api returns error for non-API module" do
      {:ok, ctx} = MquickjsEx.new(memory: @default_memory)
      {:error, reason} = MquickjsEx.load_api(ctx, String)
      assert reason =~ "not a valid MquickjsEx.API"
    end

    test "load_api! raises for non-API module" do
      {:ok, ctx} = MquickjsEx.new(memory: @default_memory)

      assert_raise MquickjsEx.RuntimeException, ~r/not a valid MquickjsEx.API/, fn ->
        MquickjsEx.load_api!(ctx, String)
      end
    end
  end

  # ============================================================================
  # __js_functions__ Tests
  # ============================================================================

  describe "__js_functions__/0" do
    test "returns list of function metadata" do
      functions = BasicAPI.__js_functions__()

      assert {:add, false, false} in functions
      assert {:multiply, false, false} in functions
      assert {:greet, false, false} in functions
    end

    test "tracks variadic attribute" do
      functions = VariadicAPI.__js_functions__()

      assert {:sum, false, true} in functions
      assert {:join, false, true} in functions
      assert {:double, false, false} in functions
    end

    test "tracks uses_state attribute" do
      functions = StateAccessAPI.__js_functions__()

      assert {:get_config, true, false} in functions
      assert {:set_config, true, false} in functions
    end
  end
end
