"""Inventory a repository's unfinished work. Run it with python3 -I."""

import sys
from pathlib import Path

# The skill root, so `scripts.unfinishedlib` imports however the script is started.
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from scripts.unfinishedlib.cli import main  # noqa: E402

if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
