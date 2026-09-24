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
from conftest import run_target_escript


# --- origin_and_target tests (target pass) ---

class TestBasicStartApply:
    """Pool creation and basic apply -- origin_and_target."""

    def test_basic_start_apply(self):
        """Builder pattern start + apply with Keep returns {ok, 84}."""
        result = run_target_escript("test_basic_start_apply.escript")
        assert result.returncode == 0, (
            f"Basic start+apply failed.\nstdout: {result.stdout}\nstderr: {result.stderr}"
        )
        assert "PASS" in result.stdout


class TestSequentialReuse:
    """Sequential reuse validates check-in correctness -- origin_and_target."""

    def test_sequential_reuse(self):
        """Sequential apply from same process: R1={ok,84} R2={ok,43} R3={ok,42}."""
        result = run_target_escript("test_sequential_reuse.escript")
        assert result.returncode == 0, (
            f"Sequential reuse failed.\nstdout: {result.stdout}\nstderr: {result.stderr}"
        )
        assert "PASS" in result.stdout


class TestPoolExhaustion:
    """Pool exhaustion and recovery -- origin_and_target."""

    def test_pool_exhaustion_and_recovery(self):
        """Exhaust pool (error), wait for return, recover (ok)."""
        result = run_target_escript("test_pool_exhaustion.escript", timeout=30)
        assert result.returncode == 0, (
            f"Pool exhaustion failed.\nstdout: {result.stdout}\nstderr: {result.stderr}"
        )
        assert "PASS" in result.stdout


class TestWorkerCrashRecovery:
    """Worker crash while busy -- origin_and_target."""

    def test_worker_crash_recovery(self):
        """Crash worker while busy, pool spawns replacement and recovers."""
        result = run_target_escript("test_worker_crash_recovery.escript", timeout=30)
        assert result.returncode == 0, (
            f"Worker crash recovery failed.\nstdout: {result.stdout}\nstderr: {result.stderr}"
        )
        assert "PASS" in result.stdout


class TestUserCrashRecovery:
    """User process crash recovery -- origin_and_target."""

    def test_user_crash_recovery(self):
        """User crash triggers ProcessDown, resource returned to pool."""
        result = run_target_escript("test_user_crash_recovery.escript", timeout=30)
        assert result.returncode == 0, (
            f"User crash recovery failed.\nstdout: {result.stdout}\nstderr: {result.stderr}"
        )
        assert "PASS" in result.stdout


class TestShutdown:
    """Shutdown with on_shutdown callback -- origin_and_target."""

    def test_shutdown(self):
        """Shutdown calls on_shutdown callback for all 2 resources."""
        result = run_target_escript("test_shutdown.escript")
        assert result.returncode == 0, (
            f"Shutdown failed.\nstdout: {result.stdout}\nstderr: {result.stderr}"
        )
        assert "PASS" in result.stdout


# --- target_only tests (new enterprise features) ---

class TestCheckoutStrategies:
    """FIFO and LIFO checkout strategies -- target_only."""

    def test_lifo_strategy(self):
        """LIFO: last-returned resource is checked out first."""
        result = run_target_escript("test_lifo_strategy.escript")
        assert result.returncode == 0, (
            f"LIFO strategy failed.\nstdout: {result.stdout}\nstderr: {result.stderr}"
        )
        assert "PASS" in result.stdout

    def test_fifo_strategy(self):
        """FIFO: first-returned resource is checked out first."""
        result = run_target_escript("test_fifo_strategy.escript")
        assert result.returncode == 0, (
            f"FIFO strategy failed.\nstdout: {result.stdout}\nstderr: {result.stderr}"
        )
        assert "PASS" in result.stdout


class TestLazyCreation:
    """Lazy resource creation -- target_only."""

    def test_lazy_creation(self):
        """Lazy: no resources at init, created on demand."""
        result = run_target_escript("test_lazy_creation.escript")
        assert result.returncode == 0, (
            f"Lazy creation failed.\nstdout: {result.stdout}\nstderr: {result.stderr}"
        )
        assert "PASS" in result.stdout


class TestResourceDiscard:
    """Resource discard and replacement -- target_only."""

    def test_discard_replaces_resource(self):
        """Discard: resource destroyed and replaced, pool stays functional."""
        result = run_target_escript("test_discard_resource.escript")
        assert result.returncode == 0, (
            f"Discard resource failed.\nstdout: {result.stdout}\nstderr: {result.stderr}"
        )
        assert "PASS" in result.stdout


class TestBlockingCheckout:
    """Blocking checkout (apply_blocking) -- target_only."""

    def test_apply_blocking(self):
        """Blocking: non-blocking fails immediately, blocking waits and succeeds."""
        result = run_target_escript("test_apply_blocking.escript", timeout=30)
        assert result.returncode == 0, (
            f"Blocking checkout failed.\nstdout: {result.stdout}\nstderr: {result.stderr}"
        )
        assert "PASS" in result.stdout


class TestPoolStatus:
    """Pool status introspection -- target_only."""

    def test_pool_status(self):
        """Status: reports Ready/Full/Overloaded with correct counts."""
        result = run_target_escript("test_pool_status.escript", timeout=30)
        assert result.returncode == 0, (
            f"Pool status failed.\nstdout: {result.stdout}\nstderr: {result.stderr}"
        )
        assert "PASS" in result.stdout


class TestNamedPool:
    """Named pool registration -- target_only."""

    def test_named_pool(self):
        """Named: pool accessible via process name and returned subject."""
        result = run_target_escript("test_named_pool.escript")
        assert result.returncode == 0, (
            f"Named pool failed.\nstdout: {result.stdout}\nstderr: {result.stderr}"
        )
        assert "PASS" in result.stdout
