import os
import sys
from pathlib import Path

# Compliance/main.py imports as `main`; tests live under Compliance/tests/.
# Make the parent dir importable without depending on packaging.
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

# Force the audit-log writer into the no-op branch — tests don't carry a Mongo.
os.environ.pop("MONGO_URI", None)
os.environ.pop("MONGO_URL", None)
