import os
import sys
from pathlib import Path


def use_local_venv():
    base_dir = Path(__file__).resolve().parent
    venv_python = base_dir / ".venv" / "Scripts" / "python.exe"

    if not venv_python.exists():
        return

    current_python = Path(sys.executable).resolve()
    target_python = venv_python.resolve()

    if current_python == target_python:
        return

    os.execv(str(target_python), [str(target_python), *sys.argv])
