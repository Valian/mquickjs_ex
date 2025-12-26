# Known Issues

## Intermittent Parser Failures in BEAM Environment

### Status
**Resolved** - Fixed by copying binary data before passing to JS_Eval

### Summary
MQuickJS exhibited intermittent parsing failures when running as a NIF within the BEAM (Erlang VM), despite working 100% reliably as a standalone C program. The failure manifested as "unexpected character" or "unexpected character in expression" errors during `JS_Eval()` even when parsing valid JavaScript code.

### Root Cause
Passing Erlang binary data pointers directly to `JS_Eval()` caused intermittent failures. The exact mechanism is unclear, but may be related to how the BEAM manages binary memory (possibly memory protection, alignment, or memory mapping differences).

### Solution
Copy the binary data to a malloc'd buffer before passing to `JS_Eval()`:

```c
char *code_copy = malloc(code_bin.size + 1);
memcpy(code_copy, code_bin.data, code_bin.size);
code_copy[code_bin.size] = '\0';

JSValue result = JS_Eval(js->ctx, code_copy, code_bin.size, "eval", 0);
free(code_copy);
```

This simple change eliminated all intermittent failures. Tests went from ~40-60% failure rate to 100% success rate across 100+ test runs.

### Investigation History

#### Original Symptoms
- `JS_Eval()` returned parsing errors for syntactically correct code
- Error messages: "unexpected character" or "variable 'I' is not defined" (where 'I' didn't appear in the code)
- Failure rate: approximately 40-75% of test runs failed
- The same code worked perfectly in standalone C tests (1000+ iterations, 0 failures)

#### Attempted Fixes (Before Finding Solution)

**Memory Allocation Strategies (did not help):**
| Strategy | Result |
|----------|--------|
| `malloc()` | ~40% success |
| `calloc()` | ~25% success |
| `mmap(MAP_ANONYMOUS)` | ~25% success |
| `posix_memalign()` + `memset()` | ~30% success |
| `enif_alloc()` + `memset()` | ~20% success |

**Compiler Optimizations (did not help):**
| Flag | Result |
|------|--------|
| `-O2` | ~40% success |
| `-Os` | ~20% success |
| `-O0 -g` | ~10% success (worse!) |

**Other Attempts (did not help):**
- Memory barriers (`__sync_synchronize()`)
- Pre-warming context on NIF load
- Stdlib validation checks
- Different memory sizes (64KB, 128KB, 256KB)
- Dirty schedulers (`ERL_NIF_DIRTY_JOB_CPU_BOUND`)

#### Key Observation
The error "variable 'I' is not defined" when parsing code like `var x = 1;` indicated the parser was reading garbage data. The character 'I' (ASCII 73) doesn't appear in the input, suggesting the parser was reading from corrupted or wrong memory.

#### What Fixed It
Copying the binary data to a new malloc'd buffer before passing to JS_Eval. This suggests the issue was with how Erlang binary memory is accessed, not with MQuickJS itself.

### Files Involved

- `c_src/mquickjs_ex.c` - NIF implementation (see `nif_eval` function)
- `test/mquickjs_ex_test.exs` - Test suite (retry logic removed after fix)

### References

- MQuickJS source: `~/Projects/mquickjs`
- BEAM NIF documentation: https://www.erlang.org/doc/man/erl_nif.html
