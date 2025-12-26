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
      assert {:ok, :executed} = MquickjsEx.eval(ctx, "var x = 1 + 2;")
    end

    test "can eval multiple statements" do
      {:ok, ctx} = MquickjsEx.new(memory: @default_memory)
      assert {:ok, :executed} = MquickjsEx.eval(ctx, "var x = 1; var y = 2; var z = x + y;")
    end

    test "can use JS built-ins" do
      {:ok, ctx} = MquickjsEx.new(memory: @default_memory)
      assert {:ok, :executed} = MquickjsEx.eval(ctx, "var arr = [1, 2, 3]; arr.push(4);")
    end

    test "can use Math object" do
      {:ok, ctx} = MquickjsEx.new(memory: @default_memory)
      assert {:ok, :executed} = MquickjsEx.eval(ctx, "var x = Math.sqrt(16);")
    end

    test "can use JSON" do
      {:ok, ctx} = MquickjsEx.new(memory: @default_memory)
      assert {:ok, :executed} = MquickjsEx.eval(ctx, ~s|var obj = JSON.parse('{"a": 1}');|)
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
end
