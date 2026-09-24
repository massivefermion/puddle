"""Functional tests for the puddle resource pool manager library.

These tests exercise the compiled puddle BEAM modules directly via Erlang
escripts. Each escript starts a fresh pool actor on the BEAM VM, exercises
a specific behavior, and verifies the result through exit codes and stdout.

The escripts use the target (v1.0.0) builder API:
  puddle:new(CreateFn) -> puddle:size(Builder, N) -> puddle:start(Builder, Timeout)

Origin baseline results were captured separately against the pre-M1 code
using origin escripts that call the old positional API (start/3, shutdown/2).

Tests validate both preserved behaviors (origin_and_target) and new features
(target_only):

Preserved behaviors:
- Pool creation and basic resource usage
- Sequential reuse (explicit check-in correctness)
- Pool exhaustion and recovery
- Worker crash recovery
- User process crash recovery
- Shutdown with callback

New enterprise features:
- FIFO and LIFO checkout strategies
- Lazy resource creation
- Resource discard and replacement
- Blocking checkout (apply_blocking)
- Pool status introspection (Ready/Full/Overloaded)
- Named pool registration
"""
import pytest
from conftest import run_target_escript

_ESCRIPTS = [
    pytest.param("test_basic_start_apply.escript", "Basic start+apply", 60, id="basic_start_apply"),
    pytest.param("test_sequential_reuse.escript", "Sequential reuse", 60, id="sequential_reuse"),
    pytest.param("test_pool_exhaustion.escript", "Pool exhaustion", 30, id="pool_exhaustion"),
    pytest.param("test_worker_crash_recovery.escript", "Worker crash recovery", 30, id="worker_crash_recovery"),
    pytest.param("test_user_crash_recovery.escript", "User crash recovery", 30, id="user_crash_recovery"),
    pytest.param("test_shutdown.escript", "Shutdown", 60, id="shutdown"),
    pytest.param("test_lifo_strategy.escript", "LIFO strategy", 60, id="lifo_strategy"),
    pytest.param("test_fifo_strategy.escript", "FIFO strategy", 60, id="fifo_strategy"),
    pytest.param("test_lazy_creation.escript", "Lazy creation", 60, id="lazy_creation"),
    pytest.param("test_discard_resource.escript", "Discard resource", 60, id="discard_resource"),
    pytest.param("test_apply_blocking.escript", "Blocking checkout", 30, id="apply_blocking"),
    pytest.param("test_pool_status.escript", "Pool status", 30, id="pool_status"),
    pytest.param("test_named_pool.escript", "Named pool", 60, id="named_pool"),
]


@pytest.mark.parametrize("escript,label,timeout", _ESCRIPTS)
def test_escript(escript, label, timeout):
    result = run_target_escript(escript, timeout=timeout)
    assert result.returncode == 0, (
        f"{label} failed.\nstdout: {result.stdout}\nstderr: {result.stderr}"
    )
    assert "PASS" in result.stdout
