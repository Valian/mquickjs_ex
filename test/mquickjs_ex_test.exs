defmodule MquickjsExTest do
  use ExUnit.Case

  # Use 256KB for tests
  @default_memory 256 * 1024

  describe "Phase 1 validation" do
    test "can create context" do
      assert {:ok, ctx} = MquickjsEx.new(memory: @default_memory)
      assert is_reference(ctx)
    end

    test "can create context with custom memory size" do
      assert {:ok, ctx} = MquickjsEx.new(memory: 131_072)
      assert is_reference(ctx)
    end

    test "can eval simple code" do
      {:ok, ctx} = MquickjsEx.new(memory: @default_memory)
      # var statements return undefined (nil)
      assert {:ok, nil} = MquickjsEx.eval(ctx, "var x = 1 + 2;")
    end

    test "can eval multiple statements" do
      {:ok, ctx} = MquickjsEx.new(memory: @default_memory)
      assert {:ok, nil} = MquickjsEx.eval(ctx, "var x = 1; var y = 2; var z = x + y;")
    end

    test "can use JS built-ins" do
      {:ok, ctx} = MquickjsEx.new(memory: @default_memory)
      # push returns new length
      assert {:ok, 4} = MquickjsEx.eval(ctx, "var arr = [1, 2, 3]; arr.push(4);")
    end

    test "can use Math object" do
      {:ok, ctx} = MquickjsEx.new(memory: @default_memory)
      assert {:ok, nil} = MquickjsEx.eval(ctx, "var x = Math.sqrt(16);")
    end

    test "can use JSON" do
      {:ok, ctx} = MquickjsEx.new(memory: @default_memory)
      assert {:ok, nil} = MquickjsEx.eval(ctx, ~s|var obj = JSON.parse('{"a": 1}');|)
    end

    test "eval returns error on syntax error" do
      {:ok, ctx} = MquickjsEx.new(memory: @default_memory)
      result = MquickjsEx.eval(ctx, "var x = ")
      assert match?({:error, _}, result)
    end

    test "context cleanup works (no crash on GC)" do
      for _ <- 1..100 do
        {:ok, _ctx} = MquickjsEx.new(memory: @default_memory)
      end

      :erlang.garbage_collect()
      assert true
    end
  end

  describe "Phase 2: JS → Elixir primitives" do
    test "eval returns integers" do
      {:ok, ctx} = MquickjsEx.new(memory: @default_memory)
      assert {:ok, 42} = MquickjsEx.eval(ctx, "42")
      assert {:ok, -17} = MquickjsEx.eval(ctx, "-17")
      assert {:ok, 0} = MquickjsEx.eval(ctx, "0")
    end

    test "eval returns floats" do
      {:ok, ctx} = MquickjsEx.new(memory: @default_memory)
      assert {:ok, 3.14} = MquickjsEx.eval(ctx, "3.14")
      assert {:ok, -0.5} = MquickjsEx.eval(ctx, "-0.5")
    end

    test "eval returns whole floats as integers" do
      {:ok, ctx} = MquickjsEx.new(memory: @default_memory)
      # 4.0 should be returned as 4
      assert {:ok, 4} = MquickjsEx.eval(ctx, "4.0")
    end

    test "eval returns strings" do
      {:ok, ctx} = MquickjsEx.new(memory: @default_memory)
      assert {:ok, "hello"} = MquickjsEx.eval(ctx, ~s|"hello"|)
      assert {:ok, ""} = MquickjsEx.eval(ctx, ~s|""|)
      assert {:ok, "hello world"} = MquickjsEx.eval(ctx, ~s|"hello" + " " + "world"|)
    end

    test "eval returns booleans" do
      {:ok, ctx} = MquickjsEx.new(memory: @default_memory)
      assert {:ok, true} = MquickjsEx.eval(ctx, "true")
      assert {:ok, false} = MquickjsEx.eval(ctx, "false")
      assert {:ok, true} = MquickjsEx.eval(ctx, "1 === 1")
      assert {:ok, false} = MquickjsEx.eval(ctx, "1 === 2")
    end

    test "eval returns nil for null and undefined" do
      {:ok, ctx} = MquickjsEx.new(memory: @default_memory)
      assert {:ok, nil} = MquickjsEx.eval(ctx, "null")
      assert {:ok, nil} = MquickjsEx.eval(ctx, "undefined")
    end
  end

  describe "Phase 2: JS → Elixir arrays" do
    test "eval returns empty array" do
      {:ok, ctx} = MquickjsEx.new(memory: @default_memory)
      assert {:ok, []} = MquickjsEx.eval(ctx, "[]")
    end

    test "eval returns array of integers" do
      {:ok, ctx} = MquickjsEx.new(memory: @default_memory)
      assert {:ok, [1, 2, 3]} = MquickjsEx.eval(ctx, "[1, 2, 3]")
    end

    test "eval returns array of mixed types" do
      {:ok, ctx} = MquickjsEx.new(memory: @default_memory)
      assert {:ok, [1, "two", true, nil]} = MquickjsEx.eval(ctx, ~s|[1, "two", true, null]|)
    end

    test "eval returns nested arrays" do
      {:ok, ctx} = MquickjsEx.new(memory: @default_memory)
      assert {:ok, [[1, 2], [3, 4]]} = MquickjsEx.eval(ctx, "[[1, 2], [3, 4]]")
    end
  end

  describe "Phase 2: JS → Elixir objects" do
    test "eval returns empty object" do
      {:ok, ctx} = MquickjsEx.new(memory: @default_memory)
      assert {:ok, %{}} = MquickjsEx.eval(ctx, "({})")
    end

    test "eval returns object with properties" do
      {:ok, ctx} = MquickjsEx.new(memory: @default_memory)
      assert {:ok, %{"a" => 1, "b" => 2}} = MquickjsEx.eval(ctx, "({a: 1, b: 2})")
    end

    test "eval returns nested objects" do
      {:ok, ctx} = MquickjsEx.new(memory: @default_memory)
      assert {:ok, %{"outer" => %{"inner" => 42}}} =
               MquickjsEx.eval(ctx, "({outer: {inner: 42}})")
    end

    test "eval returns object with array values" do
      {:ok, ctx} = MquickjsEx.new(memory: @default_memory)
      assert {:ok, %{"items" => [1, 2, 3]}} = MquickjsEx.eval(ctx, "({items: [1, 2, 3]})")
    end

    test "functions are not serializable" do
      {:ok, ctx} = MquickjsEx.new(memory: @default_memory)
      assert {:error, :function_not_serializable} =
               MquickjsEx.eval(ctx, "(function() {})")
    end
  end

  describe "Phase 2: Elixir → JS (via set/get)" do
    test "set and get integer" do
      {:ok, ctx} = MquickjsEx.new(memory: @default_memory)
      assert :ok = MquickjsEx.set(ctx, :x, 42)
      assert {:ok, 42} = MquickjsEx.get(ctx, :x)
    end

    test "set and get float" do
      {:ok, ctx} = MquickjsEx.new(memory: @default_memory)
      assert :ok = MquickjsEx.set(ctx, :pi, 3.14159)
      assert {:ok, pi} = MquickjsEx.get(ctx, :pi)
      assert_in_delta pi, 3.14159, 0.00001
    end

    test "set and get string" do
      {:ok, ctx} = MquickjsEx.new(memory: @default_memory)
      assert :ok = MquickjsEx.set(ctx, :message, "Hello from Elixir")
      assert {:ok, "Hello from Elixir"} = MquickjsEx.get(ctx, :message)
    end

    test "set and get boolean" do
      {:ok, ctx} = MquickjsEx.new(memory: @default_memory)
      assert :ok = MquickjsEx.set(ctx, :flag, true)
      assert {:ok, true} = MquickjsEx.get(ctx, :flag)
      assert :ok = MquickjsEx.set(ctx, :flag, false)
      assert {:ok, false} = MquickjsEx.get(ctx, :flag)
    end

    test "set and get nil" do
      {:ok, ctx} = MquickjsEx.new(memory: @default_memory)
      assert :ok = MquickjsEx.set(ctx, :nothing, nil)
      assert {:ok, nil} = MquickjsEx.get(ctx, :nothing)
    end

    test "set and get list" do
      {:ok, ctx} = MquickjsEx.new(memory: @default_memory)
      assert :ok = MquickjsEx.set(ctx, :items, [1, 2, 3])
      assert {:ok, [1, 2, 3]} = MquickjsEx.get(ctx, :items)
    end

    test "set and get map" do
      {:ok, ctx} = MquickjsEx.new(memory: @default_memory)
      assert :ok = MquickjsEx.set(ctx, :config, %{"debug" => true, "timeout" => 5000})
      assert {:ok, %{"debug" => true, "timeout" => 5000}} = MquickjsEx.get(ctx, :config)
    end

    test "set and get nested structure" do
      {:ok, ctx} = MquickjsEx.new(memory: @default_memory)
      data = %{
        "users" => [
          %{"name" => "Alice", "age" => 30},
          %{"name" => "Bob", "age" => 25}
        ],
        "count" => 2
      }

      assert :ok = MquickjsEx.set(ctx, :data, data)
      assert {:ok, ^data} = MquickjsEx.get(ctx, :data)
    end

    test "atom values become strings" do
      {:ok, ctx} = MquickjsEx.new(memory: @default_memory)
      # atoms (other than true/false/nil) become JS strings
      assert :ok = MquickjsEx.set(ctx, :status, :active)
      assert {:ok, "active"} = MquickjsEx.get(ctx, :status)
    end

    test "maps with atom keys work" do
      {:ok, ctx} = MquickjsEx.new(memory: @default_memory)
      assert :ok = MquickjsEx.set(ctx, :config, %{debug: true, timeout: 5000})
      # Keys come back as strings
      assert {:ok, %{"debug" => true, "timeout" => 5000}} = MquickjsEx.get(ctx, :config)
    end
  end

  describe "Phase 2: round-trip through JS" do
    test "set value, use in JS, get result" do
      {:ok, ctx} = MquickjsEx.new(memory: @default_memory)
      :ok = MquickjsEx.set(ctx, :x, 10)
      {:ok, result} = MquickjsEx.eval(ctx, "x * 2")
      assert result == 20
    end

    test "pass array, modify in JS" do
      {:ok, ctx} = MquickjsEx.new(memory: @default_memory)
      :ok = MquickjsEx.set(ctx, :arr, [1, 2, 3])
      {:ok, _} = MquickjsEx.eval(ctx, "arr.push(4); arr.push(5);")
      {:ok, result} = MquickjsEx.get(ctx, :arr)
      assert result == [1, 2, 3, 4, 5]
    end

    test "pass object, modify in JS" do
      {:ok, ctx} = MquickjsEx.new(memory: @default_memory)
      :ok = MquickjsEx.set(ctx, :obj, %{"a" => 1})
      {:ok, _} = MquickjsEx.eval(ctx, "obj.b = 2; obj.c = 3;")
      {:ok, result} = MquickjsEx.get(ctx, :obj)
      assert result == %{"a" => 1, "b" => 2, "c" => 3}
    end
  end

  describe "state persistence" do
    test "variables persist across eval calls" do
      {:ok, ctx} = MquickjsEx.new(memory: @default_memory)
      {:ok, _} = MquickjsEx.eval(ctx, "var counter = 0;")
      {:ok, _} = MquickjsEx.eval(ctx, "counter++;")
      {:ok, _} = MquickjsEx.eval(ctx, "counter++;")
      {:ok, result} = MquickjsEx.eval(ctx, "counter")
      assert result == 2
    end

    test "functions persist across eval calls" do
      {:ok, ctx} = MquickjsEx.new(memory: @default_memory)
      {:ok, _} = MquickjsEx.eval(ctx, "function double(x) { return x * 2; }")
      {:ok, result} = MquickjsEx.eval(ctx, "double(21)")
      assert result == 42
    end
  end

  describe "garbage collection" do
    test "gc can be triggered without error" do
      {:ok, ctx} = MquickjsEx.new(memory: @default_memory)
      {:ok, _} = MquickjsEx.eval(ctx, "var arr = [1, 2, 3]; arr = null;")
      assert :ok = MquickjsEx.gc(ctx)
    end
  end

  describe "bang functions" do
    test "eval! returns {result, ctx}" do
      {:ok, ctx} = MquickjsEx.new(memory: @default_memory)
      {result, ^ctx} = MquickjsEx.eval!(ctx, "1 + 2")
      assert result == 3
    end

    test "eval! raises on error" do
      {:ok, ctx} = MquickjsEx.new(memory: @default_memory)
      assert_raise RuntimeError, ~r/JS Error/, fn ->
        MquickjsEx.eval!(ctx, "undefined_var")
      end
    end

    test "get! returns value directly" do
      {:ok, ctx} = MquickjsEx.new(memory: @default_memory)
      {_, ctx} = MquickjsEx.eval!(ctx, "var x = 42;")
      assert 42 = MquickjsEx.get!(ctx, :x)
    end

    test "set! returns ctx for chaining" do
      {:ok, ctx} = MquickjsEx.new(memory: @default_memory)
      ctx = MquickjsEx.set!(ctx, :a, 1)
      ctx = MquickjsEx.set!(ctx, :b, 2)
      assert is_reference(ctx)
      assert {:ok, 1} = MquickjsEx.get(ctx, :a)
      assert {:ok, 2} = MquickjsEx.get(ctx, :b)
    end
  end
end
