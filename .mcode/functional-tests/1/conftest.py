"""Shared fixtures and helpers for puddle functional tests."""
import os
import subprocess

PUDDLE_DIR = os.path.join(os.environ.get("WORKSPACE_DIR", "/l2l/workspace"), "puddle")
ESCRIPT_CMD = os.path.expanduser("~/.kerl/installs/27.3/bin/escript")
SCRIPTS_DIR = os.path.join(os.path.dirname(__file__), "scripts")


def run_escript(name, timeout=60):
    """Run an Erlang escript against the compiled puddle BEAM modules.

    The escript adds code paths via code:add_paths(filelib:wildcard(...))
    so it needs the CWD to be the puddle repo root.
    """
    script_path = os.path.join(SCRIPTS_DIR, name)
    result = subprocess.run(
        [ESCRIPT_CMD, script_path],
        capture_output=True,
        text=True,
        timeout=timeout,
        cwd=PUDDLE_DIR,
    )
    return result
