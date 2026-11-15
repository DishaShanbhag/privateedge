"""Load a config YAML, resolving its `inherits:` chain (child keys override parent keys)."""
from pathlib import Path

import yaml


def _merge(base, over):
    out = dict(base)
    for k, v in over.items():
        out[k] = _merge(out[k], v) if isinstance(v, dict) and isinstance(out.get(k), dict) else v
    return out


def load_config(path):
    path = Path(path)
    cfg = yaml.safe_load(path.read_text()) or {}
    parent = cfg.pop("inherits", None)
    if parent:
        cfg = _merge(load_config(path.parent / parent), cfg)
    cfg["name"] = path.stem
    return cfg
