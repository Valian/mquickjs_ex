defmodule MquickjsEx.BuiltinReplacementTest do
  @moduledoc """
  Tests to verify whether built-in JavaScript functions can be replaced/overridden.

  This is important for:
  1. Security: Understanding if malicious code can tamper with expected behavior
  2. Flexibility: Understanding if users can customize built-in behavior
  3. Isolation: Understanding if changes persist across eval calls

  Note: MQuickJS has some ES5 limitations:
  - Rest parameters (...args) are NOT supported - use `arguments` object instead
  - Object.freeze/Object.seal are NOT available
  - Date constructor is limited (only Date.now() works)
  """
  use ExUnit.Case, async: true

  # ============================================================================
  # Console Object Replacement
  # ============================================================================

  describe "console.log replacement" do
    test "can replace console.log with a custom function" do
      {:ok, ctx} = MquickjsEx.new()

      # Replace console.log with a function that captures arguments
      # Note: MQuickJS doesn't support rest parameters, use `arguments` object
      result =
        MquickjsEx.eval(ctx, """
          var captured = [];
          console.log = function() {
            var args = [];
            for (var i = 0; i < arguments.length; i++) {
              args.push(arguments[i]);
            }
            captured.push(args);
          };
          console.log("hello", "world");
          console.log(42);
          captured;
        """)

      assert {:ok, captured} = result
      assert captured == [["hello", "world"], [42]]
    end

    test "replaced console.log persists across eval calls" do
      {:ok, ctx} = MquickjsEx.new()

      # First eval: replace console.log
      # Note: Add `undefined` at the end to avoid returning the function
      {:ok, nil} =
        MquickjsEx.eval(ctx, """
          var logs = [];
          console.log = function() {
            var args = [];
            for (var i = 0; i < arguments.length; i++) {
              args.push(arguments[i]);
            }
            logs.push(args.join(' '));
          };
          undefined;
        """)

      # Second eval: use the replaced function
      {:ok, _} = MquickjsEx.eval(ctx, "console.log('test message')")

      # Third eval: retrieve captured logs
      {:ok, logs} = MquickjsEx.eval(ctx, "logs")
      assert logs == ["test message"]
    end

    test "can replace entire console object" do
      {:ok, ctx} = MquickjsEx.new()

      result =
        MquickjsEx.eval(ctx, """
          var myConsole = {
            logs: [],
            log: function() {
              var args = [];
              for (var i = 0; i < arguments.length; i++) args.push(arguments[i]);
              this.logs.push({type: 'log', args: args});
            },
            warn: function() {
              var args = [];
              for (var i = 0; i < arguments.length; i++) args.push(arguments[i]);
              this.logs.push({type: 'warn', args: args});
            },
            error: function() {
              var args = [];
              for (var i = 0; i < arguments.length; i++) args.push(arguments[i]);
              this.logs.push({type: 'error', args: args});
            }
          };
          console = myConsole;
          console.log("info");
          console.warn("warning");
          console.error("error");
          console.logs;
        """)

      assert {:ok, logs} = result
      assert length(logs) == 3
      assert Enum.at(logs, 0) == %{"type" => "log", "args" => ["info"]}
      assert Enum.at(logs, 1) == %{"type" => "warn", "args" => ["warning"]}
      assert Enum.at(logs, 2) == %{"type" => "error", "args" => ["error"]}
    end
  end

  # ============================================================================
  # Math Object Methods Replacement
  # ============================================================================

  describe "Math methods replacement" do
    test "can replace Math.sqrt" do
      {:ok, ctx} = MquickjsEx.new()

      result =
        MquickjsEx.eval(ctx, """
          var originalSqrt = Math.sqrt;
          Math.sqrt = function(x) {
            return originalSqrt(x) * 2;
          };
          Math.sqrt(16);
        """)

      # Original sqrt(16) = 4, our fake returns 8
      assert {:ok, 8} = result
    end

    test "can replace Math.random with deterministic function" do
      {:ok, ctx} = MquickjsEx.new()

      result =
        MquickjsEx.eval(ctx, """
          var counter = 0;
          Math.random = function() {
            counter++;
            return counter / 10;
          };
          [Math.random(), Math.random(), Math.random()];
        """)

      assert {:ok, [0.1, 0.2, 0.3]} = result
    end

    test "can replace entire Math object" do
      {:ok, ctx} = MquickjsEx.new()

      result =
        MquickjsEx.eval(ctx, """
          Math = {
            PI: 3,
            sqrt: function(x) { return x; },
            abs: function(x) { return x > 0 ? x : -x; }
          };
          [Math.PI, Math.sqrt(16), Math.abs(-5)];
        """)

      assert {:ok, [3, 16, 5]} = result
    end
  end

  # ============================================================================
  # JSON Methods Replacement
  # ============================================================================

  describe "JSON methods replacement" do
    test "can replace JSON.stringify" do
      {:ok, ctx} = MquickjsEx.new()

      result =
        MquickjsEx.eval(ctx, """
          var originalStringify = JSON.stringify;
          JSON.stringify = function(obj) {
            return "REDACTED";
          };
          JSON.stringify({secret: "password"});
        """)

      assert {:ok, "REDACTED"} = result
    end

    test "can replace JSON.parse" do
      {:ok, ctx} = MquickjsEx.new()

      result =
        MquickjsEx.eval(ctx, """
          JSON.parse = function(str) {
            return {replaced: true, original: str};
          };
          JSON.parse('{"foo": "bar"}');
        """)

      assert {:ok, %{"replaced" => true, "original" => "{\"foo\": \"bar\"}"}} = result
    end
  end

  # ============================================================================
  # Array Methods Replacement
  # ============================================================================

  describe "Array prototype methods replacement" do
    test "can replace Array.prototype.push" do
      {:ok, ctx} = MquickjsEx.new()

      result =
        MquickjsEx.eval(ctx, """
          var pushCount = 0;
          var originalPush = Array.prototype.push;
          Array.prototype.push = function() {
            pushCount++;
            return originalPush.apply(this, arguments);
          };
          var arr = [];
          arr.push(1);
          arr.push(2);
          arr.push(3);
          [arr, pushCount];
        """)

      assert {:ok, [[1, 2, 3], 3]} = result
    end

    test "can replace Array.prototype.map" do
      {:ok, ctx} = MquickjsEx.new()

      result =
        MquickjsEx.eval(ctx, """
          Array.prototype.map = function(fn) {
            var result = [];
            for (var i = 0; i < this.length; i++) {
              result.push(fn(this[i], i) + "_mapped");
            }
            return result;
          };
          [1, 2, 3].map(function(x) { return x; });
        """)

      assert {:ok, ["1_mapped", "2_mapped", "3_mapped"]} = result
    end
  end

  # ============================================================================
  # String Methods Replacement
  # ============================================================================

  describe "String prototype methods replacement" do
    test "can replace String.prototype.toUpperCase" do
      {:ok, ctx} = MquickjsEx.new()

      result =
        MquickjsEx.eval(ctx, """
          String.prototype.toUpperCase = function() {
            return this.split('').reverse().join('');
          };
          "hello".toUpperCase();
        """)

      assert {:ok, "olleh"} = result
    end

    test "can add custom methods to String.prototype" do
      {:ok, ctx} = MquickjsEx.new()

      result =
        MquickjsEx.eval(ctx, """
          String.prototype.reverse = function() {
            return this.split('').reverse().join('');
          };
          "hello".reverse();
        """)

      assert {:ok, "olleh"} = result
    end
  end

  # ============================================================================
  # Object Methods Replacement
  # ============================================================================

  describe "Object methods replacement" do
    test "can replace Object.keys and result is usable" do
      {:ok, ctx} = MquickjsEx.new()

      # Object.keys returns something that doesn't serialize well in MQuickJS.
      # We can verify the replacement by testing the behavior indirectly
      result =
        MquickjsEx.eval(ctx, """
          var originalKeys = Object.keys;
          var replacementCalled = false;
          Object.keys = function(obj) {
            replacementCalled = true;
            return originalKeys(obj);
          };
          Object.keys({a: 1});
          replacementCalled;
        """)

      assert {:ok, true} = result
    end

    test "can replace Object.assign" do
      {:ok, ctx} = MquickjsEx.new()

      result =
        MquickjsEx.eval(ctx, """
          Object.assign = function(target) {
            for (var i = 1; i < arguments.length; i++) {
              var source = arguments[i];
              for (var key in source) {
                target[key + "_custom"] = source[key];
              }
            }
            return target;
          };
          Object.assign({}, {a: 1, b: 2});
        """)

      assert {:ok, %{"a_custom" => 1, "b_custom" => 2}} = result
    end
  end

  # ============================================================================
  # Global Functions Replacement
  # ============================================================================

  describe "global functions replacement" do
    test "can replace parseInt" do
      {:ok, ctx} = MquickjsEx.new()

      result =
        MquickjsEx.eval(ctx, """
          var originalParseInt = parseInt;
          parseInt = function(str, radix) {
            return originalParseInt(str, radix) + 1;
          };
          parseInt("10");
        """)

      assert {:ok, 11} = result
    end

    test "can replace parseFloat" do
      {:ok, ctx} = MquickjsEx.new()

      result =
        MquickjsEx.eval(ctx, """
          parseFloat = function(str) {
            return 0;
          };
          parseFloat("3.14");
        """)

      assert {:ok, 0} = result
    end

    test "can replace isNaN" do
      {:ok, ctx} = MquickjsEx.new()

      result =
        MquickjsEx.eval(ctx, """
          isNaN = function(x) {
            return false;
          };
          isNaN("not a number");
        """)

      assert {:ok, false} = result
    end
  end

  # ============================================================================
  # Error Class Replacement
  # ============================================================================

  describe "Error class replacement" do
    test "can replace Error constructor" do
      {:ok, ctx} = MquickjsEx.new()

      result =
        MquickjsEx.eval(ctx, """
          var OriginalError = Error;
          Error = function(message) {
            var err = new OriginalError("CUSTOM: " + message);
            return err;
          };
          try {
            throw new Error("test");
          } catch(e) {
            e.message;
          }
        """)

      assert {:ok, "CUSTOM: test"} = result
    end
  end

  # ============================================================================
  # Date Object Replacement
  # ============================================================================

  describe "Date object replacement" do
    test "can replace Date.now" do
      {:ok, ctx} = MquickjsEx.new()

      result =
        MquickjsEx.eval(ctx, """
          Date.now = function() {
            return 1234567890000;
          };
          Date.now();
        """)

      # MQuickJS returns floats for large numbers
      assert {:ok, value} = result
      assert value == 1_234_567_890_000 or value == 1_234_567_890_000.0
    end

    # Note: Full Date constructor is not supported in MQuickJS (only Date.now())
    # So we skip testing Date constructor replacement
  end

  # ============================================================================
  # Isolation Tests - Does replacement affect other contexts?
  # ============================================================================

  describe "context isolation" do
    test "replacement in one context does not affect another" do
      {:ok, ctx1} = MquickjsEx.new()
      {:ok, ctx2} = MquickjsEx.new()

      # Replace Math.sqrt in ctx1 and verify replacement took effect
      {:ok, nil} =
        MquickjsEx.eval(ctx1, """
          Math.sqrt = function(x) { return x; };
          undefined;
        """)

      # ctx1 should have the replacement
      assert {:ok, 16} = MquickjsEx.eval(ctx1, "Math.sqrt(16)")

      # ctx2 should have the original
      assert {:ok, 4} = MquickjsEx.eval(ctx2, "Math.sqrt(16)")
    end

    test "each context has independent global state" do
      {:ok, ctx1} = MquickjsEx.new()
      {:ok, ctx2} = MquickjsEx.new()

      # Set a global in ctx1
      {:ok, nil} = MquickjsEx.eval(ctx1, "var globalValue = 'ctx1';")

      # ctx1 should have it
      assert {:ok, "ctx1"} = MquickjsEx.eval(ctx1, "globalValue")

      # ctx2 should not
      result = MquickjsEx.eval(ctx2, "typeof globalValue")
      assert {:ok, "undefined"} = result
    end
  end

  # ============================================================================
  # Restoration Tests
  # ============================================================================

  describe "builtin restoration" do
    test "can restore original function if saved" do
      {:ok, ctx} = MquickjsEx.new()

      result =
        MquickjsEx.eval(ctx, """
          var originalSqrt = Math.sqrt;
          Math.sqrt = function(x) { return 0; };

          var broken = Math.sqrt(16);

          Math.sqrt = originalSqrt;
          var fixed = Math.sqrt(16);

          [broken, fixed];
        """)

      assert {:ok, [0, 4]} = result
    end

    test "changes persist until restored" do
      {:ok, ctx} = MquickjsEx.new()

      # Replace
      {:ok, nil} =
        MquickjsEx.eval(ctx, """
          var originalAbs = Math.abs;
          Math.abs = function(x) { return -999; };
          undefined;
        """)

      # Verify replaced
      assert {:ok, -999} = MquickjsEx.eval(ctx, "Math.abs(5)")
      assert {:ok, -999} = MquickjsEx.eval(ctx, "Math.abs(-5)")

      # Restore
      {:ok, nil} = MquickjsEx.eval(ctx, "Math.abs = originalAbs; undefined;")

      # Verify restored
      assert {:ok, 5} = MquickjsEx.eval(ctx, "Math.abs(-5)")
    end
  end

  # ============================================================================
  # Using callbacks with replaced builtins
  # ============================================================================

  describe "callbacks with replaced builtins" do
    test "Elixir callback can be used as console.log replacement" do
      {:ok, ctx} = MquickjsEx.new()

      ctx =
        MquickjsEx.set!(ctx, :elixirLog, fn [args] ->
          send(self(), {:log, args})
          nil
        end)

      {:ok, nil} =
        MquickjsEx.eval(ctx, """
          console.log = function() {
            var args = [];
            for (var i = 0; i < arguments.length; i++) {
              args.push(arguments[i]);
            }
            elixirLog(args);
          };
          undefined;
        """)

      {:ok, _} =
        MquickjsEx.eval(ctx, """
          console.log("Hello from JS!");
          console.log(1, 2, 3);
          undefined;
        """)

      assert_receive {:log, ["Hello from JS!"]}
      assert_receive {:log, [1, 2, 3]}
    end

    test "Elixir callback can replace Math.random" do
      {:ok, ctx} = MquickjsEx.new()

      ctx = MquickjsEx.set!(ctx, :secureRandom, fn [] -> :rand.uniform() end)

      {:ok, nil} = MquickjsEx.eval(ctx, "Math.random = secureRandom; undefined;")

      result =
        MquickjsEx.eval(ctx, """
          var r1 = Math.random();
          var r2 = Math.random();
          r1 !== r2;
        """)

      assert {:ok, true} = result
    end

    test "Elixir callback can intercept function calls on replaced builtins" do
      # Test that a replaced builtin can call back to Elixir
      # Using a simpler replacement pattern that works within memory constraints
      {:ok, ctx} = MquickjsEx.new(memory: 256 * 1024)

      ctx =
        MquickjsEx.set!(ctx, :myCustomFunc, fn [x] ->
          send(self(), {:custom_called, x})
          x * 2
        end)

      # Replace a builtin with our custom function directly
      {:ok, nil} = MquickjsEx.eval(ctx, "Math.floor = myCustomFunc; undefined;")

      {:ok, result} = MquickjsEx.eval(ctx, "Math.floor(5)")

      assert_receive {:custom_called, 5}
      assert result == 10
    end
  end

  # ============================================================================
  # Security implications
  # ============================================================================

  describe "security implications of builtin replacement" do
    test "replaced functions cannot escape sandbox" do
      {:ok, ctx} = MquickjsEx.new()

      # Even if we replace eval, we can't escape the sandbox
      result =
        MquickjsEx.eval(ctx, """
          try {
            var evil = Function('return this.process');
            typeof evil();
          } catch(e) {
            "caught";
          }
        """)

      assert {:ok, value} = result
      # Should be undefined or error, not object/function
      assert value in ["undefined", "caught", nil]
    end

    test "cannot use replacement to access Node.js globals" do
      {:ok, ctx} = MquickjsEx.new()

      # Test 1: Function constructor
      result1 =
        MquickjsEx.eval(ctx, """
          try {
            var F = (function(){}).constructor;
            var global = F('return this')();
            typeof global.require;
          } catch(e) {
            "error";
          }
        """)

      assert {:ok, value1} = result1
      assert value1 in ["undefined", "error"]

      # Test 2: Through prototype chain
      result2 =
        MquickjsEx.eval(ctx, """
          try {
            var global2 = Object.prototype.constructor.constructor('return this')();
            typeof global2.process;
          } catch(e2) {
            "error";
          }
        """)

      assert {:ok, value2} = result2
      assert value2 in ["undefined", "error"]
    end
  end

  # ============================================================================
  # MQuickJS Limitations Documentation Tests
  # ============================================================================

  describe "MQuickJS ES5 limitations" do
    test "rest parameters are NOT supported" do
      {:ok, ctx} = MquickjsEx.new()

      result =
        MquickjsEx.eval(ctx, """
          try {
            eval("function f(...args) { return args; }");
            "supported";
          } catch(e) {
            "not supported";
          }
        """)

      # Should error because rest params aren't supported
      assert match?({:error, _}, result)
    end

    test "arguments object works as alternative to rest params" do
      {:ok, ctx} = MquickjsEx.new()

      result =
        MquickjsEx.eval(ctx, """
          function collectArgs() {
            var args = [];
            for (var i = 0; i < arguments.length; i++) {
              args.push(arguments[i]);
            }
            return args;
          }
          collectArgs(1, 2, 3, "four");
        """)

      assert {:ok, [1, 2, 3, "four"]} = result
    end

    test "Object.freeze is NOT available" do
      {:ok, ctx} = MquickjsEx.new()

      result = MquickjsEx.eval(ctx, "typeof Object.freeze")
      assert {:ok, "undefined"} = result
    end

    test "Object.seal is NOT available" do
      {:ok, ctx} = MquickjsEx.new()

      result = MquickjsEx.eval(ctx, "typeof Object.seal")
      assert {:ok, "undefined"} = result
    end
  end
end
