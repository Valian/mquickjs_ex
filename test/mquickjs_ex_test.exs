defmodule MquickjsExTest do
  use ExUnit.Case

  # Use 256KB for tests
  @default_memory 256 * 1024

  describe "Phase 1 validation" do
    test "can create context" do
      assert {:ok, ctx} = MquickjsEx.new(memory: @default_memory)
      assert is_struct(ctx, MquickjsEx.Context)
    end

    test "can create context with custom memory size" do
      assert {:ok, ctx} = MquickjsEx.new(memory: 131_072)
      assert is_struct(ctx, MquickjsEx.Context)
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
      assert {:ok, ctx} = MquickjsEx.set(ctx, :x, 42)
      assert {:ok, 42} = MquickjsEx.get(ctx, :x)
    end

    test "set and get float" do
      {:ok, ctx} = MquickjsEx.new(memory: @default_memory)
      assert {:ok, ctx} = MquickjsEx.set(ctx, :pi, 3.14159)
      assert {:ok, pi} = MquickjsEx.get(ctx, :pi)
      assert_in_delta pi, 3.14159, 0.00001
    end

    test "set and get string" do
      {:ok, ctx} = MquickjsEx.new(memory: @default_memory)
      assert {:ok, ctx} = MquickjsEx.set(ctx, :message, "Hello from Elixir")
      assert {:ok, "Hello from Elixir"} = MquickjsEx.get(ctx, :message)
    end

    test "set and get boolean" do
      {:ok, ctx} = MquickjsEx.new(memory: @default_memory)
      assert {:ok, ctx} = MquickjsEx.set(ctx, :flag, true)
      assert {:ok, true} = MquickjsEx.get(ctx, :flag)
      assert {:ok, ctx} = MquickjsEx.set(ctx, :flag, false)
      assert {:ok, false} = MquickjsEx.get(ctx, :flag)
    end

    test "set and get nil" do
      {:ok, ctx} = MquickjsEx.new(memory: @default_memory)
      assert {:ok, ctx} = MquickjsEx.set(ctx, :nothing, nil)
      assert {:ok, nil} = MquickjsEx.get(ctx, :nothing)
    end

    test "set and get list" do
      {:ok, ctx} = MquickjsEx.new(memory: @default_memory)
      assert {:ok, ctx} = MquickjsEx.set(ctx, :items, [1, 2, 3])
      assert {:ok, [1, 2, 3]} = MquickjsEx.get(ctx, :items)
    end

    test "set and get map" do
      {:ok, ctx} = MquickjsEx.new(memory: @default_memory)
      assert {:ok, ctx} = MquickjsEx.set(ctx, :config, %{"debug" => true, "timeout" => 5000})
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

      assert {:ok, ctx} = MquickjsEx.set(ctx, :data, data)
      assert {:ok, ^data} = MquickjsEx.get(ctx, :data)
    end

    test "atom values become strings" do
      {:ok, ctx} = MquickjsEx.new(memory: @default_memory)
      # atoms (other than true/false/nil) become JS strings
      assert {:ok, ctx} = MquickjsEx.set(ctx, :status, :active)
      assert {:ok, "active"} = MquickjsEx.get(ctx, :status)
    end

    test "maps with atom keys work" do
      {:ok, ctx} = MquickjsEx.new(memory: @default_memory)
      assert {:ok, ctx} = MquickjsEx.set(ctx, :config, %{debug: true, timeout: 5000})
      # Keys come back as strings
      assert {:ok, %{"debug" => true, "timeout" => 5000}} = MquickjsEx.get(ctx, :config)
    end
  end

  describe "Phase 2: round-trip through JS" do
    test "set value, use in JS, get result" do
      {:ok, ctx} = MquickjsEx.new(memory: @default_memory)
      {:ok, ctx} = MquickjsEx.set(ctx, :x, 10)
      {:ok, result} = MquickjsEx.eval(ctx, "x * 2")
      assert result == 20
    end

    test "pass array, modify in JS" do
      {:ok, ctx} = MquickjsEx.new(memory: @default_memory)
      {:ok, ctx} = MquickjsEx.set(ctx, :arr, [1, 2, 3])
      {:ok, _} = MquickjsEx.eval(ctx, "arr.push(4); arr.push(5);")
      {:ok, result} = MquickjsEx.get(ctx, :arr)
      assert result == [1, 2, 3, 4, 5]
    end

    test "pass object, modify in JS" do
      {:ok, ctx} = MquickjsEx.new(memory: @default_memory)
      {:ok, ctx} = MquickjsEx.set(ctx, :obj, %{"a" => 1})
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
      {result, _ctx} = MquickjsEx.eval!(ctx, "1 + 2")
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
      assert is_struct(ctx, MquickjsEx.Context)
      assert {:ok, 1} = MquickjsEx.get(ctx, :a)
      assert {:ok, 2} = MquickjsEx.get(ctx, :b)
    end
  end

  # ============================================================================
  # Callback Tests (using set + eval)
  # ============================================================================

  describe "basic callback invocation" do
    test "single callback" do
      {:ok, ctx} = MquickjsEx.new(memory: @default_memory)
      ctx = MquickjsEx.set!(ctx, :double, fn x -> x * 2 end)
      {:ok, result} = MquickjsEx.eval(ctx, "double(21)")
      assert result == 42
    end

    test "callback returning string" do
      {:ok, ctx} = MquickjsEx.new(memory: @default_memory)
      ctx = MquickjsEx.set!(ctx, :greet, fn name -> "Hello, #{name}!" end)
      {:ok, result} = MquickjsEx.eval(ctx, ~s|greet("World")|)
      assert result == "Hello, World!"
    end

    test "callback returning list" do
      {:ok, ctx} = MquickjsEx.new(memory: @default_memory)
      ctx = MquickjsEx.set!(ctx, :get_items, fn -> [1, 2, 3] end)
      {:ok, result} = MquickjsEx.eval(ctx, "get_items()")
      assert result == [1, 2, 3]
    end

    test "callback returning map" do
      {:ok, ctx} = MquickjsEx.new(memory: @default_memory)
      ctx = MquickjsEx.set!(ctx, :get_user, fn id -> %{"id" => id, "name" => "Alice"} end)
      {:ok, result} = MquickjsEx.eval(ctx, "get_user(1)")
      assert result == %{"id" => 1, "name" => "Alice"}
    end

    test "callback with multiple arguments" do
      {:ok, ctx} = MquickjsEx.new(memory: @default_memory)
      ctx = MquickjsEx.set!(ctx, :add, fn a, b -> a + b end)
      {:ok, result} = MquickjsEx.eval(ctx, "add(10, 32)")
      assert result == 42
    end

    test "callback with no arguments" do
      {:ok, ctx} = MquickjsEx.new(memory: @default_memory)
      ctx = MquickjsEx.set!(ctx, :get_answer, fn -> 42 end)
      {:ok, result} = MquickjsEx.eval(ctx, "get_answer()")
      assert result == 42
    end
  end

  describe "multiple sequential callbacks" do
    test "two callbacks in sequence" do
      {:ok, ctx} = MquickjsEx.new(memory: @default_memory)
      ctx = MquickjsEx.set!(ctx, :fetch_a, fn -> 10 end)
      ctx = MquickjsEx.set!(ctx, :fetch_b, fn -> 20 end)

      code = """
      var a = fetch_a();
      var b = fetch_b();
      a + b
      """

      {:ok, result} = MquickjsEx.eval(ctx, code)
      assert result == 30
    end

    test "three callbacks in sequence" do
      {:ok, ctx} = MquickjsEx.new(memory: @default_memory)
      ctx = MquickjsEx.set!(ctx, :step1, fn -> 1 end)
      ctx = MquickjsEx.set!(ctx, :step2, fn x -> x * 2 end)
      ctx = MquickjsEx.set!(ctx, :step3, fn x -> x + 10 end)

      code = """
      var a = step1();
      var b = step2(a);
      var c = step3(b);
      c
      """

      {:ok, result} = MquickjsEx.eval(ctx, code)
      # step1() -> 1, step2(1) -> 2, step3(2) -> 12
      assert result == 12
    end

    test "same callback called multiple times" do
      {:ok, ctx} = MquickjsEx.new(memory: @default_memory)
      counter = :counters.new(1, [])
      ctx = MquickjsEx.set!(ctx, :next, fn ->
        :counters.add(counter, 1, 1)
        :counters.get(counter, 1)
      end)

      code = """
      var a = next();
      var b = next();
      var c = next();
      [a, b, c]
      """

      {:ok, result} = MquickjsEx.eval(ctx, code)
      assert result == [1, 2, 3]
    end
  end

  describe "callback result used in computations" do
    test "callback result used in arithmetic" do
      {:ok, ctx} = MquickjsEx.new(memory: @default_memory)
      ctx = MquickjsEx.set!(ctx, :get_base, fn -> 100 end)
      {:ok, result} = MquickjsEx.eval(ctx, "get_base() * 2 + 5")
      assert result == 205
    end

    test "callback result used in string concatenation" do
      {:ok, ctx} = MquickjsEx.new(memory: @default_memory)
      ctx = MquickjsEx.set!(ctx, :get_name, fn -> "World" end)
      {:ok, result} = MquickjsEx.eval(ctx, ~s|"Hello, " + get_name() + "!"|)
      assert result == "Hello, World!"
    end

    test "callback result used in array operations" do
      {:ok, ctx} = MquickjsEx.new(memory: @default_memory)
      ctx = MquickjsEx.set!(ctx, :get_items, fn -> [1, 2, 3] end)

      code = """
      var items = get_items();
      items.push(4);
      items
      """

      {:ok, result} = MquickjsEx.eval(ctx, code)
      assert result == [1, 2, 3, 4]
    end

    test "callback result used in object operations" do
      {:ok, ctx} = MquickjsEx.new(memory: @default_memory)
      ctx = MquickjsEx.set!(ctx, :get_config, fn -> %{"debug" => false} end)

      code = """
      var config = get_config();
      config.debug = true;
      config.timeout = 5000;
      config
      """

      {:ok, result} = MquickjsEx.eval(ctx, code)
      assert result == %{"debug" => true, "timeout" => 5000}
    end
  end

  describe "nested callbacks" do
    test "callback in conditional branch" do
      {:ok, ctx} = MquickjsEx.new(memory: @default_memory)
      ctx = MquickjsEx.set!(ctx, :should_proceed, fn -> true end)
      ctx = MquickjsEx.set!(ctx, :get_value, fn -> 42 end)

      code = """
      if (should_proceed()) {
        get_value()
      } else {
        0
      }
      """

      {:ok, result} = MquickjsEx.eval(ctx, code)
      assert result == 42
    end

    test "callback in loop" do
      {:ok, ctx} = MquickjsEx.new(memory: @default_memory)
      ctx = MquickjsEx.set!(ctx, :get_item, fn i -> i * 10 end)

      code = """
      var sum = 0;
      for (var i = 0; i < 3; i++) {
        sum = sum + get_item(i);
      }
      sum
      """

      {:ok, result} = MquickjsEx.eval(ctx, code)
      # 0*10 + 1*10 + 2*10 = 30
      assert result == 30
    end

    test "callback result passed to another callback" do
      {:ok, ctx} = MquickjsEx.new(memory: @default_memory)
      ctx = MquickjsEx.set!(ctx, :fetch_id, fn -> 42 end)
      ctx = MquickjsEx.set!(ctx, :fetch_user, fn id -> %{"id" => id, "name" => "User#{id}"} end)

      code = """
      var id = fetch_id();
      var user = fetch_user(id);
      user.name
      """

      {:ok, result} = MquickjsEx.eval(ctx, code)
      assert result == "User42"
    end
  end

  describe "callback error handling" do
    test "unknown callback returns error" do
      {:ok, ctx} = MquickjsEx.new(memory: @default_memory)
      {:error, reason} = MquickjsEx.eval(ctx, "unknown_func()")
      assert reason =~ "unknown_func"
    end

    test "callback exception is caught" do
      {:ok, ctx} = MquickjsEx.new(memory: @default_memory)
      ctx = MquickjsEx.set!(ctx, :fail, fn -> raise "intentional error" end)
      {:error, reason} = MquickjsEx.eval(ctx, "fail()")
      assert reason =~ "Callback error"
      assert reason =~ "intentional error"
    end
  end

  describe "complex callback scenarios" do
    test "simulated HTTP fetch pattern" do
      {:ok, ctx} = MquickjsEx.new(memory: @default_memory)
      ctx = MquickjsEx.set!(ctx, :fetch_data, fn url ->
        %{"url" => url, "status" => 200, "body" => "response from #{url}"}
      end)

      code = """
      var response = fetch_data("https://api.example.com/data");
      response.body
      """

      {:ok, result} = MquickjsEx.eval(ctx, code)
      assert result == "response from https://api.example.com/data"
    end

    test "multiple fetch with aggregation" do
      {:ok, ctx} = MquickjsEx.new(memory: @default_memory)
      ctx = MquickjsEx.set!(ctx, :fetch_user, fn id -> %{"id" => id, "name" => "User#{id}"} end)

      code = """
      var user1 = fetch_user(1);
      var user2 = fetch_user(2);
      var user3 = fetch_user(3);
      [user1.name, user2.name, user3.name]
      """

      {:ok, result} = MquickjsEx.eval(ctx, code)
      assert result == ["User1", "User2", "User3"]
    end

    test "JSON parsing pattern" do
      {:ok, ctx} = MquickjsEx.new(memory: @default_memory)
      ctx = MquickjsEx.set!(ctx, :fetch_json, fn _url ->
        ~s|{"items": [1, 2, 3], "count": 3}|
      end)

      code = """
      var json_str = fetch_json("http://example.com");
      var data = JSON.parse(json_str);
      data.count
      """

      {:ok, result} = MquickjsEx.eval(ctx, code)
      assert result == 3
    end
  end

  # ============================================================================
  # Persistent Elixir Functions (set with functions)
  # ============================================================================

  describe "setting functions via set/3" do
    test "set function and call from eval" do
      {:ok, ctx} = MquickjsEx.new(memory: @default_memory)
      {:ok, ctx} = MquickjsEx.set(ctx, :double, fn x -> x * 2 end)
      {:ok, result} = MquickjsEx.eval(ctx, "double(21)")
      assert result == 42
    end

    test "set! function and call from eval!" do
      {:ok, ctx} = MquickjsEx.new(memory: @default_memory)
      ctx = MquickjsEx.set!(ctx, :add, fn a, b -> a + b end)
      {result, _ctx} = MquickjsEx.eval!(ctx, "add(10, 32)")
      assert result == 42
    end

    test "multiple functions set via set!" do
      {:ok, ctx} = MquickjsEx.new(memory: @default_memory)
      ctx = MquickjsEx.set!(ctx, :add, fn a, b -> a + b end)
      ctx = MquickjsEx.set!(ctx, :multiply, fn a, b -> a * b end)
      ctx = MquickjsEx.set!(ctx, :greet, fn name -> "Hello, #{name}!" end)

      {result, ctx} = MquickjsEx.eval!(ctx, "add(2, 3)")
      assert result == 5

      {result, ctx} = MquickjsEx.eval!(ctx, "multiply(4, 5)")
      assert result == 20

      {result, _ctx} = MquickjsEx.eval!(ctx, ~s|greet("World")|)
      assert result == "Hello, World!"
    end

    test "mix of values and functions" do
      {:ok, ctx} = MquickjsEx.new(memory: @default_memory)
      ctx = MquickjsEx.set!(ctx, :multiplier, 10)
      ctx = MquickjsEx.set!(ctx, :scale, fn x -> x * 10 end)

      {result, _ctx} = MquickjsEx.eval!(ctx, "scale(multiplier)")
      assert result == 100
    end

    test "function persists across multiple eval calls" do
      {:ok, ctx} = MquickjsEx.new(memory: @default_memory)
      ctx = MquickjsEx.set!(ctx, :increment, fn x -> x + 1 end)

      {result1, ctx} = MquickjsEx.eval!(ctx, "increment(1)")
      {result2, ctx} = MquickjsEx.eval!(ctx, "increment(10)")
      {result3, _ctx} = MquickjsEx.eval!(ctx, "increment(100)")

      assert result1 == 2
      assert result2 == 11
      assert result3 == 101
    end

    test "function with complex return value" do
      {:ok, ctx} = MquickjsEx.new(memory: @default_memory)
      ctx = MquickjsEx.set!(ctx, :get_user, fn id ->
        %{"id" => id, "name" => "User#{id}", "active" => true}
      end)

      {result, _ctx} = MquickjsEx.eval!(ctx, "get_user(42).name")
      assert result == "User42"
    end
  end
end
