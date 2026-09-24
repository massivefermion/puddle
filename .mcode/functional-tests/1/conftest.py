"""Shared fixtures and helpers for puddle functional tests."""
import os
import subprocess
import time

PUDDLE_DIR = os.path.join(os.environ.get("WORKSPACE_DIR", "/l2l/workspace"), "puddle")
KERL_ACTIVATE = os.path.expanduser("~/.kerl/installs/27.3/activate")
ESCRIPT_CMD = os.path.expanduser("~/.kerl/installs/27.3/bin/escript")
SCRIPTS_DIR = os.path.join(os.path.dirname(__file__), "scripts")
ORIGIN_SCRIPTS_DIR = os.path.join(SCRIPTS_DIR)
TARGET_SCRIPTS_DIR = os.path.join(SCRIPTS_DIR, "target")


def run_escript(name, scripts_dir=None, timeout=60):
    """Run an Erlang escript against the compiled puddle BEAM modules.

    The escript adds code paths via code:add_paths(filelib:wildcard(...))
    so it needs the CWD to be the puddle repo root.
    """
    if scripts_dir is None:
        scripts_dir = TARGET_SCRIPTS_DIR
    script_path = os.path.join(scripts_dir, name)

    env = os.environ.copy()
    # Ensure OTP 27 is on the PATH
    kerl_bin = os.path.expanduser("~/.kerl/installs/27.3/bin")
    env["PATH"] = kerl_bin + ":" + env.get("PATH", "")

    start = time.time()
    result = subprocess.run(
        [ESCRIPT_CMD, script_path],
        capture_output=True,
        text=True,
        timeout=timeout,
        cwd=PUDDLE_DIR,
        env=env,
    )
    result.duration_ms = (time.time() - start) * 1000
    return result


def run_origin_escript(name, timeout=60):
    """Run an escript from the origin (root) scripts directory."""
    return run_escript(name, scripts_dir=ORIGIN_SCRIPTS_DIR, timeout=timeout)


def run_target_escript(name, timeout=60):
    """Run an escript from the target scripts directory."""
    return run_escript(name, scripts_dir=TARGET_SCRIPTS_DIR, timeout=timeout)
