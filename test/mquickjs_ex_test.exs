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

  # ============================================================================
  # Phase 3: Trampoline Pattern
  # ============================================================================

  describe "Phase 3: basic callback invocation" do
    test "run with no callbacks works like eval" do
      {:ok, ctx} = MquickjsEx.new(memory: @default_memory)
      {:ok, result, _ctx} = MquickjsEx.run(ctx, "1 + 2", %{})
      assert result == 3
    end

    test "run with single callback" do
      {:ok, ctx} = MquickjsEx.new(memory: @default_memory)

      callbacks = %{
        "double" => fn [x] -> x * 2 end
      }

      {:ok, result, _ctx} = MquickjsEx.run(ctx, "double(21)", callbacks)
      assert result == 42
    end

    test "run with callback returning string" do
      {:ok, ctx} = MquickjsEx.new(memory: @default_memory)

      callbacks = %{
        "greet" => fn [name] -> "Hello, #{name}!" end
      }

      {:ok, result, _ctx} = MquickjsEx.run(ctx, ~s|greet("World")|, callbacks)
      assert result == "Hello, World!"
    end

    test "run with callback returning list" do
      {:ok, ctx} = MquickjsEx.new(memory: @default_memory)

      callbacks = %{
        "get_items" => fn [] -> [1, 2, 3] end
      }

      {:ok, result, _ctx} = MquickjsEx.run(ctx, "get_items()", callbacks)
      assert result == [1, 2, 3]
    end

    test "run with callback returning map" do
      {:ok, ctx} = MquickjsEx.new(memory: @default_memory)

      callbacks = %{
        "get_user" => fn [id] -> %{"id" => id, "name" => "Alice"} end
      }

      {:ok, result, _ctx} = MquickjsEx.run(ctx, "get_user(1)", callbacks)
      assert result == %{"id" => 1, "name" => "Alice"}
    end

    test "run with multiple arguments" do
      {:ok, ctx} = MquickjsEx.new(memory: @default_memory)

      callbacks = %{
        "add" => fn [a, b] -> a + b end
      }

      {:ok, result, _ctx} = MquickjsEx.run(ctx, "add(10, 32)", callbacks)
      assert result == 42
    end

    test "run with no arguments" do
      {:ok, ctx} = MquickjsEx.new(memory: @default_memory)

      callbacks = %{
        "get_answer" => fn [] -> 42 end
      }

      {:ok, result, _ctx} = MquickjsEx.run(ctx, "get_answer()", callbacks)
      assert result == 42
    end
  end

  describe "Phase 3: multiple sequential callbacks" do
    test "two callbacks in sequence" do
      {:ok, ctx} = MquickjsEx.new(memory: @default_memory)

      callbacks = %{
        "fetch_a" => fn [] -> 10 end,
        "fetch_b" => fn [] -> 20 end
      }

      code = """
      var a = fetch_a();
      var b = fetch_b();
      a + b
      """

      {:ok, result, _ctx} = MquickjsEx.run(ctx, code, callbacks)
      assert result == 30
    end

    test "three callbacks in sequence" do
      {:ok, ctx} = MquickjsEx.new(memory: @default_memory)

      callbacks = %{
        "step1" => fn [] -> 1 end,
        "step2" => fn [x] -> x * 2 end,
        "step3" => fn [x] -> x + 10 end
      }

      code = """
      var a = step1();
      var b = step2(a);
      var c = step3(b);
      c
      """

      {:ok, result, _ctx} = MquickjsEx.run(ctx, code, callbacks)
      # step1() -> 1, step2(1) -> 2, step3(2) -> 12
      assert result == 12
    end

    test "same callback called multiple times" do
      {:ok, ctx} = MquickjsEx.new(memory: @default_memory)

      counter = :counters.new(1, [])

      callbacks = %{
        "next" => fn [] ->
          :counters.add(counter, 1, 1)
          :counters.get(counter, 1)
        end
      }

      code = """
      var a = next();
      var b = next();
      var c = next();
      [a, b, c]
      """

      {:ok, result, _ctx} = MquickjsEx.run(ctx, code, callbacks)
      assert result == [1, 2, 3]
    end
  end

  describe "Phase 3: callback result used in computations" do
    test "callback result used in arithmetic" do
      {:ok, ctx} = MquickjsEx.new(memory: @default_memory)

      callbacks = %{
        "get_base" => fn [] -> 100 end
      }

      {:ok, result, _ctx} = MquickjsEx.run(ctx, "get_base() * 2 + 5", callbacks)
      assert result == 205
    end

    test "callback result used in string concatenation" do
      {:ok, ctx} = MquickjsEx.new(memory: @default_memory)

      callbacks = %{
        "get_name" => fn [] -> "World" end
      }

      {:ok, result, _ctx} = MquickjsEx.run(ctx, ~s|"Hello, " + get_name() + "!"|, callbacks)
      assert result == "Hello, World!"
    end

    test "callback result used in array operations" do
      {:ok, ctx} = MquickjsEx.new(memory: @default_memory)

      callbacks = %{
        "get_items" => fn [] -> [1, 2, 3] end
      }

      code = """
      var items = get_items();
      items.push(4);
      items
      """

      {:ok, result, _ctx} = MquickjsEx.run(ctx, code, callbacks)
      assert result == [1, 2, 3, 4]
    end

    test "callback result used in object operations" do
      {:ok, ctx} = MquickjsEx.new(memory: @default_memory)

      callbacks = %{
        "get_config" => fn [] -> %{"debug" => false} end
      }

      code = """
      var config = get_config();
      config.debug = true;
      config.timeout = 5000;
      config
      """

      {:ok, result, _ctx} = MquickjsEx.run(ctx, code, callbacks)
      assert result == %{"debug" => true, "timeout" => 5000}
    end
  end

  describe "Phase 3: nested callbacks" do
    test "callback in conditional branch" do
      {:ok, ctx} = MquickjsEx.new(memory: @default_memory)

      callbacks = %{
        "should_proceed" => fn [] -> true end,
        "get_value" => fn [] -> 42 end
      }

      code = """
      if (should_proceed()) {
        get_value()
      } else {
        0
      }
      """

      {:ok, result, _ctx} = MquickjsEx.run(ctx, code, callbacks)
      assert result == 42
    end

    test "callback in loop" do
      {:ok, ctx} = MquickjsEx.new(memory: @default_memory)

      callbacks = %{
        "get_item" => fn [i] -> i * 10 end
      }

      code = """
      var sum = 0;
      for (var i = 0; i < 3; i++) {
        sum = sum + get_item(i);
      }
      sum
      """

      {:ok, result, _ctx} = MquickjsEx.run(ctx, code, callbacks)
      # 0*10 + 1*10 + 2*10 = 30
      assert result == 30
    end

    test "callback result passed to another callback" do
      {:ok, ctx} = MquickjsEx.new(memory: @default_memory)

      callbacks = %{
        "fetch_id" => fn [] -> 42 end,
        "fetch_user" => fn [id] -> %{"id" => id, "name" => "User#{id}"} end
      }

      code = """
      var id = fetch_id();
      var user = fetch_user(id);
      user.name
      """

      {:ok, result, _ctx} = MquickjsEx.run(ctx, code, callbacks)
      assert result == "User42"
    end
  end

  describe "Phase 3: error handling" do
    test "unknown callback returns error" do
      {:ok, ctx} = MquickjsEx.new(memory: @default_memory)

      {:error, reason} = MquickjsEx.run(ctx, "unknown_func()", %{})
      assert reason =~ "unknown_func"
    end

    test "JS error propagates correctly" do
      {:ok, ctx} = MquickjsEx.new(memory: @default_memory)

      callbacks = %{
        "get_value" => fn [] -> 42 end
      }

      {:error, _reason} = MquickjsEx.run(ctx, "undefined_var", callbacks)
    end

    test "callback exception is caught" do
      {:ok, ctx} = MquickjsEx.new(memory: @default_memory)

      callbacks = %{
        "fail" => fn [] -> raise "intentional error" end
      }

      {:error, reason} = MquickjsEx.run(ctx, "fail()", callbacks)
      assert reason =~ "Callback error"
      assert reason =~ "intentional error"
    end
  end

  describe "Phase 3: run! function" do
    test "run! returns {result, ctx} on success" do
      {:ok, ctx} = MquickjsEx.new(memory: @default_memory)

      callbacks = %{
        "double" => fn [x] -> x * 2 end
      }

      {result, ^ctx} = MquickjsEx.run!(ctx, "double(21)", callbacks)
      assert result == 42
    end

    test "run! raises on error" do
      {:ok, ctx} = MquickjsEx.new(memory: @default_memory)

      assert_raise RuntimeError, ~r/JS Error/, fn ->
        MquickjsEx.run!(ctx, "unknown_func()", %{})
      end
    end
  end

  describe "Phase 3: complex scenarios" do
    test "simulated HTTP fetch pattern" do
      {:ok, ctx} = MquickjsEx.new(memory: @default_memory)

      callbacks = %{
        "fetch_data" => fn [url] ->
          # Simulate HTTP response
          %{"url" => url, "status" => 200, "body" => "response from #{url}"}
        end
      }

      code = """
      var response = fetch_data("https://api.example.com/data");
      response.body
      """

      {:ok, result, _ctx} = MquickjsEx.run(ctx, code, callbacks)
      assert result == "response from https://api.example.com/data"
    end

    test "multiple fetch with aggregation" do
      {:ok, ctx} = MquickjsEx.new(memory: @default_memory)

      callbacks = %{
        "fetch_user" => fn [id] -> %{"id" => id, "name" => "User#{id}"} end
      }

      code = """
      var user1 = fetch_user(1);
      var user2 = fetch_user(2);
      var user3 = fetch_user(3);
      [user1.name, user2.name, user3.name]
      """

      {:ok, result, _ctx} = MquickjsEx.run(ctx, code, callbacks)
      assert result == ["User1", "User2", "User3"]
    end

    test "JSON parsing pattern" do
      {:ok, ctx} = MquickjsEx.new(memory: @default_memory)

      callbacks = %{
        "fetch_json" => fn [_url] ->
          ~s|{"items": [1, 2, 3], "count": 3}|
        end
      }

      code = """
      var json_str = fetch_json("http://example.com");
      var data = JSON.parse(json_str);
      data.count
      """

      {:ok, result, _ctx} = MquickjsEx.run(ctx, code, callbacks)
      assert result == 3
    end
  end
end
