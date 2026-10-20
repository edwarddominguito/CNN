import os
import sys
from pathlib import Path


def use_local_venv():
    # scripts/python_env.py -> scripts/ -> backend/, where .venv lives.
    base_dir = Path(__file__).resolve().parents[1]
    os.environ.setdefault("MPLCONFIGDIR", str(base_dir / ".matplotlib_cache"))
    os.environ.setdefault("TF_CPP_MIN_LOG_LEVEL", "2")

    venv_python = base_dir / ".venv" / "Scripts" / "python.exe"
    if not venv_python.exists():
        return

    target = venv_python.resolve()
    if Path(sys.executable).resolve() == target:
        return

    try:
        os.execv(str(target), [str(target), *sys.orig_argv[1:]])
    except OSError as error:
        raise SystemExit(
            f"Could not restart with the project's Python ({target}): {error}\n"
            "Recreate the virtual environment in backend/.venv and install "
            "requirements.txt."
        ) from error
