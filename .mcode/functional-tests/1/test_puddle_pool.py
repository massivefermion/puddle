"""Functional tests for the puddle resource pool manager library.

These tests exercise the compiled puddle BEAM modules directly via Erlang
escripts. Each test starts a fresh pool, exercises a specific behavior,
and verifies the result through exit codes and stdout.

The tests validate:
- Pool creation and basic resource usage (start, apply, shutdown)
- Sequential reuse without process exit (explicit check-in correctness)
- Pool exhaustion and recovery
- Worker crash recovery
- User process crash recovery
- Shutdown with proper cleanup
"""
import pytest
from conftest import run_escript


class TestPoolBasics:
    """Basic pool operations: start, apply, shutdown."""

    def test_basic_start_apply(self):
        """Start pool with 2 resources, apply a doubling function, verify result."""
        result = run_escript("test_basic_start_apply.escript")
        assert result.returncode == 0, (
            f"Basic start+apply failed.\nstdout: {result.stdout}\nstderr: {result.stderr}"
        )
        assert "PASS" in result.stdout

    def test_shutdown(self):
        """Shutdown pool and verify shutdown callback is called for all resources."""
        result = run_escript("test_shutdown.escript")
        assert result.returncode == 0, (
            f"Shutdown test failed.\nstdout: {result.stdout}\nstderr: {result.stderr}"
        )
        assert "PASS" in result.stdout


class TestCheckInBehavior:
    """Tests for explicit check-in correctness (the primary bug fix)."""

    def test_sequential_reuse(self):
        """Apply multiple times sequentially from the same process.

        This directly tests the check-in fix: on origin (broken), the 2nd
        apply fails because the resource is never returned via explicit
        check-in. On target (fixed), all applies succeed.
        """
        result = run_escript("test_sequential_reuse.escript")
        assert result.returncode == 0, (
            f"Sequential reuse failed.\nstdout: {result.stdout}\nstderr: {result.stderr}"
        )
        assert "PASS" in result.stdout


class TestPoolExhaustion:
    """Tests for pool exhaustion and recovery."""

    def test_pool_exhaustion_and_recovery(self):
        """Exhaust pool, verify rejection, wait for return, verify recovery."""
        result = run_escript("test_pool_exhaustion.escript", timeout=30)
        assert result.returncode == 0, (
            f"Pool exhaustion test failed.\nstdout: {result.stdout}\nstderr: {result.stderr}"
        )
        assert "PASS" in result.stdout


class TestCrashRecovery:
    """Tests for crash recovery: worker crashes and user crashes."""

    def test_worker_crash_recovery(self):
        """Crash a worker while busy, verify pool spawns replacement.

        On origin: pool does NOT recover (unhandled worker crash while busy).
        On target: pool recovers (replacement worker spawned).
        """
        result = run_escript("test_worker_crash_recovery.escript", timeout=30)
        assert result.returncode == 0, (
            f"Worker crash recovery failed.\nstdout: {result.stdout}\nstderr: {result.stderr}"
        )
        assert "PASS" in result.stdout

    def test_user_crash_recovery(self):
        """Crash a user process, verify resource is returned to pool.

        The user process uses the resource successfully but then panics.
        The pool should detect the user crash via ProcessDown and return
        the resource to idle.
        """
        result = run_escript("test_user_crash_recovery.escript", timeout=30)
        assert result.returncode == 0, (
            f"User crash recovery failed.\nstdout: {result.stdout}\nstderr: {result.stderr}"
        )
        assert "PASS" in result.stdout
